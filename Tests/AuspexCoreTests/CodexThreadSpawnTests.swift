import AgentSessionKit
import AgentSessionLive
import Foundation
import GRDB
import Testing

@testable import AuspexCore

/// Codex threads spawned into the cloud sandbox, which belong to the project
/// of the thread that spawned them.
@Suite("Codex thread spawn")
struct CodexThreadSpawnTests {
    private let parentID = "0198f4c2-77bd-7a10-b3e9-5c2d84f10ab6"
    private let childID = "0198f6d0-11ac-7e54-8b26-3ad70f9c1e83"

    /// A synthetic `session_meta` line, shaped like a desktop sub-agent's.
    private func header(
        id: String,
        parent: String? = nil,
        agentPath: String? = "/root/factory_build",
        guardian: Bool = false
    ) -> Data {
        var source: Any = "vscode"
        if guardian {
            source = ["subagent": ["other": "guardian"]]
        } else if let parent {
            var spawn: [String: Any] = ["parent_thread_id": parent, "depth": 1]
            if let agentPath { spawn["agent_path"] = agentPath }
            spawn["agent_nickname"] = "Example"
            source = ["subagent": ["thread_spawn": spawn]]
        }
        let object: [String: Any] = [
            "timestamp": "2026-08-21T00:00:00Z",
            "type": "session_meta",
            "payload": [
                "id": id,
                "cwd": "/root/factory_build",
                "originator": "codex_desktop",
                "source": source,
            ] as [String: Any],
        ]
        return try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    // MARK: - The header

    @Test("a thread_spawn header names its parent, and a /root/ agent path is the cloud")
    func parsesSpawn() {
        let spawn = CodexThreadSpawn.parse(
            headerLines: [header(id: childID, parent: parentID)], sessionID: childID
        )
        #expect(spawn?.parentThreadID == parentID)
        #expect(spawn?.runsInCloud == true)
        #expect(spawn?.cloudVariant == "cloud:\(parentID)")

        let local = CodexThreadSpawn.parse(
            headerLines: [header(id: childID, parent: parentID, agentPath: "worker")],
            sessionID: childID
        )
        #expect(local?.runsInCloud == false)
    }

    @Test("an ancestor's replayed header is skipped; a guardian or plain thread is no spawn")
    func ignoresOtherHeaders() {
        let replayed = CodexThreadSpawn.parse(
            headerLines: [
                header(id: parentID, parent: "0198aaaa-0000-7000-8000-000000000001"),
                header(id: childID, parent: parentID),
            ],
            sessionID: childID
        )
        #expect(replayed?.parentThreadID == parentID)

        #expect(CodexThreadSpawn.parse(
            headerLines: [header(id: childID, guardian: true)], sessionID: childID) == nil)
        #expect(CodexThreadSpawn.parse(headerLines: [header(id: childID)], sessionID: childID)
            == nil)
        #expect(CodexThreadSpawn.parse(
            headerLines: [header(id: childID, parent: childID)], sessionID: childID) == nil)
        #expect(CodexThreadSpawn.parse(headerLines: [Data("not json".utf8)], sessionID: childID)
            == nil)
    }

    @Test("the variant is read back from the identity, for the Codex store only")
    func variantRoundTrip() {
        var identity = Fixtures.identity(key: Fixtures.key(.codex, childID), cwd: nil)
        identity.variant = "cloud:\(parentID)"
        #expect(SessionRelations.cloudSpawnParentID(of: identity) == parentID)

        var other = Fixtures.identity(key: Fixtures.key(.claudeCode, childID), cwd: nil)
        other.variant = "cloud:\(parentID)"
        #expect(!SessionRelations.isCloudSpawn(other))

        identity.variant = "cloud:\(childID)"
        #expect(!SessionRelations.isCloudSpawn(identity))
    }

    // MARK: - Grouping

    @Test("a cloud spawn is linked to its parent and takes the parent's project")
    func cloudSpawnFollowsParent() async throws {
        let root = try GitFixtures.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try GitFixtures.makeDirectory(root.appendingPathComponent("widget"))
        try GitFixtures.makeRepository(at: repository, branch: "main")
        let rollout = root.appendingPathComponent("rollout-\(childID).jsonl")
        var contents = header(id: childID, parent: parentID)
        contents.append(Data("\n".utf8))
        try contents.write(to: rollout)

        let store = try AuspexStore(inMemory: true)
        let registry = SessionRegistry(
            store: store, publishInterval: 0, persistInterval: 0, tickInterval: 0
        )
        let parent = Fixtures.key(.codex, parentID)
        let child = Fixtures.key(.codex, childID)

        var parentIdentity = Fixtures.identity(key: parent, cwd: repository.path)
        parentIdentity.gitRoot = nil
        await registry.ingest(
            Fixtures.event(.sessionStarted(identity: parentIdentity), key: parent, at: 0)
        )
        // What the kit hands over for such a thread: the sandbox's directory,
        // `subagent` as the entrypoint, the originator as the variant, and no
        // parent — its header carried no `session_id` and nothing linked it.
        var childIdentity = SessionIdentity(
            key: child,
            sourcePath: rollout.path,
            variant: "codex_desktop",
            cwd: "/root/factory_build",
            entrypoint: "subagent"
        )
        childIdentity.gitBranch = nil
        await registry.ingest(
            Fixtures.event(.sessionStarted(identity: childIdentity), key: child, at: 1)
        )

        let spawns = CodexSpawnMemo()
        let coordinator = GroupingCoordinator(
            registry: registry,
            table: StubProcessTable(records: [], environments: [:]),
            placements: PlacementService(),
            memo: LinkerMemo(),
            spawns: spawns
        )
        let first = await coordinator.tick()
        // Only the parent is placed; the spawn's directory is not asked about.
        #expect(first.placements == 1)
        #expect(first.links == 1)

        let second = await coordinator.tick()
        #expect(second.placements == 0)
        #expect(second.links == 0)
        #expect(spawns.readCount == 1)

        await registry.stop()
        let frame = await registry.snapshot()
        let spawned = try #require(frame.session(for: child))
        #expect(spawned.identity.variant == "cloud:\(parentID)")
        #expect(spawned.identity.parent == parent)
        #expect(spawned.identity.parentLink == .subagent(toolUseID: nil))
        #expect(frame.inheritsProject(spawned))
        let parentSession = try #require(frame.session(for: parent))
        #expect(frame.projectKey(for: spawned) == frame.projectKey(for: parentSession))
        #expect(frame.projectKey(for: spawned) == ProjectResolver.standardized(repository.path))
        // And the sandbox's directory never became a project or a scratch row.
        #expect(try store.projects.fetchProjects().map(\.name) == ["widget"])
        #expect(!frame.isSandbox(spawned))
    }

    @Test("a tag the kit overwrote is restored without reading the header again")
    func restoresOverwrittenTag() {
        let spawns = CodexSpawnMemo(read: { _, _ in
            CodexThreadSpawn(parentThreadID: "0198f4c2-77bd-7a10-b3e9-5c2d84f10ab6",
                             agentPath: "/root/factory_build")
        })
        let identity = SessionIdentity(
            key: Fixtures.key(.codex, childID),
            sourcePath: "/Users/example/.codex/sessions/rollout.jsonl",
            variant: "codex_desktop",
            entrypoint: "subagent"
        )
        #expect(spawns.pendingVariants(for: [identity]).count == 1)
        var tagged = identity
        tagged.variant = "cloud:\(parentID)"
        #expect(spawns.pendingVariants(for: [tagged]).isEmpty)
        // A re-read of the rollout from the top writes the originator back.
        #expect(spawns.pendingVariants(for: [identity])[identity.key] == "cloud:\(parentID)")
        #expect(spawns.readCount == 1)

        // Anything that is not a Codex sub-agent is never read.
        var plain = identity
        plain.entrypoint = "vscode"
        let other = SessionIdentity(
            key: Fixtures.key(.claudeCode, "x"), sourcePath: "/x", entrypoint: "subagent"
        )
        #expect(spawns.pendingVariants(for: [plain, other]).isEmpty)
        #expect(spawns.readCount == 1)
    }

    @Test("a cloud spawn whose parent is not on the board goes to its harness's scratch")
    func orphanedCloudSpawn() throws {
        var identity = Fixtures.identity(key: Fixtures.key(.codex, childID), cwd: "/root/factory_build")
        identity.gitRoot = nil
        identity.variant = "cloud:\(parentID)"
        let session = SessionStateReducer.initialSnapshot(identity: identity)
        let frame = BoardSnapshot(generatedAt: Fixtures.date(0), sessions: [session])
        #expect(frame.projectKey(for: session) == PseudoProject.scratchKey(for: .codex))
    }
}
