import AgentSessionKit
import AgentSessionLive
import Foundation
import GRDB
import Testing

@testable import AuspexCore

/// The one-time pass that folds the per-run project rows earlier builds wrote
/// into their workspace roots. Everything is fabricated under
/// `/Users/example`.
@Suite("ProjectRollupMigration")
struct ProjectRollupMigrationTests {
    private let rules = ScratchRules(home: "/Users/example")
    private let workspace = "/Users/example/work/reports"

    private func run(_ index: Int) -> String {
        "\(workspace)/.runs/2026-09-\(String(format: "%02d", index + 1))"
    }

    /// A session in `directory`, assigned to the row `placement` names —
    /// what an earlier build wrote for every working directory.
    private func seed(
        _ store: AuspexStore,
        _ key: SessionKey,
        in directory: String,
        placement: ProjectPlacement? = nil
    ) throws {
        try store.sessions.upsert(snapshot: SessionStateReducer.initialSnapshot(
            identity: Fixtures.identity(key: key, cwd: directory)
        ))
        try store.projects.assign(placement ?? .plain(directory: directory), to: key)
    }

    private func task(_ store: AuspexStore, _ title: String, key: String?) throws -> Int64 {
        try store.dbWriter.write { db in
            try db.execute(
                sql: """
                    INSERT INTO tasks (title, status, priority, project_key, created_at, updated_at)
                    VALUES (?, 'todo', 0, ?, 0, 0)
                    """,
                arguments: [title, key]
            )
            return db.lastInsertedRowID
        }
    }

    private func plan(_ store: AuspexStore, _ slug: String, key: String?) throws -> Int64 {
        try store.dbWriter.write { db in
            try db.execute(
                sql: """
                    INSERT INTO plans (slug, title, project_key, created_at, updated_at)
                    VALUES (?, ?, ?, 0, 0)
                    """,
                arguments: [slug, slug, key]
            )
            return db.lastInsertedRowID
        }
    }

    private func key(ofTask id: Int64, _ store: AuspexStore) throws -> String? {
        try store.dbWriter.read { db in
            try String.fetchOne(db, sql: "SELECT project_key FROM tasks WHERE id = ?", arguments: [id])
        }
    }

    private func key(ofPlan id: Int64, _ store: AuspexStore) throws -> String? {
        try store.dbWriter.read { db in
            try String.fetchOne(db, sql: "SELECT project_key FROM plans WHERE id = ?", arguments: [id])
        }
    }

    private func root(of session: SessionKey, _ store: AuspexStore) throws -> String? {
        try store.dbWriter.read { db in
            try String.fetchOne(db, sql: """
                SELECT p.root_path FROM sessions s JOIN projects p ON p.id = s.project_id
                WHERE s.key = ?
                """, arguments: [session.description])
        }
    }

    private func roots(_ store: AuspexStore) throws -> Set<String> {
        Set(try store.projects.fetchProjects(withCounts: false).map(\.rootPath))
    }

    @Test("ten run folders become one workspace row, and their sessions and tasks follow")
    func runsFoldIntoTheirWorkspace() async throws {
        let store = try AuspexStore(inMemory: true)
        var sessions: [SessionKey] = []
        for index in 0..<10 {
            let key = Fixtures.key(.codex, "run-\(index)")
            sessions.append(key)
            try seed(store, key, in: run(index))
        }
        let first = try task(store, "Check the first run", key: run(0))
        let last = try task(store, "Check the last run", key: run(9))
        let milestone = try plan(store, "september-runs", key: run(4))
        #expect(try roots(store).count == 10)

        let migration = ProjectRollupMigration(store: store)
        #expect(try await migration.hasRun() == false)
        let report = try #require(try await migration.runIfNeeded(
            rules: rules,
            protectedRoots: [],
            directoryExists: { _ in true },
            // Small batches, so the pass is several transactions.
            batchSize: 3,
            now: Fixtures.date(0)
        ))

        #expect(report.projectsMerged == 10)
        #expect(report.projectsCreated == 1)
        #expect(report.projectsCleared == 0)
        #expect(report.sessionsMoved == 10)
        #expect(report.tasksMoved == 2)
        #expect(report.plansMoved == 1)
        #expect(try roots(store) == [workspace])
        for key in sessions {
            #expect(try root(of: key, store) == workspace)
        }
        // The work went with the folder; nothing became "no project".
        #expect(try key(ofTask: first, store) == workspace)
        #expect(try key(ofTask: last, store) == workspace)
        #expect(try key(ofPlan: milestone, store) == workspace)
        let summary = try #require(try store.projects.fetchProjects().first)
        #expect(summary.name == "reports")
        #expect(summary.gitRoot == nil)
        #expect(summary.sessionCount == 10)

        // Once.
        #expect(try await migration.hasRun())
        #expect(try await migration.runIfNeeded(
            rules: rules, protectedRoots: [], directoryExists: { _ in true }
        ) == nil)
    }

    @Test("repositories, the person's projects and workspace roots stay; scratch goes")
    func onlyThreeKindsRemain() async throws {
        let store = try AuspexStore(inMemory: true)
        let repo = Fixtures.key(.claudeCode, "repo")
        let pinned = Fixtures.key(.claudeCode, "pinned")
        let alreadyRoot = Fixtures.key(.cursor, "root")
        let revision = Fixtures.key(.cursor, "revision")
        let home = Fixtures.key(.codex, "home")
        let retired = Fixtures.key(.claudeCode, "retired")

        // A repository three levels deep: never rolled up, whatever its depth.
        try seed(store, repo, in: "/Users/example/Coding/Gits/auspex/Sources", placement: ProjectPlacement(
            projectRootPath: "/Users/example/Coding/Gits/auspex",
            projectName: "auspex",
            gitRoot: "/Users/example/Coding/Gits/auspex"
        ))
        // Pinned by the person, below the workspace depth.
        try seed(store, pinned, in: "\(workspace)/.runs/special")
        try seed(store, alreadyRoot, in: "/Users/example/work/studio 101")
        try seed(store, revision, in: "/Users/example/work/studio 101/live-revision-v3")
        try seed(store, home, in: "/Users/example")
        try seed(store, retired, in: "/Users/example/work/retired/run-1")
        let retiredTask = try task(store, "Archive the retired job", key: "/Users/example/work/retired/run-1")
        let bot = try task(store, "Watch the feed", key: PseudoProject.key(for: .grokBot))
        let scratch = try task(store, "Filed from nowhere", key: TaskProject.scratchKey)
        let thread = try task(store, "From a chat", key: PseudoProject.scratchKey(for: .codex))
        let loose = try plan(store, "loose", key: PseudoProject.scratchKey(for: .cursor))

        let report = try #require(try await ProjectRollupMigration(store: store).runIfNeeded(
            rules: rules,
            protectedRoots: ["\(workspace)/.runs/special"],
            directoryExists: { $0 != "/Users/example/work/retired" },
            now: Fixtures.date(0)
        ))

        #expect(try roots(store) == [
            "/Users/example/Coding/Gits/auspex",
            "\(workspace)/.runs/special",
            "/Users/example/work/studio 101",
        ])
        #expect(try root(of: repo, store) == "/Users/example/Coding/Gits/auspex")
        #expect(try root(of: pinned, store) == "\(workspace)/.runs/special")
        #expect(try root(of: alreadyRoot, store) == "/Users/example/work/studio 101")
        #expect(try root(of: revision, store) == "/Users/example/work/studio 101")
        // Projectless: the home, and a job whose whole workspace is gone.
        #expect(try root(of: home, store) == nil)
        #expect(try root(of: retired, store) == nil)
        #expect(report.projectsMerged == 1)
        #expect(report.projectsCreated == 0)
        #expect(report.projectsCleared == 2)
        #expect(report.sessionsUnassigned == 2)
        // A task under a folder that is no project keeps the folder it named;
        // every key that already meant "no project" is now the one key.
        #expect(try key(ofTask: retiredTask, store) == "/Users/example/work/retired/run-1")
        for id in [bot, scratch, thread] {
            #expect(try key(ofTask: id, store) == PseudoProject.projectlessKey)
        }
        #expect(try key(ofPlan: loose, store) == PseudoProject.projectlessKey)
        #expect(report.tasksMoved == 3)
        #expect(report.plansMoved == 1)
    }

    @Test("a pass cut short and run again finishes the job and changes nothing twice")
    func resumesWhereItStopped() async throws {
        let store = try AuspexStore(inMemory: true)
        for index in 0..<4 {
            try seed(store, Fixtures.key(.codex, "run-\(index)"), in: run(index))
        }
        let migration = ProjectRollupMigration(store: store)
        _ = try await migration.runIfNeeded(
            rules: rules, protectedRoots: [], directoryExists: { _ in true }
        )
        // As though the stamp had never been written.
        try await store.dbWriter.write { db in
            try db.execute(sql: "DELETE FROM meta WHERE key = ?", arguments: [StoreMetaKey.projectsRolledUp])
        }
        let again = try #require(try await migration.runIfNeeded(
            rules: rules, protectedRoots: [], directoryExists: { _ in true }
        ))
        #expect(!again.changedAnything)
        #expect(try roots(store) == [workspace])
    }

    @Test("tasks still filed under a chat folder join Projectless, once")
    func scratchTaskKeysFold() async throws {
        let store = try AuspexStore(inMemory: true)
        let chat = "/Users/example/Documents/Codex/2026-10-13/j-k"
        let pinned = "/Users/example/Documents/Codex/2026-10-14/kept"
        let chatTask = try task(store, "chat", key: chat)
        let chatPlan = try plan(store, "chat-plan", key: chat)
        let homeTask = try task(store, "home", key: "/Users/example")
        let pinnedTask = try task(store, "pinned", key: pinned)
        let realTask = try task(store, "real", key: workspace)
        let goneTask = try task(store, "gone", key: "/Users/example/work/retired/run-1")

        let migration = ProjectRollupMigration(store: store)
        let report = try #require(try await migration.foldScratchTaskKeysIfNeeded(
            rules: rules, protectedRoots: [pinned]
        ))
        #expect(report.tasksMoved == 2)
        #expect(report.plansMoved == 1)
        #expect(try key(ofTask: chatTask, store) == PseudoProject.projectlessKey)
        #expect(try key(ofPlan: chatPlan, store) == PseudoProject.projectlessKey)
        #expect(try key(ofTask: homeTask, store) == PseudoProject.projectlessKey)
        #expect(try key(ofTask: pinnedTask, store) == pinned)
        #expect(try key(ofTask: realTask, store) == workspace)
        #expect(try key(ofTask: goneTask, store) == "/Users/example/work/retired/run-1")
        #expect(try await migration.foldScratchTaskKeysIfNeeded(rules: rules, protectedRoots: []) == nil)
    }
}
