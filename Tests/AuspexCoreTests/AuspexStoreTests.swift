import Foundation
import GRDB
import Testing

@testable import AuspexCore

@Suite("AuspexStore")
struct AuspexStoreTests {
    /// Every table `v1_initial` is responsible for. Named explicitly rather
    /// than counted, so dropping one from the migration fails here instead of
    /// at the first query that needs it.
    static let expectedTables = [
        "events",
        "messages",
        "messages_fts",
        "meta",
        "projects",
        "session_tags",
        "sessions",
        "source_cursors",
        "tags",
        "task_links",
        "task_log",
        "tasks",
        "tool_calls",
        "worktrees"
    ]

    @Test("v1_initial creates every table the schema is made of")
    func migratorCreatesEveryTable() throws {
        let store = try AuspexStore(inMemory: true)

        let missing = try store.dbWriter.read { db in
            try Self.expectedTables.filter { try !db.tableExists($0) }
        }
        #expect(missing.isEmpty, "missing tables: \(missing.joined(separator: ", "))")
    }

    @Test("messages_fts is an FTS5 trigram index over the messages table")
    func fullTextIndexIsTrigram() throws {
        let store = try AuspexStore(inMemory: true)

        let sql = try #require(try store.dbWriter.read { db in
            try String.fetchOne(
                db,
                sql: "SELECT sql FROM sqlite_master WHERE name = 'messages_fts'"
            )
        })
        #expect(sql.contains("fts5"))
        #expect(sql.contains("tokenize='trigram'"))
        #expect(sql.contains("content='messages'"))
        #expect(sql.contains("content_rowid='id'"))

        // The three triggers are what keep the index in step with the table.
        let triggers = try store.dbWriter.read { db in
            try String.fetchAll(
                db,
                sql: "SELECT name FROM sqlite_master WHERE type = 'trigger' ORDER BY name"
            )
        }
        #expect(triggers.filter { $0.hasPrefix("messages_") }
            == ["messages_ad", "messages_ai", "messages_au"])
    }

    @Test("the columns the board sorts and filters on exist on sessions")
    func sessionsTableHasProjectedColumns() throws {
        let store = try AuspexStore(inMemory: true)

        let columns = try store.dbWriter.read { db in
            Set(try db.columns(in: "sessions").map(\.name))
        }
        let required: Set<String> = [
            "key", "harness", "session_id", "variant", "parent_key", "root_key",
            "parent_link", "cwd", "project_id", "worktree_id", "git_branch", "pid",
            "proc_start", "title", "model", "entrypoint", "source_path", "started_at",
            "last_event_at", "ended_at", "state", "state_detail", "is_alive",
            "turn_count", "tool_call_count", "tokens_in", "tokens_out", "tokens_cached",
            "snapshot_json"
        ]
        #expect(required.isSubset(of: columns))

        let indexes = try store.dbWriter.read { db in
            Set(try db.indexes(on: "sessions").map(\.name))
        }
        #expect(indexes.isSuperset(of: [
            "sessions_on_harness",
            "sessions_on_project_id",
            "sessions_on_last_event_at",
            "sessions_on_is_alive"
        ]))
    }

    @Test("foreign keys are enforced, so an event cannot outrun its session")
    func foreignKeysAreEnforced() throws {
        let store = try AuspexStore(inMemory: true)

        #expect(throws: DatabaseError.self) {
            try store.dbWriter.write { db in
                try db.execute(sql: """
                    INSERT INTO events (session_key, ts, observed_at, seq, kind)
                    VALUES ('claudeCode:never-stored', 0, 0, 0, 'note')
                    """)
            }
        }
    }

    @Test("the migrator creates the meta table in an in-memory database")
    func migratorCreatesMetaTable() throws {
        let store = try AuspexStore(inMemory: true)

        let exists = try store.dbWriter.read { db in
            try db.tableExists("meta")
        }
        #expect(exists)

        let columns = try store.dbWriter.read { db in
            try db.columns(in: "meta").map(\.name).sorted()
        }
        #expect(columns == ["key", "value"])
    }

    @Test("v1_initial is registered and applied")
    func initialMigrationIsApplied() throws {
        let store = try AuspexStore(inMemory: true)

        #expect(AuspexStore.migrator.migrations.contains("v1_initial"))

        let applied = try store.dbWriter.read { db in
            try AuspexStore.migrator.appliedMigrations(db)
        }
        #expect(applied.contains("v1_initial"))
    }

    @Test("meta values round-trip and upsert")
    func metaValuesRoundTrip() throws {
        let store = try AuspexStore(inMemory: true)

        #expect(try store.metaValue(forKey: "schema_owner") == nil)

        try store.setMetaValue("auspex", forKey: "schema_owner")
        #expect(try store.metaValue(forKey: "schema_owner") == "auspex")

        try store.setMetaValue("auspex-core", forKey: "schema_owner")
        #expect(try store.metaValue(forKey: "schema_owner") == "auspex-core")
    }

    @Test("an on-disk store opens under an injected home")
    func onDiskStoreOpensUnderInjectedHome() throws {
        let home = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("auspex-store-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }

        let paths = AuspexPaths(homeDirectory: home)
        let store = try AuspexStore(paths: paths)
        try store.setMetaValue(AuspexVersion.marketingVersion, forKey: "created_by_version")

        #expect(FileManager.default.fileExists(atPath: paths.databaseURL.path))
        #expect(try store.metaValue(forKey: "created_by_version") == AuspexVersion.marketingVersion)
    }
}
