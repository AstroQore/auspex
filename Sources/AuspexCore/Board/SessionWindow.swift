import AgentSessionKit
import AgentSessionLive
import Foundation

/// How far back the board and the map reach.
///
/// ## Why there is a window at all
///
/// The registry bootstraps a week of sessions, which is right for the *store*:
/// the trace, the search and the task ledger all want that history, and a week
/// of rows is a handful of megabytes. It is wrong for the *picture*. A machine
/// that has been running agents for a week has a dozen live sessions and over
/// a thousand finished ones, and the board and the scene were placing all of
/// them — 1,176 desks in the office, a garden a screen and a half wide, and a
/// camera that had to sit at 6 % zoom to frame it. The map stopped being a map.
///
/// So the surfaces get a recency window and the store keeps its week. Twelve
/// hours by default, which is a working day plus the evening: everything a
/// person has actually been doing is inside it, and a week of history is one
/// menu away rather than one screen wide.
public enum SessionWindow: String, Sendable, Codable, Hashable, CaseIterable, Identifiable {
    case hour
    case sixHours
    case twelveHours
    case day
    case week
    /// Everything the registry loaded. What the board did before there was a
    /// window, and still what somebody looking for a session from Tuesday
    /// wants.
    case all

    public var id: String { rawValue }

    /// What a fresh install gets.
    public static let standard = SessionWindow.twelveHours

    /// How far back it reaches, or `nil` for no limit.
    public var duration: TimeInterval? {
        switch self {
        case .hour: 3_600
        case .sixHours: 6 * 3_600
        case .twelveHours: 12 * 3_600
        case .day: 24 * 3_600
        case .week: 7 * 24 * 3_600
        case .all: nil
        }
    }

    /// What the menu row says.
    public var title: String {
        switch self {
        case .hour: "1 hour"
        case .sixHours: "6 hours"
        case .twelveHours: "12 hours"
        case .day: "24 hours"
        case .week: "7 days"
        case .all: "All"
        }
    }

    /// What the header's button says, once one is chosen. Short, because it
    /// sits beside the grouping menu and the search field in a bar that gives
    /// way at 1,100 points.
    public var shortTitle: String {
        switch self {
        case .hour: "1 h"
        case .sixHours: "6 h"
        case .twelveHours: "12 h"
        case .day: "24 h"
        case .week: "7 d"
        case .all: "All"
        }
    }
}

/// One board, windowed: what is drawn, and how much was left out.
public struct WindowedBoard: Sendable, Equatable {
    /// The frame with the older sessions taken out.
    public let board: BoardSnapshot
    /// How many sessions the window is hiding. The number in the "N older
    /// hidden" hints, and `0` when there is nothing to say.
    public let hidden: Int

    public init(board: BoardSnapshot, hidden: Int) {
        self.board = board
        self.hidden = hidden
    }
}

/// The recency rule: which sessions a window keeps.
///
/// Pure and total — the same board, window and instant always give the same
/// answer — so what the window does is a table of cases rather than something
/// that has to be observed on a running machine.
public enum SessionRecency {
    /// When a session was last doing anything, as far as the board knows.
    ///
    /// `lastEventAt` first because it is what the board sorts on and what a
    /// person means by "active"; `startedAt` behind it for a session that has
    /// been seen but has produced nothing yet.
    public static func lastActiveAt(_ session: SessionSnapshot) -> Date? {
        session.lastEventAt ?? session.startedAt
    }

    /// Whether a session is shown whatever its age.
    ///
    /// Three kinds are, and they are the three the app exists for: something
    /// running, something working, and something blocked on a person. A window
    /// that could hide a session waiting on a permission prompt would be a
    /// window that hides the one card that matters — and the clock it would
    /// hide it by is the clock that has been running *because* nobody answered.
    ///
    /// `state.isActive` covers thinking, tooling, writing, delegating and
    /// waiting; `isAlive` covers a live process that happens to be idle
    /// between turns.
    public static func isExempt(_ session: SessionSnapshot) -> Bool {
        session.isAlive || session.state.isActive
    }

    /// Whether `session` is inside `window` at `now`.
    public static func isVisible(
        _ session: SessionSnapshot,
        in window: SessionWindow,
        now: Date
    ) -> Bool {
        guard let duration = window.duration else { return true }
        if isExempt(session) { return true }
        // A session with no timestamps at all is a record the store knows
        // nothing about the age of. Hiding it would be the window claiming
        // knowledge it does not have, so it stays.
        guard let at = lastActiveAt(session) else { return true }
        return now.timeIntervalSince(at) <= duration
    }

    /// Applies a window to a frame.
    ///
    /// - Parameters:
    ///   - board: the frame as the registry produced it.
    ///   - window: how far back to reach.
    ///   - now: the instant to measure from. The assembler passes the frame's
    ///     own ``BoardSnapshot/generatedAt``, which is what keeps the whole
    ///     derivation a pure function of the frame — and what stops the board
    ///     quietly re-filtering itself between two frames that say the same
    ///     thing.
    public static func apply(
        to board: BoardSnapshot,
        window: SessionWindow,
        now: Date
    ) -> WindowedBoard {
        guard window.duration != nil else { return WindowedBoard(board: board, hidden: 0) }
        let kept = board.filtered { isVisible($0, in: window, now: now) }
        return WindowedBoard(board: kept, hidden: board.sessions.count - kept.sessions.count)
    }

    /// How the "N older hidden" hint reads, or `nil` when nothing is hidden.
    ///
    /// One sentence, written here rather than in the three views that show it —
    /// the collapsed `Ended` header, the scene's garden nameplate, and the
    /// window menu — because three call sites phrasing it their own way is
    /// three chances to disagree about what the number counts.
    public static func hint(hidden: Int, window: SessionWindow) -> String? {
        guard hidden > 0, window != .all else { return nil }
        return hidden == 1
            ? "1 older than \(window.shortTitle), hidden"
            : "\(hidden) older than \(window.shortTitle), hidden"
    }
}
