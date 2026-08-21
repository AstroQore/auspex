import AgentSessionKit
import AgentSessionLive
import Foundation
import GRDB

/// Reads and writes the task ledger: milestones, tasks, claims, the log behind
/// them, and what agents said when they called for a person.
///
/// Every task carries a `project_key` in the board's own key space — see
/// ``TaskProject``. The repository never *resolves* one: it is handed the key
/// its caller worked out from the frame, because the frame is where a
/// session's project lives and a store that guessed would be a second answer
/// to a question that already has one.
///
/// A value over a `DatabaseWriter`, like ``SessionRepository``, so the MCP
/// server, the board model and a test can each make one without sharing
/// anything mutable. Every method does its own transaction; the ones that have
/// to be atomic against a concurrent claim say so in their own comments.
public struct TaskRepository: Sendable {
    public let dbWriter: any DatabaseWriter

    public init(dbWriter: any DatabaseWriter) {
        self.dbWriter = dbWriter
    }

    public init(store: AuspexStore) {
        self.dbWriter = store.dbWriter
    }

    // MARK: - Milestones

    /// Registers a milestone, or returns the one already registered under the
    /// same slug.
    ///
    /// Idempotent by slug, because that is what makes a brief safe to re-run:
    /// a supervisor whose first attempt died halfway through re-registers the
    /// same milestone and gets the same id back rather than a second heading on
    /// the board. A re-registration that *knows* the project when the first one
    /// did not fills it in — learning where the work is happening is not a
    /// conflict.
    @discardableResult
    public func createPlan(
        title: String,
        slug: String? = nil,
        summary: String? = nil,
        projectID: Int64? = nil,
        projectKey: String? = nil,
        createdBy: SessionKey? = nil,
        now: Date = Date()
    ) throws -> AuspexPlan {
        let handle = TaskSlug.make(slug ?? title)
        return try dbWriter.write { db in
            if let existing = try Self.plan(slug: handle, in: db) {
                guard existing.projectKey == nil, let projectKey else { return existing }
                try db.execute(
                    sql: "UPDATE plans SET project_key = ?, updated_at = ? WHERE id = ?",
                    arguments: [projectKey, now.timeIntervalSince1970, existing.id]
                )
                return try Self.plan(id: existing.id, in: db) ?? existing
            }
            try db.execute(
                sql: """
                    INSERT INTO plans
                        (slug, title, summary, status, project_id, project_key,
                         created_by_key, created_at, updated_at, archived_at)
                    VALUES (?, ?, ?, 'active', ?, ?, ?, ?, ?, NULL)
                    """,
                arguments: [
                    handle, title, summary, projectID, projectKey, createdBy?.description,
                    now.timeIntervalSince1970, now.timeIntervalSince1970
                ]
            )
            let id = db.lastInsertedRowID
            guard let plan = try Self.plan(id: id, in: db) else {
                throw TaskLedgerError.notFound("plan \(id)")
            }
            return plan
        }
    }

    /// The milestones, newest first. Archived ones are left out unless asked
    /// for.
    public func plans(includingArchived: Bool = false, limit: Int = 200) throws -> [AuspexPlan] {
        try dbWriter.read { db in
            var sql = "SELECT * FROM plans"
            if !includingArchived { sql += " WHERE status = 'active'" }
            sql += " ORDER BY updated_at DESC, id DESC LIMIT ?"
            return try Row.fetchAll(db, sql: sql, arguments: [limit]).compactMap(AuspexPlan.init(row:))
        }
    }

    /// One plan by id.
    public func plan(id: Int64) throws -> AuspexPlan? {
        try dbWriter.read { db in try Self.plan(id: id, in: db) }
    }

    /// One plan by the handle a brief carries.
    public func plan(slug: String) throws -> AuspexPlan? {
        try dbWriter.read { db in try Self.plan(slug: TaskSlug.make(slug), in: db) }
    }

    /// Either spelling, which is what a tool argument actually is: an agent
    /// holds whichever of the two its brief happened to carry.
    public func plan(reference: String) throws -> AuspexPlan? {
        if let id = Int64(reference), let plan = try plan(id: id) { return plan }
        return try plan(slug: reference)
    }

    /// Archives a plan. Its tasks stay exactly where they are — a plan is a
    /// heading, and filing the heading away must not silently close the work
    /// underneath it.
    @discardableResult
    public func archivePlan(id: Int64, now: Date = Date()) throws -> AuspexPlan? {
        try dbWriter.write { db in
            try db.execute(
                sql: """
                    UPDATE plans SET status = 'archived', archived_at = ?, updated_at = ?
                     WHERE id = ?
                    """,
                arguments: [now.timeIntervalSince1970, now.timeIntervalSince1970, id]
            )
            return try Self.plan(id: id, in: db)
        }
    }

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

    /// The ids of every task the ledger holds, and of the ones that are closed.
    ///
    /// Two `SELECT`s of one column each rather than a join per row: readiness
    /// is a set membership question asked of a whole page at once.
    private static func closedTaskIDs(in db: Database) throws -> Set<Int64> {
        Set(try Int64.fetchAll(db, sql: "SELECT id FROM tasks WHERE status = 'done'"))
    }

    private static func allTaskIDs(in db: Database) throws -> Set<Int64> {
        Set(try Int64.fetchAll(db, sql: "SELECT id FROM tasks"))
    }

    /// Fills in the `depends_on` edges for a page of tasks, in one query.
    private static func attachDependencies(
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

    /// Replaces a task's dependencies. A self-edge is dropped rather than
    /// stored: a task that waits on itself is never ready, and nothing good
    /// comes of letting a caller say so.
    private static func setDependencies(
        _ ids: [Int64],
        of taskID: Int64,
        at date: Date,
        in db: Database
    ) throws {
        try db.execute(sql: "DELETE FROM task_deps WHERE task_id = ?", arguments: [taskID])
        var seen: Set<Int64> = [taskID]
        for id in ids where seen.insert(id).inserted {
            // Only edges to rows that exist. A dependency on a task nobody
            // filed would be a permanent block with no way to see what it is.
            guard try Bool.fetchOne(
                db, sql: "SELECT EXISTS(SELECT 1 FROM tasks WHERE id = ?)", arguments: [id]
            ) == true else { continue }
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
    public func setDependencies(_ ids: [Int64], of taskID: Int64, now: Date = Date()) throws {
        try dbWriter.write { db in
            try Self.setDependencies(ids, of: taskID, at: now, in: db)
            try db.execute(
                sql: "UPDATE tasks SET updated_at = ? WHERE id = ?",
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
        now: Date = Date()
    ) throws -> AuspexTask {
        try dbWriter.write { db in
            guard let existing = try Self.task(id: id, in: db) else {
                throw TaskLedgerError.notFound("task \(id)")
            }
            guard existing.projectKey != key else { return existing }
            try db.execute(
                sql: "UPDATE tasks SET project_key = ?, updated_at = ? WHERE id = ?",
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

    /// Takes a task, recording who took it and for what.
    ///
    /// One statement, guarded in SQL rather than read-then-write: two workers
    /// handed the same id race here, and the loser must be told plainly rather
    /// than quietly overwriting the winner's scope. A re-claim by the *same*
    /// session is allowed and updates the scope — a worker refining what it
    /// took is not a conflict.
    ///
    /// `projectKey` is the claiming session's project. It is applied only to a
    /// task that has none yet: a task inherits its project from whoever first
    /// takes it, and a task that already knows where it lives is not moved by
    /// somebody picking it up from a worktree next door.
    ///
    /// - Throws: ``TaskLedgerError/alreadyClaimed(_:)`` when somebody else
    ///   holds it.
    @discardableResult
    public func claimTask(
        id: Int64,
        role: String,
        scope: String?,
        by session: SessionKey?,
        projectKey: String? = nil,
        now: Date = Date()
    ) throws -> AuspexTask {
        try dbWriter.write { db in
            guard let existing = try Self.task(id: id, in: db) else {
                throw TaskLedgerError.notFound("task \(id)")
            }
            if let holder = existing.claimedBy, holder != session {
                throw TaskLedgerError.alreadyClaimed(holder.description)
            }
            try db.execute(
                sql: """
                    UPDATE tasks
                       SET claim_role = ?, claim_scope = ?, claimed_by_key = ?,
                           claimed_at = ?, updated_at = ?,
                           project_key = COALESCE(project_key, ?),
                           status = CASE WHEN status = 'todo' THEN 'doing' ELSE status END
                     WHERE id = ?
                    """,
                arguments: [
                    role, scope, session?.description,
                    now.timeIntervalSince1970, now.timeIntervalSince1970, projectKey, id
                ]
            )
            if existing.projectKey == nil, let projectKey {
                try Self.adoptProject(projectKey, forPlan: existing.planID, in: db)
            }
            if let session {
                try Self.link(taskID: id, session: session, kind: .claim, at: now, in: db)
            }
            try Self.appendLog(
                taskID: id,
                actor: session,
                kind: "claimed",
                message: [role, scope].compactMap { $0 }.joined(separator: " · "),
                at: now,
                in: db
            )
            try Self.touchPlan(existing.planID, at: now, in: db)
            guard let task = try Self.task(id: id, in: db) else {
                throw TaskLedgerError.notFound("task \(id)")
            }
            return task
        }
    }

    /// Releases a claim without closing the task — the honest thing for a
    /// worker that is giving up, as opposed to one that finished.
    @discardableResult
    public func releaseTask(id: Int64, by session: SessionKey?, now: Date = Date()) throws -> AuspexTask {
        try dbWriter.write { db in
            try db.execute(
                sql: """
                    UPDATE tasks
                       SET claim_role = NULL, claim_scope = NULL, claimed_by_key = NULL,
                           claimed_at = NULL, updated_at = ?,
                           status = CASE WHEN status = 'doing' THEN 'todo' ELSE status END
                     WHERE id = ?
                    """,
                arguments: [now.timeIntervalSince1970, id]
            )
            try Self.appendLog(taskID: id, actor: session, kind: "released", message: nil, at: now, in: db)
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
        actor: SessionKey? = nil,
        now: Date = Date()
    ) throws -> AuspexTask {
        try dbWriter.write { db in
            guard let existing = try Self.task(id: id, in: db) else {
                throw TaskLedgerError.notFound("task \(id)")
            }
            var assignments: [String] = ["updated_at = ?"]
            var arguments: StatementArguments = [now.timeIntervalSince1970]
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
                    assignments.append("project_key = ?")
                    arguments += [key]
                }
            }
            arguments += [id]
            try db.execute(
                sql: "UPDATE tasks SET \(assignments.joined(separator: ", ")) WHERE id = ?",
                arguments: arguments
            )
            if let dependsOn {
                try Self.setDependencies(dependsOn, of: id, at: now, in: db)
            }
            if let status, status != existing.status {
                try Self.appendLog(
                    taskID: id, actor: actor, kind: "status",
                    message: "\(existing.status.rawValue) → \(status.rawValue)", at: now, in: db
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
        now: Date = Date()
    ) throws -> AuspexTask {
        try dbWriter.write { db in
            guard let existing = try Self.task(id: id, in: db) else {
                throw TaskLedgerError.notFound("task \(id)")
            }
            try db.execute(
                sql: """
                    UPDATE tasks
                       SET status = 'review', completed_at = ?, updated_at = ?,
                           result = COALESCE(?, result)
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
        now: Date = Date()
    ) throws -> AuspexTask {
        try dbWriter.write { db in
            guard let existing = try Self.task(id: id, in: db) else {
                throw TaskLedgerError.notFound("task \(id)")
            }
            try db.execute(
                sql: """
                    UPDATE tasks
                       SET status = 'done',
                           completed_at = COALESCE(completed_at, ?),
                           updated_at = ?
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

    // MARK: - Links

    /// Attaches a session to a task.
    public func link(
        taskID: Int64,
        session: SessionKey,
        kind: AuspexTaskLinkKind,
        now: Date = Date()
    ) throws {
        try dbWriter.write { db in
            try Self.link(taskID: taskID, session: session, kind: kind, at: now, in: db)
            try Self.appendLog(
                taskID: taskID, actor: session, kind: "linked", message: kind.rawValue, at: now, in: db
            )
        }
    }

    /// Detaches a session from a task. A claim link is left alone: releasing a
    /// claim is ``releaseTask(id:by:now:)``, and unlinking one behind its back
    /// would leave the task claimed by a session no longer on it.
    public func unlink(taskID: Int64, session: SessionKey) throws {
        try dbWriter.write { db in
            try db.execute(
                sql: """
                    DELETE FROM task_links
                     WHERE task_id = ? AND session_key = ? AND kind <> 'claim'
                    """,
                arguments: [taskID, session.description]
            )
        }
    }

    /// Every session attached to a task.
    public func links(taskID: Int64) throws -> [AuspexTaskLink] {
        try dbWriter.read { db in
            try Row.fetchAll(
                db,
                sql: "SELECT * FROM task_links WHERE task_id = ? ORDER BY created_at ASC",
                arguments: [taskID]
            ).compactMap(AuspexTaskLink.init(row:))
        }
    }

    /// Every link on the board, so one query feeds a whole render rather than
    /// one query per task.
    public func allLinks() throws -> [AuspexTaskLink] {
        try dbWriter.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM task_links ORDER BY task_id ASC, created_at ASC")
                .compactMap(AuspexTaskLink.init(row:))
        }
    }

    /// The tasks a session is attached to.
    public func tasks(linkedTo session: SessionKey) throws -> [AuspexTask] {
        try dbWriter.read { db in
            try Row.fetchAll(db, sql: """
                SELECT t.* FROM tasks t
                  JOIN task_links l ON l.task_id = t.id
                 WHERE l.session_key = ?
                 ORDER BY t.updated_at DESC
                """, arguments: [session.description]).compactMap(AuspexTask.init(row:))
        }
    }

    // MARK: - Log

    /// Adds a line to a task's history.
    public func appendLog(
        taskID: Int64,
        actor: SessionKey?,
        kind: String,
        message: String?,
        ref: String? = nil,
        now: Date = Date()
    ) throws {
        try dbWriter.write { db in
            try Self.appendLog(
                taskID: taskID, actor: actor, kind: kind, message: message,
                ref: ref, at: now, in: db
            )
            try db.execute(
                sql: "UPDATE tasks SET updated_at = ? WHERE id = ?",
                arguments: [now.timeIntervalSince1970, taskID]
            )
        }
    }

    /// A task's history, oldest first.
    public func log(taskID: Int64, limit: Int = 200) throws -> [AuspexTaskLogEntry] {
        try dbWriter.read { db in
            try Row.fetchAll(db, sql: """
                SELECT * FROM (
                    SELECT id, task_id, ts, actor_key, kind, detail_json, ref
                      FROM task_log WHERE task_id = ?
                     ORDER BY id DESC LIMIT ?
                ) ORDER BY id ASC
                """, arguments: [taskID, limit]).compactMap(AuspexTaskLogEntry.init(row:))
        }
    }

    // MARK: - Notices

    /// Records what an agent called about, replacing whatever it last said.
    ///
    /// A live state rather than a log: two unanswered questions from one
    /// session are one stuck session, and a board that counted both would say
    /// two people are needed when one is.
    @discardableResult
    public func recordNotice(
        session: SessionKey,
        kind: AgentNoticeKind,
        message: String,
        urgency: AgentNoticeUrgency = .normal,
        now: Date = Date()
    ) throws -> AgentNotice {
        try dbWriter.write { db in
            try db.execute(
                sql: """
                    INSERT INTO session_notices
                        (session_key, kind, message, urgency, created_at, cleared_at)
                    VALUES (?, ?, ?, ?, ?, NULL)
                    ON CONFLICT(session_key) DO UPDATE SET
                        kind = excluded.kind,
                        message = excluded.message,
                        urgency = excluded.urgency,
                        created_at = excluded.created_at,
                        cleared_at = NULL
                    """,
                arguments: [
                    session.description, kind.rawValue, message,
                    urgency.rawValue, now.timeIntervalSince1970
                ]
            )
            return AgentNotice(
                session: session, kind: kind, message: message,
                urgency: urgency, createdAt: now
            )
        }
    }

    /// Marks a notice answered. Idempotent; a second dismissal keeps the first
    /// timestamp, so "when did this stop needing me" does not drift.
    public func clearNotice(session: SessionKey, now: Date = Date()) throws {
        try dbWriter.write { db in
            try db.execute(
                sql: """
                    UPDATE session_notices SET cleared_at = ?
                     WHERE session_key = ? AND cleared_at IS NULL
                    """,
                arguments: [now.timeIntervalSince1970, session.description]
            )
        }
    }

    /// Every notice still asking, by session.
    ///
    /// Read once and held in memory by the board model, for the reason
    /// ``SessionRepository/allLastSeen()`` is: a card must not go to SQLite to
    /// find out whether it is calling for somebody.
    public func liveNotices() throws -> [SessionKey: AgentNotice] {
        try dbWriter.read { db in
            let rows = try Row.fetchAll(
                db, sql: "SELECT * FROM session_notices WHERE cleared_at IS NULL"
            )
            var notices: [SessionKey: AgentNotice] = [:]
            for row in rows {
                guard let notice = AgentNotice(row: row) else { continue }
                notices[notice.session] = notice
            }
            return notices
        }
    }

    /// One session's notice, live or not.
    public func notice(session: SessionKey) throws -> AgentNotice? {
        try dbWriter.read { db in
            try Row.fetchOne(
                db,
                sql: "SELECT * FROM session_notices WHERE session_key = ?",
                arguments: [session.description]
            ).flatMap(AgentNotice.init(row:))
        }
    }

    // MARK: - Reports

    /// Records the line an agent wrote about what it is doing.
    @discardableResult
    public func recordReport(
        session: SessionKey,
        focus: String,
        progress: String?,
        now: Date = Date()
    ) throws -> AgentReport {
        try dbWriter.write { db in
            try db.execute(
                sql: """
                    INSERT INTO session_reports (session_key, focus, progress, created_at)
                    VALUES (?, ?, ?, ?)
                    ON CONFLICT(session_key) DO UPDATE SET
                        focus = excluded.focus,
                        progress = excluded.progress,
                        created_at = excluded.created_at
                    """,
                arguments: [session.description, focus, progress, now.timeIntervalSince1970]
            )
            return AgentReport(session: session, focus: focus, progress: progress, createdAt: now)
        }
    }

    /// Every self-reported line, by session.
    public func allReports() throws -> [SessionKey: AgentReport] {
        try dbWriter.read { db in
            let rows = try Row.fetchAll(db, sql: "SELECT * FROM session_reports")
            var reports: [SessionKey: AgentReport] = [:]
            for row in rows {
                guard let report = AgentReport(row: row) else { continue }
                reports[report.session] = report
            }
            return reports
        }
    }

    // MARK: - Statements shared between the transactions above

    private static func plan(id: Int64, in db: Database) throws -> AuspexPlan? {
        try Row.fetchOne(db, sql: "SELECT * FROM plans WHERE id = ?", arguments: [id])
            .flatMap(AuspexPlan.init(row:))
    }

    private static func plan(slug: String, in db: Database) throws -> AuspexPlan? {
        try Row.fetchOne(db, sql: "SELECT * FROM plans WHERE slug = ?", arguments: [slug])
            .flatMap(AuspexPlan.init(row:))
    }

    private static func task(id: Int64, in db: Database) throws -> AuspexTask? {
        try Row.fetchOne(db, sql: "SELECT * FROM tasks WHERE id = ?", arguments: [id])
            .flatMap(AuspexTask.init(row:))
    }

    /// Gives a milestone the project of the first task filed under it.
    ///
    /// A milestone is registered before anybody knows where the work will
    /// happen — `plans.create` is the first call a supervisor makes — so its
    /// project is usually learned from the task that follows. Never
    /// overwritten: the first answer is the one the board has already drawn.
    private static func adoptProject(_ key: String?, forPlan planID: Int64?, in db: Database) throws {
        guard let key, let planID else { return }
        try db.execute(
            sql: "UPDATE plans SET project_key = ? WHERE id = ? AND project_key IS NULL",
            arguments: [key, planID]
        )
    }

    /// A milestone's `updated_at` follows its tasks, so "the milestone somebody
    /// is working in" sorts to the top of the board without anybody maintaining
    /// it by hand.
    private static func touchPlan(_ planID: Int64?, at date: Date, in db: Database) throws {
        guard let planID else { return }
        try db.execute(
            sql: "UPDATE plans SET updated_at = ? WHERE id = ?",
            arguments: [date.timeIntervalSince1970, planID]
        )
    }

    private static func link(
        taskID: Int64,
        session: SessionKey,
        kind: AuspexTaskLinkKind,
        at date: Date,
        in db: Database
    ) throws {
        try db.execute(
            sql: """
                INSERT INTO task_links (task_id, session_key, kind, created_at)
                VALUES (?, ?, ?, ?)
                ON CONFLICT(task_id, session_key, kind) DO NOTHING
                """,
            arguments: [taskID, session.description, kind.rawValue, date.timeIntervalSince1970]
        )
    }

    /// The log's `detail_json` column holds a plain sentence rather than a
    /// blob. v1 named it for a structure that never arrived, and inventing one
    /// now would mean every reader parsing JSON to show one line.
    private static func appendLog(
        taskID: Int64,
        actor: SessionKey?,
        kind: String,
        message: String?,
        ref: String? = nil,
        at date: Date,
        in db: Database
    ) throws {
        try db.execute(
            sql: """
                INSERT INTO task_log (task_id, ts, actor_key, kind, detail_json, ref)
                VALUES (?, ?, ?, ?, ?, ?)
                """,
            arguments: [
                taskID, date.timeIntervalSince1970, actor?.description, kind,
                (message?.isEmpty ?? true) ? nil : message,
                (ref?.isEmpty ?? true) ? nil : ref
            ]
        )
    }
}

// MARK: - Labels

/// A task's labels, on their way in and out of the one column that holds them.
///
/// A JSON array of strings, and total in both directions: a column holding
/// something else — written by an older build, or by a person with `sqlite3`
/// open — decodes as no labels rather than sinking the query that read it.
public enum TaskLabels {
    /// How many labels one task may carry, and how long each may be.
    ///
    /// A cap rather than a validation error, for the reason every other
    /// agent-supplied string here is capped: an agent that gets an error back
    /// retries, and an agent that gets its list trimmed carries on.
    public static let limit = 12
    public static let lengthLimit = 40

    /// Trimmed, lowercased, deduplicated, capped — in the order given.
    public static func normalize(_ raw: [String]) -> [String] {
        var seen: Set<String> = []
        var kept: [String] = []
        for label in raw {
            let trimmed = label
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            guard !trimmed.isEmpty else { continue }
            let capped = String(trimmed.prefix(lengthLimit))
            guard seen.insert(capped).inserted else { continue }
            kept.append(capped)
            if kept.count == limit { break }
        }
        return kept
    }

    /// The column value, or `nil` when there is nothing to store.
    static func encode(_ labels: [String]) -> String? {
        let normalized = normalize(labels)
        guard !normalized.isEmpty else { return nil }
        guard let data = try? JSONEncoder().encode(normalized) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    /// What a column holds, read back.
    static func decode(_ raw: String?) -> [String] {
        guard let raw, !raw.isEmpty, let data = raw.data(using: .utf8) else { return [] }
        guard let decoded = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return normalize(decoded)
    }
}

// MARK: - Counts

/// How much work one project is carrying.
///
/// Two numbers rather than a list, because every reader of this is a badge: a
/// sidebar row, a Projects-page column, a lane header. "3 tasks open" is the
/// whole of what a person wants from a project they are not looking at.
public struct TaskProjectCounts: Hashable, Sendable {
    /// Every task in the project, finished ones included.
    public let total: Int
    /// The ones that are not in `done`.
    public let open: Int

    public init(total: Int, open: Int) {
        self.total = total
        self.open = open
    }

    /// What a badge says, or `nil` when the project carries nothing and the
    /// badge should not be drawn at all.
    public var openDescription: String? {
        guard open > 0 else { return nil }
        return open == 1 ? "1 task open" : "\(open) tasks open"
    }
}

// MARK: - Errors

/// What the ledger refuses to do, in words a tool result can quote.
public enum TaskLedgerError: Error, Sendable, Equatable, CustomStringConvertible {
    case notFound(String)
    case alreadyClaimed(String)
    /// The board is read-only in this process — a demo replay.
    case readOnly

    public var description: String {
        switch self {
        case let .notFound(what): "No such \(what)."
        case let .alreadyClaimed(holder): "Already claimed by \(holder)."
        case .readOnly: "This Auspex is replaying a demo board and will not write to it."
        }
    }
}

// MARK: - Slugs

/// The handle a plan travels under.
public enum TaskSlug {
    /// Lowercases, keeps letters, digits, and dashes, and collapses everything
    /// else into single dashes.
    ///
    /// Deliberately not a general slugifier: it is applied to *agent input*, so
    /// its job is to produce something short, safe to print in a brief, and
    /// impossible to confuse with a path or a shell word. Non-ASCII letters
    /// survive — a Chinese plan title should stay legible rather than become
    /// a row of dashes.
    public static func make(_ raw: String, limit: Int = 64) -> String {
        var out = ""
        var lastWasDash = false
        for character in raw.lowercased() {
            if character.isLetter || character.isNumber {
                out.append(character)
                lastWasDash = false
            } else if !lastWasDash, !out.isEmpty {
                out.append("-")
                lastWasDash = true
            }
            if out.count >= limit { break }
        }
        while out.hasSuffix("-") { out.removeLast() }
        return out.isEmpty ? "plan" : out
    }
}

// MARK: - Row decoding

extension AuspexPlan {
    init?(row: Row) {
        guard let id = row["id"] as Int64?,
              let slug = row["slug"] as String?,
              let title = row["title"] as String?,
              let statusRaw = row["status"] as String?,
              let status = Status(rawValue: statusRaw),
              let createdAt = row["created_at"] as Double?,
              let updatedAt = row["updated_at"] as Double?
        else { return nil }
        self.init(
            id: id,
            slug: slug,
            title: title,
            summary: row["summary"],
            status: status,
            projectID: row["project_id"],
            projectKey: row["project_key"],
            createdBy: (row["created_by_key"] as String?).flatMap(SessionKey.init(string:)),
            createdAt: Date(timeIntervalSince1970: createdAt),
            updatedAt: Date(timeIntervalSince1970: updatedAt),
            archivedAt: (row["archived_at"] as Double?).map(Date.init(timeIntervalSince1970:))
        )
    }
}

extension AuspexTask {
    init?(row: Row) {
        guard let id = row["id"] as Int64?,
              let title = row["title"] as String?,
              let statusRaw = row["status"] as String?,
              let createdAt = row["created_at"] as Double?,
              let updatedAt = row["updated_at"] as Double?
        else { return nil }
        self.init(
            id: id,
            planID: row["plan_id"],
            title: title,
            body: row["body"],
            // A row written before the four columns settled reads as `todo`
            // rather than sinking the whole query.
            status: AuspexTaskStatus(rawValue: statusRaw) ?? .todo,
            priority: row["priority"] as Int? ?? 0,
            projectID: row["project_id"],
            projectKey: row["project_key"],
            createdBy: (row["created_by_key"] as String?).flatMap(SessionKey.init(string:)),
            claimRole: row["claim_role"],
            claimScope: row["claim_scope"],
            claimedBy: (row["claimed_by_key"] as String?).flatMap(SessionKey.init(string:)),
            claimedAt: (row["claimed_at"] as Double?).map(Date.init(timeIntervalSince1970:)),
            completedAt: (row["completed_at"] as Double?).map(Date.init(timeIntervalSince1970:)),
            result: row["result"],
            source: row["source"],
            kind: (row["kind"] as String?).flatMap(TaskKind.init(rawValue:)),
            labels: TaskLabels.decode(row["labels"]),
            createdAt: Date(timeIntervalSince1970: createdAt),
            updatedAt: Date(timeIntervalSince1970: updatedAt)
        )
    }
}

extension AuspexTaskLink {
    init?(row: Row) {
        guard let taskID = row["task_id"] as Int64?,
              let keyString = row["session_key"] as String?,
              let session = SessionKey(string: keyString),
              let kindRaw = row["kind"] as String?,
              let kind = AuspexTaskLinkKind(rawValue: kindRaw),
              let createdAt = row["created_at"] as Double?
        else { return nil }
        self.init(
            taskID: taskID,
            session: session,
            kind: kind,
            createdAt: Date(timeIntervalSince1970: createdAt)
        )
    }
}

extension AuspexTaskLogEntry {
    init?(row: Row) {
        guard let id = row["id"] as Int64?,
              let taskID = row["task_id"] as Int64?,
              let ts = row["ts"] as Double?,
              let kind = row["kind"] as String?
        else { return nil }
        self.init(
            id: id,
            taskID: taskID,
            timestamp: Date(timeIntervalSince1970: ts),
            actor: (row["actor_key"] as String?).flatMap(SessionKey.init(string:)),
            kind: kind,
            message: row["detail_json"],
            ref: row["ref"]
        )
    }
}

extension AgentNotice {
    init?(row: Row) {
        guard let keyString = row["session_key"] as String?,
              let session = SessionKey(string: keyString),
              let kindRaw = row["kind"] as String?,
              let kind = AgentNoticeKind(rawValue: kindRaw),
              let message = row["message"] as String?,
              let createdAt = row["created_at"] as Double?
        else { return nil }
        self.init(
            session: session,
            kind: kind,
            message: message,
            urgency: (row["urgency"] as String?).flatMap(AgentNoticeUrgency.init(rawValue:)) ?? .normal,
            createdAt: Date(timeIntervalSince1970: createdAt),
            clearedAt: (row["cleared_at"] as Double?).map(Date.init(timeIntervalSince1970:))
        )
    }
}

extension AgentReport {
    init?(row: Row) {
        guard let keyString = row["session_key"] as String?,
              let session = SessionKey(string: keyString),
              let focus = row["focus"] as String?,
              let createdAt = row["created_at"] as Double?
        else { return nil }
        self.init(
            session: session,
            focus: focus,
            progress: row["progress"],
            createdAt: Date(timeIntervalSince1970: createdAt)
        )
    }
}
