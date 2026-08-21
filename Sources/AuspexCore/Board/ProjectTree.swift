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
    /// lying about what the machine is doing. The finished ones are dropped
    /// all the same — see ``listable(_:)`` and ``ungroupedHidden``.
    public let ungrouped: [BoardRow]

    /// How many sessions under no project have finished, and are in the
    /// board's Ended section rather than in this column.
    public let ungroupedHidden: Int

    /// How many sessions the sidebar draws under one checkout, and under
    /// "No project", before it offers the rest behind a row.
    ///
    /// ## Why the tree has a cap at all
    ///
    /// The sidebar is one of two surfaces that never leave the window, and
    /// every row in it is a view SwiftUI compares on every graph update — the
    /// report this was measured against had 143 of them, and a `sample` of
    /// that window was `AG::LayoutDescriptor::compare` most of the way down.
    /// A tree is a way of *finding* a session, and a column that lists eighty
    /// of them under one heading has stopped being one; eight is where a
    /// checkout still reads as a list rather than as a wall, and the rest are
    /// one click away.
    ///
    /// It caps what is *drawn*, not what is known: the rows are all here, and
    /// every count on every row above is tallied over all of them, so a
    /// checkout whose one red session is past the cap is still drawn red.
    public static let listLimit = 8

    /// An empty tree, for a view's initial state.
    public static let empty = ProjectTree(projects: [], ungrouped: [])

    public init(projects: [Project], ungrouped: [BoardRow], ungroupedHidden: Int = 0) {
        self.projects = projects
        self.ungrouped = ungrouped
        self.ungroupedHidden = max(0, ungroupedHidden)
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
        /// How many of its sessions are asking for a person.
        ///
        /// Carried on the row rather than counted in the sidebar's body,
        /// because a body runs many times for one change and this one is what
        /// decides whether a project is drawn in red — the one thing in a
        /// column of a dozen project names that has to be true at a glance.
        public let needsYouCount: Int
        /// How many have reported finishing.
        public let doneReportedCount: Int
        /// The distinct harnesses at work here, in catalog order — the row's
        /// harness dots.
        public let harnesses: [Harness]
        /// `false` when no session here reported a git root: the directory is
        /// its own project, named after itself.
        public let isRepository: Bool
        /// The colour a person chose for it, as `#RRGGBB`, when it is one of
        /// their own projects.
        public let colorHex: String?
        /// Whether it is pinned. Pinned projects are already first in the
        /// list; the row says so too, because a list that reorders itself
        /// without explaining why is a list nobody trusts.
        public let isPinned: Bool

        public var id: String { key }

        public init(
            key: String,
            name: String,
            checkouts: [Checkout],
            harnesses: [Harness],
            isRepository: Bool,
            colorHex: String? = nil,
            isPinned: Bool = false
        ) {
            self.key = key
            self.name = name
            self.checkouts = checkouts
            self.harnesses = harnesses
            self.isRepository = isRepository
            self.colorHex = colorHex
            self.isPinned = isPinned
            self.liveCount = checkouts.reduce(0) { $0 + $1.liveCount }
            // Every session under the project, including the ones the tree
            // does not list — see ``Checkout/hiddenCount``.
            self.sessionCount = checkouts.reduce(0) { $0 + $1.sessionCount }
            self.needsYouCount = checkouts.reduce(0) { $0 + $1.needsYouCount }
            self.doneReportedCount = checkouts.reduce(0) { $0 + $1.doneReportedCount }
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
        /// The sessions still running in it, in board order with delegated
        /// ones nested under whoever spawned them — see ``BoardRow/depth``.
        ///
        /// Not every session in the checkout: the finished ones are not in the
        /// tree at all. See ``ProjectTree/listable(_:)`` and ``hiddenCount``.
        public let sessions: [BoardRow]
        /// How many of this checkout's sessions have finished, and are
        /// therefore in the board's Ended section rather than here.
        ///
        /// Carried rather than recomputed because it is the only trace they
        /// leave in this column, and a sidebar that quietly dropped rows would
        /// be lying about what the machine is doing.
        public let hiddenCount: Int
        /// How many of them are believed to be running.
        public let liveCount: Int
        /// How many are asking for a person.
        public let needsYouCount: Int
        /// How many have reported finishing.
        public let doneReportedCount: Int

        /// Every session in the checkout, listed or not.
        public var sessionCount: Int { sessions.count + hiddenCount }

        /// - Parameters:
        ///   - sessions: the rows to list.
        ///   - hiddenCount: how many more the checkout holds.
        ///   - counts: the tallies, over *all* of them. A checkout whose one
        ///     red session is past the cap still has to be drawn red, or the
        ///     cap would hide the thing the sidebar exists to point at.
        public init(
            id: String,
            path: String?,
            branch: String?,
            agentWorktreeTask: String?,
            isWorktree: Bool,
            sessions: [BoardRow],
            hiddenCount: Int = 0,
            counts: Counts? = nil
        ) {
            self.id = id
            self.path = path
            self.branch = branch
            self.agentWorktreeTask = agentWorktreeTask
            self.isWorktree = isWorktree
            self.sessions = sessions
            self.hiddenCount = max(0, hiddenCount)
            let tallies = counts ?? Counts(rows: sessions)
            self.liveCount = tallies.live
            self.needsYouCount = tallies.needsYou
            self.doneReportedCount = tallies.doneReported
        }

        /// What a checkout's badge says, tallied over every session in it
        /// rather than over the ones that fitted.
        public struct Counts: Sendable, Equatable {
            public var live: Int
            public var needsYou: Int
            public var doneReported: Int

            public init(live: Int = 0, needsYou: Int = 0, doneReported: Int = 0) {
                self.live = live
                self.needsYou = needsYou
                self.doneReported = doneReported
            }

            public init(rows: [BoardRow]) {
                self.init(
                    live: rows.count { !$0.isEnded },
                    needsYou: rows.count { $0.needsPerson },
                    doneReported: rows.count { $0.isDoneReported }
                )
            }
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
        names: [String: String] = [:],
        builder: BoardRowBuilder? = nil
    ) -> ProjectTree {
        // One builder for the whole tree: it holds the index that turns "what
        // is my parent called" from a scan of the board into a lookup.
        let builder = builder ?? BoardRowBuilder(board: board)
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

        let projects = board.claims.pinnedFirst(order) { $0 }.map { key -> Project in
            let sessions = byProject[key] ?? []
            // In catalog order, and in one pass: asking `allCases.filter` here
            // walked every session once per harness, on a sidebar that is
            // rebuilt on every frame.
            var seen: Set<Harness> = []
            for session in sessions { seen.insert(session.key.harness) }
            return Project(
                key: key,
                // The person's own name for the project first, then the
                // store's, then the path's last component. A project somebody
                // named should be called that everywhere, and the store's name
                // is what the resolver decided.
                name: board.claims.name(forKey: key)
                    ?? names[key] ?? BoardGrouping.projectName(forPath: key),
                checkouts: checkouts(in: sessions, projectKey: key, builder: builder),
                harnesses: Harness.allCases.filter(seen.contains),
                isRepository: sessions.contains { $0.identity.gitRoot != nil },
                colorHex: board.claims.colorHex(forKey: key),
                isPinned: board.claims.isPinned(key)
            )
        }
        let listedUngrouped = listable(ungrouped)
        return ProjectTree(
            projects: projects,
            ungrouped: nested(listedUngrouped, builder: builder),
            ungroupedHidden: ungrouped.count - listedUngrouped.count
        )
    }

    /// What a checkout's badges say, tallied straight off the snapshots.
    ///
    /// Over every session in it, listed or not — a badge that only counted the
    /// listed rows would go quiet exactly when a checkout got busy enough to be
    /// worth looking at. From snapshots and not from rows, because building a
    /// row per unlisted session is the work the cut exists to stop doing.
    static func counts(
        of sessions: [SessionSnapshot],
        builder: BoardRowBuilder
    ) -> Checkout.Counts {
        var counts = Checkout.Counts()
        for session in sessions {
            if !session.state.isEnded { counts.live += 1 }
            let attention = builder.attention(for: session)
            if attention.wantsPerson { counts.needsYou += 1 }
            if attention.isDoneReported { counts.doneReported += 1 }
        }
        return counts
    }

    /// The sessions a branch of the tree can list: the ones that are not over.
    ///
    /// A finished session has no state to watch and nothing anybody has to act
    /// on, and the board already keeps every one of them — in the collapsed
    /// section at the bottom, which exists for exactly this. Listing them in
    /// the tree as well is what turns a sidebar of a dozen live sessions into a
    /// column of 143 rows, and every one of those rows is a view SwiftUI
    /// compares on every graph update.
    ///
    /// How many of what is left gets *drawn* is the sidebar's decision rather
    /// than this type's — see ``listLimit``. The difference is real: a person
    /// can ask the sidebar for the rest of the live ones, and nobody needs to
    /// ask it for the finished ones, because they are somewhere better.
    static func listable(_ sessions: [SessionSnapshot]) -> [SessionSnapshot] {
        sessions.filter { !$0.state.isEnded }
    }

    /// A run of sessions as rows, with delegated ones placed under whoever
    /// spawned them.
    ///
    /// The frame's order already puts the session that most needs a person at
    /// the top, and that is the order roots keep. What this adds is that a
    /// subagent appears *under* its parent rather than several rows above it,
    /// which is the only thing that makes an indent mean anything.
    ///
    /// Done here rather than in the sidebar's body because it is O(sessions)
    /// and a body may run many times for one change.
    static func nested(
        _ sessions: [SessionSnapshot],
        builder: BoardRowBuilder
    ) -> [BoardRow] {
        let present = Set(sessions.map(\.key))
        var childrenOf: [SessionKey: [SessionSnapshot]] = [:]
        var roots: [SessionSnapshot] = []
        for session in sessions {
            if let parent = session.identity.parent, parent != session.key, present.contains(parent) {
                childrenOf[parent, default: []].append(session)
            } else {
                roots.append(session)
            }
        }

        var rows: [BoardRow] = []
        rows.reserveCapacity(sessions.count)
        var visited: Set<SessionKey> = []
        func walk(_ session: SessionSnapshot, depth: Int) {
            guard visited.insert(session.key).inserted else { return }
            rows.append(builder.row(for: session, depth: depth))
            // Capped so a ten-deep chain does not push a title off a 232 pt
            // column; the tree's full shape is the trace pane's job to show.
            for child in childrenOf[session.key] ?? [] { walk(child, depth: min(depth + 1, 2)) }
        }
        for root in roots { walk(root, depth: 0) }
        // A cycle in the recorded parent links would strand its members;
        // appending whatever is left keeps the tree total.
        for session in sessions where !visited.contains(session.key) {
            rows.append(builder.row(for: session, depth: 0))
        }
        return rows
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
        projectKey: String,
        builder: BoardRowBuilder
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
            let all = byCheckout[id] ?? []
            let listed = listable(all)
            return Checkout(
                id: "\(projectKey)#\(id)",
                path: attribute.path,
                branch: attribute.branch,
                agentWorktreeTask: attribute.path.flatMap(ProjectResolver.agentWorktreeTask(in:)),
                // A pseudo project is not a repository, so nothing under it
                // is a checkout *of* one. A scratch thread has a path and it
                // differs from the key — the test every real project uses —
                // and calling it a worktree would put a branch glyph beside a
                // folder that has no branch.
                isWorktree: !PseudoProject.isPseudo(projectKey)
                    && attribute.path.map { $0 != projectKey } ?? false,
                // Already in board order: the sessions were appended in the
                // order the frame listed them.
                sessions: nested(listed, builder: builder),
                hiddenCount: all.count - listed.count,
                // Over every session in the checkout rather than over the
                // eight that fitted: a badge that only counted the listed rows
                // would go quiet exactly when a checkout got busy enough to be
                // worth looking at. From the snapshots and not from rows,
                // because a row per hidden session is the work the cap exists
                // to stop doing.
                counts: counts(of: all, builder: builder)
            )
        }
    }
}
