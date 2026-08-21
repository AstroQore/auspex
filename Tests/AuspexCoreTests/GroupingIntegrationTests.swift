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

    private func projectRowCount(_ store: AuspexStore) throws -> Int {
        try store.dbWriter.read { db in
            try Row.fetchAll(db, sql: "SELECT id FROM projects").count
        }
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

    @Test("a scratch placement reaches the frame, and takes the folder off the wall")
    func sandboxPlacementReachesTheFrame() async throws {
        let store = try AuspexStore(inMemory: true)
        let registry = makeRegistry(store)
        let key = SessionKey(harness: .codex, sessionID: "desk-1")
        let thread = HarnessSandbox.Thread(
            directory: "/Users/example/Documents/Codex/2026-08-21/zhe",
            name: "zhe",
            note: HarnessSandbox.sandboxNote
        )

        await registry.ingest(
            started(key, cwd: "/Users/example/Documents/Codex/2026-08-21/zhe"))
        #expect(await registry.applyPlacements([key: .sandbox(thread: thread)]) == 1)

        let frame = await registry.snapshot()
        let session = try #require(frame.session(for: key))
        #expect(frame.isSandbox(session))
        #expect(frame.sandboxThreadName(for: session) == "zhe")
        #expect(frame.projectKey(for: session) == PseudoProject.scratchKey(for: .codex))
        // The directory is still on the identity; it is only refused as a
        // grouping key.
        #expect(session.identity.cwd == "/Users/example/Documents/Codex/2026-08-21/zhe")
        #expect(session.identity.gitRoot == nil)
        #expect(BoardGrouping.groups(for: frame, groupBy: .project).map(\.title)
            == ["Codex · scratch"])
        await registry.stop()

        // And no project row for the folder: the `projects` table indexes the
        // real ones, and a row per desktop conversation would fill it with
        // names nothing looks up.
        let stored = try #require(try row(store, key))
        #expect(stored["project_id"] as Int64? == nil)
        #expect(try projectRowCount(store) == 0)
    }

    @Test("a session that leaves the scratch stops being remembered as scratch")
    func aLaterPlacementClearsTheScratch() async throws {
        let store = try AuspexStore(inMemory: true)
        let registry = makeRegistry(store)
        let key = SessionKey(harness: .codex, sessionID: "desk-1")
        let thread = HarnessSandbox.Thread(
            directory: "/Users/example/Documents/Codex/2026-08-21/zhe",
            name: "zhe",
            note: HarnessSandbox.sandboxNote
        )

        await registry.ingest(
            started(key, cwd: "/Users/example/Documents/Codex/2026-08-21/zhe"))
        _ = await registry.applyPlacements([key: .sandbox(thread: thread)])
        _ = await registry.applyPlacements([key: placement])

        let frame = await registry.snapshot()
        let session = try #require(frame.session(for: key))
        #expect(!frame.isSandbox(session))
        #expect(frame.projectKey(for: session) == "/Users/example/Code/widget")
        await registry.stop()
    }

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

    @Test("a tick folds a Codex Auto Review rollout under the root its variant names")
    func coordinatorFoldsAutoReview() async throws {
        let store = try AuspexStore(inMemory: true)
        let registry = makeRegistry(store)
        let root = Fixtures.key(.codex, "0198f4c2-77bd-7a10-b3e9-5c2d84f10ab6")
        let review = Fixtures.key(.codex, "0198f6d0-11ac-7e54-8b26-3ad70f9c1e83")

        await registry.ingest(started(root, cwd: nil))
        var guardian = Fixtures.identity(key: review, cwd: nil, pid: nil)
        guardian.gitRoot = nil
        guardian.gitBranch = nil
        // The only record of the relationship anywhere. Neither rollout's body
        // mentions the other, and no process links them: a guardian run holds
        // no writer lock, so it has no pid to walk a tree from.
        guardian.variant = "auto-review:\(root.sessionID)"
        await registry.ingest(
            Fixtures.event(.sessionStarted(identity: guardian), key: review, at: 1)
        )

        // An empty table, so nothing here can come from a process inference.
        let coordinator = GroupingCoordinator(
            registry: registry,
            table: StubProcessTable(records: [], environments: [:])
        )
        #expect(await coordinator.tick().links == 1)
        #expect(await coordinator.tick().links == 0)

        await registry.stop()
        let folded = try #require(await registry.session(for: review)?.identity)
        #expect(folded.parent == root)
        #expect(folded.parentLink == .subagent(toolUseID: nil))
        // And the store re-roots the subtree, which is what the tree grouping
        // and the sidebar read.
        #expect(try row(store, review)?["root_key"] as String? == root.description)
        #expect(try row(store, review)?["parent_key"] as String? == root.description)
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
