import AgentSessionKit
import AgentSessionLive
import Foundation
import GRDB
import Testing

@testable import AuspexCore

/// The directories that are where a session ran rather than a project it
/// belongs to.
@Suite("ScratchRules")
struct ScratchRulesTests {
    private let rules = ScratchRules(home: "/Users/example")

    // MARK: - The rules

    @Test("the Codex desktop's chat folders are scratch for Codex, whatever their shape")
    func codexDesktopFolders() {
        let undated = rules.match(cwd: "/Users/example/Documents/Codex/new-chat", harness: .codex)
        #expect(undated?.reason == .conversation)
        #expect(undated?.name == "new-chat")
        #expect(rules.match(cwd: "/Users/example/Documents/Codex", harness: .chatgptWork)?.reason
            == .conversation)

        // The dated shape names its thread, for anyone.
        let dated = rules.match(
            cwd: "/Users/example/Documents/Codex/2026-08-21/zhe/src", harness: .claudeCode
        )
        #expect(dated?.reason == .conversation)
        #expect(dated?.directory == "/Users/example/Documents/Codex/2026-08-21/zhe")
        #expect(dated?.name == "zhe")

        // Somebody else's session in an undated folder there is in a folder.
        #expect(rules.match(cwd: "/Users/example/Documents/Codex/notes", harness: .claudeCode)
            == nil)
        #expect(rules.match(cwd: "/Users/example/Documents/Codex/notes", harness: nil) == nil)
    }

    @Test("Claude Desktop's scratch workspaces are scratch, named after the conversation folder")
    func claudeDesktopScratch() {
        let match = rules.match(
            cwd: "/Users/example/Library/Application Support/Claude/scratch-workspaces/"
                + "ws-1/0a1b/scratch-2026-08-21-9f3c/build",
            harness: .claudeCode
        )
        #expect(match?.reason == .desktopScratch)
        #expect(match?.directory == "/Users/example/Library/Application Support/Claude/"
            + "scratch-workspaces/ws-1/0a1b/scratch-2026-08-21-9f3c")
        #expect(match?.name == "scratch-2026-08-21-9f3c")
        #expect(match.map(ProjectPlacement.scratch)?.isProjectless == true)
    }

    @Test("the home directory itself is scratch, and nothing under it is for that reason")
    func homeDirectory() {
        let match = rules.match(cwd: "/Users/example/", harness: .codex)
        #expect(match?.reason == .home)
        #expect(match?.name == "~")
        #expect(rules.match(cwd: "/Users/example/Code/widget", harness: .codex) == nil)
        // Another account's home is an ordinary directory to this one.
        #expect(rules.match(cwd: "/Users/example-guest", harness: .codex) == nil)
    }

    @Test("container and temporary roots are scratch, component by component")
    func sandboxRoots() {
        #expect(rules.match(cwd: "/root/app", harness: .codex)?.reason == .container)
        #expect(rules.match(cwd: "/workspace", harness: .grokBuild)?.reason == .container)
        #expect(rules.match(cwd: "/tmp/clone", harness: .claudeCode)?.reason == .temporary)
        #expect(rules.match(cwd: "/private/tmp/clone/src", harness: .cursor)?.name == "src")
        #expect(rules.match(cwd: "/rootless/app", harness: .codex) == nil)
        #expect(rules.match(cwd: "/workspaces/app", harness: .codex) == nil)
        #expect(rules.match(cwd: "relative/path", harness: .codex) == nil)
    }

    @Test("a folder the person marked is scratch, ahead of every other rule")
    func userPrefix() {
        let marked = ScratchRules(home: "/Users/example", userPrefixes: ["/Users/example/Downloads/"])
        #expect(marked.userPrefixes == ["/Users/example/Downloads"])
        let match = marked.match(cwd: "/Users/example/Downloads/zip-1", harness: .claudeCode)
        #expect(match?.reason == .userRule)
        #expect(match?.name == "zip-1")
        #expect(match.map(ProjectPlacement.scratch)?.placementNote == "rule")
        #expect(marked.match(cwd: "/Users/example/Downloadsx", harness: .claudeCode) == nil)
        #expect(rules.match(cwd: "/Users/example/Downloads/zip-1", harness: .claudeCode) == nil)
    }

    // MARK: - Through the service

    @Test("a directory in no repository and not on this Mac is scratch")
    func missingDirectory() async throws {
        let service = PlacementService(
            resolver: ProjectResolver(homeDirectory: "/Users/example"),
            rules: rules,
            directoryExists: { _ in false }
        )
        let placement = try #require(
            await service.placement(for: Fixtures.key(.codex, "gone"), cwd: "/Users/example/gone")
        )
        #expect(placement.isProjectless)
        #expect(placement.placementNote == ScratchRules.Reason.missing.rawValue)
        #expect(placement.projectName == "gone")
    }

    @Test("a missing checkout inside a repository still belongs to the repository")
    func missingWorktreeKeepsItsRepository() async throws {
        let root = try GitFixtures.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try GitFixtures.makeDirectory(root.appendingPathComponent("widget"))
        try GitFixtures.makeRepository(at: repository, branch: "main")
        let removed = repository.appendingPathComponent(".agents/worktrees/feat-gone").path

        let service = PlacementService(rules: rules, directoryExists: { _ in false })
        let placement = try #require(
            await service.placement(for: Fixtures.key(.codex, "merged"), cwd: removed)
        )
        #expect(!placement.isProjectless)
        #expect(placement.gitRoot == ProjectResolver.standardized(repository.path))
    }

    @Test("a directory on disk is asked about once, however many sessions are in it")
    func existenceIsAskedOnce() async throws {
        let asked = Counter()
        let service = PlacementService(
            resolver: ProjectResolver(homeDirectory: "/Users/example"),
            rules: rules,
            directoryExists: { _ in asked.increment(); return true }
        )
        for index in 0..<3 {
            let placement = await service.placement(
                for: Fixtures.key(.claudeCode, "s\(index)"), cwd: "/Users/example/plain"
            )
            #expect(placement?.isProjectless == false)
        }
        #expect(asked.value == 1)
    }

    @Test("changing the person's scratch folders places every session again")
    func userPrefixesReplace() async throws {
        let service = PlacementService(
            resolver: ProjectResolver(homeDirectory: "/Users/example"),
            rules: rules,
            directoryExists: { _ in true }
        )
        let key = Fixtures.key(.claudeCode, "dl")
        let before = await service.placement(for: key, cwd: "/Users/example/Downloads/zip-1")
        #expect(before?.isProjectless == false)
        #expect(await service.placement(for: key, cwd: "/Users/example/Downloads/zip-1") == nil)

        await service.setUserScratchPrefixes(["/Users/example/Downloads"])
        let after = await service.placement(for: key, cwd: "/Users/example/Downloads/zip-1")
        #expect(after?.placementNote == ScratchRules.Reason.userRule.rawValue)

        // The same rules again change nothing, and so forget nothing.
        await service.setUserScratchPrefixes(["/Users/example/Downloads/"])
        #expect(await service.placement(for: key, cwd: "/Users/example/Downloads/zip-1") == nil)
    }

    // MARK: - Through the registry

    @Test("a scratch session writes no project row and lets go of the one it had")
    func scratchWritesNoProject() async throws {
        let store = try AuspexStore(inMemory: true)
        let registry = SessionRegistry(
            store: store, publishInterval: 0, persistInterval: 0, tickInterval: 0
        )
        let key = Fixtures.key(.codex, "home-chat")
        var identity = Fixtures.identity(key: key, cwd: "/Users/example", pid: nil)
        identity.gitRoot = nil
        identity.gitBranch = nil
        await registry.ingest(Fixtures.event(.sessionStarted(identity: identity), key: key, at: 0))
        await registry.flushPendingWrites()

        // What an earlier build left behind: the home directory as a project.
        try await store.dbWriter.write { db in
            let assignment = try store.projects.upsert(.plain(directory: "/Users/example"), in: db)
            try db.execute(
                sql: "UPDATE sessions SET project_id = ? WHERE key = ?",
                arguments: [assignment.projectID, key.description]
            )
        }

        let service = PlacementService(
            resolver: ProjectResolver(homeDirectory: "/Users/example"),
            rules: rules,
            directoryExists: { _ in true }
        )
        let placements = await service.placements(for: [identity])
        #expect(placements[key]?.placementNote == ScratchRules.Reason.home.rawValue)
        #expect(await registry.applyPlacements(placements) == 1)
        await registry.stop()

        let projectID = try await store.dbWriter.read { db in
            try Row.fetchOne(
                db, sql: "SELECT project_id FROM sessions WHERE key = ?", arguments: [key.description]
            )?["project_id"] as Int64?
        }
        #expect(projectID == nil)
        let frame = await registry.snapshot()
        let session = try #require(frame.session(for: key))
        #expect(frame.projectKey(for: session) == PseudoProject.scratchKey(for: .codex))
        #expect(frame.sandboxThreadName(for: session) == "~")
    }
}

/// A count that a `@Sendable` closure can bump.
final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int { lock.withLock { count } }

    func increment() { lock.withLock { count += 1 } }
}
