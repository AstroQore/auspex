import AppKit
import AuspexCore
import SwiftUI

/// The countdown that folds Now's stage, and the one timer it needs.
///
/// The rules are ``StageIdleCollapse``'s; this is the part that has a clock.
/// It hears input from a ``StageIdleProbe`` in the window, arms a single
/// one-shot timer for the machine's deadline, and tells its owner when the
/// stage folds or opens — and at no other time, so nothing observes the
/// hundred-a-second pointer moves that feed it.
///
/// ## No timer per input
///
/// Input moves the deadline and leaves the armed timer alone. The timer goes
/// off at the deadline it was armed for; if input has moved the deadline
/// since, the machine says the stage is not idle yet and the timer is armed
/// again for the new one. A person working in the window costs one wake every
/// two and a half minutes, and a person who is not costs one wake in total.
/// Nothing ticks, and nothing is armed while the stage is folded or out of
/// sight.
@MainActor
final class StageIdleController {
    private let clock = ContinuousClock()
    private var machine: StageIdleCollapse
    private var timer: Task<Void, Never>?
    /// When the armed timer goes off.
    private var armedFor: ContinuousClock.Instant?
    /// The probes whose window can see the stage. More than one when the
    /// board is open in two windows.
    private var watchers: Set<ObjectIdentifier> = []

    /// Hears every fold and every open — `true` for folded — and nothing else.
    var onChange: ((Bool) -> Void)?

    /// Starts unwatched: the countdown begins when a window shows the stage.
    init(delay: Duration = StageIdleCollapse.delay) {
        machine = StageIdleCollapse(delay: delay, now: clock.now, isWatched: false)
    }

    /// The countdown's length. Set once, at launch, by a demo that asked for
    /// a shorter one.
    var delay: Duration {
        get { machine.delay }
        set {
            machine.delay = newValue
            rearm()
        }
    }

    var isCollapsed: Bool { machine.isCollapsed }
    /// Whether the chevron folded it, rather than the countdown.
    var isManual: Bool { machine.isManual }
    /// When the stage folds if nothing happens first.
    var deadline: ContinuousClock.Instant? { machine.deadline }
    /// Whether a timer is armed — which is only while somebody can see an
    /// open stage.
    var isArmed: Bool { timer != nil }

    /// A mouse move, click, scroll or key in a window showing the stage.
    ///
    /// The hot path: called for every pointer move. It writes one instant
    /// into a value and, when a timer is already armed, does nothing else.
    func noteActivity() {
        machine.handle(.userActivity, at: clock.now)
        if timer == nil { rearm() }
    }

    /// The stage's chevron.
    func toggleByHand() { send(.manualToggle) }

    /// The folded strip, or anything else that asks for the office back.
    func open() { send(.tapStrip) }

    /// Folds the stage without waiting, as the chevron would. For the
    /// offscreen renderer, which has no hand to click it.
    func collapseByHand() {
        guard !machine.isCollapsed else { return }
        send(.manualToggle)
    }

    /// What one probe sees: whether its window shows the stage.
    func report(_ watcher: ObjectIdentifier, isWatching: Bool) {
        if isWatching {
            watchers.insert(watcher)
        } else {
            watchers.remove(watcher)
        }
        send(.visibility(!watchers.isEmpty))
    }

    private func send(_ event: StageIdleCollapse.Event) {
        let moved = machine.handle(event, at: clock.now)
        rearm()
        if moved { onChange?(machine.isCollapsed) }
    }

    /// Makes the one timer match the machine's deadline.
    private func rearm() {
        guard let deadline = machine.deadline else {
            timer?.cancel()
            timer = nil
            armedFor = nil
            return
        }
        // Set to go off at or before the deadline: when it does, it finds the
        // stage not idle yet and arms again for wherever the deadline has got
        // to. Only a deadline that moved *earlier* — a shorter delay — needs
        // the timer replaced.
        if timer != nil, let armedFor, armedFor <= deadline { return }
        timer?.cancel()
        armedFor = deadline
        timer = Task { [weak self] in
            // A second of tolerance lets the system fold this wake into one it
            // was making anyway; nobody can tell 150 s from 151.
            try? await Task.sleep(until: deadline, tolerance: .seconds(1), clock: .continuous)
            guard !Task.isCancelled else { return }
            self?.fire()
        }
    }

    private func fire() {
        timer = nil
        armedFor = nil
        send(.timerFired)
    }
}

/// A zero-sized view that hears the person's input in its window, and whether
/// that window can be seen, for a ``StageIdleController``.
///
/// ## Listening without taking
///
/// Clicks, scrolls, keys and gestures come from a local event monitor, which
/// sees every event the app dispatches and hands each one straight back — it
/// never consumes one, so nothing the person does lands differently for its
/// being here. Only events addressed to this view's window count: the menu
/// bar's panel and the Settings window are not the board.
///
/// Pointer moves come from a tracking area over the window's content view,
/// owned by this view. A window only produces mouse-moved events for somebody
/// who asked, and asking with a tracking area means they are delivered to
/// this view alone rather than to the window's first responder.
///
/// ## Visibility
///
/// The same occlusion test as ``SurfaceVisibilityProbe``: a covered,
/// minimised or closed window cannot see the stage, so its countdown stops,
/// and starts over when the window can again.
struct StageIdleProbe: NSViewRepresentable {
    let controller: StageIdleController

    func makeNSView(context: Context) -> ProbeView { ProbeView(controller: controller) }

    func updateNSView(_ view: ProbeView, context: Context) {}

    static func dismantleNSView(_ view: ProbeView, coordinator: ()) {
        view.detach()
    }

    final class ProbeView: NSView {
        /// The input that counts, beside pointer moves. Board frames are not
        /// events at all, so they cannot be in it.
        static let inputMask: NSEvent.EventTypeMask = [
            .leftMouseDown, .rightMouseDown, .otherMouseDown,
            .scrollWheel, .keyDown,
            .magnify, .smartMagnify, .rotate, .swipe,
        ]

        private let controller: StageIdleController
        private var monitor: Any?
        private var tracking: NSTrackingArea?
        private weak var trackedView: NSView?
        private var observers: [any NSObjectProtocol] = []

        init(controller: StageIdleController) {
            self.controller = controller
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { nil }

        /// Never the target of a click: it is in the tree to find the window.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            detach()
            guard let window else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: Self.inputMask) { [weak self] event in
                MainActor.assumeIsolated {
                    if let self, let window = self.window, event.window === window {
                        self.controller.noteActivity()
                    }
                }
                return event
            }
            if let content = window.contentView {
                let area = NSTrackingArea(
                    rect: .zero,
                    options: [.mouseMoved, .activeAlways, .inVisibleRect],
                    owner: self,
                    userInfo: nil
                )
                content.addTrackingArea(area)
                tracking = area
                trackedView = content
            }
            let names: [Notification.Name] = [
                NSWindow.didChangeOcclusionStateNotification,
                NSWindow.willCloseNotification,
                NSWindow.didMiniaturizeNotification,
                NSWindow.didDeminiaturizeNotification,
            ]
            observers = names.map { name in
                NotificationCenter.default.addObserver(
                    forName: name, object: window, queue: .main
                ) { [weak self] notification in
                    let closing = notification.name == NSWindow.willCloseNotification
                    MainActor.assumeIsolated { self?.refresh(closing: closing) }
                }
            }
            refresh(closing: false)
        }

        override func mouseMoved(with event: NSEvent) {
            controller.noteActivity()
        }

        /// Lets go of the window: the monitor, the tracking area, the
        /// observers, and this view's say in whether the stage is watched.
        func detach() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            if let tracking { trackedView?.removeTrackingArea(tracking) }
            tracking = nil
            trackedView = nil
            for observer in observers { NotificationCenter.default.removeObserver(observer) }
            observers.removeAll()
            controller.report(ObjectIdentifier(self), isWatching: false)
        }

        private func refresh(closing: Bool) {
            let isVisible = !closing
                && window.map { $0.isVisible && $0.occlusionState.contains(.visible) } ?? false
            controller.report(ObjectIdentifier(self), isWatching: isVisible)
        }

        isolated deinit { detach() }
    }
}
