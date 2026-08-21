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
/// 2. **Done** — did anything *say* it finished while I was elsewhere?
/// 3. **Working** — how much is in flight?
/// 4. **Idle** — how much is sitting open doing nothing?
/// 5. **Ended** — how much history is behind this? (Counted, never a chip.)
///
/// The first two are the ones no harness can answer, and they are counted only
/// from something explicit: an agent calling `auspex.notify`, a
/// `PermissionRequest` hook, a harness's own permission wait. A turn simply
/// ending counts towards neither — see ``AttentionState`` for why that
/// inference was worth removing.
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
    /// Sessions something explicit says are blocked on a person.
    public let needsYou: Int
    /// Sessions whose agent reported finishing something.
    public let doneReported: Int
    /// Sessions doing something: thinking, running a tool, writing, or waiting
    /// on children.
    public let working: Int
    /// Sessions that are open with nothing outstanding.
    public let idle: Int
    /// Sessions that are over.
    public let ended: Int

    /// The five numbers, given directly. Every session is in exactly one of
    /// them, so they add up to the board.
    public init(needsYou: Int, doneReported: Int, working: Int, idle: Int, ended: Int) {
        self.needsYou = needsYou
        self.doneReported = doneReported
        self.working = working
        self.idle = idle
        self.ended = ended
    }

    /// Folds a frame's per-state tallies into the numbers the header shows.
    ///
    /// Activity only: with no attention map there is nothing explicit to read,
    /// so `doneReported` is zero and `needsYou` holds only the permission
    /// waits — which are themselves an explicit signal, and the one a state
    /// tally can see.
    public init(counts: BoardSnapshot.Counts, doneReported: Int = 0) {
        self.needsYou = counts.waitingPermission
        self.doneReported = doneReported
        self.working = counts.thinking + counts.tooling + counts.delegating
        self.idle = counts.idle
        self.ended = counts.ended
    }

    /// A summary of one frame.
    public init(board: BoardSnapshot) {
        self.init(counts: board.counts)
    }

    /// A summary of a set of sessions and what each of them is signalling.
    ///
    /// The form the board uses per frame: it already holds the sessions and
    /// the attention map, and deriving rows for the whole board just to count
    /// them would pay for a delegation-tree walk per session.
    ///
    /// A session is *moved* into its attention bucket rather than added to it,
    /// so the five numbers add up to the number of cards on the wall. Counting
    /// a blocked session as working as well would make the chip a person is
    /// most likely to click the one that lies.
    public init(sessions: [SessionSnapshot], attention: [SessionKey: AttentionState]) {
        var tally: [TaskLedger.Bucket: Int] = [:]
        for session in sessions {
            let bucket = TaskLedger.bucket(
                attention: attention[session.key] ?? .none,
                state: session.state
            )
            tally[bucket, default: 0] += 1
        }
        self.init(
            needsYou: tally[.needsYou] ?? 0,
            doneReported: tally[.doneReported] ?? 0,
            working: tally[.working] ?? 0,
            idle: tally[.idle] ?? 0,
            ended: tally[.ended] ?? 0
        )
    }

    /// A summary of the rows a board actually drew.
    ///
    /// The form the board itself uses: rows already carry
    /// ``BoardRow/attention``, which is the one thing a `BoardSnapshot` cannot
    /// produce on its own.
    public init(rows: [BoardRow]) {
        var tally: [TaskLedger.Bucket: Int] = [:]
        for row in rows { tally[TaskLedger.bucket(of: row), default: 0] += 1 }
        self.init(
            needsYou: tally[.needsYou] ?? 0,
            doneReported: tally[.doneReported] ?? 0,
            working: tally[.working] ?? 0,
            idle: tally[.idle] ?? 0,
            ended: tally[.ended] ?? 0
        )
    }

    /// Everything except the finished ones — the number beside the board's
    /// heading.
    public var live: Int { needsYou + doneReported + working + idle }

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
        case .doneReported: doneReported
        case .working: working
        case .idle: idle
        case .ended: ended
        }
    }

    /// The chips the header draws, in reading order, with the empty ones
    /// dropped.
    ///
    /// Two rules, and both are about what a chip *teaches* by being there:
    ///
    /// - **A zero is not a chip.** Saying `0 needs you` on every quiet machine
    ///   teaches a reader that the red chip is always present, which is exactly
    ///   what it must not be — and the same is true of the green one beside it.
    /// - **`ended` never gets one.** The finished sessions have a fold of their
    ///   own at the bottom of the board with its own count, and a header chip
    ///   for history would be the loudest row in the window quoting the least
    ///   urgent number in it.
    public var chips: [(kind: Kind, value: Int)] {
        Kind.allCases.compactMap { kind in
            guard kind != .ended else { return nil }
            let value = value(for: kind)
            guard value > 0 else { return nil }
            return (kind, value)
        }
    }
}
