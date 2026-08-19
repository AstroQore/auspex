import AgentSessionLive
import Foundation

/// What the board does with the sessions that are over.
///
/// ## Why this is a policy and not a filter
///
/// A machine that has been running agents for a week has a few dozen live
/// sessions and several hundred finished ones. Drawing all of them as cards is
/// the single most expensive thing the board could do, and it spends that cost
/// on the least useful rows on the wall: a finished session has no state to
/// watch, nothing to animate, and nothing anybody has to act on.
///
/// So finished sessions leave the grid entirely. They collect in one section
/// at the bottom, drawn as one-line rows, and only the most recent
/// ``collapsedLimit`` of them are drawn at all until the reader asks for the
/// rest. The board's cost then scales with what is *running*, which is the
/// number a person's machine actually bounds.
///
/// ## Why "most recent" is defined here
///
/// A frame's own order already puts finished sessions last and, within them,
/// the most recently active first. Re-deriving that here rather than trusting
/// it is deliberate: the cap is the difference between showing twenty rows and
/// showing four hundred, and a cap applied to an order that quietly changed
/// would silently hide the wrong twenty.
public enum EndedSessions {
    /// How many finished sessions the collapsed section shows.
    ///
    /// Enough to cover the last few hours of a working day, few enough that
    /// the section never becomes the tallest thing on the board.
    public static let collapsedLimit = 20

    /// Divides a set of sessions into the ones still on the board and the ones
    /// that are over, preserving the order of each.
    ///
    /// "Over" is ``SessionState/isEnded`` and nothing else. A session whose
    /// process has gone but whose state is still `thinking` is *stale*, not
    /// finished — it stays in the grid, where the stale tag can say so.
    public static func split(
        _ sessions: [SessionSnapshot]
    ) -> (active: [SessionSnapshot], ended: [SessionSnapshot]) {
        var active: [SessionSnapshot] = []
        var ended: [SessionSnapshot] = []
        active.reserveCapacity(sessions.count)
        for session in sessions {
            if session.state.isEnded {
                ended.append(session)
            } else {
                active.append(session)
            }
        }
        return (active, ended)
    }

    /// Finished sessions, most recently finished first.
    ///
    /// Ordered by when they stopped, falling back to their last event and then
    /// to the session key, so the answer is total and does not shuffle between
    /// frames.
    public static func mostRecentFirst(_ ended: [SessionSnapshot]) -> [SessionSnapshot] {
        ended.sorted { lhs, rhs in
            let lhsAt = lhs.endedAt ?? lhs.lastEventAt ?? .distantPast
            let rhsAt = rhs.endedAt ?? rhs.lastEventAt ?? .distantPast
            if lhsAt != rhsAt { return lhsAt > rhsAt }
            return lhs.key.description < rhs.key.description
        }
    }

    /// The rows the collapsed section actually draws.
    ///
    /// - Parameters:
    ///   - ended: the finished sessions, in any order.
    ///   - showingAll: `true` once the reader has asked for the whole list.
    ///   - limit: how many to show otherwise.
    public static func visible(
        _ ended: [SessionSnapshot],
        showingAll: Bool,
        limit: Int = collapsedLimit
    ) -> [SessionSnapshot] {
        let ordered = mostRecentFirst(ended)
        guard !showingAll, limit >= 0 else { return ordered }
        return Array(ordered.prefix(limit))
    }

    /// How many finished sessions are not being drawn.
    ///
    /// The number on the "show all" control. `0` means the control has nothing
    /// to offer and should not be there.
    public static func hiddenCount(
        _ ended: [SessionSnapshot],
        showingAll: Bool,
        limit: Int = collapsedLimit
    ) -> Int {
        guard !showingAll, limit >= 0 else { return 0 }
        return max(0, ended.count - limit)
    }
}
