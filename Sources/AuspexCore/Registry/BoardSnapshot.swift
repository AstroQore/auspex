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
/// The sessions are already sorted, the counts already computed and the keys
/// already indexed, because a value every surface reads on every frame should
/// not make each of them redo the same work.
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

    /// The sessions whose working directory is a harness's own per-thread
    /// scratch, and what that thread's folder is called.
    ///
    /// Carried on the frame for the reason ``claims`` is: the answer needs a
    /// home directory to work out and every surface that groups would
    /// otherwise have to fetch one, which is five places to get it right and
    /// four to forget. ``ProjectResolver`` decides once, against the home it
    /// was built with, and the frame remembers.
    ///
    /// Empty on a frame nothing has been placed on yet, which reads exactly
    /// like the behaviour before there was such a thing as scratch.
    public let sandboxThreads: [SessionKey: String]

    /// The sessions in no repository that are filed under a root other than
    /// their own directory, and that root — see ``ProjectRollup``.
    ///
    /// Carried on the frame for the reason ``sandboxThreads`` is: the answer
    /// needs the disk and the person's project roots, and the placement
    /// service already asked both. Empty on a frame nothing has been placed on
    /// yet, which groups every plain directory by itself, as it always did.
    public let workspaceRoots: [SessionKey: String]

    /// Where each session sits in ``sessions``.
    ///
    /// Built once with the frame. ``session(for:)`` used to be a linear scan,
    /// and it is asked inside loops over every session — the ancestor walk in
    /// ``projectKey(for:)``, the sidebar's tree, the unit builder, the ignore
    /// rules — which made each of those quadratic in the size of the board.
    ///
    /// Derived from ``sessions`` and so left out of `==`.
    public let index: [SessionKey: Int]

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
        claims: ProjectClaims = .empty,
        sandboxThreads: [SessionKey: String] = [:],
        workspaceRoots: [SessionKey: String] = [:]
    ) {
        self.generatedAt = generatedAt
        self.sessions = Self.sorted(sessions)
        self.counts = Counts(sessions: self.sessions)
        self.tree = SessionTreeBuilder.build(self.sessions)
        self.claims = claims
        self.sandboxThreads = sandboxThreads
        self.workspaceRoots = workspaceRoots
        self.index = Self.makeIndex(self.sessions)
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
        claims: ProjectClaims,
        sandboxThreads: [SessionKey: String],
        workspaceRoots: [SessionKey: String],
        index: [SessionKey: Int]? = nil
    ) {
        self.generatedAt = generatedAt
        self.sessions = sessions
        self.counts = counts
        self.tree = tree
        self.claims = claims
        self.sandboxThreads = sandboxThreads
        self.workspaceRoots = workspaceRoots
        self.index = index ?? Self.makeIndex(sessions)
    }

    /// The first position of every key. First rather than last, so a board
    /// that somehow held a key twice answers the way the old scan did.
    private static func makeIndex(_ sessions: [SessionSnapshot]) -> [SessionKey: Int] {
        var index: [SessionKey: Int] = [:]
        index.reserveCapacity(sessions.count)
        for (position, session) in sessions.enumerated() where index[session.key] == nil {
            index[session.key] = position
        }
        return index
    }

    /// Everything but ``index``, which is a function of ``sessions``.
    public static func == (lhs: BoardSnapshot, rhs: BoardSnapshot) -> Bool {
        lhs.generatedAt == rhs.generatedAt
            && lhs.sessions == rhs.sessions
            && lhs.counts == rhs.counts
            && lhs.tree == rhs.tree
            && lhs.claims == rhs.claims
            && lhs.sandboxThreads == rhs.sandboxThreads
            && lhs.workspaceRoots == rhs.workspaceRoots
    }

    /// An empty board, for a view's initial state.
    public static let empty = BoardSnapshot(generatedAt: .distantPast, sessions: [])

    /// Whether two frames say the same thing about the machine.
    ///
    /// Everything except ``generatedAt``, which moves on every frame and which
    /// nothing on screen draws. The distinction is what lets a consumer refuse
    /// to republish a frame that changed nothing: `==` can never be true
    /// between two consecutive frames, so a model that guarded on it would
    /// invalidate every reader of the board eight times a second for a picture
    /// that is identical.
    ///
    /// `counts` and `tree` are derived from `sessions` in every initialiser, so
    /// comparing the sessions, the claims and the scratch folders answers for
    /// all five. The scratch folders are not derived from anything here: a
    /// folder a person marks as scratch moves its session to another heading
    /// without changing the session.
    public func saysTheSameAs(_ other: BoardSnapshot) -> Bool {
        sessions == other.sessions && claims == other.claims && sandboxThreads == other.sandboxThreads
            && workspaceRoots == other.workspaceRoots
    }

    /// The same frame, placed by a different set of user projects.
    public func applying(claims: ProjectClaims) -> BoardSnapshot {
        guard claims != self.claims else { return self }
        return BoardSnapshot(
            sorted: sessions,
            generatedAt: generatedAt,
            counts: counts,
            tree: tree,
            claims: claims,
            sandboxThreads: sandboxThreads,
            workspaceRoots: workspaceRoots,
            index: index
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
            claims: claims,
            sandboxThreads: sandboxThreads,
            workspaceRoots: workspaceRoots
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

    /// The session with `key`, when the board has one. A dictionary lookup —
    /// see ``index``.
    public func session(for key: SessionKey) -> SessionSnapshot? {
        index[key].map { sessions[$0] }
    }

    /// Sessions grouped by the harness that produced them, each group still in
    /// board order.
    public var byHarness: [Harness: [SessionSnapshot]] {
        Dictionary(grouping: sessions) { $0.key.harness }
    }

    /// Sessions grouped by project — the git root when one is known, the
    /// workspace a plain directory rolls up to, and the working directory
    /// otherwise. Every session is in it: one with no project of its own is
    /// under ``PseudoProject/projectlessKey``.
    ///
    /// The git root is preferred so that three sessions in three worktrees of
    /// one repository group together instead of looking like three projects.
    public var byProject: [String: [SessionSnapshot]] {
        Dictionary(grouping: sessions.filter { projectKey(for: $0) != nil }) {
            projectKey(for: $0) ?? ""
        }
    }

    /// Sessions that can be placed under no key at all. Always empty since
    /// every such session files under Projectless; kept for the readers that
    /// still ask.
    public var ungroupedSessions: [SessionSnapshot] {
        sessions.filter { projectKey(for: $0) == nil }
    }

    /// The grouping key for one session, falling back to its ancestors and
    /// then to Projectless.
    ///
    /// A delegated session frequently records no directory at all — a Claude
    /// subagent has no process and no cwd line, and a spawned harness may not
    /// have written one yet — but it is unambiguously working on whatever its
    /// parent is working on. So an unplaceable child takes the key of the
    /// nearest ancestor that has one.
    ///
    /// A user project's claim is asked first, at every step of that walk: a
    /// person who put a directory in a project meant its sessions and the
    /// subagents they spawn, and a child that inherited its parent's automatic
    /// key while its parent moved into a project would be the one row on the
    /// board in the wrong place.
    ///
    /// A session's own key is its git root, then the workspace a plain
    /// directory was rolled up to (``workspaceRoots``), then its directory.
    /// Two kinds of session never group by their own directory. A scratch
    /// thread — a Codex desktop conversation's folder, a Claude Desktop
    /// scratch workspace, the home directory — has a directory that is not a
    /// project; a Codex thread another thread spawned has one that is not what
    /// it is working on (see ``CodexThreadSpawn``). Both take their nearest
    /// placeable ancestor's key, and a child of a scratch thread is in that
    /// thread.
    ///
    /// Everything left after that walk is **Projectless**: a scratch thread
    /// with no project above it, a session with no directory and no ancestor
    /// with one, a harness whose store records no directory at all (Grok Bot).
    /// One key, ``PseudoProject/projectlessKey``, for all of them — which is
    /// why this never answers `nil`. The optional is kept for the callers that
    /// were written against the residue.
    public func projectKey(for session: SessionSnapshot) -> String? {
        if let claimed = claims.key(for: session) { return claimed }
        if groupsByOwnDirectory(session), let own = ownKey(for: session) { return own }
        var seen: Set<SessionKey> = [session.key]
        var current = session.identity.parent
        while let key = current, seen.insert(key).inserted {
            guard let ancestor = self.session(for: key) else { break }
            if let claimed = claims.key(for: ancestor) { return claimed }
            // A child of a scratch thread is in that thread. Inheriting the
            // *directory* would put it back under a folder name.
            if isSandbox(ancestor) { return PseudoProject.projectlessKey }
            if !inheritsProject(ancestor), let inherited = ownKey(for: ancestor) {
                return inherited
            }
            current = ancestor.identity.parent
        }
        return PseudoProject.projectlessKey
    }

    /// Whether a session is filed under Projectless.
    public func isProjectless(_ session: SessionSnapshot) -> Bool {
        projectKey(for: session).map(PseudoProject.isProjectless) ?? true
    }

    /// The key a session's own directory gives it: the git root, then the
    /// workspace it was rolled up to, then the directory. `nil` for a session
    /// that reported none of them — an empty string is no directory.
    private func ownKey(for session: SessionSnapshot) -> String? {
        if let root = session.identity.gitRoot, !root.isEmpty { return root }
        if let root = workspaceRoots[session.key] { return root }
        if let cwd = session.identity.cwd, !cwd.isEmpty { return cwd }
        return nil
    }

    /// Whether this session's own directory can be its project key — neither
    /// a scratch thread nor a spawned thread.
    private func groupsByOwnDirectory(_ session: SessionSnapshot) -> Bool {
        !isSandbox(session) && !inheritsProject(session)
    }

    /// Whether this session takes its project from its parent whatever its
    /// own directory says: a Codex thread another thread spawned.
    public func inheritsProject(_ session: SessionSnapshot) -> Bool {
        SessionRelations.isThreadSpawn(session.identity)
    }

    /// Whether this session's own directory is a harness's per-thread scratch.
    public func isSandbox(_ session: SessionSnapshot) -> Bool {
        sandboxThreads[session.key] != nil
    }

    /// The folder a scratch session is running in, when it is running in one
    /// — `zhe` for a Codex desktop thread. Not a heading and not a title: the
    /// session is under Projectless, and its row carries the directory.
    public func sandboxThreadName(for session: SessionSnapshot) -> String? {
        sandboxThreads[session.key]
    }

    /// What to call a project key: the name a person gave it, then
    /// "Projectless" for a pseudo key, then the key's last path component.
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
        if let root = session.identity.gitRoot, !root.isEmpty { return root }
        if let cwd = session.identity.cwd, !cwd.isEmpty { return cwd }
        return nil
    }
}
