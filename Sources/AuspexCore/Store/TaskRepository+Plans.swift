import AgentSessionLive
import Foundation
import GRDB

extension TaskRepository {
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

    // MARK: - Shared plan statements

    static func plan(id: Int64, in db: Database) throws -> AuspexPlan? {
        try Row.fetchOne(db, sql: "SELECT * FROM plans WHERE id = ?", arguments: [id])
            .flatMap(AuspexPlan.init(row:))
    }

    static func plan(slug: String, in db: Database) throws -> AuspexPlan? {
        try Row.fetchOne(db, sql: "SELECT * FROM plans WHERE slug = ?", arguments: [slug])
            .flatMap(AuspexPlan.init(row:))
    }

    /// Gives a milestone the project of the first task filed under it.
    ///
    /// A milestone is registered before anybody knows where the work will
    /// happen — `plans.create` is the first call a supervisor makes — so its
    /// project is usually learned from the task that follows. Never
    /// overwritten: the first answer is the one the board has already drawn.
    static func adoptProject(_ key: String?, forPlan planID: Int64?, in db: Database) throws {
        guard let key, let planID else { return }
        try db.execute(
            sql: "UPDATE plans SET project_key = ? WHERE id = ? AND project_key IS NULL",
            arguments: [key, planID]
        )
    }

    /// A milestone's `updated_at` follows its tasks, so "the milestone somebody
    /// is working in" sorts to the top of the board without anybody maintaining
    /// it by hand.
    static func touchPlan(_ planID: Int64?, at date: Date, in db: Database) throws {
        guard let planID else { return }
        try db.execute(
            sql: "UPDATE plans SET updated_at = ? WHERE id = ?",
            arguments: [date.timeIntervalSince1970, planID]
        )
    }
}
