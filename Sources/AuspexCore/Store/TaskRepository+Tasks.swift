import AgentSessionLive
import Foundation
import GRDB

extension TaskRepository {
    // MARK: - Tasks

    /// Files a task in a project.
    ///
    /// `projectKey` is the project the task is in, resolved by the caller from
    /// the frame — see ``TaskProject/resolve(explicit:session:board:)``. When
    /// it is `nil` and the task is being filed under a milestone, the
    /// milestone's project is used: a task inside a heading is inside whatever
    /// contains the heading.
    @discardableResult
    public func createTask(
        title: String,
        body: String? = nil,
        planID: Int64? = nil,
        status: AuspexTaskStatus = .todo,
        priority: Int = 0,
        projectID: Int64? = nil,
        projectKey: String? = nil,
        createdBy: SessionKey? = nil,
        source: String? = nil,
        kind: TaskKind? = nil,
        labels: [String] = [],
        dependsOn: [Int64] = [],
        now: Date = Date()
    ) throws -> AuspexTask {
        try dbWriter.write { db in
            let key = try projectKey
                ?? planID.flatMap { try Self.plan(id: $0, in: db)?.projectKey }
            try db.execute(
                sql: """
                    INSERT INTO tasks
                        (title, body, status, priority, project_id, project_key,
                         created_by_key, source, created_at, updated_at, plan_id,
                         kind, labels)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    title, body, status.rawValue, priority, projectID, key,
                    createdBy?.description, source,
                    now.timeIntervalSince1970, now.timeIntervalSince1970, planID,
                    kind?.rawValue, TaskLabels.encode(labels)
                ]
            )
            let id = db.lastInsertedRowID
            try Self.appendLog(
                taskID: id, actor: createdBy, kind: "created", message: title, at: now, in: db
            )
            try Self.setDependencies(dependsOn, of: id, at: now, in: db)
            try Self.adoptProject(key, forPlan: planID, in: db)
            try Self.touchPlan(planID, at: now, in: db)
            guard let task = try Self.task(id: id, in: db) else {
                throw TaskLedgerError.notFound("task \(id)")
            }
            return try Self.attachDependencies(to: [task], in: db)[0]
        }
    }

    /// The tasks matching a filter, board order: by status column, then
    /// priority, then most recently touched.
    public func tasks(
        planID: Int64? = nil,
        projectKey: String? = nil,
        statuses: [AuspexTaskStatus] = [],
        claimedBy: SessionKey? = nil,
        readyOnly: Bool = false,
        limit: Int = 500
    ) throws -> [AuspexTask] {
        try dbWriter.read { db in
            var sql = "SELECT * FROM tasks"
            var clauses: [String] = []
            var arguments = StatementArguments()
            if let planID {
                clauses.append("plan_id = ?")
                arguments += [planID]
            }
            if let projectKey {
                clauses.append("project_key = ?")
                arguments += [projectKey]
            }
            if !statuses.isEmpty {
                let placeholders = Array(repeating: "?", count: statuses.count).joined(separator: ", ")
                clauses.append("status IN (\(placeholders))")
                arguments += StatementArguments(statuses.map(\.rawValue))
            }
            if let claimedBy {
                clauses.append("claimed_by_key = ?")
                arguments += [claimedBy.description]
            }
            if !clauses.isEmpty { sql += " WHERE " + clauses.joined(separator: " AND ") }
            sql += """
                 ORDER BY CASE status
                            WHEN 'todo' THEN 0 WHEN 'doing' THEN 1
                            WHEN 'blocked' THEN 2 WHEN 'review' THEN 3 ELSE 4 END,
                          priority DESC, updated_at DESC, id DESC
                 LIMIT ?
                """
            arguments += [limit]
            let page = try Row.fetchAll(db, sql: sql, arguments: arguments)
                .compactMap(AuspexTask.init(row:))
            let withDeps = try Self.attachDependencies(to: page, in: db)
            guard readyOnly else { return withDeps }
            // Readiness is answered against the *whole* ledger, not against
            // the page: a task filtered to one project can perfectly well wait
            // on one in another, and a filter that could not see it would call
            // the task ready and hand a worker something that cannot start.
            let closed = try Self.closedTaskIDs(in: db)
            let known = try Self.allTaskIDs(in: db)
            return withDeps.filter { $0.isReady(closed: closed, known: known) }
        }
    }

    /// One task by id, with its dependencies.
    public func task(id: Int64) throws -> AuspexTask? {
        try dbWriter.read { db in
            guard let task = try Self.task(id: id, in: db) else { return nil }
            return try Self.attachDependencies(to: [task], in: db).first
        }
    }

    /// How many tasks each project holds, and how many of them are still open.
    ///
    /// One `GROUP BY` on an indexed column rather than a fetch of every task,
    /// because the readers are a sidebar row and a Projects-page column: both
    /// are on screen while nothing is happening, and both want a number rather
    /// than a list. See `AGENTS.md` § 4.1.
    public func taskCounts() throws -> [String: TaskProjectCounts] {
        try dbWriter.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT project_key AS project_key,
                       COUNT(*) AS total,
                       SUM(CASE WHEN status = 'done' THEN 0 ELSE 1 END) AS open_count
                  FROM tasks
                 WHERE project_key IS NOT NULL
                 GROUP BY project_key
                """)
            var counts: [String: TaskProjectCounts] = [:]
            counts.reserveCapacity(rows.count)
            for row in rows {
                guard let key = row["project_key"] as String? else { continue }
                counts[key] = TaskProjectCounts(
                    total: row["total"] as Int? ?? 0,
                    open: row["open_count"] as Int? ?? 0
                )
            }
            return counts
        }
    }

    /// Moves a task into a project, and every session already on it with it.
    ///
    /// Separate from ``updateTask(id:title:body:status:priority:planID:actor:now:)``
    /// because it is the one edit that changes which lane a row is *in* rather
    /// than what it says, and because it writes a line into the task's history:
    /// a task that moved between projects without leaving a trace is a task
    /// somebody will spend an afternoon looking for.
    @discardableResult
    public func moveTask(
        id: Int64,
        toProjectKey key: String,
        actor: SessionKey? = nil,
        expectedVersion: Int64? = nil,
        now: Date = Date()
    ) throws -> AuspexTask {
        try dbWriter.write { db in
            guard let existing = try Self.task(id: id, in: db) else {
                throw TaskLedgerError.notFound("task \(id)")
            }
            try Self.assertVersion(expectedVersion, of: existing)
            guard existing.projectKey != key else { return existing }
            try db.execute(
                sql: "UPDATE tasks SET project_key = ?, updated_at = ?, version = version + 1 WHERE id = ?",
                arguments: [key, now.timeIntervalSince1970, id]
            )
            try Self.appendLog(
                taskID: id, actor: actor, kind: "project",
                message: [existing.projectKey, key].compactMap { $0 }.joined(separator: " → "),
                at: now, in: db
            )
            guard let task = try Self.task(id: id, in: db) else {
                throw TaskLedgerError.notFound("task \(id)")
            }
            return task
        }
    }

    /// Changes whatever was given and leaves the rest alone.
    ///
    /// Every parameter is doubly optional so that "not mentioned" and
    /// "explicitly cleared" stay different answers: `.some(nil)` clears the
    /// body, `nil` does not touch it.
    @discardableResult
    public func updateTask(
        id: Int64,
        title: String? = nil,
        body: String?? = nil,
        status: AuspexTaskStatus? = nil,
        priority: Int? = nil,
        planID: Int64?? = nil,
        kind: TaskKind?? = nil,
        labels: [String]? = nil,
        dependsOn: [Int64]? = nil,
        projectKey: String? = nil,
        actor: SessionKey? = nil,
        expectedVersion: Int64? = nil,
        now: Date = Date()
    ) throws -> AuspexTask {
        try dbWriter.write { db in
            guard let existing = try Self.task(id: id, in: db) else {
                throw TaskLedgerError.notFound("task \(id)")
            }
            try Self.assertVersion(expectedVersion, of: existing)
            let currentDependencies = try Self.dependencies(of: id, in: db)
            let nextDependencies = try dependsOn.map {
                try Self.validatedDependencies($0, of: id, in: db)
            }
            var assignments: [String] = ["updated_at = ?", "version = version + 1"]
            var arguments: StatementArguments = [now.timeIntervalSince1970]
            var targetProject = existing.projectKey
            if let title {
                assignments.append("title = ?")
                arguments += [title]
            }
            if let body {
                assignments.append("body = ?")
                arguments += [body]
            }
            if let status {
                assignments.append("status = ?")
                arguments += [status.rawValue]
                // Moving a task back before Review by hand un-finishes it.
                // Leaving `completed_at` behind would make the row read as
                // finished on one column and open on another. `review` keeps
                // it: the work *was* finished, and the stamp is when.
                if status != .done, status != .review {
                    assignments.append("completed_at = NULL")
                }
            }
            if let priority {
                assignments.append("priority = ?")
                arguments += [priority]
            }
            if let kind {
                assignments.append("kind = ?")
                arguments += [kind?.rawValue]
            }
            if let labels {
                assignments.append("labels = ?")
                arguments += [TaskLabels.encode(labels)]
            }
            if let planID {
                assignments.append("plan_id = ?")
                arguments += [planID]
                // Moving a task under a milestone moves it into the project
                // that milestone is in — the containment runs one way, and a
                // task filed under a heading in another project would break it.
                let milestone = try planID.flatMap { try Self.plan(id: $0, in: db) }
                if let key = milestone?.projectKey, key != existing.projectKey {
                    targetProject = key
                }
            }
            if let projectKey { targetProject = projectKey }
            if targetProject != existing.projectKey {
                assignments.append("project_key = ?")
                arguments += [targetProject]
            }
            let nextLabels = labels.map(TaskLabels.normalize)
            let titleChanged = title.map { $0 != existing.title } ?? false
            let bodyChanged = body.map { $0 != existing.body } ?? false
            let statusChanged = status.map { $0 != existing.status } ?? false
            let priorityChanged = priority.map { $0 != existing.priority } ?? false
            let planChanged = planID.map { $0 != existing.planID } ?? false
            let kindChanged = kind.map { $0 != existing.kind } ?? false
            let labelsChanged = nextLabels.map { $0 != existing.labels } ?? false
            let dependenciesChanged = nextDependencies.map {
                $0 != currentDependencies
            } ?? false
            let projectChanged = targetProject != existing.projectKey
            let changed = titleChanged || bodyChanged || statusChanged || priorityChanged
                || planChanged || kindChanged || labelsChanged || dependenciesChanged
                || projectChanged
            guard changed else {
                return existing.withDependencies(currentDependencies)
            }
            arguments += [id]
            try db.execute(
                sql: "UPDATE tasks SET \(assignments.joined(separator: ", ")) WHERE id = ?",
                arguments: arguments
            )
            if let nextDependencies, nextDependencies != currentDependencies {
                try Self.setDependencies(nextDependencies, of: id, at: now, in: db)
            }
            if let status, status != existing.status {
                try Self.appendLog(
                    taskID: id, actor: actor, kind: "status",
                    message: "\(existing.status.rawValue) → \(status.rawValue)", at: now, in: db
                )
            }
            if targetProject != existing.projectKey {
                try Self.appendLog(
                    taskID: id, actor: actor, kind: "project",
                    message: [existing.projectKey, targetProject]
                        .compactMap { $0 }.joined(separator: " → "),
                    at: now, in: db
                )
            }
            try Self.touchPlan(existing.planID, at: now, in: db)
            guard let task = try Self.task(id: id, in: db) else {
                throw TaskLedgerError.notFound("task \(id)")
            }
            return try Self.attachDependencies(to: [task], in: db)[0]
        }
    }

    /// Records that whoever was doing this task has finished it, and asks for
    /// it to be looked at.
    ///
    /// **It does not close the task.** An agent saying it is done is a claim
    /// about its own work, and the one thing a board full of agents must not
    /// let any of them do is mark their own homework. So the task lands in
    /// ``AuspexTaskStatus/review``, where it is still counted as open, still
    /// on the wall, and still wearing the sentence the worker wrote — until a
    /// person closes it with ``closeTask(id:by:now:)``.
    @discardableResult
    public func completeTask(
        id: Int64,
        result: String?,
        by session: SessionKey? = nil,
        requireHolder: Bool = false,
        expectedVersion: Int64? = nil,
        now: Date = Date()
    ) throws -> AuspexTask {
        try dbWriter.write { db in
            guard let existing = try Self.task(id: id, in: db) else {
                throw TaskLedgerError.notFound("task \(id)")
            }
            try Self.assertVersion(expectedVersion, of: existing)
            if requireHolder, existing.claimedBy != session {
                throw TaskLedgerError.notTaskHolder(existing.claimedBy?.description)
            }
            try db.execute(
                sql: """
                    UPDATE tasks
                       SET status = 'review', completed_at = ?, updated_at = ?,
                           result = COALESCE(?, result), version = version + 1
                     WHERE id = ?
                    """,
                arguments: [now.timeIntervalSince1970, now.timeIntervalSince1970, result, id]
            )
            try Self.appendLog(
                taskID: id, actor: session, kind: "finished", message: result, at: now, in: db
            )
            try Self.touchPlan(existing.planID, at: now, in: db)
            guard let task = try Self.task(id: id, in: db) else {
                throw TaskLedgerError.notFound("task \(id)")
            }
            return try Self.attachDependencies(to: [task], in: db)[0]
        }
    }

    /// Closes a task. The gesture only a person makes.
    ///
    /// `actor` is `nil` for the ordinary case — somebody clicked — and is only
    /// ever a session when a later ingress needs to say who. Separate from
    /// ``updateTask(id:status:)`` so the log line says *closed* rather than
    /// `review → done`, which is the same fact in a worse sentence.
    @discardableResult
    public func closeTask(
        id: Int64,
        by session: SessionKey? = nil,
        expectedVersion: Int64? = nil,
        now: Date = Date()
    ) throws -> AuspexTask {
        try dbWriter.write { db in
            guard let existing = try Self.task(id: id, in: db) else {
                throw TaskLedgerError.notFound("task \(id)")
            }
            try Self.assertVersion(expectedVersion, of: existing)
            try db.execute(
                sql: """
                    UPDATE tasks
                       SET status = 'done',
                           completed_at = COALESCE(completed_at, ?),
                           updated_at = ?, version = version + 1
                     WHERE id = ?
                    """,
                arguments: [now.timeIntervalSince1970, now.timeIntervalSince1970, id]
            )
            try Self.appendLog(
                taskID: id, actor: session, kind: "closed", message: nil, at: now, in: db
            )
            try Self.touchPlan(existing.planID, at: now, in: db)
            guard let task = try Self.task(id: id, in: db) else {
                throw TaskLedgerError.notFound("task \(id)")
            }
            return try Self.attachDependencies(to: [task], in: db)[0]
        }
    }

    // MARK: - Shared task statements

    static func task(id: Int64, in db: Database) throws -> AuspexTask? {
        try Row.fetchOne(db, sql: "SELECT * FROM tasks WHERE id = ?", arguments: [id])
            .flatMap(AuspexTask.init(row:))
    }

    static func assertVersion(_ expected: Int64?, of task: AuspexTask) throws {
        guard let expected else { return }
        guard expected == task.version else {
            throw TaskLedgerError.versionConflict(expected: expected, actual: task.version)
        }
    }
}
