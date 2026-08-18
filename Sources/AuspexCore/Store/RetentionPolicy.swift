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
/// Not scheduled yet — M4 wires it to an idle timer. Call ``run(now:)``.
public struct RetentionJob: Sendable {
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
    /// to the filesystem.
    ///
    /// Deletes run in one transaction so a crash mid-pass cannot leave the
    /// event log trimmed by one rule and not the other. `PRAGMA
    /// incremental_vacuum` runs afterwards, outside that transaction: it is
    /// bookkeeping on the file, not on the data, and it is a no-op on a
    /// database that is not in incremental auto-vacuum mode.
    @discardableResult
    public func run(now: Date = Date()) throws -> RetentionReport {
        var report = RetentionReport(
            eventsOverPerSessionLimit: 0,
            eventsOverAgeLimit: 0,
            messagesOverAgeLimit: 0,
            messagesFromExcludedHarnesses: 0
        )

        try dbWriter.write { db in
            if policy.eventsPerSession > 0 {
                // The window function partitions by session, so one chatty
                // session's overflow is trimmed without touching a quiet one.
                try db.execute(sql: """
                    DELETE FROM events WHERE id IN (
                        SELECT id FROM (
                            SELECT id, ROW_NUMBER() OVER (
                                PARTITION BY session_key ORDER BY id DESC
                            ) AS row_number_desc
                            FROM events
                        ) WHERE row_number_desc > ?
                    )
                    """, arguments: [policy.eventsPerSession])
                report.eventsOverPerSessionLimit = db.changesCount
            }

            if policy.eventsMaxAge > 0 {
                let cutoff = now.addingTimeInterval(-policy.eventsMaxAge).timeIntervalSince1970
                try db.execute(
                    sql: "DELETE FROM events WHERE observed_at < ?",
                    arguments: [cutoff]
                )
                report.eventsOverAgeLimit = db.changesCount
            }

            if let ftsMaxAge = policy.ftsMaxAge, ftsMaxAge > 0 {
                let cutoff = now.addingTimeInterval(-ftsMaxAge).timeIntervalSince1970
                try db.execute(sql: "DELETE FROM messages WHERE ts < ?", arguments: [cutoff])
                report.messagesOverAgeLimit = db.changesCount
            }

            let excluded = policy.excludedHarnessesForFTS
            if !excluded.isEmpty {
                let placeholders = Array(repeating: "?", count: excluded.count).joined(separator: ", ")
                try db.execute(
                    sql: "DELETE FROM messages WHERE harness IN (\(placeholders))",
                    arguments: StatementArguments(excluded.map(\.rawValue))
                )
                report.messagesFromExcludedHarnesses = db.changesCount
            }
        }

        if report.totalDeleted > 0 {
            try dbWriter.writeWithoutTransaction { db in
                try db.execute(sql: "PRAGMA incremental_vacuum")
            }
        }

        return report
    }
}
