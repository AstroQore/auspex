import AgentSessionKit
import AgentSessionLive
import Foundation

/// The board as a ledger of assignments rather than a wall of activity.
///
/// The state machine answers *what is this session doing*. Somebody running a
/// dozen sessions across five harnesses needs two more answers before that one
/// is worth anything: **is anything stuck on me**, and **did anything finish
/// while I was elsewhere**. Neither is a fact about the session's transcript.
///
/// ## Two axes, and only one of them is inferred
///
/// **Activity** — working, idle, stale, ended — is inferred for every session
/// on the machine, always. **Attention** — needs you, done reported — comes
/// only from something explicit: an agent calling `auspex.notify`, a
/// `PermissionRequest` hook, a harness's own permission wait. See
/// ``AttentionState``.
///
/// The bucket is the two axes folded into the one question a header asks, and
/// the fold is *attention first*: a session that is blocked is blocked whatever
/// its transcript looks like from outside, and a session whose agent said it
/// finished is finished whether or not its process is still alive.
public enum TaskLedger {
    /// Whether a session is idle with the agent having spoken last, and has
    /// not been opened since.
    ///
    /// The old `doneUnseen` inference, kept as a *dot* and nothing else. It is
    /// counted nowhere, sorted by nothing, and never notified — because on a
    /// machine that has been running agents all week it is true of hundreds of
    /// sessions at once, and a bucket that large is a bucket nobody reads.
    ///
    /// It survives because it is still worth a glance on a card that is
    /// already in front of you: *this one stopped after saying something, and
    /// you have not looked*. Three conditions, and each is a way the dot goes
    /// wrong without it:
    ///
    /// - **A turn closed and the session is idle.** Not ended: a finished
    ///   session is in the collapsed fold, where a dot would be decoration.
    /// - **Nobody delegated it.** A subagent is a step inside somebody else's
    ///   task, not a task.
    /// - **It has an assignment.** With no ``SessionBrief/firstPrompt`` there
    ///   is nothing the reply is a reply *to*.
    public static func isQuietReply(
        state: SessionState,
        lastTurnEndedAt: Date?,
        lastSeenAt: Date?,
        isChild: Bool,
        hasAssignment: Bool
    ) -> Bool {
        guard let lastTurnEndedAt, !isChild, hasAssignment else { return false }
        guard case .idle = state else { return false }
        guard let lastSeenAt else { return true }
        return lastTurnEndedAt > lastSeenAt
    }

    /// The same question asked of a whole snapshot.
    public static func isQuietReply(_ session: SessionSnapshot, lastSeenAt: Date?) -> Bool {
        isQuietReply(
            state: session.state,
            lastTurnEndedAt: session.brief.lastTurnEndedAt,
            lastSeenAt: lastSeenAt,
            isChild: isChild(session.identity),
            hasAssignment: session.brief.firstPrompt != nil
        )
    }

    /// Whether a session was started by another session rather than by a
    /// person.
    ///
    /// Either kind of evidence counts. `parent` is the key of the session that
    /// spawned it; `parentLink` is *how that was worked out*, and a link can be
    /// recorded — an inherited environment, a spawned process — in the moment
    /// before the parent's own key is known.
    public static func isChild(_ identity: SessionIdentity) -> Bool {
        identity.parent != nil || identity.parentLink != nil
    }

    /// One session's attention, from the frame's own inputs.
    ///
    /// A convenience over ``AttentionState/derive(state:notice:acknowledgedAt:lastPromptAt:lastEventAt:now:)``
    /// so the assembler, the menu bar and the scene all ask the same way and
    /// cannot fall out of step by passing the arguments in a different order.
    public static func attention(
        of session: SessionSnapshot,
        notice: AgentNotice?,
        acknowledgedAt: Date?,
        now: Date
    ) -> AttentionState {
        AttentionState.derive(
            state: session.state,
            notice: notice,
            acknowledgedAt: acknowledgedAt,
            lastPromptAt: session.brief.lastPromptAt,
            lastEventAt: session.lastEventAt,
            now: now
        )
    }

    /// Which bucket a row belongs to, for counting, filtering, and sorting.
    ///
    /// One row is in exactly one bucket, and the order of the cases is the
    /// order a person asks about them: *is anything stuck on me*, *did
    /// anything report finishing*, *what is in flight*, *what is sitting
    /// open*, *what is history*.
    public enum Bucket: String, CaseIterable, Sendable, Hashable {
        /// Blocked on a person and going nowhere without one. Explicit only.
        case needsYou
        /// An agent said it finished something. Explicit only.
        case doneReported
        /// Thinking, running a tool, writing, or waiting on a child.
        case working
        /// Open with nothing outstanding.
        case idle
        /// Over.
        case ended

        /// The word after the number on a summary chip.
        public var label: String {
            switch self {
            case .needsYou: "needs you"
            case .doneReported: "done"
            case .working: "working"
            case .idle: "idle"
            case .ended: "ended"
            }
        }

        /// Whether this bucket is one an agent put a session in by saying
        /// something, rather than one Auspex inferred.
        public var isAttention: Bool {
            switch self {
            case .needsYou, .doneReported: true
            case .working, .idle, .ended: false
            }
        }
    }

    /// The bucket for one row.
    public static func bucket(of row: BoardRow) -> Bucket {
        bucket(attention: row.attention, state: row.state)
    }

    /// The one place the bucket is decided, so a row and the session behind it
    /// can never land in different ones.
    ///
    /// Attention wins over activity, and both attention buckets do. `needsYou`
    /// because being blocked is the only thing a person has to act on *now*;
    /// `doneReported` because an agent that says it finished has said the most
    /// useful true thing about itself, and whether its process happens to still
    /// be alive is the card's business rather than the header's.
    public static func bucket(attention: AttentionState, state: SessionState) -> Bucket {
        switch attention {
        case .needsYou: return .needsYou
        case .doneReported: return .doneReported
        case .none: break
        }
        switch state {
        case .thinking, .toolCalling, .writingFile, .delegating: return .working
        // Belt and braces. A harness wait always derives to `needsYou` above;
        // this catches a caller that built the attention some other way.
        case .waitingPermission: return .needsYou
        case .idle: return .idle
        case .ended: return .ended
        }
    }

    // MARK: - Order

    /// Board order within a group: what needs a person, then what reported
    /// finishing, then what is running, then what is quiet.
    ///
    /// Deliberately *not* ``BoardSnapshot/sorted(_:)``'s order, which ranks by
    /// state alone. A session whose agent said it finished an hour ago is more
    /// urgent than one halfway through a `swift build`, and a state rank cannot
    /// express that because "reported" is not a state.
    ///
    /// The tie-break inside each bucket is the clock that bucket is about —
    /// when the signal arrived for the attention ones, last activity for
    /// everything else — and then the key, so a board of identical rows does
    /// not reshuffle on every tick.
    public static func sorted(_ rows: [BoardRow]) -> [BoardRow] {
        guard rows.count > 1 else { return rows }
        // The keys are derived once per row and the *indices* are sorted.
        //
        // Two costs this avoids, and the board pays them on every frame over a
        // few hundred rows. A comparator that derives the bucket on the fly
        // derives it twice per comparison — order n·log n times rather than n.
        // And decorating with the row itself would copy a `BoardRow` — two
        // dozen fields, six of them strings — once into the decoration and
        // once back out.
        let keys = rows.map(SortKey.init)
        let order = rows.indices.sorted { SortKey.precedes(keys[$0], keys[$1]) }
        return order.map { rows[$0] }
    }

    /// What a row sorts by, worked out once.
    private struct SortKey {
        let rank: Int
        let clock: Date
        /// The tie-break, so a board of otherwise identical rows does not
        /// reshuffle between frames. Built once per row rather than per
        /// comparison, which is where it used to be.
        let id: String

        init(_ row: BoardRow) {
            let bucket = TaskLedger.bucket(of: row)
            self.rank = TaskLedger.rank(bucket)
            self.clock = TaskLedger.clock(of: row, in: bucket)
            self.id = row.key.description
        }

        init(_ session: SessionSnapshot, attention: AttentionState, noticeAt: Date?) {
            let bucket = TaskLedger.bucket(attention: attention, state: session.state)
            self.rank = TaskLedger.rank(bucket)
            self.clock = TaskLedger.clock(of: session, in: bucket, signalAt: noticeAt)
            self.id = session.key.description
        }

        static func precedes(_ lhs: SortKey, _ rhs: SortKey) -> Bool {
            if lhs.rank != rhs.rank { return lhs.rank < rhs.rank }
            if lhs.clock != rhs.clock { return lhs.clock > rhs.clock }
            return lhs.id < rhs.id
        }
    }

    /// Where a bucket sits in the order. Declaration order is display order.
    public static func rank(_ bucket: Bucket) -> Int {
        switch bucket {
        case .needsYou: 0
        case .doneReported: 1
        case .working: 2
        case .idle: 3
        case .ended: 4
        }
    }

    /// The instant a bucket is ordered by.
    static func clock(of row: BoardRow, in bucket: Bucket) -> Date {
        switch bucket {
        case .needsYou, .doneReported:
            // When the signal arrived, which is the whole of what these two
            // buckets are about. The newest call is the one at the top.
            row.notice?.at ?? row.lastEventAt ?? .distantPast
        case .ended:
            row.endedAt ?? row.lastEventAt ?? .distantPast
        case .working, .idle:
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
        attention: [SessionKey: AttentionState],
        notices: [SessionKey: AgentNotice] = [:]
    ) -> [SessionSnapshot] {
        guard sessions.count > 1 else { return sessions }
        // Keyed once for the same reasons as the row form, and one more: the
        // naive comparator hashes a `SessionKey` into the maps twice per
        // comparison, and a `SessionSnapshot` is the most expensive value in
        // the package to copy.
        let keys = sessions.map {
            SortKey(
                $0,
                attention: attention[$0.key] ?? .none,
                noticeAt: notices[$0.key]?.createdAt
            )
        }
        let order = sessions.indices.sorted { SortKey.precedes(keys[$0], keys[$1]) }
        return order.map { sessions[$0] }
    }

    static func clock(
        of session: SessionSnapshot,
        in bucket: Bucket,
        signalAt: Date? = nil
    ) -> Date {
        switch bucket {
        case .needsYou, .doneReported:
            signalAt ?? session.lastEventAt ?? .distantPast
        case .ended:
            session.endedAt ?? session.lastEventAt ?? .distantPast
        case .working, .idle:
            session.lastEventAt ?? .distantPast
        }
    }

    /// Whether a session belongs on a surface that shows what still wants
    /// attention: everything live, plus anything an agent has spoken about.
    ///
    /// The menu bar's list. A session that ended quietly is history and belongs
    /// on the board's collapsed section, not in a panel a person opens to ask
    /// what is outstanding.
    public static func wantsAttention(
        _ session: SessionSnapshot,
        attention: AttentionState
    ) -> Bool {
        attention.isSignalling || !session.state.isEnded
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
