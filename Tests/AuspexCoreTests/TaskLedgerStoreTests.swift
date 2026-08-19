import AgentSessionKit
import AgentSessionLive
import Foundation
import GRDB
import Testing

@testable import AuspexCore

/// A snapshot blob exactly as event schema 1 wrote one: every field the model
/// had then, and no `brief`.
///
/// Written out rather than produced by encoding a `SessionSnapshot`, because
/// the whole point is that this build's encoder can no longer produce it.
/// Synthetic throughout — `/Users/example`, a fixed id, a prompt written for
/// the test.
private let schemaOneSnapshotJSON = """
{"identity":{"key":{"harness":"claudeCode","sessionID":"11111111-2222-3333-4444-555555555555"},\
"sourcePath":"/Users/example/.claude/projects/widget/session.jsonl",\
"cwd":"/Users/example/Code/widget","title":"Fix the widget resizer"},\
"state":{"idle":{}},"isAlive":true,"isStale":false,\
"pending":{"openToolCalls":{},"openChildren":[]},\
"lastEventAt":1767225660,"startedAt":1767225600,\
"turnCount":2,"toolCallCount":5,"tokensIn":100,"tokensOut":20,"tokensCached":0,"children":[]}
"""

@Suite("SnapshotBriefMigration")
struct SnapshotBriefMigrationTests {
    @Test("a schema-1 blob cannot be decoded by this build")
    func schemaOneIsUndecodable() {
        // The premise. If this ever stops being true the migration is dead
        // weight, and a test that quietly passed would not say so.
        let decoded = try? StoreJSON.decode(
            SessionSnapshot.self, from: schemaOneSnapshotJSON, using: StoreJSON.makeDecoder()
        )
        #expect(decoded == nil)
    }

    @Test("adding an empty brief makes it decodable again, unchanged otherwise")
    func addingBriefRescuesIt() throws {
        let patched = try #require(SnapshotBriefMigration.addingBrief(to: schemaOneSnapshotJSON))
        let snapshot = try StoreJSON.decode(
            SessionSnapshot.self, from: patched, using: StoreJSON.makeDecoder()
        )

        #expect(snapshot.brief.isEmpty)
        #expect(snapshot.identity.title == "Fix the widget resizer")
        #expect(snapshot.turnCount == 2)
        #expect(snapshot.toolCallCount == 5)
        #expect(snapshot.tokensIn == 100)
        #expect(snapshot.lastEventAt == Date(timeIntervalSince1970: 1_767_225_660))
    }

    @Test("a blob that already carries a brief is left alone")
    func idempotent() throws {
        let patched = try #require(SnapshotBriefMigration.addingBrief(to: schemaOneSnapshotJSON))
        #expect(SnapshotBriefMigration.addingBrief(to: patched) == nil)
    }

    @Test("something that is not a snapshot object is refused rather than mangled")
    func refusesGarbage() {
        #expect(SnapshotBriefMigration.addingBrief(to: "") == nil)
        #expect(SnapshotBriefMigration.addingBrief(to: "not json") == nil)
        #expect(SnapshotBriefMigration.addingBrief(to: "[1,2,3]") == nil)
    }
}

@Suite("AuspexStore · the task-ledger migration")
struct TaskLedgerMigrationTests {
    /// The real migrator with the debug erase switched off, so a v1 database
    /// can be built, written to, and then migrated — which is the thing under
    /// test and exactly what a person's own store will do on the next launch.
    private func migrator() -> DatabaseMigrator {
        var migrator = AuspexStore.migrator
        migrator.eraseDatabaseOnSchemaChange = false
        return migrator
    }

    private func v1Database() throws -> DatabaseQueue {
        let queue = try DatabaseQueue(configuration: AuspexStore.configuration())
        try migrator().migrate(queue, upTo: "v1_initial")
        return queue
    }

    @Test("a session written under schema 1 survives the upgrade")
    func schemaOneRowSurvives() throws {
        let queue = try v1Database()
        try queue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO sessions
                        (key, harness, session_id, source_path, state, is_alive, is_stale,
                         turn_count, tool_call_count, tokens_in, tokens_out, tokens_cached,
                         last_event_at, snapshot_json)
                    VALUES (?, 'claudeCode', ?, ?, 'idle', 1, 0, 2, 5, 100, 20, 0, ?, ?)
                    """,
                arguments: [
                    Fixtures.key().description,
                    Fixtures.key().sessionID,
                    "/Users/example/.claude/projects/widget/session.jsonl",
                    1_767_225_660.0,
                    schemaOneSnapshotJSON
                ]
            )
        }

        try migrator().migrate(queue)

        let repository = SessionRepository(dbWriter: queue)
        let restored = try repository.fetchAll()
        #expect(restored.count == 1)
        #expect(restored.first?.identity.title == "Fix the widget resizer")
        #expect(restored.first?.brief.isEmpty == true)
        #expect(try repository.undecodableSnapshotCount() == 0)
    }

    @Test("the upgrade stamps the schema it wrote")
    func stampsTheSchemaVersion() throws {
        let queue = try v1Database()
        try migrator().migrate(queue)
        let store = try AuspexStore(dbWriter: queue)
        #expect(store.storedEventSchemaVersion == AgentSessionLive.eventSchemaVersion)
    }

    @Test("a blob nothing can rescue costs one row, not the whole board")
    func undecodableRowIsSkipped() throws {
        let store = try AuspexStore(inMemory: true)
        let repository = store.sessions
        try repository.upsert(snapshot: Fixtures.snapshot())
        try store.dbWriter.write { db in
            try db.execute(
                sql: """
                    INSERT INTO sessions
                        (key, harness, session_id, source_path, state, is_alive, is_stale,
                         turn_count, tool_call_count, tokens_in, tokens_out, tokens_cached,
                         snapshot_json)
                    VALUES ('claudeCode:broken', 'claudeCode', 'broken', '/Users/example/x',
                            'idle', 1, 0, 0, 0, 0, 0, 0, 'not a snapshot')
                    """
            )
        }

        // Bootstrap is the only caller and it runs before the first event:
        // throwing here would trade a whole board for one bad row.
        #expect(try repository.fetchAll().count == 1)
        #expect(try repository.undecodableSnapshotCount() == 1)
        #expect(try repository.sessionCount() == 2)
    }
}

@Suite("SessionRepository · the brief and what has been read")
struct SessionLedgerRepositoryTests {
    private func briefed() -> SessionSnapshot {
        var snapshot = Fixtures.snapshot()
        snapshot.brief = SessionBrief(
            firstPrompt: "Make the resizer stop snapping back",
            firstPromptAt: Fixtures.date(0),
            latestPrompt: "Now cover it with a test",
            lastPromptAt: Fixtures.date(60),
            latestAssistant: "The snap-back was a stale layout pass.",
            lastAssistantAt: Fixtures.date(90),
            lastTurnEndedAt: Fixtures.date(120)
        )
        return snapshot
    }

    @Test("the brief round-trips through the blob and lands in its columns")
    func briefRoundTrips() throws {
        let store = try AuspexStore(inMemory: true)
        let repository = store.sessions
        let snapshot = briefed()
        try repository.upsert(snapshot: snapshot)

        let restored = try #require(try repository.fetch(key: snapshot.key))
        #expect(restored.brief == snapshot.brief)

        // The projection is written from the same value in the same place, so
        // a query can answer "what was this told to do" without the blob.
        let row = try store.dbWriter.read { db in
            try Row.fetchOne(
                db,
                sql: """
                    SELECT first_prompt, latest_prompt, latest_assistant, last_turn_ended_at
                      FROM sessions WHERE key = ?
                    """,
                arguments: [snapshot.key.description]
            )
        }
        let projected = try #require(row)
        #expect(projected["first_prompt"] as String? == "Make the resizer stop snapping back")
        #expect(projected["latest_prompt"] as String? == "Now cover it with a test")
        #expect(projected["latest_assistant"] as String? == "The snap-back was a stale layout pass.")
        #expect(projected["last_turn_ended_at"] as Double? == Fixtures.date(120).timeIntervalSince1970)
    }

    @Test("a session nobody has opened has never been seen")
    func unseenByDefault() throws {
        let repository = try AuspexStore(inMemory: true).sessions
        #expect(try repository.lastSeen(key: Fixtures.key()) == nil)
        #expect(try repository.allLastSeen().isEmpty)
    }

    @Test("opening a session is recorded, and recorded again when reopened")
    func markSeenUpserts() throws {
        let repository = try AuspexStore(inMemory: true).sessions
        try repository.markSeen(key: Fixtures.key(), at: Fixtures.date(10))
        #expect(try repository.lastSeen(key: Fixtures.key()) == Fixtures.date(10))

        try repository.markSeen(key: Fixtures.key(), at: Fixtures.date(50))
        #expect(try repository.lastSeen(key: Fixtures.key()) == Fixtures.date(50))
    }

    @Test("a stamp older than the one on record cannot un-read a session")
    func markSeenIsMonotonic() throws {
        let repository = try AuspexStore(inMemory: true).sessions
        try repository.markSeen(key: Fixtures.key(), at: Fixtures.date(50))
        try repository.markSeen(key: Fixtures.key(), at: Fixtures.date(10))
        #expect(try repository.lastSeen(key: Fixtures.key()) == Fixtures.date(50))
    }

    @Test("a session can be marked seen before its row exists")
    func markSeenNeedsNoSessionRow() throws {
        // A card is clicked the instant it appears, which can be before the
        // flush that writes the session it is about. A foreign key here would
        // turn that click into a thrown error.
        let repository = try AuspexStore(inMemory: true).sessions
        try repository.markSeen(key: Fixtures.key(.codex, "never-stored"), at: Fixtures.date(1))
        #expect(try repository.lastSeen(key: Fixtures.key(.codex, "never-stored"))
            == Fixtures.date(1))
        #expect(try repository.sessionCount() == 0)
    }

    @Test("the whole map comes back keyed by session")
    func allLastSeenRoundTrips() throws {
        let repository = try AuspexStore(inMemory: true).sessions
        try repository.markSeen(key: Fixtures.key(), at: Fixtures.date(10))
        try repository.markSeen(key: Fixtures.key(.codex, "abc"), at: Fixtures.date(20))

        let seen = try repository.allLastSeen()
        #expect(seen.count == 2)
        #expect(seen[Fixtures.key()] == Fixtures.date(10))
        #expect(seen[Fixtures.key(.codex, "abc")] == Fixtures.date(20))
    }

    @Test("what a person has read outlives the session row")
    func seenSurvivesSessionDeletion() throws {
        let store = try AuspexStore(inMemory: true)
        let repository = store.sessions
        try repository.upsert(snapshot: Fixtures.snapshot())
        try repository.markSeen(key: Fixtures.key(), at: Fixtures.date(10))
        try store.dbWriter.write { db in
            try db.execute(sql: "DELETE FROM sessions WHERE key = ?", arguments: [Fixtures.key().description])
        }
        // Retention drops old sessions. A transcript that comes back must not
        // come back marked unread.
        #expect(try repository.lastSeen(key: Fixtures.key()) == Fixtures.date(10))
    }
}
