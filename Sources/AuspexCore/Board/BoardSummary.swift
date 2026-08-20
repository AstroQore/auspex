import AgentSessionKit
import AgentSessionLive
import Foundation

/// The numbers across the top of the board.
///
/// ``BoardSnapshot/Counts`` has seven, one per state, because that is what a
/// reducer produces. A header with seven numbers in it is a header nobody
/// reads, so this folds them into the questions a person actually asks, in
/// the order they ask them:
///
/// 1. **Needs you** — is anything stuck on me?
/// 2. **Done unseen** — did anything finish while I was elsewhere?
/// 3. **Working** — how much is in flight?
/// 4. **Idle** — how much is sitting open doing nothing?
/// 5. **Done** — how much history is behind this?
///
/// The second is the one no harness can answer, because it is half a fact
/// about the person: a session is *done unseen* when its last turn closed
/// after the last time its card was opened. It is also the number this whole
/// app exists for — an agent that finished an hour ago and was never read is
/// the thing a person running twelve of them actually loses.
///
/// `working` deliberately folds thinking, tooling, and delegating together:
/// the distinction between them is what the *cards* are for, and a header that
/// split them would be asking the reader to add three numbers up before they
/// could answer the question they came with.
///
/// It is a value in Core rather than three lines in a view body because the
/// header, the menu bar, and the sidebar all quote these numbers, and three
/// call sites each folding the counts their own way is three chances to
/// disagree about what "working" means.
public struct BoardSummary: Sendable, Equatable, Hashable {
    /// Sessions blocked on a person.
    public let needsYou: Int
    /// Sessions that closed a turn since their card was last opened.
    ///
    /// Overlaps the others by construction: a done-unseen session is also
    /// idle or ended, and is counted in both. That is deliberate — `idle`
    /// answers "how much is sitting open" and this answers "how much is
    /// waiting to be read", and a person asks them separately.
    public let doneUnseen: Int
    /// Sessions doing something: thinking, running a tool, writing, or waiting
    /// on children.
    public let working: Int
    /// Sessions that are open with nothing outstanding.
    public let idle: Int
    /// Sessions that are over.
    public let done: Int

    /// Folds a frame's per-state tallies into the numbers the header shows.
    ///
    /// `doneUnseen` cannot be derived from state alone — it needs Auspex's own
    /// record of what has been opened — so a caller that has the rows passes
    /// it, and one that only has the counts leaves it at zero rather than
    /// guessing.
    public init(counts: BoardSnapshot.Counts, doneUnseen: Int = 0) {
        self.needsYou = counts.waitingPermission
        self.doneUnseen = doneUnseen
        self.working = counts.thinking + counts.tooling + counts.delegating
        self.idle = counts.idle
        self.done = counts.ended
    }

    /// A summary of one frame.
    public init(board: BoardSnapshot) {
        self.init(counts: board.counts)
    }

    /// A summary of a set of sessions, told what has been read and what the
    /// agents have said.
    ///
    /// The form the board uses per frame: it already holds the sessions, the
    /// seen-at map and the notices, and deriving rows for the whole board just
    /// to count them would pay for a delegation-tree walk per session.
    ///
    /// A session whose agent called `auspex.notify` is *moved* into "needs
    /// you" rather than added to it. Counting it in both would make the five
    /// numbers add up to more than the board has cards on it, and the chip a
    /// person is most likely to click would be the one that lies.
    public init(
        sessions: [SessionSnapshot],
        seenAt: [SessionKey: Date],
        notices: [SessionKey: AgentNotice] = [:]
    ) {
        var counts = BoardSnapshot.Counts(sessions: sessions)
        var unseen = 0
        for session in sessions {
            let notice = notices[session.key]
            if TaskLedger.isUnseenDone(
                state: session.state,
                lastTurnEndedAt: session.brief.lastTurnEndedAt,
                lastSeenAt: seenAt[session.key],
                isChild: TaskLedger.isChild(session.identity),
                hasAssignment: session.brief.firstPrompt != nil,
                notice: notice
            ) {
                unseen += 1
            }
            guard notice?.kind.wantsPerson == true else { continue }
            if case .waitingPermission = session.state { continue }
            counts.waitingPermission += 1
            switch session.state {
            case .thinking: counts.thinking -= 1
            case .toolCalling, .writingFile: counts.tooling -= 1
            case .delegating: counts.delegating -= 1
            case .idle: counts.idle -= 1
            case .ended: counts.ended -= 1
            case .waitingPermission: break
            }
        }
        self.init(counts: counts, doneUnseen: unseen)
    }

    /// A summary of the rows a board actually drew.
    ///
    /// The form the board itself uses: rows already carry
    /// ``BoardRow/isUnseenDone``, which is the one number a `BoardSnapshot`
    /// cannot produce on its own.
    public init(rows: [BoardRow]) {
        var counts = BoardSnapshot.Counts()
        var unseen = 0
        for row in rows {
            switch row.state {
            case .thinking: counts.thinking += 1
            case .toolCalling, .writingFile: counts.tooling += 1
            case .delegating: counts.delegating += 1
            case .waitingPermission: counts.waitingPermission += 1
            case .idle: counts.idle += 1
            case .ended: counts.ended += 1
            }
            if row.isUnseenDone { unseen += 1 }
        }
        self.init(counts: counts, doneUnseen: unseen)
    }

    /// Everything except the finished ones — the number beside the board's
    /// heading.
    public var live: Int { needsYou + working + idle }

    /// What a chip is about, and what a click on it filters the board to.
    ///
    /// The same vocabulary the ledger sorts and buckets by, rather than a
    /// second enum beside it: a chip that counts one thing and filters to
    /// another is the bug this alias makes unspellable. The view maps it to a
    /// colour; nothing here knows what colour anything is.
    public typealias Kind = TaskLedger.Bucket

    /// The value for one kind.
    public func value(for kind: Kind) -> Int {
        switch kind {
        case .needsYou: needsYou
        case .doneUnseen: doneUnseen
        case .working: working
        case .idle: idle
        case .done: done
        }
    }

    /// The chips the header draws, in reading order, with the empty ones
    /// dropped.
    ///
    /// `done` survives at zero and the rest do not. A board that has never
    /// finished anything is a board that has just started, and saying `0 done`
    /// there is honest; saying `0 needs you` on every quiet machine teaches a
    /// reader that the red chip is always present, which is exactly what it
    /// must not be — and the same is true of the green one beside it.
    public var chips: [(kind: Kind, value: Int)] {
        Kind.allCases.compactMap { kind in
            let value = value(for: kind)
            guard value > 0 || kind == .done else { return nil }
            return (kind, value)
        }
    }
}
