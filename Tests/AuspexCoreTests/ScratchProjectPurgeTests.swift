import AgentSessionKit
import AgentSessionLive
import Foundation
import GRDB
import Testing

@testable import AuspexCore

@Suite("ScratchProjectPurge")
struct ScratchProjectPurgeTests {
    private let rules = ScratchRules(home: "/Users/example")

    /// A session in `directory`, assigned to the plain project there — what
    /// an earlier build wrote for every working directory.
    private func seed(_ store: AuspexStore, _ key: SessionKey, in directory: String) throws {
        try store.sessions.upsert(snapshot: SessionStateReducer.initialSnapshot(
            identity: Fixtures.identity(key: key, cwd: directory)
        ))
        try store.projects.assign(.plain(directory: directory), to: key)
    }

    private func projectRoots(_ store: AuspexStore) throws -> Set<String> {
        Set(try store.projects.fetchProjects(withCounts: false).map(\.rootPath))
    }

    private func projectID(_ store: AuspexStore, _ key: SessionKey) throws -> Int64? {
        try store.dbWriter.read { db in
            try Row.fetchOne(
                db, sql: "SELECT project_id FROM sessions WHERE key = ?", arguments: [key.description]
            )?["project_id"] as Int64?
        }
    }

    private func isStored(_ store: AuspexStore, _ key: SessionKey) throws -> Bool {
        try store.dbWriter.read { db in
            try Row.fetchOne(
                db, sql: "SELECT key FROM sessions WHERE key = ?", arguments: [key.description]
            ) != nil
        }
    }

    @Test("scratch rows go, their sessions stay, and real and claimed projects are kept")
    func removesScratchRows() async throws {
        let store = try AuspexStore(inMemory: true)
        let home = Fixtures.key(.codex, "home")
        let chat = Fixtures.key(.codex, "chat")
        let desktop = Fixtures.key(.claudeCode, "desktop")
        let gone = Fixtures.key(.claudeCode, "gone")
        let notes = Fixtures.key(.claudeCode, "notes")
        let widget = Fixtures.key(.claudeCode, "widget")
        let claimed = Fixtures.key(.codex, "claimed")
        let desktopScratch = "/Users/example/Library/Application Support/Claude/"
            + "scratch-workspaces/ws-1/0a1b/scratch-2026-08-21-9f3c"

        try seed(store, home, in: "/Users/example")
        try seed(store, chat, in: "/Users/example/Documents/Codex/2026-08-21/zhe")
        try seed(store, desktop, in: desktopScratch)
        try seed(store, gone, in: "/Users/example/Code/gone")
        // Undated, and nobody from Codex in it: an ordinary folder.
        try seed(store, notes, in: "/Users/example/Documents/Codex/notes")
        try seed(store, widget, in: "/Users/example/Code/widget")
        // Scratch by the rules, but the person made a project of it.
        try seed(store, claimed, in: "/Users/example/Documents/Codex/2026-08-22/keep")

        let purge = ScratchProjectPurge(store: store)
        #expect(try await purge.hasRun() == false)
        let report = try await purge.runIfNeeded(
            rules: rules,
            protectedRoots: ["/Users/example/Documents/Codex/2026-08-22/keep"],
            directoryExists: { $0 != "/Users/example/Code/gone" },
            now: Fixtures.date(0)
        )

        #expect(report == ScratchProjectPurge.Report(projectsRemoved: 4, sessionsUnassigned: 4))
        #expect(try projectRoots(store) == [
            "/Users/example/Documents/Codex/notes",
            "/Users/example/Code/widget",
            "/Users/example/Documents/Codex/2026-08-22/keep",
        ])
        for key in [home, chat, desktop, gone] {
            // The session is still stored; it just belongs to no project.
            #expect(try isStored(store, key))
            #expect(try projectID(store, key) == nil)
        }
        for key in [notes, widget, claimed] {
            #expect(try projectID(store, key) != nil)
        }

        // Once per store.
        #expect(try await purge.hasRun())
        #expect(try await purge.runIfNeeded(rules: rules, protectedRoots: []) == nil)
    }

    @Test("the Codex desktop tree is scratch only for the harnesses that make it")
    func codexTreeIsHarnessScoped() async throws {
        let store = try AuspexStore(inMemory: true)
        try seed(store, Fixtures.key(.codex, "a"), in: "/Users/example/Documents/Codex/notes")
        try seed(store, Fixtures.key(.chatgptWork, "b"), in: "/Users/example/Documents/Codex/notes")
        try seed(store, Fixtures.key(.codex, "c"), in: "/Users/example/Documents/Codex/shared")
        try seed(store, Fixtures.key(.cursor, "d"), in: "/Users/example/Documents/Codex/shared")

        let report = try await ScratchProjectPurge(store: store).runIfNeeded(
            rules: rules,
            protectedRoots: [],
            directoryExists: { _ in true }
        )
        #expect(report?.projectsRemoved == 1)
        #expect(try projectRoots(store) == ["/Users/example/Documents/Codex/shared"])
    }
}
