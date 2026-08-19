import AgentSessionKit
import AgentSessionLive
import Foundation
import GRDB

/// Reads and writes the project side of the schema: the `projects` and
/// `worktrees` rows a ``ProjectPlacement`` implies, and the foreign keys on
/// `sessions` that point at them.
///
/// A value over a `DatabaseWriter`, like ``SessionRepository``, and split from
/// it for the same reason the tables are split: a project outlives every
/// session in it, and retention deleting a session must not take the project
/// with it.
///
/// ## Why the columns and not just `snapshot_json`
///
/// ``BoardSnapshot/byProject`` already groups a live board without touching
/// the database. `sessions.project_id` exists for the questions a board cannot
/// answer from what it is holding: every session this repository has ever seen,
/// counted per project, ordered, and paged — over rows whose snapshots are not
/// in memory. That is a `GROUP BY` on an indexed integer, or it is decoding
/// every blob in the table.
public struct ProjectRepository: Sendable {
    /// The database this repository writes through.
    public let dbWriter: any DatabaseWriter

    public init(dbWriter: any DatabaseWriter) {
        self.dbWriter = dbWriter
    }

    public init(store: AuspexStore) {
        self.dbWriter = store.dbWriter
    }

    // MARK: - Upserting placements

    /// The rows a placement resolves to.
    public struct Assignment: Hashable, Sendable {
        /// The `projects` row id.
        public let projectID: Int64
        /// The `worktrees` row id, when the placement named a linked worktree.
        public let worktreeID: Int64?

        public init(projectID: Int64, worktreeID: Int64? = nil) {
            self.projectID = projectID
            self.worktreeID = worktreeID
        }
    }

    /// Inserts or updates the project (and worktree) a placement names, in its
    /// own transaction.
    @discardableResult
    public func upsert(_ placement: ProjectPlacement) throws -> Assignment {
        try dbWriter.write { db in
            try upsert(placement, in: db)
        }
    }

    /// Placement upsert inside a caller-owned transaction.
    ///
    /// `git_root` and `branch` are written with `COALESCE` so that a later
    /// resolution which learned less — a directory seen before its repository
    /// was cloned, a `HEAD` that could not be read — does not erase what an
    /// earlier one knew. `name` is overwritten, because a renamed directory is
    /// a renamed project.
    @discardableResult
    public func upsert(_ placement: ProjectPlacement, in db: Database) throws -> Assignment {
        try db.execute(
            sql: """
                INSERT INTO projects (root_path, git_root, name, created_at)
                VALUES (?, ?, ?, ?)
                ON CONFLICT(root_path) DO UPDATE SET
                    git_root = COALESCE(excluded.git_root, projects.git_root),
                    name = excluded.name
                """,
            arguments: [
                placement.projectRootPath,
                placement.gitRoot,
                placement.projectName,
                Date().timeIntervalSince1970,
            ]
        )
        guard let projectID = try Int64.fetchOne(
            db,
            sql: "SELECT id FROM projects WHERE root_path = ?",
            arguments: [placement.projectRootPath]
        ) else {
            throw ProjectRepositoryError.projectNotWritten(placement.projectRootPath)
        }

        guard let worktreePath = placement.worktreePath else {
            return Assignment(projectID: projectID)
        }
        try db.execute(
            sql: """
                INSERT INTO worktrees (project_id, path, branch)
                VALUES (?, ?, ?)
                ON CONFLICT(path) DO UPDATE SET
                    project_id = excluded.project_id,
                    branch = COALESCE(excluded.branch, worktrees.branch)
                """,
            arguments: [projectID, worktreePath, placement.branch]
        )
        let worktreeID = try Int64.fetchOne(
            db,
            sql: "SELECT id FROM worktrees WHERE path = ?",
            arguments: [worktreePath]
        )
        return Assignment(projectID: projectID, worktreeID: worktreeID)
    }

    // MARK: - Assigning sessions

    /// Points a session's `project_id` and `worktree_id` at the rows a
    /// placement resolves to, in its own transaction.
    @discardableResult
    public func assign(_ placement: ProjectPlacement, to key: SessionKey) throws -> Assignment {
        try dbWriter.write { db in
            try assign(placement, to: key, in: db)
        }
    }

    /// Assignment inside a caller-owned transaction.
    ///
    /// The session row must already exist; a `sessions` row is written before
    /// anything that references it, and a placement for a session nobody has
    /// stored yet is a no-op rather than an error.
    @discardableResult
    public func assign(
        _ placement: ProjectPlacement,
        to key: SessionKey,
        in db: Database
    ) throws -> Assignment {
        let assignment = try upsert(placement, in: db)
        try apply(assignment, to: [key], in: db)
        return assignment
    }

    /// Assigns many sessions at once, upserting each distinct placement only
    /// once however many sessions share it.
    public func assign(
        placements: [SessionKey: ProjectPlacement],
        in db: Database
    ) throws -> [SessionKey: Assignment] {
        guard !placements.isEmpty else { return [:] }
        var byPlacement: [ProjectPlacement: [SessionKey]] = [:]
        for (key, placement) in placements {
            byPlacement[placement, default: []].append(key)
        }

        var out: [SessionKey: Assignment] = [:]
        for (placement, keys) in byPlacement {
            let assignment = try upsert(placement, in: db)
            try apply(assignment, to: keys, in: db)
            for key in keys { out[key] = assignment }
        }
        return out
    }

    private func apply(_ assignment: Assignment, to keys: [SessionKey], in db: Database) throws {
        guard !keys.isEmpty else { return }
        let statement = try db.makeStatement(sql: """
            UPDATE sessions SET project_id = ?, worktree_id = ? WHERE key = ?
            """)
        for key in keys {
            statement.setUncheckedArguments([
                assignment.projectID, assignment.worktreeID, key.description,
            ])
            try statement.execute()
        }
    }

    // MARK: - Roots

    /// Writes `sessions.root_key` for a set of sessions, in its own
    /// transaction.
    public func setRootKeys(_ roots: [SessionKey: SessionKey]) throws {
        try dbWriter.write { db in
            try setRootKeys(roots, in: db)
        }
    }

    /// Root-key update inside a caller-owned transaction.
    ///
    /// A session's root is a property of the whole delegation chain, so it is
    /// written from ``SessionTree/rootKeys`` rather than derived per row: a
    /// grandchild's root is not its parent.
    public func setRootKeys(_ roots: [SessionKey: SessionKey], in db: Database) throws {
        guard !roots.isEmpty else { return }
        let statement = try db.makeStatement(sql: """
            UPDATE sessions SET root_key = ? WHERE key = ? AND root_key IS NOT ?
            """)
        for (key, root) in roots.sorted(by: { $0.key.description < $1.key.description }) {
            statement.setUncheckedArguments([root.description, key.description, root.description])
            try statement.execute()
        }
    }

    // MARK: - Reading

    /// Every project, most recently active first.
    ///
    /// - Parameter withCounts: when `false`, the session tallies are left at
    ///   zero and the query is a plain table scan. A picker that only needs
    ///   names should not pay for a join.
    public func fetchProjects(withCounts: Bool = true) throws -> [ProjectSummary] {
        try dbWriter.read { db in
            guard withCounts else {
                let rows = try Row.fetchAll(db, sql: """
                    SELECT id, root_path, git_root, name, color, created_at,
                           0 AS session_count, 0 AS live_count, 0 AS worktree_count,
                           NULL AS last_event_at
                    FROM projects
                    ORDER BY name COLLATE NOCASE ASC, id ASC
                    """)
                return rows.compactMap(ProjectSummary.init(row:))
            }
            let rows = try Row.fetchAll(db, sql: """
                SELECT p.id, p.root_path, p.git_root, p.name, p.color, p.created_at,
                       COUNT(s.key) AS session_count,
                       COALESCE(SUM(s.is_alive), 0) AS live_count,
                       (SELECT COUNT(*) FROM worktrees w WHERE w.project_id = p.id)
                           AS worktree_count,
                       MAX(s.last_event_at) AS last_event_at
                FROM projects p
                LEFT JOIN sessions s ON s.project_id = p.id
                GROUP BY p.id
                ORDER BY last_event_at DESC, p.name COLLATE NOCASE ASC, p.id ASC
                """)
            return rows.compactMap(ProjectSummary.init(row:))
        }
    }

    /// The project a path is stored under, when one is.
    public func project(rootPath: String) throws -> ProjectSummary? {
        try dbWriter.read { db in
            let row = try Row.fetchOne(db, sql: """
                SELECT id, root_path, git_root, name, color, created_at,
                       0 AS session_count, 0 AS live_count, 0 AS worktree_count,
                       NULL AS last_event_at
                FROM projects WHERE root_path = ?
                """, arguments: [rootPath])
            return row.flatMap(ProjectSummary.init(row:))
        }
    }

    /// The worktrees recorded under a project, by path.
    public func worktrees(inProject id: Int64) throws -> [ProjectWorktree] {
        try dbWriter.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT id, project_id, path, branch FROM worktrees
                WHERE project_id = ? ORDER BY path ASC
                """, arguments: [id])
            return rows.compactMap(ProjectWorktree.init(row:))
        }
    }

    /// Every stored session assigned to a project, newest activity first.
    public func sessions(inProject id: Int64, limit: Int? = nil) throws -> [SessionSnapshot] {
        var sql = """
            SELECT snapshot_json FROM sessions
            WHERE project_id = ?
            ORDER BY last_event_at DESC, key ASC
            """
        var arguments: StatementArguments = [id]
        if let limit {
            sql += " LIMIT ?"
            arguments += [limit]
        }
        return try dbWriter.read { db in
            let json = try String.fetchAll(db, sql: sql, arguments: arguments)
            let decoder = StoreJSON.makeDecoder()
            return try json.map {
                try StoreJSON.decode(SessionSnapshot.self, from: $0, using: decoder)
            }
        }
    }

    /// Every stored session in one delegation tree, root first.
    public func sessions(inTreeRootedAt root: SessionKey) throws -> [SessionSnapshot] {
        try dbWriter.read { db in
            let json = try String.fetchAll(db, sql: """
                SELECT snapshot_json FROM sessions
                WHERE root_key = ?
                ORDER BY started_at ASC, key ASC
                """, arguments: [root.description])
            let decoder = StoreJSON.makeDecoder()
            return try json.map {
                try StoreJSON.decode(SessionSnapshot.self, from: $0, using: decoder)
            }
        }
    }
}

/// What went wrong writing a project.
public enum ProjectRepositoryError: Error, Equatable {
    /// The upsert reported success and the row was not there afterwards, which
    /// means something else deleted it inside the same transaction.
    case projectNotWritten(String)
}

/// One `projects` row, with the tallies a sidebar shows next to it.
public struct ProjectSummary: Hashable, Sendable, Identifiable {
    public let id: Int64
    /// What sessions group by — the git root, or the directory itself.
    public let rootPath: String
    /// The repository root, when the path is in one.
    public let gitRoot: String?
    public let name: String
    /// A user-chosen colour, when one has been set.
    public let color: String?
    public let createdAt: Date
    /// How many stored sessions point at this project.
    public let sessionCount: Int
    /// How many of them are believed to be running.
    public let liveCount: Int
    /// How many worktrees are recorded under it.
    public let worktreeCount: Int
    /// The most recent activity across its sessions, when it has any.
    public let lastEventAt: Date?

    init?(row: Row) {
        guard let id = row["id"] as Int64?,
              let rootPath = row["root_path"] as String?,
              let name = row["name"] as String?,
              let createdAt = row["created_at"] as Double?
        else { return nil }
        self.id = id
        self.rootPath = rootPath
        self.gitRoot = row["git_root"]
        self.name = name
        self.color = row["color"]
        self.createdAt = Date(timeIntervalSince1970: createdAt)
        self.sessionCount = row["session_count"] as Int? ?? 0
        self.liveCount = row["live_count"] as Int? ?? 0
        self.worktreeCount = row["worktree_count"] as Int? ?? 0
        self.lastEventAt = (row["last_event_at"] as Double?).map(Date.init(timeIntervalSince1970:))
    }
}

/// One `worktrees` row.
public struct ProjectWorktree: Hashable, Sendable, Identifiable {
    public let id: Int64
    public let projectID: Int64
    public let path: String
    public let branch: String?

    init?(row: Row) {
        guard let id = row["id"] as Int64?,
              let projectID = row["project_id"] as Int64?,
              let path = row["path"] as String?
        else { return nil }
        self.id = id
        self.projectID = projectID
        self.path = path
        self.branch = row["branch"]
    }
}
