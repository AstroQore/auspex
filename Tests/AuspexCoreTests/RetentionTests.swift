import AgentSessionKit
import AgentSessionLive
import Foundation
import GRDB
import Testing

@testable import AuspexCore

@Suite("Retention")
struct RetentionTests {
    private func makeStore(withSessions keys: [SessionKey]) throws -> AuspexStore {
        let store = try AuspexStore(inMemory: true)
        let repository = SessionRepository(store: store)
        try repository.upsert(snapshots: keys.map {
            SessionStateReducer.initialSnapshot(identity: Fixtures.identity(key: $0))
        })
        return store
    }

    @Test("the default policy keeps 2000 events per session for a fortnight")
    func defaultPolicy() {
        let policy = RetentionPolicy.default
        #expect(policy.eventsPerSession == 2000)
        #expect(policy.eventsMaxAge == TimeInterval(14 * 86_400))
        #expect(policy.ftsMaxAge == TimeInterval(30 * 86_400))
        #expect(policy.excludedHarnessesForFTS.isEmpty)
        #expect(policy.indexesText(for: .claudeCode))
    }

    @Test("the policy round-trips through meta")
    func policyRoundTripsThroughMeta() throws {
        let store = try AuspexStore(inMemory: true)
        #expect(try store.retentionPolicy() == .default)

        let policy = RetentionPolicy(
            eventsPerSession: 10,
            eventsMaxAge: 3600,
            ftsMaxAge: nil,
            excludedHarnessesForFTS: [.cursor]
        )
        try store.setRetentionPolicy(policy)
        #expect(try store.retentionPolicy() == policy)
        #expect(!policy.indexesText(for: .cursor))

        // Garbage in `meta` falls back to the default rather than throwing:
        // a board that trims nothing is better than one that will not open.
        try store.setMetaValue("not json", forKey: RetentionPolicy.metaKey)
        #expect(try store.retentionPolicy() == .default)
    }

    @Test("events beyond the per-session limit are dropped, newest kept")
    func eventsBeyondPerSessionLimitAreDropped() throws {
        let key = Fixtures.key()
        let store = try makeStore(withSessions: [key])
        let repository = SessionRepository(store: store)

        let total = 2_100
        let events = (0..<total).map { index in
            Fixtures.event(.note("step-\(index)"), key: key, at: TimeInterval(index))
        }
        try repository.insertEvents(events)
        #expect(try repository.eventCount(key: key) == total)

        let job = RetentionJob(store: store, policy: .default)
        let report = try job.run(now: Fixtures.date(TimeInterval(total)))

        #expect(report.eventsOverPerSessionLimit == total - 2_000)
        #expect(report.eventsOverAgeLimit == 0)
        #expect(try repository.eventCount(key: key) == 2_000)

        // The window kept is the newest one: the oldest 100 went.
        let oldest = try #require(try repository.recentEvents(key: key, limit: 2_000).first)
        #expect(oldest.timestamp == Fixtures.date(100))
    }

    @Test("one chatty session's overflow does not evict a quiet session")
    func perSessionLimitIsPerSession() throws {
        let chatty = Fixtures.key(.claudeCode, "chatty")
        let quiet = Fixtures.key(.codex, "quiet")
        let store = try makeStore(withSessions: [chatty, quiet])
        let repository = SessionRepository(store: store)

        try repository.insertEvents((0..<20).map {
            Fixtures.event(.note("chatty-\($0)"), key: chatty, at: TimeInterval($0))
        })
        try repository.insertEvents((0..<3).map {
            Fixtures.event(.note("quiet-\($0)"), key: quiet, at: TimeInterval($0))
        })

        let job = RetentionJob(store: store, policy: RetentionPolicy(eventsPerSession: 5))
        try job.run(now: Fixtures.date(100))

        #expect(try repository.eventCount(key: chatty) == 5)
        #expect(try repository.eventCount(key: quiet) == 3)
    }

    @Test("age is measured from when Auspex observed an event, not from its source timestamp")
    func ageIsMeasuredFromObservation() throws {
        let key = Fixtures.key()
        let store = try makeStore(withSessions: [key])
        let repository = SessionRepository(store: store)

        // A week-old transcript line, read just now during a cold-start seed.
        let seeded = AgentEvent(
            session: key,
            timestamp: Fixtures.date(-7 * 86_400),
            observedAt: Fixtures.date(0),
            kind: .note("seeded from history")
        )
        // A line Auspex read a month ago.
        let old = AgentEvent(
            session: key,
            timestamp: Fixtures.date(-30 * 86_400),
            observedAt: Fixtures.date(-30 * 86_400),
            kind: .note("read long ago")
        )
        try repository.insertEvents([seeded, old])

        let job = RetentionJob(store: store, policy: RetentionPolicy(eventsPerSession: 0))
        let report = try job.run(now: Fixtures.date(0))

        #expect(report.eventsOverAgeLimit == 1)
        let remaining = try repository.recentEvents(key: key)
        #expect(remaining.map(\.timestamp) == [Fixtures.date(-7 * 86_400)])
    }

    @Test("retention prunes the search index by age and by excluded harness")
    func retentionPrunesTheSearchIndex() throws {
        let claudeKey = Fixtures.key(.claudeCode, "indexed")
        let cursorKey = Fixtures.key(.cursor, "excluded")
        let store = try AuspexStore(inMemory: true)
        let repository = SessionRepository(store: store)

        try repository.indexMessage(
            session: claudeKey, harness: .claudeCode, role: .user,
            ts: Fixtures.date(-40 * 86_400), content: "an ancient question about resizers"
        )
        try repository.indexMessage(
            session: claudeKey, harness: .claudeCode, role: .user,
            ts: Fixtures.date(-1 * 86_400), content: "a recent question about resizers"
        )
        try repository.indexMessage(
            session: cursorKey, harness: .cursor, role: .user,
            ts: Fixtures.date(-1 * 86_400), content: "a private question about resizers"
        )
        #expect(try repository.search(query: "resizers").count == 3)

        let job = RetentionJob(
            store: store,
            policy: RetentionPolicy(excludedHarnessesForFTS: [.cursor])
        )
        let report = try job.run(now: Fixtures.date(0))

        #expect(report.messagesOverAgeLimit == 1)
        #expect(report.messagesFromExcludedHarnesses == 1)
        let hits = try repository.search(query: "resizers")
        #expect(hits.map(\.session) == [claudeKey])
        #expect(hits.first?.snippet.contains("resizers") == true)
    }

    @Test("an on-disk store is in incremental auto-vacuum mode")
    func onDiskStoreIsIncrementalAutoVacuum() throws {
        let home = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("auspex-retention-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }

        let store = try AuspexStore(paths: AuspexPaths(homeDirectory: home))
        let mode = try store.dbWriter.read { db in
            try Int.fetchOne(db, sql: "PRAGMA auto_vacuum")
        }
        // 2 == incremental. Retention's `PRAGMA incremental_vacuum` is a
        // no-op in any other mode, so this is what makes it real.
        #expect(mode == 2)
    }
}

@Suite("SourceCursorRepository")
struct SourceCursorRepositoryTests {
    @Test("cursors round-trip and merge rather than replace")
    func cursorsRoundTrip() async throws {
        let store = try AuspexStore(inMemory: true)
        let repository = SourceCursorRepository(store: store)

        #expect(try await repository.load().isEmpty)

        let claudePath = "/Users/example/.claude/projects/widget/session.jsonl"
        let cursorPath = "/Users/example/.cursor/chats/widget/store.db"
        try await repository.save(
            [claudePath: .byteOffset(inode: 8_675_309, offset: 4_096)],
            harness: .claudeCode
        )
        try await repository.save([cursorPath: .blobHead("abc123")], harness: .cursor)

        let all = try await repository.load()
        #expect(all.count == 2)
        #expect(all[claudePath] == .byteOffset(inode: 8_675_309, offset: 4_096))
        #expect(all[cursorPath] == .blobHead("abc123"))

        // Saving one harness's cursors must not forget another's.
        #expect(try await repository.load(harness: .claudeCode).keys.sorted() == [claudePath])

        // A later save for the same path replaces just that entry.
        try await repository.save([claudePath: .byteOffset(inode: 8_675_309, offset: 9_000)])
        let updated = try await repository.load()
        #expect(updated[claudePath] == .byteOffset(inode: 8_675_309, offset: 9_000))
        #expect(updated[cursorPath] == .blobHead("abc123"))
        // A save with no harness leaves the recorded one alone.
        #expect(try await repository.load(harness: .claudeCode).count == 1)

        try await repository.remove(paths: [cursorPath])
        #expect(try await repository.load().keys.sorted() == [claudePath])
    }

    @Test("every cursor shape survives the round-trip")
    func everyCursorShapeSurvives() async throws {
        let store = try AuspexStore(inMemory: true)
        let repository = SourceCursorRepository(store: store)

        let cursors: [String: SourceCursor] = [
            "/Users/example/a.jsonl": .byteOffset(inode: 1, offset: 2),
            "/Users/example/b.db": .rowID(42),
            "/Users/example/c": .blobHead("head"),
            "/Users/example/d": .composite([
                "/Users/example/d/1.jsonl": .byteOffset(inode: 3, offset: 4),
                "/Users/example/d/2.jsonl": .rowID(5)
            ])
        ]
        try await repository.save(cursors)
        #expect(try await repository.load() == cursors)
    }

    @Test("an unreadable cursor is skipped rather than resumed from")
    func unreadableCursorIsSkipped() async throws {
        let store = try AuspexStore(inMemory: true)
        let repository = SourceCursorRepository(store: store)

        try await store.dbWriter.write { db in
            try db.execute(sql: """
                INSERT INTO source_cursors (source_path, harness, cursor_json, updated_at)
                VALUES ('/Users/example/corrupt.jsonl', 'claudeCode', '{"fromTheFuture":{}}', 0)
                """)
        }
        // Re-seeding from the head of the source is the safe answer; resuming
        // from a position that could not be decoded is not.
        let loaded = try await repository.load()
        #expect(loaded.isEmpty)
    }
}
