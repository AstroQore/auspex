import AgentSessionKit
import AgentSessionLive
import Foundation
import GRDB

/// Files every task that was written before projects contained tasks.
///
/// The `v5_projects_own_tasks` migration adds `tasks.project_key` and
/// `plans.project_key`, and this is the part that has to *decide* something: a
/// row already in the ledger names no project, and leaving it NULL would keep
/// the "Unfiled" lane alive under a new name.
///
/// The evidence, in order, is the same evidence a live board uses — which is
/// the point, because the two must not disagree about where a task is:
///
/// 1. **The session that claimed it.** A claim is the strongest statement
///    anybody made about who is doing this work, and the claimer's project is
///    where the work happened.
/// 2. **The session that filed it**, for a task nobody ever took.
/// 3. **The milestone's project**, for a task filed by hand under a heading
///    whose other tasks resolved.
/// 4. ``TaskProject/scratchKey`` — a named place, not a `NULL`.
///
/// A session's own project is read from `projects.root_path` through
/// `sessions.project_id` (the git root, or the directory when there is no
/// repository — exactly what ``BoardSnapshot/projectKey(for:)`` answers), then
/// from `sessions.cwd`, then from the harness it belongs to.
///
/// The user layer is deliberately *not* consulted here. Claims live in
/// `~/.auspex/settings.json`, not in the database, and a migration that read
/// them would be a migration whose result depended on a file it does not own.
/// The Tasks page folds a claimed folder into its project when it draws —
/// which also handles the project a person makes tomorrow, over tasks filed
/// today.
enum TaskProjectBackfill {
    static func run(_ db: Database) throws {
        let sessions = try projectKeysBySession(db)
        var byTask: [Int64: String] = [:]
        var tasksByPlan: [Int64: [Int64]] = [:]
        let taskRows = try Row.fetchAll(db, sql: """
            SELECT id, plan_id, claimed_by_key, created_by_key FROM tasks ORDER BY id ASC
            """)
        for row in taskRows {
            guard let id = row["id"] as Int64? else { continue }
            if let planID = row["plan_id"] as Int64? {
                tasksByPlan[planID, default: []].append(id)
            }
            let claimed = (row["claimed_by_key"] as String?).flatMap { sessions[$0] }
            let created = (row["created_by_key"] as String?).flatMap { sessions[$0] }
            if let key = claimed ?? created { byTask[id] = key }
        }

        // Milestones take their project from whoever registered them, and
        // otherwise from the first task under them that resolved — a heading
        // belongs where its work is.
        var byPlan: [Int64: String] = [:]
        let planRows = try Row.fetchAll(db, sql: "SELECT id, created_by_key FROM plans ORDER BY id ASC")
        for row in planRows {
            guard let id = row["id"] as Int64? else { continue }
            if let key = (row["created_by_key"] as String?).flatMap({ sessions[$0] }) {
                byPlan[id] = key
                continue
            }
            if let key = (tasksByPlan[id] ?? []).compactMap({ byTask[$0] }).first {
                byPlan[id] = key
            }
        }

        // What is left is a task nobody claimed, filed by nobody Auspex still
        // has a row for: its milestone's project, or the scratch project.
        for row in taskRows {
            guard let id = row["id"] as Int64?, byTask[id] == nil else { continue }
            let planKey = (row["plan_id"] as Int64?).flatMap { byPlan[$0] }
            byTask[id] = planKey ?? TaskProject.scratchKey
        }

        try write(byTask, into: "tasks", db)
        try write(byPlan, into: "plans", db)
    }

    /// The project key of every stored session, in the board's key space.
    private static func projectKeysBySession(_ db: Database) throws -> [String: String] {
        let rows = try Row.fetchAll(db, sql: """
            SELECT s.key AS key, s.harness AS harness, s.cwd AS cwd, p.root_path AS root_path
              FROM sessions s
              LEFT JOIN projects p ON p.id = s.project_id
            """)
        var keys: [String: String] = [:]
        keys.reserveCapacity(rows.count)
        for row in rows {
            guard let key = row["key"] as String? else { continue }
            if let root = row["root_path"] as String?, !root.isEmpty {
                keys[key] = root
            } else if let cwd = row["cwd"] as String?, !cwd.isEmpty {
                keys[key] = cwd
            } else if let raw = row["harness"] as String?, let harness = Harness(rawValue: raw) {
                keys[key] = PseudoProject.key(for: harness)
            }
        }
        return keys
    }

    private static func write(_ keys: [Int64: String], into table: String, _ db: Database) throws {
        guard !keys.isEmpty else { return }
        let statement = try db.makeStatement(
            sql: "UPDATE \(table) SET project_key = ? WHERE id = ? AND project_key IS NULL"
        )
        for (id, key) in keys.sorted(by: { $0.key < $1.key }) {
            statement.setUncheckedArguments([key, id])
            try statement.execute()
        }
    }
}
