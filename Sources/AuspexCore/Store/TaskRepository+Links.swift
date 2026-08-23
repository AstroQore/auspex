import AgentSessionLive
import Foundation
import GRDB

extension TaskRepository {
    // MARK: - Links

    /// Attaches a session to a task.
    public func link(
        taskID: Int64,
        session: SessionKey,
        kind: AuspexTaskLinkKind,
        now: Date = Date()
    ) throws {
        try dbWriter.write { db in
            guard try Self.task(id: taskID, in: db) != nil else {
                throw TaskLedgerError.notFound("task \(taskID)")
            }
            let exists = try Bool.fetchOne(
                db,
                sql: """
                    SELECT EXISTS(
                        SELECT 1 FROM task_links
                         WHERE task_id = ? AND session_key = ? AND kind = ?
                    )
                    """,
                arguments: [taskID, session.description, kind.rawValue]
            ) == true
            guard !exists else { return }
            try Self.link(taskID: taskID, session: session, kind: kind, at: now, in: db)
            try Self.appendLog(
                taskID: taskID, actor: session, kind: "linked", message: kind.rawValue, at: now, in: db
            )
            try db.execute(
                sql: "UPDATE tasks SET updated_at = ?, version = version + 1 WHERE id = ?",
                arguments: [now.timeIntervalSince1970, taskID]
            )
        }
    }

    /// Detaches a session from a task. A claim link is left alone: releasing a
    /// claim is ``releaseTask(id:by:now:)``, and unlinking one behind its back
    /// would leave the task claimed by a session no longer on it.
    public func unlink(
        taskID: Int64,
        session: SessionKey,
        now: Date = Date()
    ) throws {
        try dbWriter.write { db in
            let exists = try Bool.fetchOne(
                db,
                sql: """
                    SELECT EXISTS(
                        SELECT 1 FROM task_links
                         WHERE task_id = ? AND session_key = ? AND kind <> 'claim'
                    )
                    """,
                arguments: [taskID, session.description]
            ) == true
            guard exists else { return }
            try db.execute(
                sql: """
                    DELETE FROM task_links
                     WHERE task_id = ? AND session_key = ? AND kind <> 'claim'
                    """,
                arguments: [taskID, session.description]
            )
            try Self.appendLog(
                taskID: taskID, actor: session, kind: "unlinked", message: nil,
                at: now, in: db
            )
            try db.execute(
                sql: "UPDATE tasks SET updated_at = ?, version = version + 1 WHERE id = ?",
                arguments: [now.timeIntervalSince1970, taskID]
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

    static func link(
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
}
