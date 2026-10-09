import Foundation
import GRDB

/// Removes the liveness heartbeats earlier builds wrote into `events`, once.
///
/// Until the registry learned to drop a liveness verdict that changed nothing,
/// every confirmation the resolver made — every live session, every few
/// seconds — became a row. On a machine that had run Auspex for a few weeks
/// that was three quarters of the event log: millions of rows no surface reads
/// (the trace hides them, the trajectory skips them) and every one of them
/// paid for in page cache, in the retention job's scans, and on disk.
///
/// ## Why a job and not a migration
///
/// A migration runs inside one transaction, before the window draws. Deleting
/// a few million rows there would hold the launch for as long as it takes and
/// grow the WAL by roughly the size of everything it touched. Here the rows go
/// in batches, each its own short transaction, with a yield between them so the
/// registry's own writes interleave rather than queue behind the whole pass.
///
/// ## Why it walks the row id
///
/// `kind` is not indexed, so "the next fifty thousand liveness rows" asked from
/// the top of the table each time would rescan everything the previous batches
/// had already passed over. A cursor on the primary key reads the table once,
/// front to back, however many batches that takes. Rows written after the pass
/// started are not its business: the build running it does not write
/// heartbeats.
///
/// Finished is recorded in `meta` under ``StoreMetaKey/livenessEventsPurged``,
/// so the pass costs one indexed read on every later launch.
public struct LivenessEventPurge: Sendable {
    /// Rows per transaction.
    public static let defaultBatchSize = 50_000

    public let dbWriter: any DatabaseWriter

    public init(dbWriter: any DatabaseWriter) {
        self.dbWriter = dbWriter
    }

    public init(store: AuspexStore) {
        self.dbWriter = store.dbWriter
    }

    /// Whether this store has already been purged.
    public func hasRun() async throws -> Bool {
        try await dbWriter.read { db in
            try String.fetchOne(
                db,
                sql: "SELECT value FROM meta WHERE key = ?",
                arguments: [StoreMetaKey.livenessEventsPurged]
            ) != nil
        }
    }

    /// Deletes every stored liveness event, unless this store already has.
    ///
    /// - Returns: how many rows went, or `nil` when the pass had already run.
    ///   Cancellation stops between batches and leaves the stamp unwritten, so
    ///   the next launch picks up where this one stopped.
    @discardableResult
    public func runIfNeeded(
        batchSize: Int = defaultBatchSize,
        now: Date = Date()
    ) async throws -> Int? {
        guard try await !hasRun() else { return nil }

        let ceiling = try await dbWriter.read { db in
            try Int64.fetchOne(db, sql: "SELECT MAX(id) FROM events")
        } ?? 0
        let size = max(1, batchSize)
        var cursor: Int64 = 0
        var deleted = 0
        while cursor < ceiling {
            try Task.checkCancellation()
            let from = cursor
            let batch = try await dbWriter.write { db -> (deleted: Int, last: Int64?) in
                // The highest id among the next `size` heartbeats, read by a
                // rowid range scan; the delete then covers exactly that range.
                guard let last = try Int64.fetchOne(db, sql: """
                    SELECT MAX(id) FROM (
                        SELECT id FROM events
                         WHERE id > ? AND id <= ? AND kind = 'liveness'
                         ORDER BY id
                         LIMIT ?
                    )
                    """, arguments: [from, ceiling, size])
                else { return (0, nil) }
                try db.execute(
                    sql: "DELETE FROM events WHERE id > ? AND id <= ? AND kind = 'liveness'",
                    arguments: [from, last]
                )
                return (db.changesCount, last)
            }
            guard let last = batch.last else { break }
            deleted += batch.deleted
            cursor = last
            await Task.yield()
        }

        try await dbWriter.write { db in
            try db.execute(
                sql: """
                    INSERT INTO meta (key, value) VALUES (?, ?)
                    ON CONFLICT(key) DO UPDATE SET value = excluded.value
                    """,
                arguments: [StoreMetaKey.livenessEventsPurged, String(now.timeIntervalSince1970)]
            )
        }
        if deleted > 0 {
            try await StoreSpace.reclaimFreePages(dbWriter)
        }
        return deleted
    }
}

/// Returning freed pages to the filesystem, a step at a time.
public enum StoreSpace {
    /// Pages one `incremental_vacuum` step returns: 8 MB at the default 4 KB
    /// page size. Small enough that the writer is never held for long, large
    /// enough that a few hundred megabytes is a few dozen steps.
    public static let defaultPagesPerStep = 2_000

    /// Runs `PRAGMA incremental_vacuum` in steps until the freelist is empty,
    /// yielding between them.
    ///
    /// One unbounded `incremental_vacuum` after a large delete would hold the
    /// writer for as long as it takes to move every page. Stepping keeps each
    /// hold short. A database that is not in incremental auto-vacuum mode
    /// cannot be shrunk this way at all, so it is left alone rather than looped
    /// on; and the loop also stops if a step frees nothing, which is the only
    /// other way it could fail to finish.
    ///
    /// - Returns: how many pages were released.
    @discardableResult
    public static func reclaimFreePages(
        _ dbWriter: any DatabaseWriter,
        pagesPerStep: Int = defaultPagesPerStep
    ) async throws -> Int {
        let step = max(1, pagesPerStep)
        var released = 0
        while true {
            try Task.checkCancellation()
            let freed = try await dbWriter.writeWithoutTransaction { db -> Int? in
                try reclaimStep(db, pages: step)
            }
            guard let freed, freed > 0 else { break }
            released += freed
            await Task.yield()
        }
        return released
    }

    /// The synchronous form, for callers already off the main actor that have
    /// no reason to suspend.
    @discardableResult
    public static func reclaimFreePagesNow(
        _ dbWriter: any DatabaseWriter,
        pagesPerStep: Int = defaultPagesPerStep
    ) throws -> Int {
        let step = max(1, pagesPerStep)
        var released = 0
        while true {
            let freed = try dbWriter.writeWithoutTransaction { db -> Int? in
                try reclaimStep(db, pages: step)
            }
            guard let freed, freed > 0 else { break }
            released += freed
        }
        return released
    }

    /// One step: `nil` when there is nothing this database can reclaim.
    private static func reclaimStep(_ db: Database, pages: Int) throws -> Int? {
        // 2 is INCREMENTAL. In any other mode the pragma is a no-op and the
        // freelist would never shrink.
        guard try Int.fetchOne(db, sql: "PRAGMA auto_vacuum") == 2 else { return nil }
        let before = try Int.fetchOne(db, sql: "PRAGMA freelist_count") ?? 0
        guard before > 0 else { return nil }
        try db.execute(sql: "PRAGMA incremental_vacuum(\(pages))")
        let after = try Int.fetchOne(db, sql: "PRAGMA freelist_count") ?? 0
        return before - after
    }
}
