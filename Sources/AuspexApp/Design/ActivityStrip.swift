import AppKit
import AuspexCore
import QuartzCore
import SwiftUI

/// The strip along the bottom of every session card, and the only animated
/// element on the whole board.
///
/// ## What it is for
///
/// A wall of forty cards cannot be read by reading forty cards. It is read the
/// way an instrument panel is read: peripherally, for the thing that is
/// behaving differently. Colour alone does not survive peripheral vision
/// well — motion does. So each state gets a distinct rhythm on one shared
/// strip, and a person learns the wall in about a minute: a slow breath is
/// thinking, a travelling highlight is a tool, a row of ticks stepping in
/// sequence is a session with children.
///
/// ## Why it is not a SwiftUI animation
///
/// It used to be, and it was the most expensive thing in the app.
///
/// The strip was a pure function of a 4 Hz phase from ``BoardClock``, with a
/// 250 ms implicit animation smoothing the steps. A new phase arrives every
/// 250 ms and the animation lasts 250 ms, so an animation was *always* in
/// flight — and SwiftUI drives an in-flight animation by rebuilding that
/// subtree's display list on every display frame. AppKit then answers a view
/// graph that is dirty on every display cycle by re-asking the window for its
/// minimum size, which is a `sizeThatFits` over the whole window. A board with
/// a few dozen running sessions therefore paid for a full-window layout sixty
/// times a second, forever.
///
/// Measured with `top -l 4 -s 5` and three `sample <pid> 3` per run, release
/// builds, live against the real store, the two builds launched alternately so
/// that whatever else the machine was doing — several agents' sessions writing
/// transcripts, and other copies of this app — landed on both arms equally.
/// Both arms are *moving*: the display was locked throughout, so the Core
/// Animation build was measured with its occlusion pause switched off, which is
/// the only way to compare motion against motion rather than motion against a
/// held frame.
///
/// | strips | main thread busy | process CPU |
/// | --- | --- | --- |
/// | SwiftUI animation (what this replaces) | 39–43 % | 48–61 % |
/// | Core Animation (this) | 3–8 % | 24–52 % |
///
/// The main thread is the column to read. Process CPU on that machine was
/// dominated by `LiveBoardModel.rebuildVisibleBoard`, which has nothing to do
/// with the strips and which both arms paid in full; what changed is that the
/// main thread stopped being the busiest thread in the process at all — under
/// the old strips it carried more samples than any other thread, and under
/// these it does not place in the top six. An earlier measurement of the same
/// two behaviours on a quiet machine put them at 19.8–20.8 % against 1.2–1.6 %
/// busy, so neither pair of absolute numbers travels but the ratio does.
///
/// Moving the animated property from a fill's alpha to a view `.opacity(_:)`
/// changed nothing, because the cost is not *what* SwiftUI animates — it is
/// that SwiftUI is animating at all. So the motion leaves the view graph
/// entirely: ``ActivityStripView`` is an `NSView` with a `CAGradientLayer` and
/// `CABasicAnimation`s that repeat forever. Core Animation runs them on the
/// render server, and the main thread does nothing per frame — nothing at all,
/// not even a display-list rebuild.
///
/// What has to stay true for that to hold:
///
/// - **Nothing above the strip may read a clock.** There is no clock left to
///   read: the animations carry their own time.
/// - **Only a strip that moves gets a layer.** Idle, ended, stale and needs-you
///   are one rectangle that never changes, and SwiftUI draws that for free —
///   for nothing per frame, and for no `NSView` either. A wall of four hundred
///   finished sessions therefore hosts no platform views at all, and the ones
///   it does host inherit nothing they should not: a card SwiftUI is fading or
///   desaturating is by definition one whose strip is not in a layer.
/// - **`updateNSView` must not touch the layer unless something changed.**
///   Re-applying an animation restarts it, so a card that redraws for an
///   unrelated reason would visibly reset its strip. The coordinator holds the
///   last ``StripSpec`` and compares.
/// - **The layer must be paused when nothing can see it.** `layer.speed = 0`
///   whenever the strip leaves the window or the window is occluded; Core
///   Animation is cheap but it is not free, and a board behind another window
///   should cost what a board nobody is looking at costs.
///
/// ## What each state does
///
/// One device, four behaviours, and two states that do not move at all:
///
/// - **Thinking** breathes: the whole bar fades between a quarter and four
///   fifths and back, once a second, eased at both ends.
/// - **Tool** and **Writing** sweep: a bright head travels the length of the
///   bar over a dim ground and wraps, in six seconds. Writing's head is
///   tighter, so a file write reads as a busier pass than a shell command.
///   The travel is linear on purpose — an eased sweep reads as scrubbing
///   rather than as progress.
/// - **Delegating** ticks: one cell per running child, lighting in sequence,
///   a quarter of a second each.
/// - **Needs you** is *still*, at full colour. It is the one state a card
///   already shouts about — a red outline and a glow around the whole tile —
///   and a strobing strip under a glowing card was two alarms for one event.
/// - **Idle**, **ended** and any **stale** session are still by definition.
///   A session that is not doing anything must not be the thing that moves.
///
/// ## Reduced motion, and pictures
///
/// Reduce Motion draws every rhythm's resting frame and adds no animation: the
/// sweep's gradient sits where it starts, the breath sits at its dimmest, the
/// ticks show their first cell lit. The information is still there — the
/// colour, the dot and the pill all carry it — and nothing moves.
///
/// The offscreen renderers get the same resting frame, drawn in SwiftUI rather
/// than in a layer, because `ImageRenderer` cannot draw an `NSView` and a
/// screenshot with a blank strip where the board's one moving part should be
/// says nothing true about the app.
struct ActivityStrip: View {
    let motion: StateStyle.Motion
    let color: Color
    /// Desaturates the strip — and stops it — for a session that has gone
    /// quiet.
    var isStale = false
    var height: CGFloat = 6

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isSnapshotRender) private var isSnapshotRender

    var body: some View {
        Group {
            if needsLayer(reduceMotion: reduceMotion, isSnapshotRender: isSnapshotRender) {
                StripLayer(rhythm: rhythm, color: tint, height: height)
            } else {
                StripStill(rhythm: rhythm, color: tint)
            }
        }
        .frame(height: height)
        .frame(maxWidth: .infinity)
        .accessibilityHidden(true)
    }

    /// What this state's strip does, in the terms the layer understands.
    var rhythm: StripRhythm { StripRhythm(motion) }

    /// Whether this strip has to leave the SwiftUI graph at all.
    ///
    /// Only one that actually moves does. Idle, ended, stale, needs-you,
    /// reduced motion and the offscreen renderers are all a shape that never
    /// changes, and a shape that never changes is better off as SwiftUI than as
    /// a hosted `NSView`: it costs no `NSView`, it reads no clock so it is
    /// never re-evaluated, and — the part that is not merely economy — it
    /// inherits the card's own effects. A finished card is drawn at 62 %
    /// opacity and a stale one at 45 % saturation, and neither of those reaches
    /// a platform view that SwiftUI is only hosting. On a real board that is
    /// also most of the wall: the cards that move are the few that are working.
    ///
    /// Takes its environment as arguments so the rule can be checked without a
    /// window, a screen or a render.
    func needsLayer(reduceMotion: Bool, isSnapshotRender: Bool) -> Bool {
        !isSnapshotRender && !reduceMotion && !isStale && rhythm.moves
    }

    private var tint: Color {
        isStale ? color.opacity(0.5) : color
    }
}

// MARK: - What a strip does

/// One strip's behaviour, independent of how it is drawn.
///
/// A small `Equatable` value on purpose: it is what the representable compares
/// to decide whether the layer needs touching, and touching the layer restarts
/// the animation.
enum StripRhythm: Equatable {
    /// A bar at a fixed opacity. Nothing moves.
    case bar(opacity: Double)
    /// The whole bar fades between two opacities and back, once per `period`.
    case breathe(from: Double, to: Double, period: Double)
    /// A bright head crosses a dim ground in `period` seconds and wraps.
    /// `span` is the head's half-width, as a fraction of the bar.
    case sweep(span: Double, period: Double)
    /// `count` cells, one lit at a time, `step` seconds each.
    case ticks(count: Int, step: Double)

    /// How wide a sweep's head is, in twenty-fourths of the bar — the unit
    /// ``StateStyle/Motion/sweep(width:)`` is written in.
    private static let sweepSteps = 24.0

    init(_ motion: StateStyle.Motion) {
        switch motion {
        case .steady(let opacity):
            self = .bar(opacity: opacity)
        case .breathe:
            self = .breathe(from: 0.25, to: 0.8, period: 1)
        case .sweep(let width):
            self = .sweep(span: Double(width) / Self.sweepSteps, period: 6)
        case .strobe:
            // Still, and bright. The card this sits on already carries a red
            // outline and a glow for this state; a strobing strip under it was
            // the same alarm sounded twice.
            self = .bar(opacity: 0.9)
        case .ticks(let count):
            // One child is a lit cell, not a sequence: there is nothing for the
            // light to travel between.
            self = count > 1 ? .ticks(count: count, step: 0.25) : .bar(opacity: 0.95)
        }
    }

    /// Whether this rhythm has anything to animate.
    var moves: Bool {
        switch self {
        case .bar: false
        case .breathe, .sweep, .ticks: true
        }
    }

    /// The dim ground a sweep's head travels over.
    static let sweepGround = 0.16
    /// A tick that is not the lit one.
    static let tickDim = 0.22
    /// The lit tick.
    static let tickLit = 0.95
    /// The gap between ticks, in points.
    static let tickGap = 3.0
}

// MARK: - The resting frame, in SwiftUI

/// Every rhythm's first frame, drawn without a layer.
///
/// This is what most of the wall actually is — every state that does not move,
/// every stale card, Reduce Motion, and the offscreen renderers, which cannot
/// draw an `NSView` at all. It is deliberately the *same* picture the layer
/// shows before its animation starts, so a screenshot is the board at t = 0
/// rather than a different design, and a session going quiet mid-sweep does not
/// change shape as it hands the strip back to SwiftUI.
private struct StripStill: View {
    let rhythm: StripRhythm
    let color: Color

    var body: some View {
        switch rhythm {
        case .bar(let opacity):
            bar(opacity)
        case .breathe(let from, _, _):
            bar(from)
        case .sweep(let span, _):
            bar(StripRhythm.sweepGround)
                .overlay {
                    RoundedRectangle(cornerRadius: 1, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [color.opacity(0), color, color.opacity(0)],
                                startPoint: UnitPoint(x: -span, y: 0.5),
                                endPoint: UnitPoint(x: span, y: 0.5)
                            )
                        )
                }
        case .ticks(let count, _):
            HStack(spacing: StripRhythm.tickGap) {
                ForEach(0..<count, id: \.self) { index in
                    bar(index == 0 ? StripRhythm.tickLit : StripRhythm.tickDim)
                }
            }
        }
    }

    private func bar(_ opacity: Double) -> some View {
        RoundedRectangle(cornerRadius: 1, style: .continuous)
            .fill(color.opacity(opacity))
    }
}

// MARK: - The moving strip, in Core Animation

/// Everything a strip's layers need, and nothing that changes without the
/// strip needing to change with it.
///
/// A card is re-rendered whenever anything on it moves — a token count, a line
/// of transcript — and `updateNSView` runs on every one of those. Re-applying
/// an animation restarts it, so a strip would visibly jump back to its first
/// frame every time the session it belongs to said anything. This is what the
/// coordinator compares to keep that from happening.
struct StripSpec: Equatable {
    var rhythm: StripRhythm
    var color: Color
}

/// The bridge to ``ActivityStripView``.
private struct StripLayer: NSViewRepresentable {
    let rhythm: StripRhythm
    let color: Color
    let height: CGFloat

    @MainActor
    final class Coordinator {
        var applied: StripSpec?
    }

    private var spec: StripSpec { StripSpec(rhythm: rhythm, color: color) }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> ActivityStripView {
        let view = ActivityStripView()
        let spec = spec
        context.coordinator.applied = spec
        view.apply(spec)
        return view
    }

    func updateNSView(_ view: ActivityStripView, context: Context) {
        let spec = spec
        guard context.coordinator.applied != spec else { return }
        context.coordinator.applied = spec
        view.apply(spec)
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        nsView: ActivityStripView,
        context: Context
    ) -> CGSize? {
        CGSize(width: proposal.width ?? 10, height: height)
    }
}

/// The strip itself: two layers and, when there are children to show, a row of
/// small ones.
///
/// Every animation is added once, repeats forever, and is never removed. The
/// main thread's whole involvement in the board's motion is this class's
/// ``apply(_:)``, which runs when a session changes state, and ``layout()``,
/// which runs when a card is resized.
///
/// The three layers are not `private` because the tests read them. There is no
/// other way to check this: a strip with the wrong duration, or one that has
/// quietly stopped repeating, looks exactly like a correct one in a screenshot,
/// and a screenshot is all an `NSView` full of Core Animation offers from the
/// outside.
final class ActivityStripView: NSView {
    /// The bar, or the dim ground a sweep's head travels over.
    let ground = CALayer()
    /// The travelling head. Hidden unless the rhythm is a sweep.
    let head = CAGradientLayer()
    /// One per running child, for a delegating session.
    private(set) var ticks: [CALayer] = []

    private var spec: StripSpec?
    private var occlusion: (any NSObjectProtocol)?

    /// One key for every animation, so re-applying replaces rather than layers.
    static let animationKey = "auspex.strip"
    private static let cornerRadius: CGFloat = 1

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = false
        for sublayer in [ground, head] as [CALayer] {
            sublayer.cornerRadius = Self.cornerRadius
            sublayer.cornerCurve = .continuous
            sublayer.anchorPoint = .zero
            layer?.addSublayer(sublayer)
        }
        head.isHidden = true
        head.locations = [0, 0.5, 1]
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    /// Nothing here draws with `NSView`, so it never needs a redraw pass.
    override var wantsUpdateLayer: Bool { true }

    /// Invisible to the mouse. The strip sits inside a card whose whole surface
    /// selects the session, and an `NSView` hosted in the middle of that would
    /// otherwise eat every click that landed on the bottom six points of it.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    // MARK: Applying a state

    /// Rebuilds the layers and their animations for one state.
    ///
    /// Called when the session's state, its colour, or whether it may move
    /// changes — which on a live board is a few times a minute per card, not a
    /// few times a second.
    func apply(_ spec: StripSpec) {
        self.spec = spec
        // Implicit actions off: setting a colour or a frame on a layer that is
        // not a view's own backing layer animates it by default, and a strip
        // that cross-faded every time a session changed state would be a second
        // animation nobody asked for.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        rebuild(spec)
        layoutSublayers()
        CATransaction.commit()
        refreshClock()
    }

    private func rebuild(_ spec: StripSpec) {
        let colour = NSColor(spec.color).cgColor
        let clear = NSColor(spec.color).withAlphaComponent(0).cgColor
        let scale = window?.backingScaleFactor ?? layer?.contentsScale ?? 2

        ground.removeAllAnimations()
        head.removeAllAnimations()
        for tick in ticks { tick.removeFromSuperlayer() }
        ticks = []
        ground.isHidden = false
        head.isHidden = true
        ground.backgroundColor = colour

        switch spec.rhythm {
        case .bar(let opacity):
            ground.opacity = Float(opacity)

        case .breathe(let from, let to, let period):
            ground.opacity = Float(from)
            let breath = CABasicAnimation(keyPath: "opacity")
            breath.fromValue = from
            breath.toValue = to
            // Half a period out, half a period back.
            breath.duration = period / 2
            breath.autoreverses = true
            breath.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            ground.add(Self.forever(breath), forKey: Self.animationKey)

        case .sweep(let span, let period):
            ground.opacity = Float(StripRhythm.sweepGround)
            head.isHidden = false
            head.opacity = 1
            head.colors = [clear, colour, clear]
            head.startPoint = CGPoint(x: -span, y: 0.5)
            head.endPoint = CGPoint(x: span, y: 0.5)
            // The head is a gradient whose *axis* travels, which is what the
            // SwiftUI version animated too — so the picture is the same one,
            // moved by the render server instead of by us. Linear, because an
            // eased sweep reads as scrubbing rather than as progress.
            let start = CABasicAnimation(keyPath: "startPoint")
            start.fromValue = CGPoint(x: -span, y: 0.5)
            start.toValue = CGPoint(x: 1 - span, y: 0.5)
            let end = CABasicAnimation(keyPath: "endPoint")
            end.fromValue = CGPoint(x: span, y: 0.5)
            end.toValue = CGPoint(x: 1 + span, y: 0.5)
            for step in [start, end] {
                step.duration = period
                step.timingFunction = CAMediaTimingFunction(name: .linear)
            }
            let travel = CAAnimationGroup()
            travel.animations = [start, end]
            travel.duration = period
            head.add(Self.forever(travel), forKey: Self.animationKey)

        case .ticks(let count, let step):
            ground.isHidden = true
            let keyTimes = (0...count).map { NSNumber(value: Double($0) / Double(count)) }
            for index in 0..<count {
                let tick = CALayer()
                tick.cornerRadius = Self.cornerRadius
                tick.cornerCurve = .continuous
                tick.anchorPoint = .zero
                tick.contentsScale = scale
                tick.backgroundColor = colour
                tick.opacity = Float(index == 0 ? StripRhythm.tickLit : StripRhythm.tickDim)
                layer?.addSublayer(tick)
                ticks.append(tick)
                // The light is at cell `j` at time `j / count`, so every tick
                // runs the same loop with its own values. One animation per
                // tick rather than one shared clock, because the render server
                // has no trouble keeping eight of them in step and the main
                // thread would.
                let pulse = CAKeyframeAnimation(keyPath: "opacity")
                pulse.values = (0...count).map {
                    $0 % count == index ? StripRhythm.tickLit : StripRhythm.tickDim
                }
                pulse.keyTimes = keyTimes
                pulse.duration = step * Double(count)
                pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                tick.add(Self.forever(pulse), forKey: Self.animationKey)
            }
        }
    }

    /// The two settings that make an animation outlive its first run.
    private static func forever(_ animation: CAAnimation) -> CAAnimation {
        animation.repeatCount = .infinity
        animation.isRemovedOnCompletion = false
        animation.fillMode = .both
        return animation
    }

    // MARK: Geometry

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layoutSublayers()
        CATransaction.commit()
    }

    private func layoutSublayers() {
        ground.bounds = CGRect(origin: .zero, size: bounds.size)
        head.bounds = ground.bounds
        guard !ticks.isEmpty else { return }
        let gaps = StripRhythm.tickGap * CGFloat(ticks.count - 1)
        let width = max(1, (bounds.width - gaps) / CGFloat(ticks.count))
        for (index, tick) in ticks.enumerated() {
            tick.bounds = CGRect(x: 0, y: 0, width: width, height: bounds.height)
            tick.position = CGPoint(x: (width + StripRhythm.tickGap) * CGFloat(index), y: 0)
        }
    }

    /// Pixel-aligned on the display the window is actually on. A 6 pt strip
    /// with a 1 pt radius is small enough that drawing it at the wrong scale
    /// is visible as a soft edge.
    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        let scale = window?.backingScaleFactor ?? 2
        layer?.contentsScale = scale
        ground.contentsScale = scale
        head.contentsScale = scale
        for tick in ticks { tick.contentsScale = scale }
    }

    // MARK: Running only when it can be seen

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let observer = occlusion {
            NotificationCenter.default.removeObserver(observer)
            occlusion = nil
        }
        if let window {
            occlusion = NotificationCenter.default.addObserver(
                forName: NSWindow.didChangeOcclusionStateNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshClock() }
            }
        }
        viewDidChangeBackingProperties()
        refreshClock()
    }

    override func viewDidHide() {
        super.viewDidHide()
        refreshClock()
    }

    override func viewDidUnhide() {
        super.viewDidUnhide()
        refreshClock()
    }

    /// Whether this strip's animations should be running at all.
    ///
    /// A card scrolled out of a `LazyVGrid` leaves the view hierarchy, so
    /// `window == nil` covers the wall's own recycling; occlusion covers the
    /// window being behind another one, which is where an all-day app spends
    /// most of its life.
    private var shouldRun: Bool {
        guard let spec, spec.rhythm.moves else { return false }
        guard let window, window.occlusionState.contains(.visible) else { return false }
        return !isHiddenOrHasHiddenAncestor
    }

    private func refreshClock() {
        guard let layer else { return }
        if shouldRun {
            resume(layer)
        } else {
            pause(layer)
        }
    }

    /// Freezes the layer's time where it stands, so resuming picks the rhythm
    /// up rather than restarting it.
    private func pause(_ layer: CALayer) {
        guard layer.speed != 0 else { return }
        let stopped = layer.convertTime(CACurrentMediaTime(), from: nil)
        layer.speed = 0
        layer.timeOffset = stopped
    }

    private func resume(_ layer: CALayer) {
        guard layer.speed == 0 else { return }
        let stopped = layer.timeOffset
        layer.speed = 1
        layer.timeOffset = 0
        layer.beginTime = 0
        layer.beginTime = layer.convertTime(CACurrentMediaTime(), from: nil) - stopped
    }

    /// Isolated so it may touch the observer token, which is not `Sendable`.
    /// The view is main-actor bound and so is everything it holds.
    isolated deinit {
        if let occlusion { NotificationCenter.default.removeObserver(occlusion) }
    }
}

/// A stopwatch that is driven by the board's clock rather than by one of its
/// own.
///
/// It reads ``BoardClock/now`` and nothing else, so it is invalidated once a
/// second — and a session that has ended reads nothing at all, because its
/// duration is fixed and a frozen number does not need a clock to tell it so.
struct ElapsedLabel: View {
    /// When the interval being measured began.
    let since: Date?
    /// When it stopped, for a session that is over. `nil` while it is running.
    var until: Date?
    var font: Font = AuspexType.monoClock
    var tint: Color = AuspexPalette.text

    var body: some View {
        Group {
            if let since {
                if let until {
                    Text(DurationFormat.clock(until.timeIntervalSince(since)))
                } else {
                    RunningElapsed(since: since)
                }
            } else {
                Text(verbatim: "--:--")
            }
        }
        .font(font)
        .auspexTabularDigits()
        .foregroundStyle(tint)
    }
}

/// The half of ``ElapsedLabel`` that is actually live.
///
/// The clock's ``BoardClock/now`` is what the duration is measured against,
/// which is both what subscribes this view to the 1 Hz tick and what keeps
/// every stopwatch on the wall showing the same instant.
private struct RunningElapsed: View {
    let since: Date

    @Environment(BoardClock.self) private var clock: BoardClock?

    var body: some View {
        let now = clock?.now ?? Date()
        return Text(DurationFormat.clock(now.timeIntervalSince(since)))
    }
}
