import AgentSessionKit
import Foundation
import GRDB
import Testing

@testable import AuspexCore

/// `v5_projects_own_tasks` over a database that was written before projects
/// contained tasks.
///
/// The migration is where "Unfiled" is actually abolished: a store that has
/// been in use since v3 is full of tasks with no project, and leaving them
/// NULL would keep the lane alive under a new heading. Everything here is
/// fabricated under `/Users/example`.
@Suite("v5 · filing the tasks that were already there")
struct TaskProjectMigrationTests {
    /// A database at v4, with the rows a v3/v4 board would have written.
    private func makeV4Database() throws -> DatabaseQueue {
        let queue = try DatabaseQueue(configuration: AuspexStore.configuration())
        try AuspexStore.migrator.migrate(queue, upTo: "v4_acknowledgement")
        try queue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO projects (root_path, git_root, name, created_at)
                    VALUES ('/Users/example/Code/auspex', '/Users/example/Code/auspex', 'auspex', 0)
                    """
            )
            let projectID = db.lastInsertedRowID
            try insertSession(db, key: "codex:worker-1", harness: "codex", projectID: projectID)
            try insertSession(
                db, key: "cursor:worker-2", harness: "cursor",
                cwd: "/Users/example/Code/storefront-web"
            )
            try insertSession(db, key: "grokBot:bot-1", harness: "grokBot")
        }
        return queue
    }

    private func insertSession(
        _ db: Database,
        key: String,
        harness: String,
        cwd: String? = nil,
        projectID: Int64? = nil
    ) throws {
        try db.execute(
            sql: """
                INSERT INTO sessions
                    (key, harness, session_id, cwd, project_id, source_path, state, snapshot_json)
                VALUES (?, ?, ?, ?, ?, '/Users/example/store/x.jsonl', 'idle', '{}')
                """,
            arguments: [key, harness, key, cwd, projectID]
        )
    }

    private func insertTask(
        _ db: Database,
        title: String,
        planID: Int64? = nil,
        claimedBy: String? = nil,
        createdBy: String? = nil
    ) throws -> Int64 {
        try db.execute(
            sql: """
                INSERT INTO tasks
                    (title, status, priority, plan_id, claimed_by_key, created_by_key,
                     created_at, updated_at)
                VALUES (?, 'todo', 0, ?, ?, ?, 0, 0)
                """,
            arguments: [title, planID, claimedBy, createdBy]
        )
        return db.lastInsertedRowID
    }

    private func projectKey(ofTask id: Int64, in queue: DatabaseQueue) throws -> String? {
        try queue.read { db in
            try String.fetchOne(db, sql: "SELECT project_key FROM tasks WHERE id = ?", arguments: [id])
        }
    }

    @Test("every task that was there is filed in a project, and none in nowhere")
    func everyOldTaskGetsAProject() throws {
        let queue = try makeV4Database()
        var claimed: Int64 = 0
        var filed: Int64 = 0
        var orphan: Int64 = 0
        var bot: Int64 = 0
        try queue.write { db in
            claimed = try insertTask(db, title: "Claimed by a worker", claimedBy: "codex:worker-1")
            filed = try insertTask(db, title: "Filed by a worker", createdBy: "cursor:worker-2")
            orphan = try insertTask(db, title: "Nobody's")
            bot = try insertTask(db, title: "A bot's", claimedBy: "grokBot:bot-1")
        }

        try AuspexStore.migrator.migrate(queue)

        // The claimer's project — the repository row, which is the git root.
        #expect(try projectKey(ofTask: claimed, in: queue) == "/Users/example/Code/auspex")
        // No placement was ever resolved for this one, so its own cwd answers.
        #expect(try projectKey(ofTask: filed, in: queue) == "/Users/example/Code/storefront-web")
        // A harness with no directory at all belongs to the harness.
        #expect(try projectKey(ofTask: bot, in: queue) == PseudoProject.key(for: .grokBot))
        // And what is left is a named place rather than a NULL.
        #expect(try projectKey(ofTask: orphan, in: queue) == TaskProject.scratchKey)

        let unfiled = try queue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM tasks WHERE project_key IS NULL")
        }
        #expect(unfiled == 0)
    }

    @Test("a milestone lands in the project of the work under it")
    func milestonesFollowTheirTasks() throws {
        let queue = try makeV4Database()
        var planID: Int64 = 0
        var task: Int64 = 0
        try queue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO plans (slug, title, status, created_at, updated_at)
                    VALUES ('live-board', 'Ship the live board', 'active', 0, 0)
                    """
            )
            planID = db.lastInsertedRowID
            task = try insertTask(
                db, title: "Tail the rollout", planID: planID, claimedBy: "codex:worker-1"
            )
        }

        try AuspexStore.migrator.migrate(queue)

        let planKey = try queue.read { db in
            try String.fetchOne(
                db, sql: "SELECT project_key FROM plans WHERE id = ?", arguments: [planID]
            )
        }
        #expect(planKey == "/Users/example/Code/auspex")
        #expect(try projectKey(ofTask: task, in: queue) == planKey)
    }

    @Test("a task under a milestone that resolved takes the milestone's project")
    func unclaimedTasksFollowTheirMilestone() throws {
        let queue = try makeV4Database()
        var planID: Int64 = 0
        var unclaimed: Int64 = 0
        try queue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO plans (slug, title, status, created_by_key, created_at, updated_at)
                    VALUES ('live-board', 'Ship the live board', 'active', 'codex:worker-1', 0, 0)
                    """
            )
            planID = db.lastInsertedRowID
            unclaimed = try insertTask(db, title: "Nobody took it", planID: planID)
        }

        try AuspexStore.migrator.migrate(queue)
        #expect(try projectKey(ofTask: unclaimed, in: queue) == "/Users/example/Code/auspex")
    }

    @Test("the migration is registered and adds the two columns")
    func columnsExist() throws {
        let store = try AuspexStore(inMemory: true)
        #expect(AuspexStore.migrator.migrations.contains("v5_projects_own_tasks"))
        let columns = try store.dbWriter.read { db in
            (try db.columns(in: "tasks").map(\.name), try db.columns(in: "plans").map(\.name))
        }
        #expect(columns.0.contains("project_key"))
        #expect(columns.1.contains("project_key"))
    }
}
