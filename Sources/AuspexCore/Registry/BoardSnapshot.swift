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

    /// Who spawned whom, across every harness on the board.
    ///
    /// Computed with the frame rather than on demand: it is what ``byProject``
    /// groups by and what an outline view renders, and rebuilding it per reader
    /// would have three consumers each walking the same parent chains.
    public let tree: SessionTree

    /// The user's own projects, as an index over the directories they claim.
    ///
    /// Carried on the frame rather than consulted by each view, for the same
    /// reason everything else here is: ``projectKey(for:)`` is asked by the
    /// wall, the sidebar, the cards, the scene and the trace header, and a
    /// user layer applied anywhere but here would be a layer four of the five
    /// remembered to apply. ``ProjectClaims/empty`` is the whole of the
    /// behaviour before anybody has made a project.
    public let claims: ProjectClaims

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

    /// Creates a frame, sorting the sessions, tallying the counts, and
    /// building the delegation forest.
    public init(
        generatedAt: Date,
        sessions: [SessionSnapshot],
        claims: ProjectClaims = .empty
    ) {
        self.generatedAt = generatedAt
        self.sessions = Self.sorted(sessions)
        self.counts = Counts(sessions: self.sessions)
        self.tree = SessionTreeBuilder.build(self.sessions)
        self.claims = claims
    }

    /// Creates a frame from sessions that are already in board order.
    ///
    /// Private, and the only way to skip the sort: the two callers are
    /// ``applying(claims:)`` and ``filtered(keeping:)``, both of which start
    /// from a frame that was sorted when it was made. Sorting a few hundred
    /// sessions again on every applied frame is work spent to reach the order
    /// they are already in.
    private init(
        sorted sessions: [SessionSnapshot],
        generatedAt: Date,
        counts: Counts,
        tree: SessionTree,
        claims: ProjectClaims
    ) {
        self.generatedAt = generatedAt
        self.sessions = sessions
        self.counts = counts
        self.tree = tree
        self.claims = claims
    }

    /// An empty board, for a view's initial state.
    public static let empty = BoardSnapshot(generatedAt: .distantPast, sessions: [])

    /// The same frame, placed by a different set of user projects.
    public func applying(claims: ProjectClaims) -> BoardSnapshot {
        guard claims != self.claims else { return self }
        return BoardSnapshot(
            sorted: sessions,
            generatedAt: generatedAt,
            counts: counts,
            tree: tree,
            claims: claims
        )
    }

    /// The frame with some sessions taken out: same order, recounted, and with
    /// a forest rebuilt from what is left.
    ///
    /// The forest is rebuilt rather than pruned so a child whose parent was
    /// removed becomes a root instead of disappearing with it — the same rule
    /// ``BoardGrouping`` follows for a harness filter, and for the same
    /// reason: hiding a session is not a claim about the ones it started.
    public func filtered(keeping isKept: (SessionSnapshot) -> Bool) -> BoardSnapshot {
        let kept = sessions.filter(isKept)
        guard kept.count != sessions.count else { return self }
        return BoardSnapshot(
            sorted: kept,
            generatedAt: generatedAt,
            counts: Counts(sessions: kept),
            tree: SessionTreeBuilder.build(kept),
            claims: claims
        )
    }

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
        Dictionary(grouping: sessions.filter { projectKey(for: $0) != nil }) {
            projectKey(for: $0) ?? ""
        }
    }

    /// Sessions that can be placed under no project: no directory of their
    /// own, and no ancestor with one either.
    public var ungroupedSessions: [SessionSnapshot] {
        sessions.filter { projectKey(for: $0) == nil }
    }

    /// The grouping key for one session, falling back to its ancestors and
    /// then to the harness itself.
    ///
    /// A delegated session frequently records no directory at all — a Claude
    /// subagent has no process and no cwd line, and a spawned harness may not
    /// have written one yet — but it is unambiguously working on whatever its
    /// parent is working on. So an unplaceable child takes the key of the
    /// nearest ancestor that has one.
    ///
    /// What is left after that walk is of two kinds, and they are not the
    /// same. A session whose directory is *missing* is genuinely unplaceable
    /// and belongs in the residue. A session of a harness that records no
    /// directory *at all* — Grok Bot, whose conversations run on xAI's
    /// servers — is not missing anything, and filing every bot on the machine
    /// under a heading that means "could not be placed" would say something
    /// false about the store and bury the sessions that really could not be.
    /// Those take a ``PseudoProject`` key instead.
    ///
    /// A user project's claim is asked first, at every step of that walk: a
    /// person who put a directory in a project meant its sessions and the
    /// subagents they spawn, and a child that inherited its parent's automatic
    /// key while its parent moved into a project would be the one row on the
    /// board in the wrong place.
    public func projectKey(for session: SessionSnapshot) -> String? {
        if let claimed = claims.key(for: session) { return claimed }
        if let own = Self.projectKey(for: session) { return own }
        var seen: Set<SessionKey> = [session.key]
        var current = session.identity.parent
        while let key = current, seen.insert(key).inserted {
            guard let ancestor = self.session(for: key) else { break }
            if let claimed = claims.key(for: ancestor) { return claimed }
            if let inherited = Self.projectKey(for: ancestor) { return inherited }
            current = ancestor.identity.parent
        }
        guard !session.key.harness.recordsWorkingDirectory else { return nil }
        return PseudoProject.key(for: session.key.harness)
    }

    /// What to call a project key: the name a person gave it, then the
    /// harness a pseudo key stands for, then the key's last path component.
    ///
    /// Every surface that heads a section goes through here, so renaming a
    /// project in the Projects page renames it on the wall, in the sidebar, in
    /// the scene, and in the trace at once.
    public func projectDisplayName(forKey key: String) -> String {
        claims.name(forKey: key) ?? BoardGrouping.projectName(forPath: key)
    }

    /// The grouping key a session carries on its own: `gitRoot ?? cwd`.
    /// Ignores the tree — see ``projectKey(for:)-(SessionSnapshot)`` for the
    /// answer a board groups by.
    public static func projectKey(for session: SessionSnapshot) -> String? {
        session.identity.gitRoot ?? session.identity.cwd
    }
}
