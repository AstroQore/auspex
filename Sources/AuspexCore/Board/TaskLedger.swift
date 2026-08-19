import AgentSessionKit
import AgentSessionLive
import Foundation

/// The board as a ledger of assignments rather than a wall of activity.
///
/// The state machine answers *what is this session doing*. Somebody running a
/// dozen sessions across five harnesses needs three answers before that one is
/// worth anything: **what did I ask for**, **is it finished**, and **have I
/// looked at it since**. The third is the only one no harness can answer,
/// because it is not a fact about the session at all — it is a fact about the
/// person, and Auspex is the only thing in the room that holds both.
///
/// So: a session is *done and unseen* when its last turn closed after the last
/// time its card was opened. That is the state a board exists to surface — the
/// agent has stopped, it is waiting to be read, and nothing else on the
/// machine will ever mention it again.
public enum TaskLedger {
    /// Whether a session has finished something the person has not read.
    ///
    /// Two conditions, and both are load-bearing:
    ///
    /// - **A turn closed.** `lastTurnEndedAt` and not `endedAt`, because the
    ///   common case is a session that is still open in a terminal and has
    ///   simply stopped talking. Waiting for the process to exit would mean
    ///   never flagging the sessions a person actually forgets about.
    /// - **It is not still working.** `idle` and `ended` only. A session that
    ///   closed a turn and immediately opened another is not waiting on
    ///   anybody, and a session blocked on a permission is already the loudest
    ///   thing on the board — calling it "done" as well would be two claims
    ///   about one card.
    ///
    /// A session never opened reads as unseen, which is right: the person has
    /// not looked at it.
    public static func isUnseenDone(
        state: SessionState,
        lastTurnEndedAt: Date?,
        lastSeenAt: Date?
    ) -> Bool {
        guard let lastTurnEndedAt else { return false }
        switch state {
        case .idle, .ended: break
        case .thinking, .toolCalling, .writingFile, .delegating, .waitingPermission: return false
        }
        guard let lastSeenAt else { return true }
        return lastTurnEndedAt > lastSeenAt
    }

    /// Which bucket a row belongs to, for counting, filtering, and sorting.
    ///
    /// One row is in exactly one bucket, and the order of the cases is the
    /// order a person asks about them: *is anything stuck on me*, *did
    /// anything finish while I was elsewhere*, *what is in flight*, *what is
    /// sitting open*, *what is history*.
    public enum Bucket: String, CaseIterable, Sendable, Hashable {
        /// Blocked on a person and going nowhere without one.
        case needsYou
        /// Finished a turn since the card was last opened.
        case doneUnseen
        /// Thinking, running a tool, writing, or waiting on a child.
        case working
        /// Open with nothing outstanding, and already read.
        case idle
        /// Over, and already read.
        case done

        /// The word after the number on a summary chip.
        public var label: String {
            switch self {
            case .needsYou: "needs you"
            case .doneUnseen: "done unseen"
            case .working: "working"
            case .idle: "idle"
            case .done: "done"
            }
        }
    }

    /// The bucket for one row.
    public static func bucket(of row: BoardRow) -> Bucket {
        bucket(state: row.state, isUnseenDone: row.isUnseenDone)
    }

    /// The bucket for one session, given what has been read.
    public static func bucket(of session: SessionSnapshot, lastSeenAt: Date?) -> Bucket {
        bucket(
            state: session.state,
            isUnseenDone: isUnseenDone(
                state: session.state,
                lastTurnEndedAt: session.brief.lastTurnEndedAt,
                lastSeenAt: lastSeenAt
            )
        )
    }

    /// The one place the bucket is decided, so a row and the session behind it
    /// can never land in different ones.
    ///
    /// `needsYou` wins over `doneUnseen` and cannot lose: being blocked is the
    /// only state a person has to act on *now*, and `isUnseenDone` already
    /// excludes it — the check here is belt and braces for a caller that built
    /// the flag some other way.
    public static func bucket(state: SessionState, isUnseenDone: Bool) -> Bucket {
        if case .waitingPermission = state { return .needsYou }
        if isUnseenDone { return .doneUnseen }
        switch state {
        case .thinking, .toolCalling, .writingFile, .delegating: return .working
        case .idle: return .idle
        case .ended: return .done
        case .waitingPermission: return .needsYou
        }
    }

    // MARK: - Order

    /// Board order within a group: what needs a person, then what finished
    /// while they were elsewhere, then what is running, then what is quiet.
    ///
    /// Deliberately *not* ``BoardSnapshot/sorted(_:)``'s order, which ranks by
    /// state alone. A row that finished an hour ago and has not been read is
    /// more urgent than one that is halfway through a `swift build`, and a
    /// state rank cannot express that because "unseen" is not a state.
    ///
    /// The tie-break inside each bucket is the clock that bucket is about —
    /// when the turn closed for the unseen ones, last activity for everything
    /// else — and then the key, so a board of identical rows does not reshuffle
    /// on every tick.
    public static func sorted(_ rows: [BoardRow]) -> [BoardRow] {
        rows.sorted { lhs, rhs in
            let lhsBucket = bucket(of: lhs)
            let rhsBucket = bucket(of: rhs)
            if lhsBucket != rhsBucket { return rank(lhsBucket) < rank(rhsBucket) }
            let lhsAt = clock(of: lhs, in: lhsBucket)
            let rhsAt = clock(of: rhs, in: rhsBucket)
            if lhsAt != rhsAt { return lhsAt > rhsAt }
            return lhs.key.description < rhs.key.description
        }
    }

    /// Where a bucket sits in the order. Declaration order is display order.
    public static func rank(_ bucket: Bucket) -> Int {
        switch bucket {
        case .needsYou: 0
        case .doneUnseen: 1
        case .working: 2
        case .idle: 3
        case .done: 4
        }
    }

    /// The instant a bucket is ordered by.
    private static func clock(of row: BoardRow, in bucket: Bucket) -> Date {
        switch bucket {
        case .doneUnseen:
            row.lastTurnEndedAt ?? row.endedAt ?? row.lastEventAt ?? .distantPast
        case .done:
            row.endedAt ?? row.lastEventAt ?? .distantPast
        case .needsYou, .working, .idle:
            row.lastEventAt ?? .distantPast
        }
    }

    /// Board order over snapshots, for the surfaces that never build rows —
    /// the menu bar panel, most of all.
    ///
    /// The same comparator as ``sorted(_:)`` and deliberately so: the panel
    /// and the wall are two views of one board, and a person who opens the
    /// window from the third row of the menu bar should land on the third card.
    public static func sorted(
        _ sessions: [SessionSnapshot],
        seenAt: [SessionKey: Date]
    ) -> [SessionSnapshot] {
        sessions.sorted { lhs, rhs in
            let lhsBucket = bucket(of: lhs, lastSeenAt: seenAt[lhs.key])
            let rhsBucket = bucket(of: rhs, lastSeenAt: seenAt[rhs.key])
            if lhsBucket != rhsBucket { return rank(lhsBucket) < rank(rhsBucket) }
            let lhsAt = clock(of: lhs, in: lhsBucket)
            let rhsAt = clock(of: rhs, in: rhsBucket)
            if lhsAt != rhsAt { return lhsAt > rhsAt }
            return lhs.key.description < rhs.key.description
        }
    }

    private static func clock(of session: SessionSnapshot, in bucket: Bucket) -> Date {
        switch bucket {
        case .doneUnseen:
            session.brief.lastTurnEndedAt ?? session.endedAt ?? session.lastEventAt ?? .distantPast
        case .done:
            session.endedAt ?? session.lastEventAt ?? .distantPast
        case .needsYou, .working, .idle:
            session.lastEventAt ?? .distantPast
        }
    }

    /// Whether a session belongs on a surface that shows what still wants
    /// attention: everything live, plus the finished ones nobody has read.
    ///
    /// The menu bar's list. A session that ended and was read is history and
    /// belongs on the board's collapsed section, not in a panel a person opens
    /// to ask what is outstanding.
    public static func wantsAttention(_ session: SessionSnapshot, lastSeenAt: Date?) -> Bool {
        !session.state.isEnded
            || isUnseenDone(
                state: session.state,
                lastTurnEndedAt: session.brief.lastTurnEndedAt,
                lastSeenAt: lastSeenAt
            )
    }

    // MARK: - Counting and filtering

    /// How many rows are in each bucket.
    public static func counts(of rows: [BoardRow]) -> [Bucket: Int] {
        var counts: [Bucket: Int] = [:]
        for row in rows { counts[bucket(of: row), default: 0] += 1 }
        return counts
    }

    /// The rows in one bucket, in the order they were given.
    public static func rows(_ rows: [BoardRow], in bucket: Bucket) -> [BoardRow] {
        rows.filter { self.bucket(of: $0) == bucket }
    }
}
