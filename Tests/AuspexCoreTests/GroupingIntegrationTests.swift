import AgentSessionKit
import AgentSessionLive
import Foundation
import GRDB
import Testing

@testable import AuspexCore

@Suite("Grouping integration")
struct GroupingIntegrationTests {
    private func makeRegistry(_ store: AuspexStore) -> SessionRegistry {
        // Everything immediate: one frame and one transaction per event, so a
        // scripted sequence is deterministic.
        SessionRegistry(store: store, publishInterval: 0, persistInterval: 0, tickInterval: 0)
    }

    private func started(
        _ key: SessionKey,
        cwd: String? = "/Users/example/Code/widget",
        pid: pid_t? = nil,
        at offset: TimeInterval = 0
    ) -> AgentEvent {
        var identity = Fixtures.identity(key: key, cwd: cwd, pid: pid)
        identity.gitRoot = nil
        identity.gitBranch = nil
        return Fixtures.event(.sessionStarted(identity: identity), key: key, at: offset)
    }

    private func row(_ store: AuspexStore, _ key: SessionKey) throws -> Row? {
        try store.dbWriter.read { db in
            try Row.fetchOne(
                db,
                sql: """
                    SELECT project_id, worktree_id, root_key, parent_key, parent_link, git_branch
                    FROM sessions WHERE key = ?
                    """,
                arguments: [key.description]
            )
        }
    }

    private let placement = ProjectPlacement(
        projectRootPath: "/Users/example/Code/widget",
        projectName: "widget",
        gitRoot: "/Users/example/Code/widget",
        worktreePath: "/Users/example/Code/widget/.agents/worktrees/feat-x",
        branch: "feat/x",
        agentWorktreeTask: "feat-x"
    )

    // MARK: - Placements

    @Test("a placement reaches the identity, the board, and the foreign keys")
    func placementIsAppliedAndPersisted() async throws {
        let store = try AuspexStore(inMemory: true)
        let registry = makeRegistry(store)
        let key = Fixtures.key()

        await registry.ingest(started(key))
        #expect(await registry.applyPlacements([key: placement]) == 1)
        await registry.stop()

        let identity = try #require(await registry.session(for: key)?.identity)
        #expect(identity.gitRoot == "/Users/example/Code/widget")
        #expect(identity.worktreePath == placement.worktreePath)
        #expect(identity.gitBranch == "feat/x")

        let stored = try #require(try row(store, key))
        #expect(stored["project_id"] as Int64? != nil)
        #expect(stored["worktree_id"] as Int64? != nil)
        #expect(stored["git_branch"] as String? == "feat/x")

        let projects = try store.projects.fetchProjects()
        #expect(projects.map(\.name) == ["widget"])
        #expect(projects[0].sessionCount == 1)
        #expect(projects[0].worktreeCount == 1)
    }

    @Test("a placement with nothing to say about git still assigns the project")
    func placementWithoutGit() async throws {
        let store = try AuspexStore(inMemory: true)
        let registry = makeRegistry(store)
        let key = Fixtures.key()

        await registry.ingest(started(key, cwd: "/Users/example/scratch"))
        await registry.applyPlacements(
            [key: ProjectPlacement.plain(directory: "/Users/example/scratch")]
        )
        await registry.stop()

        #expect(await registry.session(for: key)?.identity.gitRoot == nil)
        #expect(try row(store, key)?["project_id"] as Int64? != nil)
        #expect(try store.projects.fetchProjects().map(\.rootPath) == ["/Users/example/scratch"])
    }

    @Test("a placement for a session the registry has never seen is ignored")
    func placementForUnknownSession() async throws {
        let store = try AuspexStore(inMemory: true)
        let registry = makeRegistry(store)
        #expect(await registry.applyPlacements([Fixtures.key(): placement]) == 0)
        await registry.stop()
        #expect(try store.projects.fetchProjects().isEmpty)
    }

    @Test("sessions in two worktrees of one repository share a project row")
    func worktreesShareAProjectRow() async throws {
        let store = try AuspexStore(inMemory: true)
        let registry = makeRegistry(store)
        let first = Fixtures.key(.claudeCode, "one")
        let second = Fixtures.key(.codex, "two")

        await registry.ingest(started(first))
        await registry.ingest(started(second))
        await registry.applyPlacements([
            first: placement,
            second: ProjectPlacement(
                projectRootPath: "/Users/example/Code/widget",
                projectName: "widget",
                gitRoot: "/Users/example/Code/widget",
                worktreePath: "/Users/example/Code/widget/.agents/worktrees/feat-y",
                branch: "feat/y",
                agentWorktreeTask: "feat-y"
            ),
        ])
        await registry.stop()

        let projects = try store.projects.fetchProjects()
        #expect(projects.count == 1)
        #expect(projects[0].sessionCount == 2)
        #expect(projects[0].worktreeCount == 2)

        let board = await registry.snapshot()
        #expect(board.byProject["/Users/example/Code/widget"]?.count == 2)
    }

    // MARK: - Links

    @Test("an inferred link becomes a parent, and re-roots the subtree in the store")
    func linkIsAppliedAndReroots() async throws {
        let store = try AuspexStore(inMemory: true)
        let registry = makeRegistry(store)
        let parent = Fixtures.key(.claudeCode, "parent")
        let child = Fixtures.key(.codex, "child")
        let grandchild = Fixtures.key(.grokBuild, "grandchild")

        await registry.ingest(started(parent))
        await registry.ingest(started(child))
        var identity = Fixtures.identity(key: grandchild)
        identity.parent = child
        identity.parentLink = .subagent(toolUseID: "t1")
        await registry.ingest(
            Fixtures.event(.sessionStarted(identity: identity), key: grandchild, at: 0)
        )
        let applied = await registry.applyLinks([
            ProcessLink(
                child: child,
                parent: parent,
                link: .envInherited,
                confidence: .high,
                evidence: "test"
            )
        ])
        #expect(applied == 1)
        await registry.stop()

        #expect(await registry.session(for: child)?.identity.parent == parent)
        #expect(await registry.session(for: child)?.identity.parentLink == .envInherited)
        let childRow = try #require(try row(store, child))
        #expect(childRow["parent_key"] as String? == parent.description)
        #expect(childRow["root_key"] as String? == parent.description)
        // The grandchild is not dirty, and its root moved anyway.
        #expect(try row(store, grandchild)?["root_key"] as String? == parent.description)
    }

    @Test("a link is refused for a session that acquired a parent in the meantime")
    func recordedParentWins() async throws {
        let store = try AuspexStore(inMemory: true)
        let registry = makeRegistry(store)
        let recorded = Fixtures.key(.claudeCode, "recorded")
        let inferred = Fixtures.key(.grokBuild, "inferred")
        let child = Fixtures.key(.codex, "child")

        await registry.ingest(started(recorded))
        await registry.ingest(started(inferred))
        var identity = Fixtures.identity(key: child)
        identity.parent = recorded
        identity.parentLink = .subagent(toolUseID: "t1")
        await registry.ingest(Fixtures.event(.sessionStarted(identity: identity), key: child, at: 0))

        let applied = await registry.applyLinks([
            ProcessLink(
                child: child, parent: inferred, link: .spawnedProcess,
                confidence: .medium, evidence: "test"
            )
        ])
        #expect(applied == 0)
        #expect(await registry.session(for: child)?.identity.parent == recorded)
    }

    @Test("a link naming a parent the board does not have is dropped")
    func unknownParentIsDropped() async throws {
        let store = try AuspexStore(inMemory: true)
        let registry = makeRegistry(store)
        let child = Fixtures.key(.codex, "child")
        await registry.ingest(started(child))

        let applied = await registry.applyLinks([
            ProcessLink(
                child: child, parent: Fixtures.key(.claudeCode, "ghost"), link: .envInherited,
                confidence: .high, evidence: "test"
            )
        ])
        #expect(applied == 0)
        #expect(await registry.session(for: child)?.identity.parent == nil)
    }

    @Test("a linked child inherits its parent's project on the board")
    func linkedChildGroupsWithItsParent() async throws {
        let store = try AuspexStore(inMemory: true)
        let registry = makeRegistry(store)
        let parent = Fixtures.key(.claudeCode, "parent")
        let child = Fixtures.key(.codex, "child")

        await registry.ingest(started(parent))
        await registry.ingest(started(child, cwd: nil))
        #expect(await registry.snapshot().ungroupedSessions.map(\.key) == [child])

        await registry.applyLinks([
            ProcessLink(
                child: child, parent: parent, link: .envInherited,
                confidence: .high, evidence: "test"
            )
        ])
        let board = await registry.snapshot()
        #expect(board.ungroupedSessions.isEmpty)
        #expect(board.byProject["/Users/example/Code/widget"]?.count == 2)
    }

    // MARK: - Linkable identities

    @Test("a session that is not running keeps its id but loses its pid")
    func linkableIdentitiesStripDeadPIDs() async throws {
        let store = try AuspexStore(inMemory: true)
        let registry = makeRegistry(store)
        let alive = Fixtures.key(.claudeCode, "alive")
        let dead = Fixtures.key(.codex, "dead")

        await registry.ingest(started(alive, pid: 100))
        await registry.ingest(started(dead, pid: 200))
        await registry.ingest(
            Fixtures.event(.sessionEnded(reason: .exited), key: dead, at: 1)
        )

        let identities = await registry.linkableIdentities()
        let byKey = Dictionary(uniqueKeysWithValues: identities.map { ($0.key, $0) })
        #expect(byKey[alive]?.pid == 100)
        #expect(byKey[dead]?.pid == nil)
        // The dead session is still there to be matched by session id.
        #expect(byKey[dead] != nil)
    }

    // MARK: - The service and the coordinator

    @Test("a placement service resolves a directory once per session")
    func placementServiceDebounces() async throws {
        let root = try GitFixtures.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try GitFixtures.makeDirectory(root.appendingPathComponent("widget"))
        try GitFixtures.makeRepository(at: repository, branch: "main")

        let key = Fixtures.key()
        let service = PlacementService()
        #expect(await service.placement(for: key, cwd: repository.path) != nil)
        #expect(await service.placement(for: key, cwd: repository.path) == nil)
        // Another session in the same directory is a different question.
        #expect(await service.placement(for: Fixtures.key(.codex, "other"), cwd: repository.path) != nil)
        // A moved session resolves again, and so does an explicit refresh.
        #expect(await service.placement(for: key, cwd: root.path) != nil)
        #expect(await service.refresh(key: key, cwd: root.path) != nil)
        #expect(await service.placement(for: key, cwd: "") == nil)
    }

    @Test("one coordinator tick places sessions and links them")
    func coordinatorTick() async throws {
        let root = try GitFixtures.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try GitFixtures.makeDirectory(root.appendingPathComponent("widget"))
        try GitFixtures.makeRepository(at: repository, branch: "main")

        let store = try AuspexStore(inMemory: true)
        let registry = makeRegistry(store)
        let parent = Fixtures.key(.claudeCode, "parent")
        let child = Fixtures.key(.codex, "child")
        await registry.ingest(started(parent, cwd: repository.path, pid: 100))
        await registry.ingest(started(child, cwd: repository.path, pid: 200))

        let table = StubProcessTable(
            records: [
                ProcessRecord(pid: 100, ppid: 1, startTime: Fixtures.date(-60), executablePath: "/bin/claude", argv: []),
                ProcessRecord(pid: 200, ppid: 100, startTime: Fixtures.date(-30), executablePath: "/bin/codex", argv: []),
            ],
            environments: [:]
        )
        let coordinator = GroupingCoordinator(registry: registry, table: table)

        let first = await coordinator.tick()
        #expect(first.placements == 2)
        #expect(first.links == 1)

        // Nothing changed, so a second tick has nothing to do.
        let second = await coordinator.tick()
        #expect(second.placements == 0)
        #expect(second.links == 0)

        await registry.stop()
        #expect(await registry.session(for: child)?.identity.parent == parent)
        #expect(await registry.session(for: parent)?.identity.gitBranch == "main")
        #expect(try row(store, child)?["root_key"] as String? == parent.description)
        #expect(try store.projects.fetchProjects().map(\.name) == ["widget"])
    }
}

/// A process table over a fixed array, so a coordinator test does not depend on
/// what happens to be running.
struct StubProcessTable: ProcessTableReading {
    let records: [ProcessRecord]
    var environments: [pid_t: [String: String]] = [:]

    func processes() -> [ProcessRecord] { records }

    func environment(pid: pid_t) -> [String: String]? { environments[pid] }
}
