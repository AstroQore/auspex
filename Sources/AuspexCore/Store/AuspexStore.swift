import Foundation
import GRDB

/// Auspex's local database.
///
/// This is a scaffold: the schema is a single `meta` key/value table, enough
/// to prove that GRDB links, that migrations run, and that the store opens
/// both on disk (under `~/.auspex/`) and in memory (for tests). Sessions,
/// events, tasks, and the FTS5 transcript index arrive with M1.
public final class AuspexStore: Sendable {
    /// The GRDB connection pool. Callers read and write through this.
    public let dbWriter: any DatabaseWriter

    /// Opens the store at `url`, creating parent directories as needed, and
    /// runs any pending migrations.
    public init(url: URL) throws {
        var configuration = Configuration()
        configuration.foreignKeysEnabled = true
        let pool = try DatabasePool(path: url.path, configuration: configuration)
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
        var configuration = Configuration()
        configuration.foreignKeysEnabled = true
        let queue = try DatabaseQueue(configuration: configuration)
        self.dbWriter = queue
        try Self.migrator.migrate(queue)
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
            // Key/value scratch table. Holds the schema marker today; later
            // milestones use it for last-scan cursors per harness.
            try db.create(table: "meta") { table in
                table.primaryKey("key", .text).notNull()
                table.column("value", .text).notNull()
            }
        }

        return migrator
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
}
