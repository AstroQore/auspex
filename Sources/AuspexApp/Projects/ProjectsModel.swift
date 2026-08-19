import AgentSessionKit
import AgentSessionLive
import AuspexCore
import Foundation
import Observation

/// The sidebar tree's state: which rows are open, and what the store calls
/// each project.
///
/// The tree itself is *not* stored here. It is derived from the frame the
/// board is already holding, which is what keeps the sidebar and the wall from
/// ever disagreeing about how many sessions are in a repository. What this
/// owns is the part a frame cannot supply:
///
/// - **Names.** `projects.name` is written by the resolver and outlives every
///   session in the project, so a repository whose agents have all finished is
///   still called by its name rather than by a path component. Refreshed on a
///   slow timer because a project is created once and renamed almost never.
/// - **Disclosure.** Which projects and checkouts the reader has opened.
@MainActor
@Observable
final class ProjectsModel {
    /// The tree the sidebar draws, rebuilt once per applied frame.
    ///
    /// Stored rather than derived in `SidebarView.body`. Building it walks
    /// every session on the board, and a body may run many times for one
    /// change — a profile of the old sidebar had `ProjectTree.build` inside
    /// `SidebarView.body` as one of the hot paths. It is also what makes the
    /// auto-expand below happen once per frame rather than once per render.
    private(set) var tree: ProjectTree = .empty

    /// The frame the tree was last built from, so a change of names can
    /// rebuild it without waiting for the next one.
    private var lastBoard: BoardSnapshot = .empty

    /// Project display names by root path, from the store.
    private(set) var names: [String: String] = [:]

    /// Projects the reader has open.
    var expandedProjects: Set<String> = []

    /// Checkouts the reader has *closed*, by ``ProjectTree/Checkout/id``.
    ///
    /// Stored as the negative because a checkout starts open: most projects
    /// have exactly one, and making a person click twice to reach a session in
    /// a project they just opened is a level of ceremony a sidebar has not
    /// earned.
    var collapsedCheckouts: Set<String> = []

    /// Projects that have been auto-opened once because something in them was
    /// live.
    ///
    /// Recorded so it happens *once* per project. A tree that re-opened a row
    /// every time a session started would fight anyone who closed it, and a
    /// tree that never opened anything would hide the only rows worth seeing
    /// on a machine with thirty projects and two live ones.
    private var didAutoExpand: Set<String> = []

    private var repository: ProjectRepository?
    private var refreshTask: Task<Void, Never>?

    /// How often the names are re-read.
    private static let refreshInterval = Duration.seconds(20)

    /// Starts refreshing names from `repository`.
    func start(repository: ProjectRepository?) {
        self.repository = repository
        guard repository != nil else { return }
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshNames()
                do {
                    try await Task.sleep(for: Self.refreshInterval)
                } catch {
                    return
                }
            }
        }
    }

    /// Stops refreshing. Called when the app is shutting down.
    func stop() {
        refreshTask?.cancel()
        refreshTask = nil
    }

    /// Re-reads `projects` and updates the name map.
    ///
    /// Counts are deliberately not asked for: every tally the sidebar shows
    /// comes from the live frame, and a stored count that disagreed with the
    /// cards next to it would be the more visible of the two wrong answers.
    func refreshNames() async {
        guard let repository else { return }
        let summaries = await Task.detached(priority: .utility) { () -> [ProjectSummary] in
            (try? repository.fetchProjects(withCounts: false)) ?? []
        }.value
        var mapped: [String: String] = [:]
        mapped.reserveCapacity(summaries.count)
        for summary in summaries { mapped[summary.rootPath] = summary.name }
        guard mapped != names else { return }
        names = mapped
        rebuild(board: lastBoard)
    }

    /// Rebuilds the tree for one frame and opens any project that is live for
    /// the first time.
    ///
    /// Called from ``LiveBoardModel/onFrame``, which is the one place a frame
    /// arrives. A view must not call this: writing observable state from a
    /// body is what turns a render into a loop.
    func rebuild(board: BoardSnapshot) {
        lastBoard = board
        let tree = ProjectTree.build(board: board, names: names)
        for project in tree.projects where project.liveCount > 0 {
            guard didAutoExpand.insert(project.key).inserted else { continue }
            expandedProjects.insert(project.key)
        }
        self.tree = tree
    }

    // MARK: Disclosure

    func isExpanded(project: ProjectTree.Project) -> Bool {
        expandedProjects.contains(project.key)
    }

    func toggle(project: ProjectTree.Project) {
        if expandedProjects.contains(project.key) {
            expandedProjects.remove(project.key)
        } else {
            expandedProjects.insert(project.key)
        }
    }

    func isExpanded(checkout: ProjectTree.Checkout) -> Bool {
        !collapsedCheckouts.contains(checkout.id)
    }

    func toggle(checkout: ProjectTree.Checkout) {
        if collapsedCheckouts.contains(checkout.id) {
            collapsedCheckouts.remove(checkout.id)
        } else {
            collapsedCheckouts.insert(checkout.id)
        }
    }
}
