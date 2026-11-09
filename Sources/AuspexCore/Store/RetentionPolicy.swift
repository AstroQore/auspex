import AgentSessionKit
import Foundation
import GRDB

/// How much history Auspex keeps.
///
/// The store grows without bound otherwise: one busy Claude Code session
/// writes thousands of events an hour, and the trigram index over its prompts
/// is several times the size of the text it indexes. The defaults are chosen
/// so a session's whole recent trace is still there when someone opens it, and
/// nothing older than a fortnight is.
///
/// Stored as JSON in `meta` rather than in `settings.json` because it
/// describes the database, and a database restored without its policy would
/// be trimmed by whatever the next launch happened to default to.
public struct RetentionPolicy: Codable, Hashable, Sendable {
    /// Newest events kept per session. Older ones are dropped even if they are
    /// well inside ``eventsMaxAge`` — one runaway session must not evict every
    /// other session's history.
    public var eventsPerSession: Int
    /// How long an event is kept, measured from when Auspex *observed* it
    /// rather than from the source's own timestamp. Seeding a week-old
    /// transcript on a cold start should not delete it on the way in.
    public var eventsMaxAge: TimeInterval
    /// How long indexed message text is kept, or `nil` to keep it forever.
    /// Separate from ``eventsMaxAge`` because search is the one feature that
    /// wants a long memory and the index is the most expensive thing to keep.
    public var ftsMaxAge: TimeInterval?
    /// Harnesses whose text is never indexed, and whose already-indexed text
    /// this policy removes. For the harness someone uses on work they would
    /// rather not have searchable at all.
    public var excludedHarnessesForFTS: [Harness]

    public init(
        eventsPerSession: Int = 2000,
        eventsMaxAge: TimeInterval = 14 * 86_400,
        ftsMaxAge: TimeInterval? = 30 * 86_400,
        excludedHarnessesForFTS: [Harness] = []
    ) {
        self.eventsPerSession = eventsPerSession
        self.eventsMaxAge = eventsMaxAge
        self.ftsMaxAge = ftsMaxAge
        self.excludedHarnessesForFTS = excludedHarnessesForFTS
    }

    public static let `default` = RetentionPolicy()

    /// Key this policy is stored under in `meta`.
    public static let metaKey = "retention_policy"

    /// `true` when `harness` may have its text indexed.
    public func indexesText(for harness: Harness) -> Bool {
        !excludedHarnessesForFTS.contains(harness)
    }
}

extension AuspexStore {
    /// The stored retention policy, or the default when none has been saved
    /// or the stored one cannot be read.
    public func retentionPolicy() throws -> RetentionPolicy {
        guard let json = try metaValue(forKey: RetentionPolicy.metaKey) else { return .default }
        guard let policy = try? StoreJSON.decode(
            RetentionPolicy.self,
            from: json,
            using: StoreJSON.makeDecoder()
        ) else { return .default }
        return policy
    }

    /// Persists the retention policy.
    public func setRetentionPolicy(_ policy: RetentionPolicy) throws {
        let json = try StoreJSON.encodeToString(policy, using: StoreJSON.makeEncoder())
        try setMetaValue(json, forKey: RetentionPolicy.metaKey)
    }
}

/// What one retention pass removed.
public struct RetentionReport: Hashable, Sendable {
    /// Events dropped for exceeding ``RetentionPolicy/eventsPerSession``.
    public var eventsOverPerSessionLimit: Int
    /// Events dropped for exceeding ``RetentionPolicy/eventsMaxAge``.
    public var eventsOverAgeLimit: Int
    /// Messages dropped for exceeding ``RetentionPolicy/ftsMaxAge``.
    public var messagesOverAgeLimit: Int
    /// Messages dropped because their harness is excluded from the index.
    public var messagesFromExcludedHarnesses: Int

    /// Total rows removed.
    public var totalDeleted: Int {
        eventsOverPerSessionLimit + eventsOverAgeLimit
            + messagesOverAgeLimit + messagesFromExcludedHarnesses
    }
}

/// Applies a ``RetentionPolicy`` to the store.
///
/// ## In batches
///
/// A store that has never been trimmed can owe millions of deletions, and one
/// `DELETE` of all of them is one transaction that holds the writer for as long
/// as it takes and grows the WAL by roughly every page it touches. So every rule
/// deletes at most `batchSize` rows per transaction (``defaultBatchSize``) and
/// goes round again until a batch comes back short; ``runBatched(now:batchSize:)``
/// also yields between batches so the registry's own writes interleave instead
/// of queueing behind the pass.
///
/// The rules are independent and idempotent, so nothing is lost by not doing
/// them atomically: a pass interrupted halfway has trimmed some of what it
/// would have, and the next one trims the rest.
///
/// ## In this order
///
/// Age first, because on a neglected store it is by far the biggest cut and it
/// has an index (`events_on_observed_at`); the per-session cap then counts what
/// is left, which is a much smaller scan. The search index follows, and freed
/// pages go back to the filesystem last — see ``StoreSpace``.
public struct RetentionJob: Sendable {
    /// Rows per transaction.
    public static let defaultBatchSize = 10_000

    public let dbWriter: any DatabaseWriter
    public let policy: RetentionPolicy

    public init(dbWriter: any DatabaseWriter, policy: RetentionPolicy = .default) {
        self.dbWriter = dbWriter
        self.policy = policy
    }

    public init(store: AuspexStore, policy: RetentionPolicy = .default) {
        self.dbWriter = store.dbWriter
        self.policy = policy
    }

    /// Deletes everything the policy no longer keeps, then returns freed pages
    /// to the filesystem — synchronously, for a caller already off the main
    /// actor that has no reason to suspend.
    @discardableResult
    public func run(now: Date = Date(), batchSize: Int = defaultBatchSize) throws -> RetentionReport {
        let size = max(1, batchSize)
        var report = RetentionReport.none
        func drain(_ step: Step) throws {
            while true {
                let deleted = try dbWriter.write { db in try step.delete(limit: size, in: db) }
                report[keyPath: step.field] += deleted
                if deleted < size { return }
            }
        }

        for step in eventAgeSteps(now: now) { try drain(step) }
        let limit = policy.eventsPerSession
        if limit > 0 {
            let overflowing = try dbWriter.read { db in try Self.overflowingSessions(limit: limit, in: db) }
            for step in Self.perSessionSteps(overflowing) { try drain(step) }
        }
        for step in messageSteps(now: now) { try drain(step) }

        if report.totalDeleted > 0 {
            try StoreSpace.reclaimFreePagesNow(dbWriter)
        }
        return report
    }

    /// The same pass, yielding between batches and stopping between them when
    /// the task is cancelled. What the app schedules.
    @discardableResult
    public func runBatched(
        now: Date = Date(),
        batchSize: Int = defaultBatchSize
    ) async throws -> RetentionReport {
        let size = max(1, batchSize)
        let writer = dbWriter
        var report = RetentionReport.none
        func drain(_ step: Step) async throws {
            while true {
                try Task.checkCancellation()
                let deleted = try await writer.write { db in try step.delete(limit: size, in: db) }
                report[keyPath: step.field] += deleted
                if deleted < size { return }
                await Task.yield()
            }
        }

        for step in eventAgeSteps(now: now) { try await drain(step) }
        let limit = policy.eventsPerSession
        if limit > 0 {
            let overflowing = try await writer.read { db in
                try Self.overflowingSessions(limit: limit, in: db)
            }
            for step in Self.perSessionSteps(overflowing) { try await drain(step) }
        }
        for step in messageSteps(now: now) { try await drain(step) }

        if report.totalDeleted > 0 {
            try await StoreSpace.reclaimFreePages(writer)
        }
        return report
    }

    // MARK: - Steps

    /// One bounded delete, repeated until it comes back short, and the report
    /// field its count goes in.
    ///
    /// Every statement takes its batch limit as the last argument and deletes
    /// by primary key through a `LIMIT`ed subquery, which SQLite allows without
    /// the `DELETE … LIMIT` extension and which picks the rows by whatever
    /// index the inner `WHERE` has.
    private struct Step: Sendable {
        let sql: String
        let values: [DatabaseValue]
        let field: WritableKeyPath<RetentionReport, Int> & Sendable

        func delete(limit: Int, in db: Database) throws -> Int {
            try db.execute(sql: sql, arguments: StatementArguments(values + [limit.databaseValue]))
            return db.changesCount
        }
    }

    /// Events older than ``RetentionPolicy/eventsMaxAge``, measured from when
    /// Auspex observed them.
    private func eventAgeSteps(now: Date) -> [Step] {
        guard policy.eventsMaxAge > 0 else { return [] }
        let cutoff = now.addingTimeInterval(-policy.eventsMaxAge).timeIntervalSince1970
        return [Step(
            sql: """
                DELETE FROM events WHERE id IN (
                    SELECT id FROM events WHERE observed_at < ? LIMIT ?
                )
                """,
            values: [cutoff.databaseValue],
            field: \.eventsOverAgeLimit
        )]
    }

    /// The sessions with more than `limit` events, and the id of the newest
    /// event each of them no longer keeps.
    ///
    /// One pass over `events_on_session_key_id` to count, then one indexed seek
    /// per overflowing session to find where its window starts. The window is
    /// the newest `limit` by id, which is the same order every trace reads in.
    private static func overflowingSessions(limit: Int, in db: Database) throws -> [(String, Int64)] {
        let keys = try String.fetchAll(db, sql: """
            SELECT session_key FROM events GROUP BY session_key HAVING COUNT(*) > ?
            """, arguments: [limit])
        var result: [(String, Int64)] = []
        result.reserveCapacity(keys.count)
        for key in keys {
            guard let floor = try Int64.fetchOne(db, sql: """
                SELECT id FROM events WHERE session_key = ?
                 ORDER BY id DESC LIMIT 1 OFFSET ?
                """, arguments: [key, limit])
            else { continue }
            result.append((key, floor))
        }
        return result
    }

    /// One session's overflow: everything at or below the newest event its
    /// window no longer holds. One chatty session's history goes without
    /// touching a quiet one's.
    private static func perSessionSteps(_ overflowing: [(String, Int64)]) -> [Step] {
        overflowing.map { key, floor in
            Step(
                sql: """
                    DELETE FROM events WHERE id IN (
                        SELECT id FROM events WHERE session_key = ? AND id <= ?
                         ORDER BY id LIMIT ?
                    )
                    """,
                values: [key.databaseValue, floor.databaseValue],
                field: \.eventsOverPerSessionLimit
            )
        }
    }

    /// The search index: text older than ``RetentionPolicy/ftsMaxAge``, then
    /// every message from an excluded harness.
    private func messageSteps(now: Date) -> [Step] {
        var steps: [Step] = []
        if let ftsMaxAge = policy.ftsMaxAge, ftsMaxAge > 0 {
            let cutoff = now.addingTimeInterval(-ftsMaxAge).timeIntervalSince1970
            steps.append(Step(
                sql: """
                    DELETE FROM messages WHERE id IN (
                        SELECT id FROM messages WHERE ts < ? LIMIT ?
                    )
                    """,
                values: [cutoff.databaseValue],
                field: \.messagesOverAgeLimit
            ))
        }
        let excluded = policy.excludedHarnessesForFTS
        if !excluded.isEmpty {
            let placeholders = Array(repeating: "?", count: excluded.count).joined(separator: ", ")
            steps.append(Step(
                sql: """
                    DELETE FROM messages WHERE id IN (
                        SELECT id FROM messages WHERE harness IN (\(placeholders)) LIMIT ?
                    )
                    """,
                values: excluded.map(\.rawValue.databaseValue),
                field: \.messagesFromExcludedHarnesses
            ))
        }
        return steps
    }
}

extension RetentionReport {
    /// A pass that removed nothing.
    public static let none = RetentionReport(
        eventsOverPerSessionLimit: 0,
        eventsOverAgeLimit: 0,
        messagesOverAgeLimit: 0,
        messagesFromExcludedHarnesses: 0
    )
}
