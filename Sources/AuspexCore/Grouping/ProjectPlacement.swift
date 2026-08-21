import Foundation

/// Where a session's working directory sits: which project it belongs to, and
/// which checkout of that project it is actually in.
///
/// The distinction is the whole point. Three agents working in three worktrees
/// of one repository are three checkouts of *one* project, and a board that
/// showed them as three projects would hide exactly the thing a person opened
/// it to see. So ``projectRootPath`` is the main repository whenever git says
/// there is one, and ``worktreePath`` carries the checkout.
public struct ProjectPlacement: Hashable, Sendable, Codable {
    /// What sessions group by: the main repository root when the directory is
    /// inside a git repository, and the directory itself when it is not.
    public let projectRootPath: String
    /// The display name — the last path component of ``projectRootPath``.
    public let projectName: String
    /// The main repository root, or `nil` when there is no repository. Equal
    /// to ``projectRootPath`` whenever it is not `nil`.
    public let gitRoot: String?
    /// The linked worktree the session is in, when it is in one rather than in
    /// the main checkout.
    public let worktreePath: String?
    /// The branch checked out in whichever gitdir applies — the worktree's own
    /// `HEAD` for a linked worktree, the repository's otherwise. A detached
    /// `HEAD` gives the short commit hash instead.
    public let branch: String?
    /// `true` when ``worktreePath`` is set: the directory is a linked worktree
    /// rather than the main checkout.
    public var isWorktree: Bool { worktreePath != nil }
    /// The task name of an agent worktree — the `<name>` in
    /// `.agents/worktrees/<name>` and its per-harness variants — when the path
    /// follows one of those conventions.
    ///
    /// Agents are told to work in a worktree named after their task, so this
    /// is usually the most informative label a row has before a title arrives.
    public let agentWorktreeTask: String?

    /// Why this directory names no project, when it names none.
    ///
    /// `nil` for an ordinary placement, which is nearly all of them. Set for a
    /// directory a harness creates per conversation rather than per project —
    /// see ``HarnessSandbox`` — where the truthful answer is that the session
    /// has no project at all, not that it has one nobody has heard of.
    ///
    /// A word rather than a flag so a reader can be told which rule fired.
    public let placementNote: String?

    /// `true` when this directory is not a project a board should group by.
    public var isProjectless: Bool { placementNote != nil }

    /// Creates a placement.
    public init(
        projectRootPath: String,
        projectName: String,
        gitRoot: String? = nil,
        worktreePath: String? = nil,
        branch: String? = nil,
        agentWorktreeTask: String? = nil,
        placementNote: String? = nil
    ) {
        self.projectRootPath = projectRootPath
        self.projectName = projectName
        self.gitRoot = gitRoot
        self.worktreePath = worktreePath
        self.branch = branch
        self.agentWorktreeTask = agentWorktreeTask
        self.placementNote = placementNote
    }

    /// The placement of a directory that is in no repository at all: it is its
    /// own project, named after itself.
    public static func plain(directory: String) -> ProjectPlacement {
        ProjectPlacement(
            projectRootPath: directory,
            projectName: (directory as NSString).lastPathComponent
        )
    }

    /// The placement of a directory a harness made for one conversation.
    ///
    /// ``projectRootPath`` is still the thread directory, because a placement
    /// has to say *where* the session is and that is where it is. What makes
    /// it projectless is ``placementNote``, and every reader that groups goes
    /// through ``BoardSnapshot/projectKey(for:)``, which asks.
    public static func sandbox(thread: HarnessSandbox.Thread) -> ProjectPlacement {
        ProjectPlacement(
            projectRootPath: thread.directory,
            projectName: thread.name,
            placementNote: thread.note
        )
    }
}
