import AppKit
import AuspexCore
import QuartzCore
import SwiftUI

// What makes Now's lists look alive without making them expensive: the
// stopwatches on the rows that are about *now* move every second, a working
// row's dot breathes, and all of it stops the moment the window cannot be
// seen.
//
// Each piece is a leaf. A stopwatch is a `TimelineView` around one `Text`, so
// a tick re-evaluates that `Text` and nothing above it; a breathing dot is a
// Core Animation layer, so it costs the app nothing per frame at all. The
// rows themselves are still compared once per board frame and redrawn only
// when their values move.

// MARK: - Whether the window can be seen

extension EnvironmentValues {
    /// Whether the window Now is drawn in can be seen. The live stopwatches
    /// tick and the dots breathe only while it is true.
    @Entry var nowIsVisible = false
}

/// A zero-sized view that reports whether its window is on screen — ordered
/// in, not miniaturised, not wholly covered.
///
/// Occlusion rather than key status, for the reason ``SurfaceVisibilityProbe``
/// gives: a board on a second display is being read without being key.
struct NowWindowProbe: NSViewRepresentable {
    let onChange: (Bool) -> Void

    func makeNSView(context: Context) -> ProbeView { ProbeView(onChange: onChange) }

    func updateNSView(_ view: ProbeView, context: Context) { view.onChange = onChange }

    final class ProbeView: NSView {
        var onChange: (Bool) -> Void
        private var observers: [any NSObjectProtocol] = []
        private var reported: Bool?

        init(onChange: @escaping (Bool) -> Void) {
            self.onChange = onChange
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
                    NSWindow.didMiniaturizeNotification,
                    NSWindow.didDeminiaturizeNotification,
                ]
                observers = names.map { name in
                    NotificationCenter.default.addObserver(
                        forName: name, object: window, queue: .main
                    ) { [weak self] _ in
                        MainActor.assumeIsolated { self?.refresh() }
                    }
                }
            }
            refresh()
        }

        private func refresh() {
            let visible = window.map { $0.isVisible && $0.occlusionState.contains(.visible) } ?? false
            guard visible != reported else { return }
            reported = visible
            // Off the layout pass that delivered it: this writes SwiftUI state.
            DispatchQueue.main.async { [weak self] in self?.onChange(visible) }
        }

        isolated deinit {
            for observer in observers { NotificationCenter.default.removeObserver(observer) }
        }
    }
}

// MARK: - A stopwatch that moves

/// A stopwatch for the rows whose time is the point — what is working, and
/// what is waiting for the reader — with whatever follows it in its cell.
///
/// Ticks every second while the window can be seen and the reading still has
/// seconds in it — its first ten minutes, see ``NowFrame/compactDuration(_:)``.
/// Past that the reading is in minutes, and the board's five-second clock
/// turns it over like every other stopwatch on the page.
///
/// ## Why the tick does not go through SwiftUI
///
/// The obvious leaf — a `TimelineView` around one `Text` — re-evaluates only
/// that `Text`, and still costs an update of the window's whole view graph
/// per tick. Measured on the three-working-sessions demo with the stage off,
/// four rows ticking on their own seconds added 3.5 % process CPU, and the
/// same rows aligned to one shared second still 1.5 % — as much as the rest
/// of the lists together. So the words are an AppKit label the size of its
/// cell, and one timer for the whole screen sets the labels that are on it;
/// SwiftUI lays the cell out once and never hears about a tick. The label
/// never changes size, so a tick never asks for a layout either.
struct NowLiveElapsed: NSViewRepresentable {
    let since: Date
    /// What follows the reading in the same cell — ` · ↳2` on a working row.
    var suffix: String = ""

    @Environment(\.nowIsVisible) private var isVisible
    @Environment(BoardClock.self) private var clock: BoardClock?
    @Environment(\.colorScheme) private var colorScheme

    func makeNSView(context: Context) -> NowLiveLabel { NowLiveLabel() }

    func updateNSView(_ label: NowLiveLabel, context: Context) {
        label.configure(
            since: since,
            suffix: suffix,
            color: AuspexPalette.nsColor(.text3, dark: colorScheme == .dark),
            // Read so the five-second clock still turns the reading over
            // when the label is not ticking on its own.
            now: clock?.now ?? Date(),
            ticks: isVisible
        )
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize, nsView: NowLiveLabel, context: Context
    ) -> CGSize? {
        CGSize(width: proposal.width ?? 64, height: NowLiveLabel.height)
    }

    static func dismantleNSView(_ label: NowLiveLabel, coordinator: ()) {
        NowSecondTicker.shared.remove(label)
    }

    /// Whether a stopwatch that has run `elapsed` still shows seconds.
    static func ticksEverySecond(elapsed: TimeInterval) -> Bool {
        elapsed < 600
    }
}

/// The label a live stopwatch draws its words in.
final class NowLiveLabel: NSTextField {
    static let height: CGFloat = 16

    private var since = Date.distantPast
    private var suffix = ""
    private var wantsTicks = false

    init() {
        super.init(frame: .zero)
        isEditable = false
        isSelectable = false
        isBordered = false
        drawsBackground = false
        lineBreakMode = .byTruncatingTail
        maximumNumberOfLines = 1
        font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        setContentHuggingPriority(.defaultLow, for: .horizontal)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    /// A label never asks to be any size: its cell decides, so new words
    /// never cost a layout.
    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: Self.height)
    }

    func configure(since: Date, suffix: String, color: NSColor, now: Date, ticks: Bool) {
        self.since = since
        self.suffix = suffix
        if textColor != color { textColor = color }
        wantsTicks = ticks
        refresh(now: now)
        updateRegistration()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateRegistration()
    }

    /// Whether the shared second should set this label: it is in a window
    /// that can be seen, and its reading still has seconds in it.
    var ticks: Bool {
        wantsTicks && window != nil
            && NowLiveElapsed.ticksEverySecond(elapsed: Date().timeIntervalSince(since))
    }

    private func updateRegistration() {
        if ticks {
            NowSecondTicker.shared.add(self)
        } else {
            NowSecondTicker.shared.remove(self)
        }
    }

    /// Sets the words for `now`, when they changed.
    func refresh(now: Date) {
        let text = NowFrame.compactDuration(now.timeIntervalSince(since)) + suffix
        guard text != stringValue else { return }
        stringValue = text
        NowBodyCounter.count(.stopwatch)
    }
}

/// One clock for every live stopwatch on screen.
///
/// A single repeating timer on the whole second, running only while some
/// label wants it: the screen's stopwatches turn over together, in one Core
/// Animation commit, and a window with none — or one nobody can see — has no
/// timer at all.
@MainActor
final class NowSecondTicker: NSObject {
    static let shared = NowSecondTicker()

    private let labels = NSHashTable<NowLiveLabel>.weakObjects()
    private var timer: DispatchSourceTimer?

    /// Whether the timer is running. For the tests.
    var isRunning: Bool { timer != nil }

    func add(_ label: NowLiveLabel) {
        guard !labels.contains(label) else { return }
        labels.add(label)
        startIfNeeded()
    }

    func remove(_ label: NowLiveLabel) {
        guard labels.contains(label) else { return }
        labels.remove(label)
        if labels.allObjects.isEmpty { stop() }
    }

    private func startIfNeeded() {
        guard timer == nil else { return }
        // On the main queue rather than the run loop, so it fires in every
        // mode — a scroll in progress included — and lands on the whole
        // second, give or take the leeway.
        let timer = DispatchSource.makeTimerSource(queue: .main)
        let now = Date().timeIntervalSinceReferenceDate
        let wait = now.rounded(.down) + 1 - now
        timer.schedule(
            deadline: .now() + wait, repeating: 1, leeway: .milliseconds(50)
        )
        timer.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer.resume()
        self.timer = timer
    }

    private func stop() {
        timer?.cancel()
        timer = nil
    }

    private func tick() {
        let now = Date()
        for label in labels.allObjects {
            guard label.ticks else {
                // Past ten minutes, or out of its window: the board's clock
                // has it from here.
                labels.remove(label)
                continue
            }
            label.refresh(now: now)
        }
        if labels.allObjects.isEmpty { stop() }
    }
}

// MARK: - A dot that breathes

/// A working row's status dot, breathing.
///
/// A Core Animation layer with one repeating opacity animation, rather than a
/// SwiftUI animation: the render server runs it, so the app does no work per
/// frame and SwiftUI never re-evaluates the row for it. Still under Reduce
/// Motion, and while the window cannot be seen.
struct NowBreathingDot: NSViewRepresentable {
    let size: CGFloat

    @Environment(\.nowIsVisible) private var isVisible
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme

    func makeNSView(context: Context) -> DotView { DotView() }

    func updateNSView(_ view: DotView, context: Context) {
        view.configure(
            color: AuspexPalette.nsColor(.text, dark: colorScheme == .dark),
            breathes: isVisible && !reduceMotion
        )
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: DotView, context: Context) -> CGSize? {
        CGSize(width: size, height: size)
    }

    final class DotView: NSView {
        private let dot = CALayer()
        private var breathes = false

        /// The breath: down to a third and back, a little over two seconds
        /// a cycle — slow enough to read as alive rather than as a warning.
        static let animationKey = "breath"

        init() {
            super.init(frame: .zero)
            wantsLayer = true
            layer?.addSublayer(dot)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { nil }

        override func layout() {
            super.layout()
            dot.frame = bounds
            dot.cornerRadius = min(bounds.width, bounds.height) / 2
        }

        func configure(color: NSColor, breathes: Bool) {
            dot.backgroundColor = color.cgColor
            guard breathes != self.breathes else { return }
            self.breathes = breathes
            if breathes {
                let breath = CABasicAnimation(keyPath: "opacity")
                breath.fromValue = 1
                breath.toValue = 0.35
                breath.duration = 1.1
                breath.autoreverses = true
                breath.repeatCount = .infinity
                breath.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                dot.add(breath, forKey: Self.animationKey)
            } else {
                dot.removeAnimation(forKey: Self.animationKey)
            }
        }

        /// Whether the dot is breathing. For the tests.
        var isBreathing: Bool { dot.animation(forKey: Self.animationKey) != nil }
    }
}

// MARK: - Counting

/// How many times the lists' rows and stopwatches were evaluated — the
/// evidence that a stopwatch's tick reaches its own `Text` and not the row
/// around it. Off unless a test turns it on.
@MainActor
enum NowBodyCounter {
    enum Part: Hashable {
        case row
        case stopwatch
    }

    static var isEnabled = false
    private(set) static var counts: [Part: Int] = [:]

    static func count(_ part: Part) {
        guard isEnabled else { return }
        counts[part, default: 0] += 1
    }

    static func reset() { counts = [:] }
}
