import AppKit
import SwiftUI

/// Whether anything that draws the board is on screen right now.
///
/// Auspex spends most of its life with no window showing: the person glances
/// at the menu bar and opens the board when something needs them. The
/// registry's frames are for whoever is drawing them, so it publishes at a
/// fraction of the rate while nobody is — see
/// `SessionRegistry.setObserved(_:)`. This is where the answer comes from.
///
/// Each surface that draws the board carries a ``SurfaceVisibilityProbe``;
/// the probe reports whether its window is actually visible on screen —
/// ordered in, not miniaturised, not fully covered — and the board counts as
/// observed while any of them is. A count of probes rather than a flag per
/// kind of surface, because a `WindowGroup` can open the board more than once.
@MainActor
final class SurfaceVisibility {
    /// The probes whose window is visible.
    private var visible: Set<ObjectIdentifier> = []

    /// `true` while at least one surface that draws the board is on screen.
    private(set) var isObserved = false

    /// Every change of ``isObserved``, in order, starting with the current
    /// value. Single-consumer; the environment forwards it to the registry.
    let changes: AsyncStream<Bool>
    private let continuation: AsyncStream<Bool>.Continuation

    init() {
        let (stream, continuation) = AsyncStream<Bool>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        changes = stream
        self.continuation = continuation
        continuation.yield(false)
    }

    /// Records what one probe sees.
    func report(_ probe: ObjectIdentifier, isVisible: Bool) {
        if isVisible {
            visible.insert(probe)
        } else {
            visible.remove(probe)
        }
        let observed = !visible.isEmpty
        guard observed != isObserved else { return }
        isObserved = observed
        continuation.yield(observed)
    }
}

/// A zero-sized view that tells a ``SurfaceVisibility`` whether the window it
/// sits in can be seen.
///
/// Occlusion rather than key or main status: a board on a second display, or
/// beside the editor a person is typing into, is being looked at without being
/// key. And occlusion rather than `scenePhase`, because the menu bar's panel
/// and a covered window are exactly the two cases a scene phase does not
/// distinguish.
struct SurfaceVisibilityProbe: NSViewRepresentable {
    let visibility: SurfaceVisibility

    func makeNSView(context: Context) -> ProbeView {
        ProbeView(visibility: visibility)
    }

    func updateNSView(_ view: ProbeView, context: Context) {}

    final class ProbeView: NSView {
        private let visibility: SurfaceVisibility
        private var observers: [any NSObjectProtocol] = []

        init(visibility: SurfaceVisibility) {
            self.visibility = visibility
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            for observer in observers { NotificationCenter.default.removeObserver(observer) }
            observers.removeAll()
            if let window {
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
            }
            refresh(closing: false)
        }

        private func refresh(closing: Bool) {
            let isVisible = !closing
                && window.map { $0.isVisible && $0.occlusionState.contains(.visible) } ?? false
            visibility.report(ObjectIdentifier(self), isVisible: isVisible)
        }

        isolated deinit {
            for observer in observers { NotificationCenter.default.removeObserver(observer) }
            visibility.report(ObjectIdentifier(self), isVisible: false)
        }
    }
}
