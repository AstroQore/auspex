import Foundation
import GRDB

extension TaskRepository {
    /// The ids of every task the ledger holds, and of the ones that are closed.
    ///
    /// Two `SELECT`s of one column each rather than a join per row: readiness
    /// is a set membership question asked of a whole page at once.
    static func closedTaskIDs(in db: Database) throws -> Set<Int64> {
        Set(try Int64.fetchAll(db, sql: "SELECT id FROM tasks WHERE status = 'done'"))
    }

    static func allTaskIDs(in db: Database) throws -> Set<Int64> {
        Set(try Int64.fetchAll(db, sql: "SELECT id FROM tasks"))
    }

    /// Fills in the `depends_on` edges for a page of tasks, in one query.
    static func attachDependencies(
        to tasks: [AuspexTask],
        in db: Database
    ) throws -> [AuspexTask] {
        guard !tasks.isEmpty else { return tasks }
        let placeholders = Array(repeating: "?", count: tasks.count).joined(separator: ", ")
        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT task_id, depends_on_id FROM task_deps
                 WHERE task_id IN (\(placeholders))
                 ORDER BY created_at ASC, depends_on_id ASC
                """,
            arguments: StatementArguments(tasks.map(\.id))
        )
        guard !rows.isEmpty else { return tasks }
        var byTask: [Int64: [Int64]] = [:]
        for row in rows {
            guard let task = row["task_id"] as Int64?,
                  let dependency = row["depends_on_id"] as Int64? else { continue }
            byTask[task, default: []].append(dependency)
        }
        return tasks.map { byTask[$0.id].map($0.withDependencies) ?? $0 }
    }

    /// Replaces a task's dependencies after validating the whole proposed
    /// graph. Nothing is deleted until validation succeeds, so a typo, a
    /// self-edge, or a cycle leaves the graph exactly as it was.
    static func setDependencies(
        _ ids: [Int64],
        of taskID: Int64,
        at date: Date,
        in db: Database
    ) throws {
        let ids = try validatedDependencies(ids, of: taskID, in: db)
        try db.execute(sql: "DELETE FROM task_deps WHERE task_id = ?", arguments: [taskID])
        for id in ids {
            try db.execute(
                sql: """
                    INSERT OR IGNORE INTO task_deps (task_id, depends_on_id, created_at)
                    VALUES (?, ?, ?)
                    """,
                arguments: [taskID, id, date.timeIntervalSince1970]
            )
        }
    }

    /// Sets what a task waits on, from outside a transaction.
    public func setDependencies(
        _ ids: [Int64],
        of taskID: Int64,
        expectedVersion: Int64? = nil,
        now: Date = Date()
    ) throws {
        try dbWriter.write { db in
            guard let existing = try Self.task(id: taskID, in: db) else {
                throw TaskLedgerError.notFound("task \(taskID)")
            }
            try Self.assertVersion(expectedVersion, of: existing)
            let normalized = try Self.validatedDependencies(ids, of: taskID, in: db)
            let current = try Int64.fetchAll(
                db,
                sql: "SELECT depends_on_id FROM task_deps WHERE task_id = ? ORDER BY created_at, depends_on_id",
                arguments: [taskID]
            )
            guard normalized != current else { return }
            try Self.setDependencies(normalized, of: taskID, at: now, in: db)
            try db.execute(
                sql: "UPDATE tasks SET updated_at = ?, version = version + 1 WHERE id = ?",
                arguments: [now.timeIntervalSince1970, taskID]
            )
        }
    }

    /// Every dependency edge in the ledger, as `task → what it waits on`.
    ///
    /// Read whole by the board, which holds a frame's worth of tasks already
    /// and would otherwise ask one query per row.
    public func allDependencies() throws -> [Int64: [Int64]] {
        try dbWriter.read { db in
            var byTask: [Int64: [Int64]] = [:]
            for row in try Row.fetchAll(
                db,
                sql: "SELECT task_id, depends_on_id FROM task_deps ORDER BY created_at ASC"
            ) {
                guard let task = row["task_id"] as Int64?,
                      let dependency = row["depends_on_id"] as Int64? else { continue }
                byTask[task, default: []].append(dependency)
            }
            return byTask
        }
    }

    static func dependencies(of taskID: Int64, in db: Database) throws -> [Int64] {
        try Int64.fetchAll(
            db,
            sql: """
                SELECT depends_on_id FROM task_deps
                 WHERE task_id = ? ORDER BY created_at ASC, depends_on_id ASC
                """,
            arguments: [taskID]
        )
    }

    /// Validates a proposed dependency replacement without touching the
    /// current graph. Following edges from each proposed dependency must never
    /// lead back to the task being changed.
    static func validatedDependencies(
        _ raw: [Int64],
        of taskID: Int64,
        in db: Database
    ) throws -> [Int64] {
        var seen: Set<Int64> = []
        let ids = raw.filter { seen.insert($0).inserted }
        if ids.contains(taskID) { throw TaskLedgerError.selfDependency(taskID) }

        let known = Set(try Int64.fetchAll(db, sql: "SELECT id FROM tasks"))
        if let missing = ids.first(where: { !known.contains($0) }) {
            throw TaskLedgerError.dependencyNotFound(missing)
        }

        let rows = try Row.fetchAll(
            db, sql: "SELECT task_id, depends_on_id FROM task_deps"
        )
        var graph: [Int64: [Int64]] = [:]
        for row in rows {
            guard let from = row["task_id"] as Int64?,
                  let to = row["depends_on_id"] as Int64? else { continue }
            graph[from, default: []].append(to)
        }
        graph[taskID] = ids

        var visiting: Set<Int64> = []
        var visited: Set<Int64> = []
        func visit(_ node: Int64, path: [Int64]) throws {
            if visiting.contains(node) {
                let start = path.firstIndex(of: node) ?? 0
                throw TaskLedgerError.dependencyCycle(Array(path[start...]) + [node])
            }
            guard visited.insert(node).inserted else { return }
            visiting.insert(node)
            for next in graph[node] ?? [] {
                try visit(next, path: path + [node])
            }
            visiting.remove(node)
        }
        try visit(taskID, path: [])
        return ids
    }
}
