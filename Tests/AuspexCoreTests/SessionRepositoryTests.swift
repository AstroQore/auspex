import AgentSessionKit
import AgentSessionLive
import Foundation
import GRDB
import Testing

@testable import AuspexCore

@Suite("SessionRepository")
struct SessionRepositoryTests {
    private func makeStore() throws -> AuspexStore {
        try AuspexStore(inMemory: true)
    }

    // MARK: - Sessions

    @Test("a snapshot round-trips, and the projected columns agree with the JSON")
    func snapshotRoundTripsWithAgreeingProjection() throws {
        let store = try makeStore()
        let repository = SessionRepository(store: store)
        let key = Fixtures.key()

        var snapshot = SessionStateReducer.initialSnapshot(identity: Fixtures.identity(key: key))
        snapshot.state = .toolCalling(name: "Bash")
        snapshot.isAlive = true
        snapshot.isStale = true
        snapshot.startedAt = Fixtures.date(0)
        snapshot.lastEventAt = Fixtures.date(30)
        snapshot.turnCount = 3
        snapshot.toolCallCount = 7
        snapshot.tokensIn = 1234
        snapshot.tokensOut = 567
        snapshot.tokensCached = 89

        try repository.upsert(snapshot: snapshot)

        let stored = try #require(try repository.fetch(key: key))
        #expect(stored == snapshot)

        let row = try #require(try store.dbWriter.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM sessions WHERE key = ?", arguments: [key.description])
        })
        #expect(row["harness"] as String? == Harness.claudeCode.rawValue)
        #expect(row["session_id"] as String? == key.sessionID)
        #expect(row["state"] as String? == "toolCalling")
        #expect(row["state_detail"] as String? == "Bash")
        #expect(row["is_alive"] as Bool? == true)
        #expect(row["is_stale"] as Bool? == true)
        #expect(row["turn_count"] as Int? == snapshot.turnCount)
        #expect(row["tool_call_count"] as Int? == snapshot.toolCallCount)
        #expect(row["tokens_in"] as Int? == snapshot.tokensIn)
        #expect(row["tokens_out"] as Int? == snapshot.tokensOut)
        #expect(row["tokens_cached"] as Int? == snapshot.tokensCached)
        #expect(row["cwd"] as String? == snapshot.identity.cwd)
        #expect(row["title"] as String? == snapshot.identity.title)
        #expect(row["model"] as String? == snapshot.identity.model)
        #expect(row["git_branch"] as String? == snapshot.identity.gitBranch)
        #expect(row["source_path"] as String? == snapshot.identity.sourcePath)
        #expect(row["pid"] as Int64? == 4242)
        // No parent, so the session is its own root.
        #expect(row["root_key"] as String? == key.description)
        #expect(row["last_event_at"] as Double? == snapshot.lastEventAt?.timeIntervalSince1970)
    }

    @Test("upserting the same key twice updates rather than duplicates")
    func upsertUpdatesInPlace() throws {
        let store = try makeStore()
        let repository = SessionRepository(store: store)
        let key = Fixtures.key()

        var snapshot = SessionStateReducer.initialSnapshot(identity: Fixtures.identity(key: key))
        try repository.upsert(snapshot: snapshot)

        snapshot.state = .waitingPermission(tool: "Write")
        snapshot.turnCount = 9
        try repository.upsert(snapshot: snapshot)

        #expect(try repository.sessionCount() == 1)
        let stored = try #require(try repository.fetch(key: key))
        #expect(stored.state == .waitingPermission(tool: "Write"))
        #expect(stored.turnCount == 9)
    }

    @Test("fetchAll(activeOnly:) hides ended sessions and sorts by recency")
    func fetchAllFiltersAndSorts() throws {
        let store = try makeStore()
        let repository = SessionRepository(store: store)

        let liveKey = Fixtures.key(.claudeCode, "live-session")
        let staleKey = Fixtures.key(.codex, "older-session")
        let endedKey = Fixtures.key(.grokBuild, "ended-session")

        var live = SessionStateReducer.initialSnapshot(identity: Fixtures.identity(key: liveKey))
        live.state = .thinking
        live.lastEventAt = Fixtures.date(100)

        var older = SessionStateReducer.initialSnapshot(identity: Fixtures.identity(key: staleKey))
        older.state = .idle
        older.lastEventAt = Fixtures.date(50)

        var ended = SessionStateReducer.initialSnapshot(identity: Fixtures.identity(key: endedKey))
        ended.state = .ended(reason: .exited)
        ended.isAlive = false
        ended.lastEventAt = Fixtures.date(200)

        try repository.upsert(snapshots: [live, older, ended])

        let all = try repository.fetchAll()
        #expect(all.map(\.key) == [endedKey, liveKey, staleKey])

        let active = try repository.fetchAll(activeOnly: true)
        #expect(active.map(\.key) == [liveKey, staleKey])

        let limited = try repository.fetchAll(limit: 1)
        #expect(limited.map(\.key) == [endedKey])
    }

    // MARK: - Events

    @Test("a batch of events inserts in one transaction and reads back in order")
    func eventsInsertAndReadBackInOrder() throws {
        let store = try makeStore()
        let repository = SessionRepository(store: store)
        let key = Fixtures.key()
        let script = Fixtures.oneTurnScript(key: key)

        try repository.upsert(
            snapshot: SessionStateReducer.initialSnapshot(identity: Fixtures.identity(key: key))
        )
        #expect(try repository.insertEvents(script) == script.count)
        #expect(try repository.eventCount(key: key) == script.count)

        let stored = try repository.recentEvents(key: key)
        #expect(stored.map(\.kindLabel) == script.map(\.kind.columnValue))
        #expect(stored.map(\.timestamp) == script.map(\.timestamp))
        // Row ids are ascending, which is what makes the window "the newest N".
        #expect(stored.map(\.id) == stored.map(\.id).sorted())

        // The payload round-trips, so a trace view gets the event back rather
        // than just its label.
        let toolStart = try #require(stored.first { $0.kindLabel == "toolCallStarted" })
        #expect(toolStart.toolCallID == "call-1")
        #expect(toolStart.toolName == "Bash")
        #expect(toolStart.rawPath == "/Users/example/.claude/projects/widget/t.jsonl")
        #expect(toolStart.rawOffset == 2048)
        guard case .toolCallStarted(let id, let name, let kind, let target) = try #require(toolStart.kind) else {
            Issue.record("decoded kind was not toolCallStarted")
            return
        }
        #expect(id == "call-1")
        #expect(name == "Bash")
        #expect(kind == .shell)
        #expect(target == "swift build")
    }

    @Test("recentEvents takes the newest window but returns it oldest-first")
    func recentEventsTakesNewestWindow() throws {
        let store = try makeStore()
        let repository = SessionRepository(store: store)
        let key = Fixtures.key()
        try repository.upsert(
            snapshot: SessionStateReducer.initialSnapshot(identity: Fixtures.identity(key: key))
        )

        let events = (0..<10).map { index in
            Fixtures.event(.note("step-\(index)"), key: key, at: TimeInterval(index))
        }
        try repository.insertEvents(events)

        let window = try repository.recentEvents(key: key, limit: 3)
        #expect(window.count == 3)
        #expect(window.map(\.timestamp) == [
            Fixtures.date(7), Fixtures.date(8), Fixtures.date(9)
        ])
        #expect(try repository.recentEvents(key: key, limit: 0).isEmpty)
    }

    // MARK: - Tool calls

    @Test("a tool call is recorded on start and closed on finish without losing its name")
    func toolCallStartAndFinish() throws {
        let store = try makeStore()
        let repository = SessionRepository(store: store)
        let key = Fixtures.key()
        try repository.upsert(
            snapshot: SessionStateReducer.initialSnapshot(identity: Fixtures.identity(key: key))
        )

        try repository.upsertToolCall(
            sessionKey: key,
            callID: "call-1",
            name: "Write",
            kind: .fileWrite,
            target: "/Users/example/Code/widget/Resizer.swift",
            startedAt: Fixtures.date(2)
        )
        try repository.finishToolCall(
            sessionKey: key,
            callID: "call-1",
            fallbackName: "call-1",
            endedAt: Fixtures.date(5),
            isError: true
        )

        let calls = try repository.toolCalls(key: key)
        #expect(calls.count == 1)
        let call = try #require(calls.first)
        #expect(call.name == "Write")
        #expect(call.kind == .fileWrite)
        #expect(call.target == "/Users/example/Code/widget/Resizer.swift")
        #expect(call.isError == true)
        #expect(call.duration == 3)
    }

    // MARK: - Full-text search

    @Test("trigram search finds a CJK substring and an identifier substring")
    func searchFindsSubstrings() throws {
        let store = try makeStore()
        let repository = SessionRepository(store: store)
        let claudeKey = Fixtures.key(.claudeCode, "search-a")
        let codexKey = Fixtures.key(.codex, "search-b")

        try repository.indexMessage(
            session: claudeKey,
            harness: .claudeCode,
            role: .user,
            ts: Fixtures.date(0),
            content: "请帮我排查 SessionRegistry 里的竞态问题，顺便补一个回归测试"
        )
        try repository.indexMessage(
            session: codexKey,
            harness: .codex,
            role: .assistant,
            ts: Fixtures.date(1),
            content: "Refactored makeBoardSnapshot() so the sort is stable across frames."
        )

        // A word tokenizer would find neither of these: there are no spaces in
        // the Chinese phrase, and `Snapshot` is glued to `makeBoard`.
        let cjk = try repository.search(query: "竞态问")
        #expect(cjk.map(\.session) == [claudeKey])
        #expect(cjk.first?.role == .user)
        #expect(cjk.first?.snippet.contains("竞态问") == true)

        let identifier = try repository.search(query: "BoardSnap")
        #expect(identifier.map(\.session) == [codexKey])
        #expect(identifier.first?.harness == .codex)

        // Trigram matching is case-insensitive for ASCII.
        #expect(try repository.search(query: "boardsnap").count == 1)
    }

    @Test("search filters by harness, guards short queries, and does not obey operators")
    func searchFiltersAndEscapes() throws {
        let store = try makeStore()
        let repository = SessionRepository(store: store)
        let claudeKey = Fixtures.key(.claudeCode, "search-a")
        let codexKey = Fixtures.key(.codex, "search-b")

        for (key, harness) in [(claudeKey, Harness.claudeCode), (codexKey, Harness.codex)] {
            try repository.indexMessage(
                session: key,
                harness: harness,
                role: .user,
                ts: Fixtures.date(0),
                content: "resizer snapping back on drag"
            )
        }

        #expect(try repository.search(query: "resizer").count == 2)
        #expect(try repository.search(query: "resizer", harnesses: [.codex]).map(\.session) == [codexKey])

        // Below the trigram minimum: answered without touching the database.
        #expect(try repository.search(query: "re").isEmpty)
        // MATCH operators are searched for, not obeyed. `NOT` would be an
        // operator to FTS5 and a plain word to a person.
        #expect(try repository.search(query: "drag NOT resizer").isEmpty)
        #expect(try repository.search(query: "snapping back").count == 2)
    }

    @Test("deleting a message removes it from the index")
    func deletingMessageUpdatesIndex() throws {
        let store = try makeStore()
        let repository = SessionRepository(store: store)
        try repository.indexMessage(
            session: Fixtures.key(),
            harness: .claudeCode,
            role: .user,
            ts: Fixtures.date(0),
            content: "the resizer snaps back"
        )
        #expect(try repository.search(query: "resizer").count == 1)

        try store.dbWriter.write { db in
            try db.execute(sql: "DELETE FROM messages")
        }
        #expect(try repository.search(query: "resizer").isEmpty)
    }
}
