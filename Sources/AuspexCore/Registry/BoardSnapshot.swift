import AgentSessionKit
import AgentSessionLive
import Foundation

/// One immutable frame of the live board.
///
/// Views never read ``SessionRegistry`` directly; they render a snapshot. That
/// is what keeps the SwiftUI board, the SpriteKit scene, and the menu bar
/// showing the same thing — three readers of one value cannot disagree, while
/// three readers of an actor can each observe a different moment.
///
/// The sessions are already sorted and the counts already computed, because a
/// value that arrives at up to 20 Hz should not make every consumer redo the
/// same work.
public struct BoardSnapshot: Sendable, Equatable {
    /// When the frame was produced. Not the time of the newest event: a frame
    /// is also published when nothing happened but a session went stale.
    public let generatedAt: Date

    /// Every known session, in board order — see ``sorted(_:)``.
    public let sessions: [SessionSnapshot]

    /// How many sessions are in each state, computed once for the header, the
    /// menu bar title, and the sidebar badges.
    public let counts: Counts

    /// The tallies a board shows at a glance.
    public struct Counts: Sendable, Equatable, Hashable {
        /// Believed to be running: alive and not ended. A stale session still
        /// counts — silence is not death.
        public var live: Int
        public var thinking: Int
        /// `toolCalling` and `writingFile` together: both are "a tool is open",
        /// and a header that split them would be counting implementation
        /// detail.
        public var tooling: Int
        public var delegating: Int
        /// The number that matters most: sessions that will make no further
        /// progress until a person looks at them.
        public var waitingPermission: Int
        public var idle: Int
        public var ended: Int

        public init(
            live: Int = 0,
            thinking: Int = 0,
            tooling: Int = 0,
            delegating: Int = 0,
            waitingPermission: Int = 0,
            idle: Int = 0,
            ended: Int = 0
        ) {
            self.live = live
            self.thinking = thinking
            self.tooling = tooling
            self.delegating = delegating
            self.waitingPermission = waitingPermission
            self.idle = idle
            self.ended = ended
        }

        /// Tallies a set of sessions.
        public init(sessions: some Sequence<SessionSnapshot>) {
            self.init()
            for session in sessions {
                if session.isAlive, !session.state.isEnded { live += 1 }
                switch session.state {
                case .thinking: thinking += 1
                case .toolCalling, .writingFile: tooling += 1
                case .delegating: delegating += 1
                case .waitingPermission: waitingPermission += 1
                case .idle: idle += 1
                case .ended: ended += 1
                }
            }
        }
    }

    /// Creates a frame, sorting the sessions and tallying the counts.
    public init(generatedAt: Date, sessions: [SessionSnapshot]) {
        self.generatedAt = generatedAt
        self.sessions = Self.sorted(sessions)
        self.counts = Counts(sessions: self.sessions)
    }

    /// An empty board, for a view's initial state.
    public static let empty = BoardSnapshot(generatedAt: .distantPast, sessions: [])

    /// Board order: running sessions first, then the ones that most need a
    /// person, then the most recently active.
    ///
    /// Alive-first comes before state rank so that a finished session cannot
    /// out-rank a running one just because it ended in an interesting way.
    /// Within a state, newest activity wins, and the session key breaks the
    /// last tie so the order does not shuffle between frames — a board that
    /// reorders identical rows on every tick is unreadable.
    public static func sorted(_ sessions: [SessionSnapshot]) -> [SessionSnapshot] {
        sessions.sorted { lhs, rhs in
            if lhs.isAlive != rhs.isAlive { return lhs.isAlive }
            let lhsRank = lhs.state.sortRank
            let rhsRank = rhs.state.sortRank
            if lhsRank != rhsRank { return lhsRank < rhsRank }
            let lhsAt = lhs.lastEventAt ?? .distantPast
            let rhsAt = rhs.lastEventAt ?? .distantPast
            if lhsAt != rhsAt { return lhsAt > rhsAt }
            return lhs.key.description < rhs.key.description
        }
    }

    // MARK: - Lookups

    /// The session with `key`, when the board has one.
    public func session(for key: SessionKey) -> SessionSnapshot? {
        sessions.first { $0.key == key }
    }

    /// Sessions grouped by the harness that produced them, each group still in
    /// board order.
    public var byHarness: [Harness: [SessionSnapshot]] {
        Dictionary(grouping: sessions) { $0.key.harness }
    }

    /// Sessions grouped by project — the git root when one is known, and the
    /// working directory otherwise.
    ///
    /// The git root is preferred so that three sessions in three worktrees of
    /// one repository group together instead of looking like three projects.
    /// Sessions whose adapter has recorded neither are in
    /// ``ungroupedSessions`` rather than under a made-up key.
    public var byProject: [String: [SessionSnapshot]] {
        Dictionary(grouping: sessions.filter { Self.projectKey(for: $0) != nil }) {
            Self.projectKey(for: $0) ?? ""
        }
    }

    /// Sessions with no git root and no working directory, which therefore
    /// cannot be placed under a project yet.
    public var ungroupedSessions: [SessionSnapshot] {
        sessions.filter { Self.projectKey(for: $0) == nil }
    }

    /// The grouping key for one session: `gitRoot ?? cwd`.
    public static func projectKey(for session: SessionSnapshot) -> String? {
        session.identity.gitRoot ?? session.identity.cwd
    }
}
