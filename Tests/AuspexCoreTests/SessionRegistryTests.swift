import AgentSessionKit
import AgentSessionLive
import Foundation
import Testing

@testable import AuspexCore

@Suite("BoardSnapshot")
struct BoardSnapshotTests {
    private func snapshot(
        _ key: SessionKey,
        state: SessionState,
        isAlive: Bool = true,
        lastEventAt: TimeInterval,
        cwd: String? = "/Users/example/Code/widget",
        gitRoot: String? = nil
    ) -> SessionSnapshot {
        var snapshot = SessionStateReducer.initialSnapshot(
            identity: Fixtures.identity(key: key, cwd: cwd, gitRoot: gitRoot)
        )
        snapshot.state = state
        snapshot.isAlive = isAlive
        snapshot.lastEventAt = Fixtures.date(lastEventAt)
        return snapshot
    }

    @Test("alive sessions sort first, then by what most needs a person")
    func sortOrder() {
        let waiting = Fixtures.key(.claudeCode, "waiting")
        let tooling = Fixtures.key(.codex, "tooling")
        let idle = Fixtures.key(.grokBuild, "idle")
        let deadButBusy = Fixtures.key(.cursor, "dead")

        let board = BoardSnapshot(generatedAt: Fixtures.date(0), sessions: [
            snapshot(idle, state: .idle, lastEventAt: 90),
            // Ended, but in a state that would otherwise out-rank everything.
            snapshot(deadButBusy, state: .waitingPermission(tool: "Write"), isAlive: false, lastEventAt: 99),
            snapshot(tooling, state: .toolCalling(name: "Bash"), lastEventAt: 10),
            snapshot(waiting, state: .waitingPermission(tool: "Write"), lastEventAt: 5)
        ])

        #expect(board.sessions.map(\.key) == [waiting, tooling, idle, deadButBusy])
    }

    @Test("ties break on recency and then on the key, so frames do not shuffle")
    func tiesAreStable() {
        let first = Fixtures.key(.claudeCode, "aaa")
        let second = Fixtures.key(.claudeCode, "bbb")
        let newer = Fixtures.key(.claudeCode, "ccc")

        let sessions = [
            snapshot(second, state: .thinking, lastEventAt: 10),
            snapshot(newer, state: .thinking, lastEventAt: 20),
            snapshot(first, state: .thinking, lastEventAt: 10)
        ]
        let board = BoardSnapshot(generatedAt: Fixtures.date(0), sessions: sessions)
        #expect(board.sessions.map(\.key) == [newer, first, second])
        // Same input in a different order produces the same frame.
        let shuffled = BoardSnapshot(generatedAt: Fixtures.date(0), sessions: sessions.reversed())
        #expect(shuffled.sessions.map(\.key) == board.sessions.map(\.key))
    }

    @Test("counts tally each state, with tool calls and file writes together")
    func counts() {
        let board = BoardSnapshot(generatedAt: Fixtures.date(0), sessions: [
            snapshot(Fixtures.key(.claudeCode, "a"), state: .thinking, lastEventAt: 1),
            snapshot(Fixtures.key(.claudeCode, "b"), state: .toolCalling(name: "Bash"), lastEventAt: 2),
            snapshot(Fixtures.key(.claudeCode, "c"), state: .writingFile(path: "/Users/example/x.swift"), lastEventAt: 3),
            snapshot(Fixtures.key(.codex, "d"), state: .delegating(children: 2), lastEventAt: 4),
            snapshot(Fixtures.key(.codex, "e"), state: .waitingPermission(tool: nil), lastEventAt: 5),
            snapshot(Fixtures.key(.codex, "f"), state: .idle, lastEventAt: 6),
            snapshot(Fixtures.key(.cursor, "g"), state: .ended(reason: .exited), isAlive: false, lastEventAt: 7)
        ])

        #expect(board.counts == BoardSnapshot.Counts(
            live: 6,
            thinking: 1,
            tooling: 2,
            delegating: 1,
            waitingPermission: 1,
            idle: 1,
            ended: 1
        ))
    }

    @Test("grouping prefers the git root, falls back to the cwd, and never invents one")
    func grouping() {
        let repoA = Fixtures.key(.claudeCode, "a")
        let repoAWorktree = Fixtures.key(.codex, "b")
        let looseCwd = Fixtures.key(.grokBuild, "c")
        let nowhere = Fixtures.key(.cursor, "d")

        let board = BoardSnapshot(generatedAt: Fixtures.date(0), sessions: [
            snapshot(repoA, state: .thinking, lastEventAt: 1,
                     cwd: "/Users/example/Code/widget", gitRoot: "/Users/example/Code/widget"),
            // A different worktree of the same repository must not look like a
            // second project.
            snapshot(repoAWorktree, state: .thinking, lastEventAt: 2,
                     cwd: "/Users/example/Code/widget/.agents/worktrees/feat-x",
                     gitRoot: "/Users/example/Code/widget"),
            snapshot(looseCwd, state: .thinking, lastEventAt: 3,
                     cwd: "/Users/example/scratch", gitRoot: nil),
            snapshot(nowhere, state: .thinking, lastEventAt: 4, cwd: nil, gitRoot: nil)
        ])

        #expect(board.byProject["/Users/example/Code/widget"]?.count == 2)
        #expect(board.byProject["/Users/example/scratch"]?.map(\.key) == [looseCwd])
        #expect(board.byProject.count == 2)
        #expect(board.ungroupedSessions.map(\.key) == [nowhere])

        #expect(board.byHarness[.claudeCode]?.map(\.key) == [repoA])
        #expect(board.byHarness.keys.count == 4)
        #expect(board.session(for: looseCwd)?.key == looseCwd)
        #expect(board.session(for: Fixtures.key(.codex, "missing")) == nil)
    }

    @Test("an empty board has zero counts")
    func emptyBoard() {
        #expect(BoardSnapshot.empty.sessions.isEmpty)
        #expect(BoardSnapshot.empty.counts == BoardSnapshot.Counts())
    }
}

@Suite("SessionRegistry")
struct SessionRegistryTests {
    /// A registry with every valve wide open, so one event produces one frame
    /// and one commit — which is what makes a scripted sequence assertable.
    private func makeRegistry(store: AuspexStore) -> SessionRegistry {
        SessionRegistry(
            store: store,
            publishInterval: 0,
            persistInterval: 0,
            tickInterval: 0
        )
    }

    @Test("a scripted turn drives the board through the reducer's states")
    func scriptedTurnPublishesStatesInOrder() async throws {
        let store = try AuspexStore(inMemory: true)
        let registry = makeRegistry(store: store)
        let key = Fixtures.key()

        // Start collecting before the first event: the stream buffers, so no
        // frame is lost, but the consumer must outlive the producer.
        let collector = Task {
            var states: [SessionState] = []
            for await board in registry.boardSnapshots {
                if let session = board.session(for: key) { states.append(session.state) }
            }
            return states
        }

        let (events, continuation) = AsyncStream<AgentEvent>.makeStream()
        let run = Task { await registry.run(events: events) }
        for event in Fixtures.oneTurnScript(key: key) {
            continuation.yield(event)
        }
        continuation.finish()
        await run.value

        let states = await collector.value
        #expect(Fixtures.collapsingRuns(states) == Fixtures.oneTurnStates)

        // The board's final word matches the last frame.
        let final = await registry.snapshot()
        #expect(final.session(for: key)?.state == .ended(reason: .exited))
        #expect(final.counts.ended == 1)
        #expect(final.counts.live == 0)
    }

    @Test("everything the script produced is durable when the stream ends")
    func scriptedTurnIsPersisted() async throws {
        let store = try AuspexStore(inMemory: true)
        let registry = makeRegistry(store: store)
        let repository = SessionRepository(store: store)
        let key = Fixtures.key()
        let script = Fixtures.oneTurnScript(key: key)

        let (events, continuation) = AsyncStream<AgentEvent>.makeStream()
        let run = Task { await registry.run(events: events) }
        for event in script { continuation.yield(event) }
        continuation.finish()
        await run.value

        #expect(await registry.persistFailureCount == 0)

        let stored = try repository.recentEvents(key: key)
        #expect(stored.map(\.kindLabel) == script.map(\.kind.columnValue))

        let session = try #require(try repository.fetch(key: key))
        #expect(session.state == .ended(reason: .exited))
        #expect(session.turnCount == 1)
        #expect(session.toolCallCount == 1)
        // The identity from `sessionStarted` made it onto the row.
        #expect(session.identity.title == "Fix the widget resizer")

        // The tool-call ledger has the pair collapsed into one row with a
        // duration, and the finish did not overwrite the name.
        let calls = try repository.toolCalls(key: key)
        #expect(calls.map(\.callID) == ["call-1"])
        #expect(calls.first?.name == "Bash")
        #expect(calls.first?.kind == .shell)
        #expect(calls.first?.isError == false)
        #expect(calls.first?.duration == 1)

        // The prompt is searchable across harnesses.
        let hits = try repository.search(query: "snapping")
        #expect(hits.map(\.session) == [key])
        #expect(hits.first?.role == .user)
    }

    @Test("a second registry over the same store starts from what the first left")
    func bootstrapFromDatabase() async throws {
        let store = try AuspexStore(inMemory: true)
        let key = Fixtures.key()

        let first = makeRegistry(store: store)
        for event in Fixtures.oneTurnScript(key: key).prefix(4) {
            await first.ingest(event)
        }
        await first.stop()

        // A relaunch: new registry, same database, no events yet.
        let second = makeRegistry(store: store)
        try await second.bootstrap()

        let board = await second.snapshot()
        let restored = try #require(board.session(for: key))
        #expect(restored.state == .thinking)
        #expect(restored.identity.title == "Fix the widget resizer")
        #expect(restored.toolCallCount == 1)

        // And it keeps reducing from there rather than starting over.
        await second.ingest(Fixtures.event(.turnEnded(reason: .complete), key: key, at: 4))
        #expect(await second.session(for: key)?.state == .idle)
        #expect(await second.session(for: key)?.turnCount == 1)
    }

    @Test("bootstrap does not overwrite a session the live set already has")
    func bootstrapYieldsToLiveState() async throws {
        let store = try AuspexStore(inMemory: true)
        let key = Fixtures.key()

        let first = makeRegistry(store: store)
        await first.ingest(Fixtures.event(
            .sessionStarted(identity: Fixtures.identity(key: key)), key: key, at: 0
        ))
        await first.stop()

        let second = makeRegistry(store: store)
        await second.ingest(Fixtures.event(.userPrompt(preview: "go on"), key: key, at: 10))
        try await second.bootstrap()
        #expect(await second.session(for: key)?.state == .thinking)
    }

    @Test("an event for an unseen session seeds an identity rather than dropping it")
    func unseenSessionIsSeededFromTheEvent() async throws {
        let store = try AuspexStore(inMemory: true)
        let registry = makeRegistry(store: store)
        let key = Fixtures.key(.codex, "mid-transcript")
        let sourcePath = "/Users/example/.codex/sessions/2026/rollout.jsonl"

        // Tailing usually begins mid-session: no `sessionStarted` ever arrives.
        await registry.ingest(Fixtures.event(
            .assistantText(preview: "picking up where the log was"),
            key: key,
            at: 0,
            raw: RawRef(path: sourcePath, byteOffset: 1_024)
        ))
        await registry.stop()

        let session = try #require(await registry.session(for: key))
        #expect(session.identity.sourcePath == sourcePath)
        #expect(session.state == .thinking)
        // Nothing is invented: an unobserved cwd stays empty.
        #expect(session.identity.cwd == nil)
        #expect(try SessionRepository(store: store).fetch(key: key)?.identity.sourcePath == sourcePath)
    }

    @Test("tick flips staleness on a quiet working session and publishes once")
    func tickMarksStaleSessions() async throws {
        let store = try AuspexStore(inMemory: true)
        let registry = SessionRegistry(
            store: store,
            reducer: SessionStateReducer(staleAfter: 90),
            publishInterval: 0,
            persistInterval: 0,
            tickInterval: 0
        )
        let key = Fixtures.key()

        await registry.ingest(Fixtures.event(
            .sessionStarted(identity: Fixtures.identity(key: key)), key: key, at: 0
        ))
        await registry.ingest(Fixtures.event(
            .toolCallStarted(id: "call-1", name: "Bash", kind: .shell, target: "swift build"),
            key: key,
            at: 1
        ))
        #expect(await registry.session(for: key)?.isStale == false)

        // Inside the window: nothing changes.
        await registry.tick(now: Fixtures.date(60))
        #expect(await registry.session(for: key)?.isStale == false)

        // Past it: the row is flagged, but the state is untouched. A long
        // `swift build` is quiet, not finished.
        await registry.tick(now: Fixtures.date(200))
        let stale = try #require(await registry.session(for: key))
        #expect(stale.isStale)
        #expect(stale.state == .toolCalling(name: "Bash"))

        await registry.stop()
        #expect(try SessionRepository(store: store).fetch(key: key)?.isStale == true)
    }

    @Test("a burst is coalesced into fewer frames than events")
    func publishingIsCoalesced() async throws {
        let store = try AuspexStore(inMemory: true)
        // 50 ms between frames: a whole turn flushed at once must not produce
        // one frame per line.
        let registry = SessionRegistry(
            store: store,
            publishInterval: 0.05,
            persistInterval: 0,
            tickInterval: 0
        )
        let key = Fixtures.key()

        let collector = Task {
            var frames = 0
            for await _ in registry.boardSnapshots { frames += 1 }
            return frames
        }

        for index in 0..<50 {
            await registry.ingest(Fixtures.event(.note("burst-\(index)"), key: key, at: TimeInterval(index)))
        }
        await registry.stop()

        let frames = await collector.value
        #expect(frames > 0)
        #expect(frames < 50)
    }
}
