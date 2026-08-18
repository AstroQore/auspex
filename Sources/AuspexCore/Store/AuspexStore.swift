import Foundation
import GRDB

/// Auspex's local database.
///
/// One SQLite file under `~/.auspex/`, opened through a `DatabasePool` in WAL
/// mode so the ingest pipeline can write while the UI reads. The schema is
/// described by ``migrator``; everything above it goes through
/// ``SessionRepository``, ``SourceCursorRepository``, and ``RetentionJob``
/// rather than touching `dbWriter` directly.
public final class AuspexStore: Sendable {
    /// The GRDB connection pool. Callers read and write through this.
    public let dbWriter: any DatabaseWriter

    /// Opens the store at `url`, creating parent directories as needed, and
    /// runs any pending migrations.
    public init(url: URL) throws {
        let pool = try DatabasePool(path: url.path, configuration: Self.configuration())
        self.dbWriter = pool
        try Self.migrator.migrate(pool)
    }

    /// Opens the store at ``AuspexPaths/databaseURL``, creating `~/.auspex/`
    /// with 0700 first.
    public convenience init(paths: AuspexPaths = .default) throws {
        let url = try paths.ensureDatabaseParentDirectory()
        try self.init(url: url)
    }

    /// Opens an in-memory store. Used by tests and by `--mcp-stdio` dry runs.
    public init(inMemory: Bool) throws {
        precondition(inMemory, "Use init(url:) for on-disk stores.")
        let queue = try DatabaseQueue(configuration: Self.configuration())
        self.dbWriter = queue
        try Self.migrator.migrate(queue)
    }

    /// Wraps an already-open writer. Tests use this to share one in-memory
    /// database between two components.
    public init(dbWriter: any DatabaseWriter) throws {
        self.dbWriter = dbWriter
        try Self.migrator.migrate(dbWriter)
    }

    // MARK: - Configuration

    /// The connection configuration every Auspex database is opened with.
    ///
    /// `auto_vacuum = INCREMENTAL` is set here rather than in a migration
    /// because SQLite only honours a change to it while the database file is
    /// still empty — by the time a migration body runs, `DatabaseMigrator`
    /// has already created its own bookkeeping table. Retention then reclaims
    /// space with `PRAGMA incremental_vacuum` instead of a full `VACUUM`,
    /// which would need to copy the whole file.
    static func configuration() -> Configuration {
        var configuration = Configuration()
        configuration.foreignKeysEnabled = true
        configuration.prepareDatabase { db in
            // A `DatabasePool`'s reader connections are opened read-only, and
            // a pragma that writes to the file header fails on them. Only the
            // writer needs to set this anyway.
            guard !db.configuration.readonly else { return }
            try db.execute(sql: "PRAGMA auto_vacuum = INCREMENTAL")
        }
        return configuration
    }

    // MARK: - Migrations

    /// Every schema change is an append-only migration. Never edit a
    /// migration that has shipped; add the next one instead.
    public static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()

        // Guards against a partially-applied schema being mistaken for an
        // up-to-date one during pre-alpha development, when migrations are
        // still being rewritten between builds.
        #if DEBUG
        migrator.eraseDatabaseOnSchemaChange = true
        #endif

        migrator.registerMigration("v1_initial") { db in
            try createProjectTables(db)
            try createSessionTables(db)
            try createEventTables(db)
            try createSearchTables(db)
            try createTaskTables(db)
            try createHousekeepingTables(db)
        }

        return migrator
    }

    // MARK: - v1 schema

    /// Timestamps are stored as `REAL` seconds since the Unix epoch
    /// (`Date.timeIntervalSince1970`) throughout. GRDB would happily store
    /// ISO-8601 text, but the board sorts and the retention job range-scan on
    /// these columns constantly, and a float compares without a parse.

    private static func createProjectTables(_ db: Database) throws {
        // A project is a checkout on disk. `root_path` is what sessions are
        // grouped by; `git_root` is filled in when the path turns out to be
        // inside a repository. Both stay empty until M2's ProjectResolver.
        try db.create(table: "projects") { table in
            table.autoIncrementedPrimaryKey("id")
            table.column("root_path", .text).notNull().unique()
            table.column("git_root", .text)
            table.column("name", .text).notNull()
            table.column("color", .text)
            table.column("created_at", .double).notNull()
        }

        // Worktrees hang off a project so `feat/x` in `.agents/worktrees/`
        // groups under the repository it was branched from rather than
        // showing up as a project of its own.
        try db.create(table: "worktrees") { table in
            table.autoIncrementedPrimaryKey("id")
            table.column("project_id", .integer)
                .notNull()
                .references("projects", onDelete: .cascade)
            table.column("path", .text).notNull().unique()
            table.column("branch", .text)
        }
        try db.create(index: "worktrees_on_project_id", on: "worktrees", columns: ["project_id"])
    }

    private static func createSessionTables(_ db: Database) throws {
        // One row per session, keyed by `SessionKey.description`
        // ("<harness>:<id>"). `snapshot_json` is the authoritative copy of the
        // reducer's `SessionSnapshot`; every other column is a projection of
        // it, denormalised so the board can sort and filter in SQL without
        // decoding thousands of blobs. The projection is written from the
        // snapshot in one place — `SessionRepository.upsert(snapshot:)` — so
        // the two cannot drift.
        try db.create(table: "sessions") { table in
            table.primaryKey("key", .text)
            table.column("harness", .text).notNull()
            table.column("session_id", .text).notNull()
            table.column("variant", .text)
            table.column("parent_key", .text)
            // The root of the delegation tree this session belongs to. Equal
            // to `key` for a top-level session. Filled in by M2's tree
            // builder; written as `key` today so grouping never sees NULL.
            table.column("root_key", .text)
            table.column("parent_link", .text)
            table.column("cwd", .text)
            table.column("project_id", .integer).references("projects", onDelete: .setNull)
            table.column("worktree_id", .integer).references("worktrees", onDelete: .setNull)
            table.column("git_branch", .text)
            table.column("pid", .integer)
            table.column("proc_start", .double)
            table.column("title", .text)
            table.column("model", .text)
            table.column("entrypoint", .text)
            table.column("source_path", .text).notNull()
            table.column("started_at", .double)
            table.column("last_event_at", .double)
            table.column("ended_at", .double)
            // `state` is the case name ("toolCalling"); `state_detail` is its
            // payload ("Bash", a file path, a child count). Split because the
            // board filters on the case and only renders the payload.
            table.column("state", .text).notNull()
            table.column("state_detail", .text)
            table.column("is_alive", .integer).notNull().defaults(to: 0)
            table.column("is_stale", .integer).notNull().defaults(to: 0)
            table.column("turn_count", .integer).notNull().defaults(to: 0)
            table.column("tool_call_count", .integer).notNull().defaults(to: 0)
            table.column("tokens_in", .integer).notNull().defaults(to: 0)
            table.column("tokens_out", .integer).notNull().defaults(to: 0)
            table.column("tokens_cached", .integer).notNull().defaults(to: 0)
            table.column("snapshot_json", .text).notNull()
        }
        try db.create(index: "sessions_on_harness", on: "sessions", columns: ["harness"])
        try db.create(index: "sessions_on_project_id", on: "sessions", columns: ["project_id"])
        try db.create(index: "sessions_on_last_event_at", on: "sessions", columns: ["last_event_at"])
        try db.create(index: "sessions_on_is_alive", on: "sessions", columns: ["is_alive"])
    }

    private static func createEventTables(_ db: Database) throws {
        // The append-only event log. `kind` is the case name, for cheap
        // filtering; `detail_json` is the whole `AgentEventKind` encoded, so a
        // row round-trips back into the event that produced it.
        //
        // The foreign key means a session row must exist before its events.
        // Writers batch both into one transaction, sessions first.
        try db.create(table: "events") { table in
            table.autoIncrementedPrimaryKey("id")
            table.column("session_key", .text)
                .notNull()
                .references("sessions", onDelete: .cascade)
            table.column("ts", .double).notNull()
            table.column("observed_at", .double).notNull()
            table.column("seq", .integer).notNull().defaults(to: 0)
            table.column("kind", .text).notNull()
            table.column("tool_call_id", .text)
            table.column("tool_name", .text)
            table.column("detail_json", .text)
            table.column("raw_path", .text)
            table.column("raw_offset", .integer)
        }
        // Covers both "the last N events of this session" and the retention
        // job's per-session window, which both order by the rowid.
        try db.create(index: "events_on_session_key_id", on: "events", columns: ["session_key", "id"])

        // Tool calls get their own table rather than being reconstructed from
        // the event log every time: the detail pane shows durations, and
        // pairing `toolCallStarted` with `toolCallFinished` across a 2000-row
        // window on every render is wasteful.
        try db.create(table: "tool_calls") { table in
            table.column("session_key", .text)
                .notNull()
                .references("sessions", onDelete: .cascade)
            table.column("call_id", .text).notNull()
            table.column("name", .text).notNull()
            table.column("kind", .text).notNull()
            table.column("target", .text)
            table.column("started_at", .double)
            table.column("ended_at", .double)
            table.column("is_error", .integer)
            table.primaryKey(["session_key", "call_id"])
        }
    }

    private static func createSearchTables(_ db: Database) throws {
        // Search across every harness at once is the thing no individual CLI
        // can do, so the text lives in a real table and FTS5 indexes it as an
        // external-content table. That keeps one copy of the body (the
        // `messages` row), lets `snippet()` work, and makes retention a plain
        // `DELETE FROM messages`.
        //
        // Deliberately no foreign key to `sessions`: the triggers below are
        // what keep the index in sync, and SQLite only fires triggers for rows
        // removed by a foreign-key action when `recursive_triggers` is on.
        // An explicit delete always fires them, so retention stays correct
        // without depending on a pragma.
        try db.create(table: "messages") { table in
            table.autoIncrementedPrimaryKey("id")
            table.column("session_key", .text).notNull()
            table.column("harness", .text).notNull()
            table.column("role", .text).notNull()
            table.column("ts", .double).notNull()
            table.column("content", .text).notNull()
        }
        try db.create(index: "messages_on_session_key", on: "messages", columns: ["session_key"])
        try db.create(index: "messages_on_ts", on: "messages", columns: ["ts"])

        // `tokenize='trigram'` rather than `unicode61`: Auspex indexes source
        // code and Chinese prose, and a word tokenizer finds neither
        // `SessionRegistry` inside `makeSessionRegistry` nor any CJK substring
        // at all, because there are no spaces to split on. The cost is a
        // larger index and a three-character minimum query length.
        //
        // Raw SQL rather than GRDB's FTS5 builder: the builder's tokenizer
        // descriptors do not cover `trigram`, and the virtual-table
        // declaration is clearer read as one statement anyway.
        try db.execute(sql: """
            CREATE VIRTUAL TABLE messages_fts USING fts5(
                content,
                session_key UNINDEXED,
                harness UNINDEXED,
                role UNINDEXED,
                ts UNINDEXED,
                content='messages',
                content_rowid='id',
                tokenize='trigram'
            )
            """)

        try db.execute(sql: """
            CREATE TRIGGER messages_ai AFTER INSERT ON messages BEGIN
                INSERT INTO messages_fts(rowid, content, session_key, harness, role, ts)
                VALUES (new.id, new.content, new.session_key, new.harness, new.role, new.ts);
            END
            """)
        try db.execute(sql: """
            CREATE TRIGGER messages_ad AFTER DELETE ON messages BEGIN
                INSERT INTO messages_fts(messages_fts, rowid, content, session_key, harness, role, ts)
                VALUES ('delete', old.id, old.content, old.session_key, old.harness, old.role, old.ts);
            END
            """)
        try db.execute(sql: """
            CREATE TRIGGER messages_au AFTER UPDATE ON messages BEGIN
                INSERT INTO messages_fts(messages_fts, rowid, content, session_key, harness, role, ts)
                VALUES ('delete', old.id, old.content, old.session_key, old.harness, old.role, old.ts);
                INSERT INTO messages_fts(rowid, content, session_key, harness, role, ts)
                VALUES (new.id, new.content, new.session_key, new.harness, new.role, new.ts);
            END
            """)
    }

    private static func createTaskTables(_ db: Database) throws {
        // The shared task board Auspex exposes over MCP. Created in v1 so the
        // schema is settled before M3 writes to it; nothing populates these
        // tables yet.
        try db.create(table: "tasks") { table in
            table.autoIncrementedPrimaryKey("id")
            table.column("title", .text).notNull()
            table.column("body", .text)
            table.column("status", .text).notNull().defaults(to: "open")
            table.column("priority", .integer).notNull().defaults(to: 0)
            table.column("project_id", .integer).references("projects", onDelete: .setNull)
            // Session keys rather than foreign keys: a task outlives the
            // session that filed it, and retention may drop the session row.
            table.column("created_by_key", .text)
            table.column("assignee_key", .text)
            table.column("source", .text)
            table.column("created_at", .double).notNull()
            table.column("updated_at", .double).notNull()
        }
        try db.create(index: "tasks_on_status", on: "tasks", columns: ["status"])
        try db.create(index: "tasks_on_project_id", on: "tasks", columns: ["project_id"])

        try db.create(table: "task_links") { table in
            table.column("task_id", .integer)
                .notNull()
                .references("tasks", onDelete: .cascade)
            table.column("session_key", .text).notNull()
            table.column("kind", .text).notNull()
            table.column("created_at", .double).notNull()
            table.primaryKey(["task_id", "session_key", "kind"])
        }
        try db.create(index: "task_links_on_session_key", on: "task_links", columns: ["session_key"])

        try db.create(table: "task_log") { table in
            table.autoIncrementedPrimaryKey("id")
            table.column("task_id", .integer)
                .notNull()
                .references("tasks", onDelete: .cascade)
            table.column("ts", .double).notNull()
            table.column("actor_key", .text)
            table.column("kind", .text).notNull()
            table.column("detail_json", .text)
        }
        try db.create(index: "task_log_on_task_id_ts", on: "task_log", columns: ["task_id", "ts"])

        try db.create(table: "tags") { table in
            table.autoIncrementedPrimaryKey("id")
            table.column("name", .text).notNull().unique()
            table.column("color", .text)
        }

        try db.create(table: "session_tags") { table in
            table.column("session_key", .text)
                .notNull()
                .references("sessions", onDelete: .cascade)
            table.column("tag_id", .integer)
                .notNull()
                .references("tags", onDelete: .cascade)
            table.primaryKey(["session_key", "tag_id"])
        }
    }

    private static func createHousekeepingTables(_ db: Database) throws {
        // Where each tailer stopped reading, so a relaunch resumes instead of
        // re-reading every transcript on the machine. `cursor_json` is an
        // encoded `SourceCursor`, whose shape differs per source kind — a byte
        // offset guarded by an inode, a row id, a content hash — and encoding
        // the enum keeps that variation out of the schema.
        try db.create(table: "source_cursors") { table in
            table.primaryKey("source_path", .text)
            table.column("harness", .text)
            table.column("cursor_json", .text).notNull()
            table.column("updated_at", .double).notNull()
        }

        // Key/value scratch table: the retention policy, and whatever later
        // milestones need to stash next to the schema rather than in
        // `settings.json`.
        try db.create(table: "meta") { table in
            table.primaryKey("key", .text).notNull()
            table.column("value", .text).notNull()
        }
    }

    // MARK: - Meta accessors

    /// Reads a value from the `meta` table.
    public func metaValue(forKey key: String) throws -> String? {
        try dbWriter.read { db in
            try String.fetchOne(
                db,
                sql: "SELECT value FROM meta WHERE key = ?",
                arguments: [key]
            )
        }
    }

    /// Inserts or updates a value in the `meta` table.
    public func setMetaValue(_ value: String, forKey key: String) throws {
        try dbWriter.write { db in
            try db.execute(
                sql: """
                    INSERT INTO meta (key, value) VALUES (?, ?)
                    ON CONFLICT(key) DO UPDATE SET value = excluded.value
                    """,
                arguments: [key, value]
            )
        }
    }

    // MARK: - Convenience

    /// A repository over this store's writer.
    public var sessions: SessionRepository {
        SessionRepository(dbWriter: dbWriter)
    }

    /// A cursor store over this store's writer.
    public var sourceCursors: SourceCursorRepository {
        SourceCursorRepository(dbWriter: dbWriter)
    }
}
