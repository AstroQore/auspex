import AgentSessionKit
import AgentSessionLive
import Foundation

/// The sidebar's view of the board: projects, the checkouts inside them, and
/// the sessions inside those.
///
/// Derived from a ``BoardSnapshot`` rather than from the database, so the tree
/// is exactly as live as the wall it sits next to. The store is consulted only
/// for *names*: a project row whose sessions have all ended still deserves to
/// be called what `projects.name` calls it, and that is the one fact a frame
/// cannot supply.
///
/// Pure and total. Every session in the snapshot ends up in exactly one place —
/// under a project, or in ``ungrouped`` — and the same snapshot always produces
/// the same tree in the same order, which is what stops a sidebar from
/// reshuffling under the reader's cursor twenty times a second.
public struct ProjectTree: Sendable, Equatable {
    /// The projects on the board, most urgent first.
    public let projects: [Project]

    /// Sessions with no directory of their own and no ancestor with one.
    ///
    /// Kept rather than hidden: a subagent whose parent has aged off the board
    /// is still running, and a sidebar that silently dropped it would be
    /// lying about what the machine is doing.
    public let ungrouped: [SessionSnapshot]

    /// An empty tree, for a view's initial state.
    public static let empty = ProjectTree(projects: [], ungrouped: [])

    public init(projects: [Project], ungrouped: [SessionSnapshot]) {
        self.projects = projects
        self.ungrouped = ungrouped
    }

    /// `true` when there is nothing to draw at all.
    public var isEmpty: Bool { projects.isEmpty && ungrouped.isEmpty }

    /// One repository — or one directory that is not in a repository.
    public struct Project: Identifiable, Sendable, Equatable {
        /// The grouping key: the git root, or the working directory when there
        /// is no repository. Also what ``LiveBoardModel`` filters the board by.
        public let key: String
        /// What to call it. The store's `projects.name` when the store knows
        /// this path, and the last path component otherwise.
        public let name: String
        /// The checkouts sessions are actually working in, most urgent first.
        public let checkouts: [Checkout]
        /// Believed to be running, across every checkout.
        public let liveCount: Int
        /// Every session under this project, ended ones included.
        public let sessionCount: Int
        /// The distinct harnesses at work here, in catalog order — the row's
        /// harness dots.
        public let harnesses: [Harness]
        /// `false` when no session here reported a git root: the directory is
        /// its own project, named after itself.
        public let isRepository: Bool

        public var id: String { key }

        public init(
            key: String,
            name: String,
            checkouts: [Checkout],
            harnesses: [Harness],
            isRepository: Bool
        ) {
            self.key = key
            self.name = name
            self.checkouts = checkouts
            self.harnesses = harnesses
            self.isRepository = isRepository
            self.liveCount = checkouts.reduce(0) { $0 + $1.liveCount }
            self.sessionCount = checkouts.reduce(0) { $0 + $1.sessions.count }
        }
    }

    /// One checkout of a project: the main working copy, or a linked worktree.
    public struct Checkout: Identifiable, Sendable, Equatable {
        /// Stable across frames so SwiftUI keeps the disclosure state while the
        /// board churns underneath it.
        public let id: String
        /// The checkout's own directory, when a session reported one.
        public let path: String?
        /// The branch checked out here, when a session reported one.
        public let branch: String?
        /// The `<task>` of an `.agents/worktrees/<task>` path — usually the
        /// most informative label a checkout has, because agents are told to
        /// name their worktree after the job.
        public let agentWorktreeTask: String?
        /// `true` when this is a linked worktree rather than the main checkout.
        public let isWorktree: Bool
        /// The sessions in it, in board order.
        public let sessions: [SessionSnapshot]
        /// How many of them are believed to be running.
        public let liveCount: Int

        public init(
            id: String,
            path: String?,
            branch: String?,
            agentWorktreeTask: String?,
            isWorktree: Bool,
            sessions: [SessionSnapshot]
        ) {
            self.id = id
            self.path = path
            self.branch = branch
            self.agentWorktreeTask = agentWorktreeTask
            self.isWorktree = isWorktree
            self.sessions = sessions
            self.liveCount = sessions.count { $0.isAlive && !$0.state.isEnded }
        }

        /// The row's headline: the agent worktree's task, the branch, or the
        /// checkout's own directory name — in that order, because that is the
        /// order of how much each one tells a reader.
        ///
        /// Never invented: a checkout that reported none of the three says so.
        public var title: String {
            if let agentWorktreeTask, !agentWorktreeTask.isEmpty { return agentWorktreeTask }
            if let branch, !branch.isEmpty { return branch }
            if let path { return BoardGrouping.projectName(forPath: path) }
            return ProjectTree.unknownCheckoutTitle
        }

        /// The line beside ``title``, when there is a second fact worth
        /// showing.
        ///
        /// Only the branch, and only when the title did not already use it —
        /// an agent worktree names its task first, and the branch is what a
        /// reader wants next. A checkout whose title *is* its branch has
        /// nothing to add.
        public var subtitle: String? {
            guard let agentWorktreeTask, !agentWorktreeTask.isEmpty else { return nil }
            return branch
        }
    }

    /// What a checkout is called when nothing about it was recorded.
    public static let unknownCheckoutTitle = "Unknown checkout"

    // MARK: - Building

    /// Builds the tree for one frame.
    ///
    /// - Parameters:
    ///   - board: the frame. Its sessions are already in board order, and that
    ///     order is preserved inside every checkout and used to rank the
    ///     projects — so the repository that needs a person is at the top.
    ///   - names: display names by project path, from `projects.name`. A path
    ///     the store has never seen falls back to its last component, which is
    ///     what the resolver would have called it anyway.
    public static func build(
        board: BoardSnapshot,
        names: [String: String] = [:]
    ) -> ProjectTree {
        var order: [String] = []
        var byProject: [String: [SessionSnapshot]] = [:]
        var ungrouped: [SessionSnapshot] = []

        for session in board.sessions {
            guard let key = board.projectKey(for: session) else {
                ungrouped.append(session)
                continue
            }
            if byProject[key] == nil {
                byProject[key] = []
                order.append(key)
            }
            byProject[key]?.append(session)
        }

        let projects = order.map { key -> Project in
            let sessions = byProject[key] ?? []
            return Project(
                key: key,
                name: names[key] ?? BoardGrouping.projectName(forPath: key),
                checkouts: checkouts(in: sessions, projectKey: key),
                harnesses: Harness.allCases.filter { harness in
                    sessions.contains { $0.key.harness == harness }
                },
                isRepository: sessions.contains { $0.identity.gitRoot != nil }
            )
        }
        return ProjectTree(projects: projects, ungrouped: ungrouped)
    }

    /// Divides a project's sessions by the checkout each is working in.
    ///
    /// The key is the worktree path when there is one and the project root
    /// otherwise, so the main checkout and every linked worktree of one
    /// repository are siblings rather than one undifferentiated pile. A
    /// session that inherited its project from an ancestor — a subagent with no
    /// directory at all — has no checkout of its own to name, and joins the
    /// checkout its nearest placed ancestor is in.
    private static func checkouts(
        in sessions: [SessionSnapshot],
        projectKey: String
    ) -> [Checkout] {
        var order: [String] = []
        var byCheckout: [String: [SessionSnapshot]] = [:]
        var attributes: [String: (path: String?, branch: String?)] = [:]

        for session in sessions {
            let path = session.identity.worktreePath ?? session.identity.gitRoot
                ?? session.identity.cwd
            let id = path ?? projectKey
            if byCheckout[id] == nil {
                byCheckout[id] = []
                order.append(id)
                attributes[id] = (path, session.identity.gitBranch)
            } else if attributes[id]?.branch == nil, let branch = session.identity.gitBranch {
                attributes[id]?.branch = branch
            }
            byCheckout[id]?.append(session)
        }

        return order.map { id in
            let attribute = attributes[id] ?? (nil, nil)
            return Checkout(
                id: "\(projectKey)#\(id)",
                path: attribute.path,
                branch: attribute.branch,
                agentWorktreeTask: attribute.path.flatMap(ProjectResolver.agentWorktreeTask(in:)),
                isWorktree: attribute.path.map { $0 != projectKey } ?? false,
                // Already in board order: the sessions were appended in the
                // order the frame listed them.
                sessions: byCheckout[id] ?? []
            )
        }
    }
}
