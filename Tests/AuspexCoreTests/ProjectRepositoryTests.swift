import AgentSessionKit
import AgentSessionLive
import Foundation
import GRDB
import Testing

@testable import AuspexCore

@Suite("ProjectRepository")
struct ProjectRepositoryTests {
    private func makeStore() throws -> AuspexStore {
        try AuspexStore(inMemory: true)
    }

    private func store(_ store: AuspexStore, _ key: SessionKey, cwd: String? = nil) throws {
        let snapshot = SessionStateReducer.initialSnapshot(
            identity: Fixtures.identity(key: key, cwd: cwd)
        )
        try SessionRepository(store: store).upsert(snapshot: snapshot)
    }

    private let widget = ProjectPlacement(
        projectRootPath: "/Users/example/Code/widget",
        projectName: "widget",
        gitRoot: "/Users/example/Code/widget",
        branch: "main"
    )
    private let widgetWorktree = ProjectPlacement(
        projectRootPath: "/Users/example/Code/widget",
        projectName: "widget",
        gitRoot: "/Users/example/Code/widget",
        worktreePath: "/Users/example/Code/widget/.agents/worktrees/feat-x",
        branch: "feat/x",
        agentWorktreeTask: "feat-x"
    )

    // MARK: - Upserting

    @Test("a placement becomes a project row, and upserting it again is idempotent")
    func projectUpsertIsIdempotent() throws {
        let store = try makeStore()
        let repository = ProjectRepository(store: store)

        let first = try repository.upsert(widget)
        let second = try repository.upsert(widget)
        #expect(first.projectID == second.projectID)
        #expect(first.worktreeID == nil)

        let projects = try repository.fetchProjects()
        #expect(projects.count == 1)
        #expect(projects[0].name == "widget")
        #expect(projects[0].gitRoot == "/Users/example/Code/widget")
    }

    @Test("a worktree hangs off its project rather than becoming one")
    func worktreeHangsOffTheProject() throws {
        let store = try makeStore()
        let repository = ProjectRepository(store: store)

        let main = try repository.upsert(widget)
        let branch = try repository.upsert(widgetWorktree)
        #expect(branch.projectID == main.projectID)
        let worktreeID = try #require(branch.worktreeID)

        #expect(try repository.fetchProjects().count == 1)
        let worktrees = try repository.worktrees(inProject: main.projectID)
        #expect(worktrees.map(\.id) == [worktreeID])
        #expect(worktrees[0].branch == "feat/x")
    }

    @Test("a later resolution that learned less does not erase what is stored")
    func laterResolutionDoesNotErase() throws {
        let store = try makeStore()
        let repository = ProjectRepository(store: store)
        _ = try repository.upsert(widgetWorktree)

        // The same paths, resolved while the repository was unreadable.
        _ = try repository.upsert(ProjectPlacement(
            projectRootPath: "/Users/example/Code/widget",
            projectName: "widget",
            worktreePath: "/Users/example/Code/widget/.agents/worktrees/feat-x"
        ))

        let project = try #require(try repository.project(rootPath: "/Users/example/Code/widget"))
        #expect(project.gitRoot == "/Users/example/Code/widget")
        #expect(try repository.worktrees(inProject: project.id)[0].branch == "feat/x")
    }

    // MARK: - Assigning

    @Test("assigning points a session's foreign keys at the placement's rows")
    func assignSetsForeignKeys() throws {
        let store = try makeStore()
        let repository = ProjectRepository(store: store)
        let key = Fixtures.key()
        try self.store(store, key)

        let assignment = try repository.assign(widgetWorktree, to: key)
        let row = try #require(try store.dbWriter.read { db in
            try Row.fetchOne(
                db,
                sql: "SELECT project_id, worktree_id FROM sessions WHERE key = ?",
                arguments: [key.description]
            )
        })
        #expect(row["project_id"] as Int64? == assignment.projectID)
        #expect(row["worktree_id"] as Int64? == assignment.worktreeID)
    }

    @Test("a batch upserts each distinct placement once")
    func batchAssignment() throws {
        let store = try makeStore()
        let repository = ProjectRepository(store: store)
        let first = Fixtures.key(.claudeCode, "one")
        let second = Fixtures.key(.codex, "two")
        let third = Fixtures.key(.grokBuild, "three")
        for key in [first, second, third] { try self.store(store, key) }

        let assignments = try store.dbWriter.write { db in
            try repository.assign(
                placements: [first: widget, second: widget, third: widgetWorktree],
                in: db
            )
        }
        #expect(assignments.count == 3)
        #expect(assignments[first]?.projectID == assignments[third]?.projectID)
        #expect(assignments[first]?.worktreeID == nil)
        #expect(assignments[third]?.worktreeID != nil)
        #expect(try repository.fetchProjects().count == 1)
    }

    @Test("a placement for a session nobody stored writes the project but no session")
    func placementForUnknownSession() throws {
        let store = try makeStore()
        let repository = ProjectRepository(store: store)
        _ = try repository.assign(widget, to: Fixtures.key(.cursor, "unknown"))
        #expect(try repository.fetchProjects().count == 1)
        #expect(try SessionRepository(store: store).sessionCount() == 0)
    }

    @Test("an upsert after an assignment leaves the foreign keys alone")
    func upsertPreservesAssignment() throws {
        let store = try makeStore()
        let sessions = SessionRepository(store: store)
        let repository = ProjectRepository(store: store)
        let key = Fixtures.key()
        try self.store(store, key)
        let assignment = try repository.assign(widget, to: key)

        // The board keeps ticking; every event re-upserts the row.
        var snapshot = try #require(try sessions.fetch(key: key))
        snapshot.turnCount = 4
        try sessions.upsert(snapshot: snapshot)

        let row = try #require(try store.dbWriter.read { db in
            try Row.fetchOne(
                db,
                sql: "SELECT project_id, turn_count FROM sessions WHERE key = ?",
                arguments: [key.description]
            )
        })
        #expect(row["project_id"] as Int64? == assignment.projectID)
        #expect(row["turn_count"] as Int? == 4)
    }

    // MARK: - Roots

    @Test("root keys are written from the tree, and a fresh row is its own root")
    func rootKeys() throws {
        let store = try makeStore()
        let repository = ProjectRepository(store: store)
        let root = Fixtures.key(.claudeCode, "root")
        let child = Fixtures.key(.codex, "child")
        let grandchild = Fixtures.key(.grokBuild, "grandchild")
        for key in [root, child, grandchild] { try self.store(store, key) }

        func storedRoot(_ key: SessionKey) throws -> String? {
            try store.dbWriter.read { db in
                try String.fetchOne(
                    db,
                    sql: "SELECT root_key FROM sessions WHERE key = ?",
                    arguments: [key.description]
                )
            }
        }
        // Before anything links them, each row is its own root.
        #expect(try storedRoot(grandchild) == grandchild.description)

        try repository.setRootKeys([root: root, child: root, grandchild: root])
        #expect(try storedRoot(child) == root.description)
        #expect(try storedRoot(grandchild) == root.description)

        #expect(try repository.sessions(inTreeRootedAt: root).map(\.key).count == 3)
    }

    // MARK: - Reading

    @Test("project counts tally the sessions assigned to them")
    func projectCounts() throws {
        let store = try makeStore()
        let repository = ProjectRepository(store: store)
        let sessions = SessionRepository(store: store)
        let first = Fixtures.key(.claudeCode, "one")
        let second = Fixtures.key(.codex, "two")
        let elsewhere = Fixtures.key(.cursor, "three")

        for key in [first, second, elsewhere] { try self.store(store, key) }
        var dead = try #require(try sessions.fetch(key: second))
        dead.isAlive = false
        try sessions.upsert(snapshot: dead)

        _ = try repository.assign(widget, to: first)
        _ = try repository.assign(widgetWorktree, to: second)
        _ = try repository.assign(
            ProjectPlacement.plain(directory: "/Users/example/scratch"), to: elsewhere
        )

        let projects = try repository.fetchProjects()
        #expect(projects.count == 2)
        let widgetSummary = try #require(projects.first { $0.name == "widget" })
        #expect(widgetSummary.sessionCount == 2)
        #expect(widgetSummary.liveCount == 1)
        #expect(widgetSummary.worktreeCount == 1)

        #expect(try repository.sessions(inProject: widgetSummary.id).map(\.key).sorted {
            $0.description < $1.description
        } == [first, second].sorted { $0.description < $1.description })
    }

    @Test("counts can be skipped for a picker that only needs names")
    func fetchWithoutCounts() throws {
        let store = try makeStore()
        let repository = ProjectRepository(store: store)
        let key = Fixtures.key()
        try self.store(store, key)
        _ = try repository.assign(widget, to: key)

        let projects = try repository.fetchProjects(withCounts: false)
        #expect(projects.map(\.name) == ["widget"])
        #expect(projects[0].sessionCount == 0)
    }

    @Test("a project with no sessions is still listed")
    func emptyProjectIsListed() throws {
        let store = try makeStore()
        let repository = ProjectRepository(store: store)
        _ = try repository.upsert(widget)
        let projects = try repository.fetchProjects()
        #expect(projects.map(\.name) == ["widget"])
        #expect(projects[0].sessionCount == 0)
        #expect(projects[0].lastEventAt == nil)
    }
}
