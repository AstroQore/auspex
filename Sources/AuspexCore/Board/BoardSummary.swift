import AgentSessionLive
import Foundation

/// The four numbers across the top of the board.
///
/// ``BoardSnapshot/Counts`` has seven, one per state, because that is what a
/// reducer produces. A header with seven numbers in it is a header nobody
/// reads, so this folds them into the four questions a person actually asks,
/// in the order they ask them:
///
/// 1. **Needs you** — is anything stuck on me?
/// 2. **Working** — how much is in flight?
/// 3. **Idle** — how much is sitting open doing nothing?
/// 4. **Done** — how much history is behind this?
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
    /// Sessions doing something: thinking, running a tool, writing, or waiting
    /// on children.
    public let working: Int
    /// Sessions that are open with nothing outstanding.
    public let idle: Int
    /// Sessions that are over.
    public let done: Int

    /// Folds a frame's per-state tallies into the four the header shows.
    public init(counts: BoardSnapshot.Counts) {
        self.needsYou = counts.waitingPermission
        self.working = counts.thinking + counts.tooling + counts.delegating
        self.idle = counts.idle
        self.done = counts.ended
    }

    /// A summary of one frame.
    public init(board: BoardSnapshot) {
        self.init(counts: board.counts)
    }

    /// Everything except the finished ones — the number beside the board's
    /// heading.
    public var live: Int { needsYou + working + idle }

    /// What a chip is about. The view maps it to a colour; nothing here knows
    /// what colour anything is.
    public enum Kind: String, CaseIterable, Sendable, Hashable {
        case needsYou
        case working
        case idle
        case done

        /// The word after the number.
        public var label: String {
            switch self {
            case .needsYou: "needs you"
            case .working: "working"
            case .idle: "idle"
            case .done: "done"
            }
        }
    }

    /// The value for one kind.
    public func value(for kind: Kind) -> Int {
        switch kind {
        case .needsYou: needsYou
        case .working: working
        case .idle: idle
        case .done: done
        }
    }

    /// The chips the header draws, in reading order, with the empty ones
    /// dropped.
    ///
    /// `done` survives at zero and the other three do not. A board that has
    /// never finished anything is a board that has just started, and saying
    /// `0 done` there is honest; saying `0 needs you` on every quiet machine
    /// teaches a reader that the red chip is always present, which is exactly
    /// what it must not be.
    public var chips: [(kind: Kind, value: Int)] {
        Kind.allCases.compactMap { kind in
            let value = value(for: kind)
            guard value > 0 || kind == .done else { return nil }
            return (kind, value)
        }
    }
}
