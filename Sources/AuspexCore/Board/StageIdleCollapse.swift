import Foundation

/// Whether Now's office stage is open, or folded into its one-line strip —
/// and when it folds on its own.
///
/// ## Why the stage folds
///
/// The stage is the one part of Now with a clock, and Now is the screen that
/// sits open beside the editor all day. A person who has not touched the
/// window for a while is not watching the office move; they are glancing at
/// the lists, or not looking at all. So after ``delay`` with no input the
/// stage folds into a strip that says how many are working and how many need
/// the person, and the office — its `SKView`, its clock, the reduced board it
/// is laid out from — leaves the window until somebody clicks the strip.
///
/// ## The rules
///
/// - The stage opens expanded.
/// - ``delay`` with no mouse, scroll or key input in the window folds it.
///   Board frames are not input: a busy machine whose person has walked away
///   is exactly the case this is for.
/// - The stage's chevron folds it by hand. Either way it stays folded until
///   the strip is clicked; a folded stage has no countdown to be affected by.
/// - Opening it — the strip, or the chevron's counterpart — starts the
///   countdown again from the full delay.
/// - While the window cannot be seen nothing counts, and when it can again
///   the countdown starts from the full delay: the person who just brought the
///   window forward is about to look at it.
///
/// ## A deadline, not a timer restarted per event
///
/// Pointer moves arrive at the display's rate. Restarting a timer for each
/// would be a task cancelled and created a hundred times a second for a
/// countdown that only matters once every two and a half minutes. So this
/// keeps the instant of the last input, the app arms one timer for
/// ``deadline``, and when that timer fires ``handle(_:at:)`` decides whether
/// the deadline has moved since — in which case the app arms again for the new
/// one. A person who keeps working costs one wake per ``delay``.
///
/// A value with no clock of its own: every event carries the instant it
/// happened at, so the whole state machine is tested without waiting.
public struct StageIdleCollapse: Sendable, Equatable {
    public typealias Instant = ContinuousClock.Instant

    /// How long the window goes without input before the stage folds.
    public static let delay: Duration = .seconds(150)

    /// What the stage looks like.
    public enum Presentation: Sendable, Equatable {
        /// The office, at full height.
        case expanded
        /// One line: a tag, two counts, and a chevron to open it again.
        case collapsed
    }

    /// What happened.
    public enum Event: Sendable, Equatable {
        /// A mouse move, click, scroll or key in the window.
        case userActivity
        /// The timer armed for ``deadline`` went off. It may be stale: input
        /// that arrived since moved the deadline without disarming it.
        case timerFired
        /// The stage's own chevron: folds an open stage by hand, and opens a
        /// folded one.
        case manualToggle
        /// The folded strip was clicked.
        case tapStrip
        /// Whether the stage can be seen at all — the window visible, Now the
        /// screen in it, the stage switched on.
        case visibility(Bool)
    }

    /// The countdown's length. A variable so a demo launch can shorten it.
    public var delay: Duration
    /// Open or folded.
    public private(set) var presentation: Presentation = .expanded
    /// Whether the stage was folded by hand rather than by the countdown.
    /// `false` while it is open.
    public private(set) var isManual = false
    /// Whether anybody can see the stage. Nothing counts while they cannot.
    public private(set) var isWatched: Bool
    /// The last input — or the moment the countdown last started over.
    private var lastInput: Instant

    /// - Parameters:
    ///   - now: when the countdown starts.
    ///   - isWatched: whether the stage is on screen yet. The app starts
    ///     unwatched and hears otherwise from the window.
    public init(delay: Duration = Self.delay, now: Instant, isWatched: Bool = true) {
        self.delay = delay
        self.lastInput = now
        self.isWatched = isWatched
    }

    /// Whether the strip is showing instead of the office.
    public var isCollapsed: Bool { presentation == .collapsed }

    /// When the stage folds if nothing else happens first. `nil` while it is
    /// folded, or while nobody can see it — which is when the app holds no
    /// timer at all.
    public var deadline: Instant? {
        guard presentation == .expanded, isWatched else { return nil }
        return lastInput.advanced(by: delay)
    }

    /// Applies one event.
    ///
    /// - Returns: whether the stage folded or opened.
    @discardableResult
    public mutating func handle(_ event: Event, at now: Instant) -> Bool {
        let before = presentation
        switch event {
        case .userActivity:
            // Input while folded does not open the stage: only the strip does.
            // A person scrolling the lists has not asked for the office back.
            if presentation == .expanded { restartCountdown(at: now) }
        case .timerFired:
            guard let deadline, now >= deadline else { break }
            fold(byHand: false)
        case .manualToggle:
            switch presentation {
            case .expanded: fold(byHand: true)
            case .collapsed: open(at: now)
            }
        case .tapStrip:
            // A click on an open stage is input like any other.
            if presentation == .collapsed { open(at: now) } else { restartCountdown(at: now) }
        case .visibility(let watched):
            guard watched != isWatched else { break }
            isWatched = watched
            if watched { lastInput = now }
        }
        return presentation != before
    }

    private mutating func restartCountdown(at now: Instant) {
        if now > lastInput { lastInput = now }
    }

    private mutating func fold(byHand: Bool) {
        presentation = .collapsed
        isManual = byHand
    }

    private mutating func open(at now: Instant) {
        presentation = .expanded
        isManual = false
        lastInput = now
    }

    /// A delay from the command line or the environment, in seconds.
    ///
    /// For demo and test launches only — the caller decides that; this only
    /// reads the number. A second is the floor and an hour the ceiling: a
    /// zero would fold the stage before it was drawn, and nothing longer is a
    /// test anybody waits for.
    public static func delay(seconds raw: String?) -> Duration? {
        guard let raw, let seconds = Double(raw.trimmingCharacters(in: .whitespaces)),
              seconds.isFinite, seconds > 0
        else { return nil }
        return .milliseconds(Int((min(max(seconds, 1), 3_600) * 1_000).rounded()))
    }
}
