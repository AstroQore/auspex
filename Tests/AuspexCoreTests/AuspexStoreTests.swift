import Foundation
import GRDB
import Testing

@testable import AuspexCore

@Suite("AuspexStore")
struct AuspexStoreTests {
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
