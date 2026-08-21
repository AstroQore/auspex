import AgentSessionLive
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

        migrator.registerMigration("v2_task_ledger") { db in
            try addBriefColumns(db)
            try createSessionViewTables(db)
            try migrateSnapshotsToSchema2(db)
        }

        migrator.registerMigration("v3_plans_and_notices") { db in
            try createPlanTables(db)
            try addTaskClaimColumns(db)
            try createNoticeTables(db)
        }

        migrator.registerMigration("v4_acknowledgement") { db in
            try addAcknowledgementColumns(db)
        }

        migrator.registerMigration("v5_projects_own_tasks") { db in
            try addTaskProjectColumns(db)
            try TaskProjectBackfill.run(db)
        }

        migrator.registerMigration("v6_context_usage") { db in
            try migrateSnapshotsToSchema3(db)
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

    // MARK: - v2 schema: the task ledger

    /// The brief, projected out of `snapshot_json` into columns.
    ///
    /// The same bargain every other projection on `sessions` makes: the blob
    /// stays authoritative and `SessionRepository` writes both from one place,
    /// so they cannot drift, while a query can answer *what was this session
    /// told to do* without decoding a few hundred snapshots. M3's task board
    /// asks exactly that question over MCP.
    private static func addBriefColumns(_ db: Database) throws {
        try db.alter(table: "sessions") { table in
            table.add(column: "first_prompt", .text)
            table.add(column: "latest_prompt", .text)
            table.add(column: "latest_assistant", .text)
            table.add(column: "last_turn_ended_at", .double)
        }
    }

    /// When the person last looked at a session.
    ///
    /// A table of its own rather than a column on `sessions`, for three
    /// reasons and each of them would have been a bug:
    ///
    /// - It is *Auspex's* state, not a projection of a harness's. Every column
    ///   on `sessions` is derived from a snapshot, and one that was not would
    ///   be the exception a future writer forgets about.
    /// - `SessionRepository.upsert(snapshots:)` writes `sessions` from a
    ///   record type. A column it does not encode survives — but only for as
    ///   long as nobody makes the projection exhaustive.
    /// - Retention deletes session rows. What a person has already read about
    ///   a session should outlive the row, so a transcript that comes back
    ///   does not come back marked unread.
    ///
    /// No foreign key, for the same reason: a view is recorded the moment a
    /// card is clicked, which can be before the first flush has written the
    /// session it is about.
    private static func createSessionViewTables(_ db: Database) throws {
        try db.create(table: "session_views") { table in
            table.primaryKey("session_key", .text)
            table.column("last_seen_at", .double).notNull()
        }
    }

    /// When the person last *dealt with* a session, as opposed to having
    /// looked at it.
    ///
    /// Two columns on `session_views` rather than a table of their own,
    /// because they answer a question about the same thing the table already
    /// holds: what has passed between this person and this session.
    ///
    /// They are not the same fact as `last_seen_at` and the difference is the
    /// whole reason for the columns. *Seen* is "the transcript was on screen",
    /// which is what puts the faint reply dot away. *Acknowledged* is "the
    /// signal has been dealt with", which a dismissal performs without anybody
    /// reading a word, and which the header's "Mark all as seen" performs for
    /// a whole board at once.
    ///
    /// `ack_reason` records which of those it was. Nothing renders it today;
    /// it is here because an acknowledgement with no provenance is impossible
    /// to reason about later — "why is this card quiet" has three answers and
    /// a boolean can hold none of them.
    private static func addAcknowledgementColumns(_ db: Database) throws {
        try db.alter(table: "session_views") { table in
            table.add(column: "acknowledged_at", .double)
            table.add(column: "ack_reason", .text)
        }
    }

    /// Brings every stored snapshot up to event schema 2.
    ///
    /// `SessionSnapshot` gained a non-optional `brief`, so a blob written
    /// before it cannot be decoded at all — the synthesized decoder asks for a
    /// key that is not there, and one such row would otherwise sink the whole
    /// bootstrap. Adding `"brief": {}` to the JSON is the migration; every
    /// field of a brief is optional, so an empty one is a valid — and honest —
    /// "we were not recording this yet".
    ///
    /// Rows that are not JSON objects at all are left exactly as they are.
    /// They cannot be rescued here, and `SessionRepository.fetchAll` skips
    /// what it cannot decode rather than failing the launch.
    private static func migrateSnapshotsToSchema2(_ db: Database) throws {
        let rows = try Row.fetchAll(db, sql: "SELECT key, snapshot_json FROM sessions")
        guard !rows.isEmpty else {
            try recordEventSchemaVersion(db)
            return
        }
        let decoder = StoreJSON.makeDecoder()
        let update = try db.makeStatement(sql: """
            UPDATE sessions
               SET snapshot_json = ?, first_prompt = ?, latest_prompt = ?,
                   latest_assistant = ?, last_turn_ended_at = ?
             WHERE key = ?
            """)
        for row in rows {
            let key: String = row["key"]
            let stored: String = row["snapshot_json"]
            let json = SnapshotBriefMigration.addingBrief(to: stored) ?? stored
            let brief = (try? StoreJSON.decode(SessionSnapshot.self, from: json, using: decoder))?
                .brief
            update.setUncheckedArguments([
                json,
                brief?.firstPrompt,
                brief?.latestPrompt,
                brief?.latestAssistant,
                brief?.lastTurnEndedAt?.timeIntervalSince1970,
                key
            ])
            try update.execute()
        }
        try recordEventSchemaVersion(db)
    }

    // MARK: - v6 schema: how full the context window is

    /// Brings every stored snapshot up to event schema 3.
    ///
    /// Kit 0.6.0 put `contextUsage`, `compactions` and `quota` on
    /// `SessionSnapshot`. Two are optional and cost a schema-2 blob nothing;
    /// `compactions` is a non-optional `Int`, and that one key is enough to
    /// make every blob written before it throw on decode. Adding
    /// `"compactions": 0` is the whole migration — see
    /// ``SnapshotContextMigration`` for why zero rather than a re-seed.
    ///
    /// Unlike the schema-2 pass, nothing is decoded here. That one had to:
    /// it was populating the brief columns beside the blob, which meant
    /// reading the brief back out of the JSON it had just written. Schema 3
    /// projects no new column, so this is a string rewrite per row and no
    /// `JSONDecoder` at all.
    ///
    /// Rows that are not JSON objects are left exactly as they are.
    /// `SessionRepository.fetchAll` skips what it cannot decode rather than
    /// failing the launch.
    private static func migrateSnapshotsToSchema3(_ db: Database) throws {
        let rows = try Row.fetchAll(db, sql: "SELECT key, snapshot_json FROM sessions")
        guard !rows.isEmpty else {
            try recordEventSchemaVersion(db)
            return
        }
        let update = try db.makeStatement(
            sql: "UPDATE sessions SET snapshot_json = ? WHERE key = ?"
        )
        for row in rows {
            let key: String = row["key"]
            let stored: String = row["snapshot_json"]
            guard let json = SnapshotContextMigration.addingCompactions(to: stored) else {
                continue
            }
            update.setUncheckedArguments([json, key])
            try update.execute()
        }
        try recordEventSchemaVersion(db)
    }

    /// Stamps the schema the stored snapshots were written by.
    private static func recordEventSchemaVersion(_ db: Database) throws {
        try db.execute(
            sql: """
                INSERT INTO meta (key, value) VALUES (?, ?)
                ON CONFLICT(key) DO UPDATE SET value = excluded.value
                """,
            arguments: [StoreMetaKey.eventSchemaVersion, String(AgentSessionLive.eventSchemaVersion)]
        )
    }

    // MARK: - v3 schema: plans, claims, and what an agent said

    /// The decomposition a task hangs under.
    ///
    /// Its own table rather than a `parent_task_id` on `tasks`, because a plan
    /// and a task answer different questions and are written by different
    /// people: a plan is registered once by whoever is handing work out, and a
    /// task churns through four states while somebody does it. Collapsing them
    /// would make "archive the plan" and "close the task" the same statement.
    private static func createPlanTables(_ db: Database) throws {
        try db.create(table: "plans") { table in
            table.autoIncrementedPrimaryKey("id")
            // The handle that travels in a brief. Unique, because the whole
            // point is that an agent can name a plan without holding its id.
            table.column("slug", .text).notNull().unique()
            table.column("title", .text).notNull()
            table.column("summary", .text)
            table.column("status", .text).notNull().defaults(to: "active")
            table.column("project_id", .integer).references("projects", onDelete: .setNull)
            // A session key rather than a foreign key, for the reason `tasks`
            // gives: a plan outlives the session that registered it.
            table.column("created_by_key", .text)
            table.column("created_at", .double).notNull()
            table.column("updated_at", .double).notNull()
            table.column("archived_at", .double)
        }
        try db.create(index: "plans_on_status", on: "plans", columns: ["status"])
    }

    /// What a claim records, added to the `tasks` table v1 created.
    ///
    /// `claim_role` and `claim_scope` are free text on purpose. The vocabulary
    /// belongs to whoever decomposed the work — "reviewer", "atlas pass 2",
    /// "the TOML half" — and an enum here would force every orchestrator to
    /// translate into ours before it could describe its own plan.
    ///
    /// The v1 default for `status` was `open`, which is not one of the four
    /// board columns. Nothing has ever written a task row (the tables were
    /// created ahead of their use), but normalising costs one statement and
    /// means the column has exactly one vocabulary from here on.
    private static func addTaskClaimColumns(_ db: Database) throws {
        try db.alter(table: "tasks") { table in
            table.add(column: "plan_id", .integer).references("plans", onDelete: .setNull)
            table.add(column: "claim_role", .text)
            table.add(column: "claim_scope", .text)
            table.add(column: "claimed_by_key", .text)
            table.add(column: "claimed_at", .double)
            table.add(column: "completed_at", .double)
            table.add(column: "result", .text)
        }
        try db.create(index: "tasks_on_plan_id", on: "tasks", columns: ["plan_id"])
        try db.execute(sql: "UPDATE tasks SET status = 'todo' WHERE status NOT IN ('todo','doing','blocked','done')")
    }

    /// What an agent said when it called for a person, and what it said it was
    /// doing.
    ///
    /// Both are Auspex's own state and neither is a projection of a harness's,
    /// so they get tables of their own for the same three reasons
    /// `session_views` does — and one more: they are the only rows in the
    /// database an *agent* authored, so keeping them separate is what makes
    /// "what did the agents tell us" a query rather than an audit.
    ///
    /// One row per session, replaced on each call. A notice is a live state,
    /// not a log: two unanswered questions from one session are one session
    /// that is stuck, and a board that showed both would be counting a session
    /// twice. The history lives in `task_log` when a task is involved.
    ///
    /// No foreign key to `sessions`, again for `session_views`' reason: a call
    /// can arrive before the flush that writes the session it is about.
    private static func createNoticeTables(_ db: Database) throws {
        try db.create(table: "session_notices") { table in
            table.primaryKey("session_key", .text)
            table.column("kind", .text).notNull()
            table.column("message", .text).notNull()
            table.column("urgency", .text).notNull().defaults(to: "normal")
            table.column("created_at", .double).notNull()
            table.column("cleared_at", .double)
        }
        try db.create(
            index: "session_notices_on_cleared_at",
            on: "session_notices",
            columns: ["cleared_at"]
        )

        try db.create(table: "session_reports") { table in
            table.primaryKey("session_key", .text)
            table.column("focus", .text).notNull()
            table.column("progress", .text)
            table.column("created_at", .double).notNull()
        }
    }

    // MARK: - v5 schema: projects contain tasks

    /// The project a task is in, and the project a milestone is inside.
    ///
    /// A text key rather than a foreign key into `projects`, and that is the
    /// decision this migration is about. The board's project key —
    /// ``BoardSnapshot/projectKey(for:)`` — is a *string*: a git root, a
    /// working directory, a folder a person claimed in
    /// `~/.auspex/settings.json`, or a ``PseudoProject`` key for a harness
    /// with no directory at all. Two of those four never reach the `projects`
    /// table, and one of them lives in a file rather than in this database. A
    /// task keyed on `projects.id` could therefore be filed under a project
    /// the wall does not group by, which is exactly the split — two vocabularies
    /// for one idea — that this schema change exists to remove.
    ///
    /// `tasks.project_id` stays where v1 put it. Nothing writes it, and
    /// dropping a column is a table rebuild for no gain.
    private static func addTaskProjectColumns(_ db: Database) throws {
        try db.alter(table: "tasks") { table in
            table.add(column: "project_key", .text)
        }
        try db.alter(table: "plans") { table in
            table.add(column: "project_key", .text)
        }
        try db.create(index: "tasks_on_project_key", on: "tasks", columns: ["project_key"])
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

    /// The ``AgentSessionLive/eventSchemaVersion`` the stored snapshots were
    /// written by, or `nil` for a store that predates the stamp.
    ///
    /// Equal to the running version on any store this build opened, because
    /// the migration that changed the shape also stamped it. A difference
    /// means a build wrote rows this one does not speak — which is a thing to
    /// say out loud rather than to discover as a decode error.
    public var storedEventSchemaVersion: Int? {
        (try? metaValue(forKey: StoreMetaKey.eventSchemaVersion)).flatMap { $0 }.flatMap(Int.init)
    }

    // MARK: - Convenience

    /// A repository over this store's writer.
    public var sessions: SessionRepository {
        SessionRepository(dbWriter: dbWriter)
    }

    /// A project repository over this store's writer.
    public var projects: ProjectRepository {
        ProjectRepository(dbWriter: dbWriter)
    }

    /// A cursor store over this store's writer.
    public var sourceCursors: SourceCursorRepository {
        SourceCursorRepository(dbWriter: dbWriter)
    }

    /// The plans, tasks, claims, and agent notices over this store's writer.
    public var tasks: TaskRepository {
        TaskRepository(dbWriter: dbWriter)
    }
}
