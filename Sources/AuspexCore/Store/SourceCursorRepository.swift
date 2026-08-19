import AgentSessionKit
import AgentSessionLive
import Foundation
import GRDB

/// Where a host persists how far each tailer has read.
///
/// `AgentSessionLive` owns ``SourceCursor`` but not the storage for it — the
/// kit deliberately has no database — so the protocol lives here, on the host
/// side, shaped the way the tailing layer will want to call it. If the kit
/// grows an equivalent protocol later, ``SourceCursorRepository`` can conform
/// to both without changing.
public protocol SourceCursorStoring: Sendable {
    /// Every stored cursor, keyed by the source path it belongs to.
    func load() async throws -> [String: SourceCursor]
    /// Persists cursors, replacing the entry for each path given and leaving
    /// every other path alone.
    func save(_ cursors: [String: SourceCursor]) async throws
}

/// The `source_cursors` table.
///
/// Cursors are saved every couple of seconds and on shutdown, so a relaunch
/// resumes each transcript from where it stopped instead of re-reading
/// gigabytes of history. ``save(_:)`` merges rather than replaces: the tailing
/// layer flushes one harness at a time, and a wholesale replace would drop the
/// others' positions.
public struct SourceCursorRepository: SourceCursorStoring {
    public let dbWriter: any DatabaseWriter

    public init(dbWriter: any DatabaseWriter) {
        self.dbWriter = dbWriter
    }

    public init(store: AuspexStore) {
        self.dbWriter = store.dbWriter
    }

    public func load() async throws -> [String: SourceCursor] {
        try await dbWriter.read { db in
            try Self.decodeCursors(
                try Row.fetchAll(db, sql: "SELECT source_path, cursor_json FROM source_cursors")
            )
        }
    }

    /// Cursors for one harness only, for a tailer that is resuming just its
    /// own sources.
    public func load(harness: Harness) async throws -> [String: SourceCursor] {
        try await dbWriter.read { db in
            try Self.decodeCursors(
                try Row.fetchAll(
                    db,
                    sql: "SELECT source_path, cursor_json FROM source_cursors WHERE harness = ?",
                    arguments: [harness.rawValue]
                )
            )
        }
    }

    public func save(_ cursors: [String: SourceCursor]) async throws {
        try await save(cursors, harness: nil)
    }

    /// Persists cursors and stamps them with the harness that produced them.
    ///
    /// Passing `nil` leaves an existing row's harness untouched, so a caller
    /// that does not know it cannot erase what an earlier save recorded.
    public func save(_ cursors: [String: SourceCursor], harness: Harness?) async throws {
        guard !cursors.isEmpty else { return }
        let now = Date().timeIntervalSince1970
        let encoder = StoreJSON.makeEncoder()
        // Encoding before the write keeps JSON work out of the transaction.
        let rows: [(path: String, json: String)] = try cursors
            .sorted { $0.key < $1.key }
            .map { ($0.key, try StoreJSON.encodeToString($0.value, using: encoder)) }
        let harnessValue = harness?.rawValue

        try await dbWriter.write { db in
            let statement = try db.makeStatement(sql: """
                INSERT INTO source_cursors (source_path, harness, cursor_json, updated_at)
                VALUES (?, ?, ?, ?)
                ON CONFLICT(source_path) DO UPDATE SET
                    harness = COALESCE(excluded.harness, source_cursors.harness),
                    cursor_json = excluded.cursor_json,
                    updated_at = excluded.updated_at
                """)
            for row in rows {
                statement.setUncheckedArguments([row.path, harnessValue, row.json, now])
                try statement.execute()
            }
        }
    }

    /// Forgets the cursors for `paths`. A source whose file was rotated away
    /// has a cursor that can only mislead the next tailer.
    public func remove(paths: [String]) async throws {
        guard !paths.isEmpty else { return }
        try await dbWriter.write { db in
            let placeholders = Array(repeating: "?", count: paths.count).joined(separator: ", ")
            try db.execute(
                sql: "DELETE FROM source_cursors WHERE source_path IN (\(placeholders))",
                arguments: StatementArguments(paths)
            )
        }
    }

    private static func decodeCursors(_ rows: [Row]) throws -> [String: SourceCursor] {
        let decoder = StoreJSON.makeDecoder()
        var result: [String: SourceCursor] = [:]
        result.reserveCapacity(rows.count)
        for row in rows {
            guard let path = row["source_path"] as String?,
                  let json = row["cursor_json"] as String?
            else { continue }
            // A cursor written by a build whose `SourceCursor` had a case this
            // one does not is unreadable, and re-seeding from the head of the
            // source is the safe answer — never resuming from a position that
            // could not be decoded.
            guard let cursor = try? StoreJSON.decode(SourceCursor.self, from: json, using: decoder)
            else { continue }
            result[path] = cursor
        }
        return result
    }
}

/// The kit's own cursor-store protocol, satisfied by the same two methods.
///
/// `AgentSessionLive` declares ``SourceCursorStore`` for
/// ``IngestCoordinator`` to resume from, and ships an in-memory and a
/// JSON-file implementation for hosts without a database. Auspex has one, so
/// it hands the coordinator this repository instead — the signatures already
/// match, which is what ``SourceCursorStoring`` predicted, so the conformance
/// is a declaration rather than an adapter.
extension SourceCursorRepository: SourceCursorStore {
    /// Writes only the cursors that moved.
    ///
    /// The coordinator saves every two seconds; with seven hundred sources
    /// tracked and one of them growing, the protocol's default would rewrite
    /// all seven hundred rows each time — `ftruncate` and a fsync's worth of
    /// `pwrite` for nothing. The repository's upsert already handles a subset,
    /// so the whole of this is choosing the smaller dictionary. `all` is
    /// ignored on purpose: the table is the source of truth for what was not
    /// touched.
    public func save(changed: [String: SourceCursor], all: [String: SourceCursor]) async throws {
        try await save(changed)
    }
}
