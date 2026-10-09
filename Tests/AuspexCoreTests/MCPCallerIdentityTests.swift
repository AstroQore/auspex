import AgentSessionKit
import AgentSessionLive
import Foundation
import GRDB
import Testing

@testable import AuspexCore

/// Who is calling when the process tree alone cannot say.
///
/// Three mechanisms, each with the failure it exists to prevent:
///
/// - a hook teaches a pid-less session its process, so the next MCP call from
///   it resolves on its own;
/// - a self-reported `session_id` is accepted only for a live session of the
///   harness the connection descends from;
/// - the walk stops at the caller's own harness, so a worker another harness
///   launched is never filed under the session that launched it.
///
/// Every process, path and id is fabricated.
@Suite("MCP caller identity")
struct MCPCallerIdentityTests {
    private static let codexKey = Fixtures.key(.codex, "0199c0de-0000-7000-8000-0000000000c1")
    private static let claudeKey = Fixtures.key(.claudeCode, "aaaa1111-2222-3333-4444-555555555555")
    private static let cursorKey = Fixtures.key(.cursor, "c0ffee00-1111-2222-3333-444444444444")
    private static let grokKey = Fixtures.key(.grokBuild, "9f0e8d7c-6b5a-4938-2716-05f4e3d2c1b0")

    private static let codexPID: pid_t = 800
    private static let bridgePID: pid_t = 801
    private static let bridgePath = "/Applications/Auspex.app/Contents/MacOS/Auspex"

    // MARK: - Fixtures

    private func session(
        _ key: SessionKey,
        pid: pid_t? = nil,
        isAlive: Bool = true,
        state: SessionState = .thinking
    ) -> SessionSnapshot {
        var snapshot = SessionStateReducer.initialSnapshot(
            identity: Fixtures.identity(key: key, pid: pid)
        )
        snapshot.state = state
        snapshot.isAlive = isAlive
        snapshot.startedAt = Fixtures.date(0)
        snapshot.lastEventAt = Fixtures.date(60)
        return snapshot
    }

    private func board(_ sessions: SessionSnapshot...) -> BoardSnapshot {
        BoardSnapshot(generatedAt: Fixtures.date(60), sessions: sessions)
    }

    private func process(
        _ pid: pid_t,
        parent: pid_t,
        _ path: String,
        startedAt offset: TimeInterval = -30
    ) -> ProcessRecord {
        ProcessRecord(
            pid: pid, ppid: parent, startTime: Fixtures.date(offset), executablePath: path, argv: []
        )
    }

    /// A bridge directly below a terminal `codex`.
    private func codexCLITable() -> FakeProcessTable {
        FakeProcessTable(records: [
            process(Self.bridgePID, parent: Self.codexPID, Self.bridgePath),
            process(Self.codexPID, parent: 700, "/usr/local/bin/codex"),
            process(700, parent: 1, "/bin/zsh")
        ])
    }

    /// A bridge below a Codex thread server that a desktop app started — one
    /// process for every thread the app has open.
    private func threadServerTable() -> FakeProcessTable {
        var table = FakeProcessTable(records: [
            process(Self.bridgePID, parent: Self.codexPID, Self.bridgePath),
            process(Self.codexPID, parent: 1, "/Applications/Example.app/Contents/Resources/codex")
        ])
        table.environments[Self.codexPID] = [
            HarnessProcess.hostedOriginatorVariable: "Example Desktop",
            "PATH": "/usr/bin"
        ]
        return table
    }

    private func makeServer(
        board: BoardSnapshot,
        table: FakeProcessTable,
        clientPIDs: [pid_t] = [bridgePID]
    ) throws -> (AuspexMCPServer, TestMCPHost, AuspexStore) {
        let store = try AuspexStore(inMemory: true)
        let host = TestMCPHost(board: board, store: store, table: table, clientPIDs: clientPIDs)
        return (AuspexMCPServer(host: host, now: { Fixtures.date(100) }), host, store)
    }

    private func hookLine(_ target: HookTarget, _ payload: [String: MCPJSON], pid: pid_t) -> Data {
        Data(HookEvent(
            target: target, pid: pid, receivedAt: Fixtures.date(90), payload: .object(payload)
        ).line().dropLast())
    }

    private func learnedPatches(_ events: [AgentEvent]) -> [(SessionKey, SessionIdentityPatch)] {
        events.compactMap { event in
            guard case let .identityUpdated(patch) = event.kind, patch.pid != nil else { return nil }
            return (event.session, patch)
        }
    }

    // MARK: - 1. A hook teaches a session its process

    @Test("a Codex hook run by codex teaches the row its pid, and the store keeps it")
    func codexHookTeachesAndPersistsPID() async throws {
        let table = codexCLITable()
        let (server, host, _) = try makeServer(
            board: board(session(Self.codexKey, pid: nil)), table: table
        )

        // `Auspex --hook codex`, whose parent is the codex process itself.
        _ = await server.answer(line: hookLine(.codex, [
            "hook_event_name": "SessionStart",
            "session_id": .string(Self.codexKey.sessionID),
            "transcript_path": "/Users/example/.codex/sessions/rollout.jsonl"
        ], pid: Self.codexPID))

        let observed = await host.observed
        let learned = learnedPatches(observed)
        #expect(learned.count == 1)
        #expect(learned.first?.0 == Self.codexKey)
        #expect(learned.first?.1.pid == Self.codexPID)
        #expect(learned.first?.1.procStart == Fixtures.date(-30), "the start time pins the process")
        #expect(observed.contains { $0.kind == .liveness(alive: true) }, "the hook's own event still lands")

        // Folded by the registry the way the app folds hook events, and
        // written to the `sessions.pid` column.
        let store = try AuspexStore(inMemory: true)
        let registry = SessionRegistry(
            store: store, publishInterval: 0, persistInterval: 0, tickInterval: 0
        )
        var seed = Fixtures.identity(key: Self.codexKey, pid: nil)
        seed.procStart = nil
        await registry.ingest(Fixtures.event(.sessionStarted(identity: seed), key: Self.codexKey, at: 0))
        for event in observed { await registry.ingest(event) }
        await registry.stop()

        let columns = try await store.dbWriter.read { db -> (pid: Int64?, start: Double?) in
            let row = try Row.fetchOne(
                db, sql: "SELECT pid, proc_start FROM sessions WHERE key = ?",
                arguments: [Self.codexKey.description]
            )
            return (row?["pid"], row?["proc_start"])
        }
        #expect(columns.pid == Int64(Self.codexPID))
        #expect(columns.start == Fixtures.date(-30).timeIntervalSince1970)
        #expect(try SessionRepository(store: store).fetch(key: Self.codexKey)?.identity.pid == Self.codexPID)
    }

    @Test("each harness's hook learns from its own program, and only from it")
    func everyHarnessLearnsFromItsOwnProgram() async throws {
        struct Case {
            let target: HookTarget
            let key: SessionKey
            let path: String
            let payload: [String: MCPJSON]
        }
        let cases = [
            Case(
                target: .claude, key: Self.claudeKey,
                path: "/Users/example/.local/share/claude/versions/2.1.0",
                payload: ["hook_event_name": "Stop", "session_id": .string(Self.claudeKey.sessionID)]
            ),
            Case(
                target: .codexNotify, key: Self.codexKey,
                path: "/usr/local/bin/codex",
                payload: ["type": "agent-turn-complete", "thread-id": .string(Self.codexKey.sessionID)]
            ),
            Case(
                target: .cursor, key: Self.cursorKey,
                path: "/Users/example/.local/share/cursor-agent/versions/2026.01.01-abc123/node",
                payload: ["hook_event_name": "stop", "conversation_id": .string(Self.cursorKey.sessionID)]
            ),
            Case(
                target: .grok, key: Self.grokKey,
                path: "/Users/example/.grok/downloads/grok-1.0.0-macos-aarch64",
                payload: ["hook_event_name": "Stop", "session_id": .string(Self.grokKey.sessionID)]
            )
        ]
        for item in cases {
            let harness: pid_t = 600
            let learning = FakeProcessTable(records: [process(harness, parent: 1, item.path)])
            let (server, host, _) = try makeServer(
                board: board(session(item.key, pid: nil)), table: learning, clientPIDs: []
            )
            _ = await server.answer(line: hookLine(item.target, item.payload, pid: harness))
            let learned = learnedPatches(await host.observed)
            #expect(learned.map(\.0) == [item.key], "\(item.target)")
            #expect(learned.first?.1.pid == harness, "\(item.target)")

            // The same hook run through a process that is not that harness —
            // a wrapper shell, or a different harness altogether — teaches
            // nothing, though the event itself is still delivered.
            for impostor in ["/bin/bash", "/usr/local/bin/agy"] {
                let wrapped = FakeProcessTable(records: [process(harness, parent: 1, impostor)])
                let (other, otherHost, _) = try makeServer(
                    board: board(session(item.key, pid: nil)), table: wrapped, clientPIDs: []
                )
                _ = await other.answer(line: hookLine(item.target, item.payload, pid: harness))
                let observed = await otherHost.observed
                #expect(learnedPatches(observed).isEmpty, "\(item.target) via \(impostor)")
                #expect(!observed.isEmpty, "\(item.target) via \(impostor)")
            }
        }
    }

    @Test("a hook learns nothing from a thread server, a known pid, or a pid-resolved row")
    func hookLearningBounds() async throws {
        // A thread server's pid identifies none of its threads.
        let (hosted, hostedHost, _) = try makeServer(
            board: board(session(Self.codexKey, pid: nil)), table: threadServerTable()
        )
        _ = await hosted.answer(line: hookLine(.codex, [
            "hook_event_name": "Stop", "session_id": .string(Self.codexKey.sessionID)
        ], pid: Self.codexPID))
        #expect(learnedPatches(await hostedHost.observed).isEmpty)
        #expect(!(await hostedHost.observed).isEmpty)

        // A pid the row already has is never replaced.
        let (known, knownHost, _) = try makeServer(
            board: board(session(Self.codexKey, pid: 4_444)), table: codexCLITable()
        )
        _ = await known.answer(line: hookLine(.codex, [
            "hook_event_name": "Stop", "session_id": .string(Self.codexKey.sessionID)
        ], pid: Self.codexPID))
        #expect(learnedPatches(await knownHost.observed).isEmpty)

        // A payload with no session id is attributed by pid, and a pid cannot
        // teach itself.
        let (circular, circularHost, _) = try makeServer(
            board: board(session(Self.codexKey, pid: Self.codexPID)), table: codexCLITable()
        )
        _ = await circular.answer(line: hookLine(.codexNotify, [
            "type": "agent-turn-complete"
        ], pid: Self.codexPID))
        let observed = await circularHost.observed
        #expect(observed.map(\.session) == [Self.codexKey])
        #expect(learnedPatches(observed).isEmpty)
    }

    @Test("once a hook taught the pid, the session's own MCP calls resolve without help")
    func learnedPIDAttributesTheNextCall() async throws {
        let (server, host, store) = try makeServer(
            board: board(session(Self.codexKey, pid: nil)), table: codexCLITable()
        )
        let task = try TaskRepository(store: store).createTask(title: "Wire the identity")
        let before = try RPC.failureText(await server.answer(line: RPC.call("tasks.claim", [
            "task_id": .int(task.id), "role": "implementer"
        ])))
        #expect(before.contains("process-attributed session"))

        _ = await server.answer(line: hookLine(.codex, [
            "hook_event_name": "SessionStart", "session_id": .string(Self.codexKey.sessionID)
        ], pid: Self.codexPID))
        var snapshot = try #require(await host.boardSnapshot().session(for: Self.codexKey))
        for event in await host.observed { snapshot = SessionStateReducer().reduce(snapshot, event: event) }
        await host.setBoard(board(snapshot))

        let claimed = try RPC.structured(await server.answer(line: RPC.call("tasks.claim", [
            "task_id": .int(task.id), "role": "implementer"
        ])))
        #expect(claimed["claimedBy"]?.stringValue == Self.codexKey.description)
    }

    // MARK: - 2. A bounded self-report

    @Test("a live session of the connection's own harness may name itself")
    func selfReportAccepted() async throws {
        let (server, _, store) = try makeServer(
            board: board(session(Self.codexKey, pid: nil)), table: threadServerTable()
        )

        // Unaided, the thread server cannot say which thread is calling.
        let unresolved = try RPC.structured(await server.answer(line: RPC.call("sessions.self")))
        #expect(unresolved["resolved"]?.boolValue == false)
        #expect(unresolved["evidence"]?.stringValue?.contains("hosts many sessions at once") == true)

        let confirmed = try RPC.structured(await server.answer(line: RPC.call("sessions.self", [
            "session_id": .string(Self.codexKey.sessionID)
        ])))
        #expect(confirmed["resolved"]?.boolValue == true)
        #expect(confirmed["session"]?["key"]?.stringValue == Self.codexKey.description)
        let evidence = try #require(confirmed["evidence"]?.stringValue)
        #expect(evidence.hasPrefix("self-reported, harness-corroborated by codex"))

        let task = try TaskRepository(store: store).createTask(title: "Thread-server work")
        let claimed = try RPC.structured(await server.answer(line: RPC.call("tasks.claim", [
            "task_id": .int(task.id), "role": "implementer",
            "session_id": .string(Self.codexKey.description)
        ])))
        #expect(claimed["claimOutcome"]?.stringValue == "claimed")
        #expect(try TaskRepository(store: store).task(id: task.id)?.claimedBy == Self.codexKey)
    }

    @Test("a self-report naming another harness's session is refused")
    func selfReportAcrossHarnessesRefused() async throws {
        let (server, _, store) = try makeServer(
            board: board(session(Self.codexKey, pid: nil), session(Self.claudeKey, pid: nil)),
            table: threadServerTable()
        )
        let task = try TaskRepository(store: store).createTask(title: "Not yours")
        let failure = try RPC.failureText(await server.answer(line: RPC.call("tasks.claim", [
            "task_id": .int(task.id), "role": "implementer",
            "session_id": .string(Self.claudeKey.description)
        ])))
        #expect(failure.contains("Claude Code session"))
        #expect(failure.contains("opened by codex"))
        #expect(failure.contains("another harness"))
        #expect(try TaskRepository(store: store).task(id: task.id)?.claimedBy == nil)
    }

    @Test("a self-report naming an ended session, or one running elsewhere, is refused")
    func selfReportOfDeadOrForeignSessionRefused() async throws {
        let ended = session(Self.codexKey, pid: nil, isAlive: false, state: .ended(reason: .exited))
        let (server, _, _) = try makeServer(board: board(ended), table: threadServerTable())
        let notRunning = try RPC.failureText(await server.answer(line: RPC.call("auspex.notify", [
            "kind": "done", "message": "finished",
            "session_id": .string(Self.codexKey.sessionID)
        ])))
        #expect(notRunning.contains("not running"))
        #expect(notRunning.contains("only for a live session"))

        // The named session demonstrably lives in another codex process.
        var table = threadServerTable()
        table.records.append(process(850, parent: 1, "/usr/local/bin/codex"))
        let (elsewhere, _, _) = try makeServer(
            board: board(session(Self.codexKey, pid: 850)), table: table
        )
        let foreign = try RPC.failureText(await elsewhere.answer(line: RPC.call("auspex.notify", [
            "kind": "done", "message": "finished",
            "session_id": .string(Self.codexKey.sessionID)
        ])))
        #expect(foreign.contains("runs in process 850"))

        // And nothing above the bridge is a harness at all.
        let anonymous = FakeProcessTable(records: [
            process(Self.bridgePID, parent: 777, Self.bridgePath),
            process(777, parent: 1, "/usr/local/bin/some-wrapper")
        ])
        let (unknown, _, _) = try makeServer(board: board(session(Self.codexKey, pid: nil)), table: anonymous)
        let uncorroborated = try RPC.failureText(await unknown.answer(line: RPC.call("auspex.notify", [
            "kind": "done", "message": "finished",
            "session_id": .string(Self.codexKey.sessionID)
        ])))
        #expect(uncorroborated.contains("harness Auspex recognises"))
        #expect(uncorroborated.contains("cannot identify its caller by itself"))
    }

    // MARK: - 3. The walk stops at the caller's own harness

    @Test("a Codex worker launched from Claude Code is never filed as the Claude session")
    func workerIsNotItsLauncher() async throws {
        // claude (600, on the board) → zsh (700) → codex (800) → bridge (801),
        // and the bridge inherited the Claude session id through all of them.
        var table = FakeProcessTable(records: [
            process(Self.bridgePID, parent: Self.codexPID, Self.bridgePath),
            process(Self.codexPID, parent: 700, "/usr/local/bin/codex"),
            process(700, parent: 600, "/bin/zsh"),
            process(600, parent: 1, "/usr/local/bin/claude")
        ])
        table.environments[Self.bridgePID] = ["CLAUDE_CODE_SESSION_ID": Self.claudeKey.sessionID]
        table.environments[Self.codexPID] = ["CLAUDE_CODE_SESSION_ID": Self.claudeKey.sessionID]
        let (server, _, _) = try makeServer(
            board: board(session(Self.claudeKey, pid: 600), session(Self.codexKey, pid: nil)),
            table: table
        )

        let unaided = try RPC.structured(await server.answer(line: RPC.call("sessions.self")))
        #expect(unaided["resolved"]?.boolValue == false)
        #expect(unaided["evidence"]?.stringValue?.contains("nearest harness process, codex") == true)

        let named = try RPC.structured(await server.answer(line: RPC.call("sessions.self", [
            "session_id": .string(Self.codexKey.sessionID)
        ])))
        #expect(named["session"]?["key"]?.stringValue == Self.codexKey.description)

        let refused = try RPC.failureText(await server.answer(line: RPC.call("sessions.self", [
            "session_id": .string(Self.claudeKey.sessionID)
        ])))
        #expect(refused.contains("another harness"))
    }

    @Test("several sessions on one pid resolve only to the single live one")
    func sharedPIDNeedsOneLiveOwner() {
        let resolver = MCPSelfResolver()
        let table = codexCLITable()
        let other = Fixtures.key(.codex, "0199c0de-0000-7000-8000-0000000000c2")

        let oneLive = resolver.attempt(
            pid: Self.bridgePID,
            candidates: [
                .init(session(other, pid: Self.codexPID, isAlive: false, state: .ended(reason: .exited))),
                .init(session(Self.codexKey, pid: Self.codexPID))
            ],
            table: table
        )
        #expect(oneLive.resolution?.session == Self.codexKey)

        let twoLive = resolver.attempt(
            pid: Self.bridgePID,
            candidates: [.init(session(other, pid: Self.codexPID)), .init(session(Self.codexKey, pid: Self.codexPID))],
            table: table
        )
        #expect(twoLive.resolution == nil)
        #expect(twoLive.refusal?.contains("2 sessions on the board run in process 800") == true)
        #expect(twoLive.harness?.executable == "codex")
    }

    @Test("a harness serving several Auspex bridges is not one session's process")
    func manyBridgesAreAmbiguous() {
        var table = codexCLITable()
        table.records.append(process(802, parent: Self.codexPID, Self.bridgePath))
        let attempt = MCPSelfResolver().attempt(
            pid: Self.bridgePID,
            candidates: [.init(session(Self.codexKey, pid: Self.codexPID))],
            table: table,
            attached: [Self.bridgePID, 802]
        )
        #expect(attempt.resolution == nil)
        #expect(attempt.refusal?.contains("serves 2 Auspex connections") == true)

        // The same tree with only one of them attached is one session.
        let single = MCPSelfResolver().attempt(
            pid: Self.bridgePID,
            candidates: [.init(session(Self.codexKey, pid: Self.codexPID))],
            table: table,
            attached: [Self.bridgePID]
        )
        #expect(single.resolution?.session == Self.codexKey)
    }

    // MARK: - Recognising a harness's program

    @Test("harness programs are recognised by name, executable, or versioned install")
    func recognisesHarnessPrograms() {
        func recognised(_ path: String, name: String? = nil) -> HarnessProcess? {
            HarnessProcess.recognize(ProcessRecord(
                pid: 42, ppid: 1, startTime: Fixtures.date(0), executablePath: path, name: name, argv: []
            ))
        }
        #expect(recognised("/usr/local/bin/claude")?.harnesses == [.claudeCode])
        #expect(recognised("/Users/example/.local/share/claude/versions/2.1.0")?.executable == "claude")
        #expect(recognised("/Applications/Example.app/Contents/Resources/codex")?.harnesses == [.codex, .chatgptWork])
        #expect(recognised("/Users/example/.local/share/cursor-agent/versions/2026.01.01-abc/node")?.executable == "cursor-agent")
        #expect(recognised("/Users/example/.grok/downloads/grok-1.0.0-macos-aarch64")?.harnesses == [.grokBuild])
        #expect(recognised("", name: "codex")?.executable == "codex", "another user's process has only a name")

        #expect(recognised("/usr/local/bin/codex-code-mode-host") == nil, "a sibling tool is not the harness")
        #expect(recognised("/Applications/Claude.app/Contents/MacOS/Claude") == nil, "the desktop app is not the CLI")
        #expect(recognised("/bin/zsh") == nil)

        let server = HarnessProcess.recognize(ProcessRecord(
            pid: 42, ppid: 1, startTime: Fixtures.date(0),
            executablePath: "/usr/local/bin/codex", argv: ["codex", "app-server"]
        ))
        #expect(server?.isMultiSession == true)
        #expect(recognised("/usr/local/bin/codex")?.isMultiSession == false)
    }
}
