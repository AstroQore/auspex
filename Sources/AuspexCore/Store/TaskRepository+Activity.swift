import AgentSessionLive
import Foundation
import GRDB

extension TaskRepository {
    // MARK: - Log

    /// Adds a line to a task's history.
    public func appendLog(
        taskID: Int64,
        actor: SessionKey?,
        kind: String,
        message: String?,
        ref: String? = nil,
        expectedVersion: Int64? = nil,
        now: Date = Date()
    ) throws {
        try dbWriter.write { db in
            guard let existing = try Self.task(id: taskID, in: db) else {
                throw TaskLedgerError.notFound("task \(taskID)")
            }
            try Self.assertVersion(expectedVersion, of: existing)
            try Self.appendLog(
                taskID: taskID, actor: actor, kind: kind, message: message,
                ref: ref, at: now, in: db
            )
            try db.execute(
                sql: "UPDATE tasks SET updated_at = ?, version = version + 1 WHERE id = ?",
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

    /// The log's `detail_json` column holds a plain sentence rather than a
    /// blob. v1 named it for a structure that never arrived, and inventing one
    /// now would mean every reader parsing JSON to show one line.
    static func appendLog(
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
