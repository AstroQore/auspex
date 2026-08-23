import AgentSessionKit
import AgentSessionLive
import Foundation
import Testing

@testable import AuspexCore

@Suite("AuspexMCPServer")
struct AuspexMCPServerTests {
    // The fabricated arrangement every test here works against: one Claude
    // Code session whose harness process is 900, an `Auspex --mcp-stdio`
    // bridge at 901 below it, and nothing else running.
    private static let sessionKey = Fixtures.key(.claudeCode, "aaaa1111-2222-3333-4444-555555555555")
    private static let harnessPID: pid_t = 900
    private static let bridgePID: pid_t = 901

    private func makeBoard(
        state: SessionState = .thinking,
        pid: pid_t? = harnessPID
    ) -> BoardSnapshot {
        var snapshot = SessionStateReducer.initialSnapshot(
            identity: Fixtures.identity(key: Self.sessionKey, pid: pid)
        )
        snapshot.state = state
        snapshot.startedAt = Fixtures.date(0)
        snapshot.lastEventAt = Fixtures.date(60)
        snapshot.brief.firstPrompt = "Wire the MCP surface"
        snapshot.brief.lastPromptAt = Fixtures.date(1)
        return BoardSnapshot(generatedAt: Fixtures.date(60), sessions: [snapshot])
    }

    private func makeTable() -> FakeProcessTable {
        FakeProcessTable(
            records: [
                .fake(pid: Self.bridgePID, ppid: Self.harnessPID, name: "Auspex"),
                .fake(pid: Self.harnessPID, ppid: 1, name: "claude")
            ]
        )
    }

    private func makeServer(
        readOnly: Bool = false,
        table: (any ProcessTableReading)? = nil,
        clientPIDs: [pid_t] = [bridgePID],
        board: BoardSnapshot? = nil
    ) throws -> (AuspexMCPServer, TestMCPHost, AuspexStore) {
        let store = try AuspexStore(inMemory: true)
        let host = TestMCPHost(
            board: board ?? makeBoard(),
            store: store,
            table: table ?? makeTable(),
            clientPIDs: clientPIDs,
            isReadOnly: readOnly
        )
        let server = AuspexMCPServer(host: host, now: { Fixtures.date(100) })
        return (server, host, store)
    }

    // MARK: - Protocol

    @Test("initialize names the protocol, the server, and how to behave")
    func initializeHandshake() async throws {
        let (server, _, _) = try makeServer()
        let result = try RPC.decode(await server.answer(line: RPC.line("initialize", id: 1)))["result"]
        #expect(result?["protocolVersion"]?.stringValue == AuspexMCPTools.protocolVersion)
        #expect(result?["serverInfo"]?["name"]?.stringValue == "auspex")
        let instructions = try #require(result?["instructions"]?.stringValue)
        #expect(instructions.contains("auspex.notify"))
        #expect(instructions.contains("auspex-coordination"))
        #expect(instructions.contains("implicit session task"))
        #expect(instructions.contains("Completion enters Review"))
    }

    @Test("a notification is answered with silence")
    func notificationsGetNoReply() async throws {
        let (server, _, _) = try makeServer()
        #expect(await server.answer(line: RPC.line("notifications/initialized")) == nil)
        #expect(await server.answer(line: RPC.line("auspex/hello", params: ["pid": 901])) == nil)
    }

    @Test("tools/list carries every tool with a schema")
    func toolsList() async throws {
        let (server, _, _) = try makeServer()
        let result = try RPC.decode(await server.answer(line: RPC.line("tools/list", id: 2)))["result"]
        let tools = try #require(result?["tools"]?.arrayValue)
        #expect(tools.count == AuspexMCPTools.all.count)
        #expect(tools.count == 20)
        for tool in tools {
            #expect(tool["name"]?.stringValue?.isEmpty == false)
            #expect(tool["inputSchema"]?["type"]?.stringValue == "object")
            #expect(tool["description"]?.stringValue?.isEmpty == false)
        }
    }

    @Test("bad JSON and unknown methods still get a line back")
    func malformedInputIsAnswered() async throws {
        let (server, _, _) = try makeServer()
        #expect(try RPC.rpcError(await server.answer(line: Data("{not json".utf8))).contains("JSON"))
        #expect(
            try RPC.rpcError(await server.answer(line: RPC.line("nonsense/method", id: 3)))
                .contains("Unknown method")
        )
        let unknownTool = try RPC.rpcError(
            await server.answer(line: RPC.call("tasks.obliterate", id: 4))
        )
        #expect(unknownTool.contains("Unknown tool"))
    }

    @Test("an argument the schema does not declare is refused rather than ignored")
    func unknownArgumentsAreRefused() async throws {
        let (server, _, _) = try makeServer()
        let message = try RPC.rpcError(
            await server.answer(line: RPC.call("peers.status", ["limitt": 5]))
        )
        #expect(message.contains("does not accept 'limitt'"))
    }

    // MARK: - notify

    @Test("notify lands on the calling session, in the right bucket")
    func notifyResolvesTheCallerFromItsPID() async throws {
        let (server, host, store) = try makeServer()
        let structured = try RPC.structured(await server.answer(line: RPC.call("auspex.notify", [
            "kind": "needs_input",
            "message": "Which of the two migrations should I keep?"
        ])))

        #expect(structured["session"]?.stringValue == Self.sessionKey.description)
        #expect(structured["kind"]?.stringValue == "needs_input")
        #expect(structured["bucket"]?.stringValue == "needs you")
        #expect(structured["resolved"]?.boolValue == true)
        // The evidence names the *ancestor* it walked to, which is the whole
        // point: the client is the bridge, not the harness.
        #expect(structured["evidence"]?.stringValue?.contains("900") == true)

        let stored = try #require(try TaskRepository(store: store).liveNotices()[Self.sessionKey])
        #expect(stored.message == "Which of the two migrations should I keep?")
        #expect(await host.notices.count == 1)
    }

    @Test("notify sanitizes what it stores and shows")
    func notifyStripsControlCharactersAndCaps() async throws {
        let (server, _, store) = try makeServer()
        let nasty = "\u{1B}[2J\u{202E}drop\u{0000}\ttable\n\nnow" + String(repeating: "x", count: 900)
        _ = await server.answer(line: RPC.call("auspex.notify", [
            "kind": "blocked", "message": .string(nasty)
        ]))

        let stored = try #require(try TaskRepository(store: store).liveNotices()[Self.sessionKey])
        #expect(!stored.message.contains("\u{1B}"))
        #expect(!stored.message.contains("\u{202E}"))
        #expect(!stored.message.contains("\u{0000}"))
        #expect(!stored.message.contains("\n"))
        // The escape itself is gone; what is left is inert text. A NUL and a
        // bidi override vanish without leaving a gap, because they were never
        // separating anything; a tab and a newline become one space, because
        // they were.
        #expect(stored.message.hasPrefix("[2Jdrop table now"))
        #expect(stored.message.count <= MCPTextSanitizer.defaultLimit)
        #expect(stored.message.hasSuffix("…"))
    }

    @Test("a message of nothing but whitespace is refused")
    func emptyMessageIsRefused() async throws {
        let (server, _, _) = try makeServer()
        let message = try RPC.rpcError(await server.answer(line: RPC.call("auspex.notify", [
            "kind": "done", "message": "   \n\t  "
        ])))
        #expect(message.contains("'message' must not be empty"))
    }

    @Test("an unresolvable caller is told so instead of filing against nobody")
    func notifyRefusesWhenItCannotTell() async throws {
        let (server, _, store) = try makeServer(clientPIDs: [])
        let message = try RPC.failureText(await server.answer(line: RPC.call("auspex.notify", [
            "kind": "blocked", "message": "no network"
        ])))
        #expect(message.contains("process-attributed session"))
        #expect(try TaskRepository(store: store).liveNotices().isEmpty)
    }

    @Test("session_id can corroborate process evidence but cannot override it")
    func sessionIDIsOnlyACrossCheck() async throws {
        let (server, _, _) = try makeServer()
        let structured = try RPC.structured(await server.answer(line: RPC.call("auspex.notify", [
            "kind": "done",
            "message": "migration landed",
            "session_id": .string(Self.sessionKey.sessionID)
        ])))
        #expect(structured["session"]?.stringValue == Self.sessionKey.description)
        #expect(structured["evidence"]?.stringValue?.contains("session_id agreed") == true)
        // Finished work waits on a person, so the bucket it lands in is the
        // one a person empties.
        #expect(structured["bucket"]?.stringValue == "review")

        let refusal = try RPC.failureText(await server.answer(line: RPC.call("auspex.notify", [
            "kind": "done", "message": "x", "session_id": "claudeCode:nobody"
        ])))
        #expect(refusal.contains("No session on the board"))

        let (unresolved, _, _) = try makeServer(clientPIDs: [])
        let uncorroborated = try RPC.failureText(await unresolved.answer(line: RPC.call(
            "auspex.notify", [
                "kind": "done", "message": "x",
                "session_id": .string(Self.sessionKey.description)
            ]
        )))
        #expect(uncorroborated.contains("cannot corroborate"))
        #expect(uncorroborated.contains("cannot identify its caller by itself"))
    }

    @Test("the hello a bridge sends is used when the socket reports no pid")
    func helloIsTheFallback() async throws {
        let (server, _, _) = try makeServer(clientPIDs: [])
        _ = await server.answer(
            line: RPC.line("auspex/hello", params: ["pid": .int(Int64(Self.harnessPID))])
        )
        let structured = try RPC.structured(await server.answer(line: RPC.call("auspex.notify", [
            "kind": "needs_review", "message": "please look at the diff"
        ])))
        #expect(structured["session"]?.stringValue == Self.sessionKey.description)
        #expect(structured["evidence"]?.stringValue?.contains("declared") == true)
    }

    @Test("a session id in the environment identifies a harness with no pid on the board")
    func environmentResolution() async throws {
        var table = makeTable()
        table.environments[Self.harnessPID] = [
            "CLAUDE_CODE_SESSION_ID": Self.sessionKey.sessionID,
            "PATH": "/usr/bin"
        ]
        let (server, _, _) = try makeServer(
            table: table,
            board: makeBoard(pid: nil)  // nothing on the board has a pid
        )
        let structured = try RPC.structured(await server.answer(line: RPC.call("auspex.notify", [
            "kind": "needs_input", "message": "which branch?"
        ])))
        #expect(structured["session"]?.stringValue == Self.sessionKey.description)
        #expect(structured["evidence"]?.stringValue?.contains("CLAUDE_CODE_SESSION_ID") == true)
    }

    // MARK: - report

    @Test("report stores one line and folds the progress into it")
    func reportRoundTrip() async throws {
        let (server, host, store) = try makeServer()
        let structured = try RPC.structured(await server.answer(line: RPC.call("auspex.report", [
            "focus": "rewriting the tailer's cursor handling",
            "progress": "step 2 of 5"
        ])))
        #expect(structured["focus"]?.stringValue == "rewriting the tailer's cursor handling")
        let stored = try #require(try TaskRepository(store: store).allReports()[Self.sessionKey])
        #expect(stored.line == "rewriting the tailer's cursor handling · step 2 of 5")
        #expect(await host.reports.count == 1)
    }

    // MARK: - Plans and tasks

    @Test("the supervisor's round trip: register, file, claim, complete")
    func orchestrationRoundTrip() async throws {
        let (server, host, store) = try makeServer()

        let plan = try RPC.structured(await server.answer(line: RPC.call("plans.create", [
            "title": "Ship the MCP surface", "summary": "notify first, tasks second"
        ])))
        #expect(plan["slug"]?.stringValue == "ship-the-mcp-surface")

        let task = try RPC.structured(await server.answer(line: RPC.call("tasks.create", [
            "title": "Write the installer", "plan": "ship-the-mcp-surface", "priority": 3
        ])))
        let taskID = try #require(task["id"]?.intValue)
        #expect(task["status"]?.stringValue == "todo")
        #expect(task["version"]?.intValue == 1)

        let claimed = try RPC.structured(await server.answer(line: RPC.call("tasks.claim", [
            "task_id": .int(Int64(taskID)), "role": "implementer", "scope": "the TOML half"
        ])))
        #expect(claimed["status"]?.stringValue == "doing")
        #expect(claimed["claimRole"]?.stringValue == "implementer")
        #expect(claimed["claimScope"]?.stringValue == "the TOML half")
        #expect(claimed["claimedBy"]?.stringValue == Self.sessionKey.description)
        #expect(claimed["claimOutcome"]?.stringValue == "claimed")
        #expect(claimed["sessions"]?.arrayValue?.first?.stringValue == Self.sessionKey.description)

        let done = try RPC.structured(await server.answer(line: RPC.call("tasks.complete", [
            "task_id": .int(Int64(taskID)), "result": "fenced writer plus 9 tests"
        ])))
        // Finishing asks for a review; it does not close anything.
        #expect(done["status"]?.stringValue == "review")
        #expect(done["result"]?.stringValue == "fenced writer plus 9 tests")
        #expect(await host.ledgerChanges == 4)

        // Finishing a task *is* reporting done. The board's `done` bucket
        // counts explicit signals only, so a worker that completed its task
        // and never called `auspex.notify` must not be the one whose work
        // disappears off the header.
        let receipt = try #require(try TaskRepository(store: store).liveNotices()[Self.sessionKey])
        #expect(receipt.kind == .done)
        #expect(receipt.message == "fenced writer plus 9 tests")

        let detail = try RPC.structured(await server.answer(line: RPC.call("plans.get", [
            "plan": "ship-the-mcp-surface"
        ])))
        #expect(detail["plan"]?["taskCount"]?.intValue == 1)
        // Still open: a task nobody has read is a task nobody has finished
        // with, whatever the agent that did the work believes.
        #expect(detail["plan"]?["openTaskCount"]?.intValue == 1)
    }

    // MARK: - The shape of a task

    @Test("a task is filed with a kind, labels, an importance and what it waits on")
    func tasksCarryTheirShape() async throws {
        let (server, _, _) = try makeServer()
        let first = try RPC.structured(await server.answer(line: RPC.call("tasks.create", [
            "title": "Land the schema", "kind": "chore", "importance": "urgent"
        ])))
        let firstID = try #require(first["id"]?.intValue)
        #expect(first["kind"]?.stringValue == "chore")
        #expect(first["importance"]?.stringValue == "urgent")
        #expect(first["shortID"]?.stringValue?.hasPrefix("AUX-") == true)

        let second = try RPC.structured(await server.answer(line: RPC.call("tasks.create", [
            "title": "Read the schema",
            "labels": .array(["Adapter", "codex", "adapter"]),
            "depends_on": .array([.int(Int64(firstID))])
        ])))
        #expect(second["labels"]?.arrayValue?.compactMap(\.stringValue) == ["adapter", "codex"])
        #expect(second["dependsOn"]?.arrayValue?.compactMap(\.intValue) == [firstID])

        // Ready is about dependencies: the one that waits is left out.
        let ready = try RPC.structured(await server.answer(line: RPC.call("tasks.list", [
            "ready_only": true
        ])))
        #expect(ready["tasks"]?.arrayValue?.compactMap { $0["id"]?.intValue } == [firstID])

        let byLabel = try RPC.structured(await server.answer(line: RPC.call("tasks.list", [
            "label": "codex"
        ])))
        #expect(byLabel["tasks"]?.arrayValue?.count == 1)
    }

    @Test("a note says what kind it is and where to check")
    func notesCarryKindAndRef() async throws {
        let (server, _, _) = try makeServer()
        let task = try RPC.structured(await server.answer(line: RPC.call("tasks.create", [
            "title": "Decide the wire format"
        ])))
        let id = try #require(task["id"]?.intValue)
        let log = try RPC.structured(await server.answer(line: RPC.call("tasks.log", [
            "task_id": .int(Int64(id)),
            "message": "Protobuf, not JSON: the store is already binary.",
            "kind": "decision",
            "ref": "a1b2c3d"
        ])))
        let last = try #require(log["entries"]?.arrayValue?.last)
        #expect(last["kind"]?.stringValue == "decision")
        #expect(last["ref"]?.stringValue == "a1b2c3d")
    }

    @Test("tasks.get returns readiness, history, and safe peer capsules")
    func taskDetailIsStructuredAndSafe() async throws {
        let (server, _, store) = try makeServer()
        let ledger = TaskRepository(store: store)
        let dependency = try ledger.createTask(
            title: "Land the schema", projectKey: "/Users/example/Code/widget"
        )
        let task = try ledger.createTask(
            title: "Wire the reader", projectKey: "/Users/example/Code/widget",
            dependsOn: [dependency.id]
        )
        try ledger.claimTask(
            id: task.id, role: "implementer", scope: "MCP payloads", by: Self.sessionKey
        )
        try ledger.appendLog(
            taskID: task.id, actor: Self.sessionKey, kind: "decision",
            message: "Capsules carry metadata, never transcript bodies."
        )

        let detail = try RPC.structured(await server.answer(line: RPC.call("tasks.get", [
            "task_id": .int(task.id)
        ])))
        #expect(detail["task"]?["id"]?.intValue == Int(task.id))
        #expect(detail["task"]?["version"]?.intValue == Int((try ledger.task(id: task.id))?.version ?? 0))
        #expect(detail["readiness"]?["ready"]?.boolValue == false)
        #expect(
            detail["readiness"]?["blocking"]?.arrayValue?.compactMap(\.intValue)
                == [Int(dependency.id)]
        )
        #expect(detail["history"]?.arrayValue?.last?["kind"]?.stringValue == "decision")
        #expect(detail["attempts"]?.arrayValue?.first?["event"]?.stringValue == "claimed")
        #expect(detail["attempts"]?.arrayValue?.first?["session"]?.stringValue == Self.sessionKey.description)
        let capsule = try #require(detail["sessions"]?.arrayValue?.first?["session"])
        #expect(capsule["key"]?.stringValue == Self.sessionKey.description)
        #expect(capsule["activity"]?["provenance"]?.stringValue == "inferred")
        #expect(capsule["assignment"] == nil)
        #expect(capsule["cwd"] == nil)
        #expect(capsule["latestAssistant"] == nil)
    }

    @Test("tasks.release is holder-only and keeps the reason")
    func releaseIsHolderOnly() async throws {
        let (server, _, store) = try makeServer()
        let ledger = TaskRepository(store: store)
        let mine = try ledger.createTask(title: "Give this back")
        try ledger.claimTask(id: mine.id, role: "implementer", scope: nil, by: Self.sessionKey)

        let released = try RPC.structured(await server.answer(line: RPC.call("tasks.release", [
            "task_id": .int(mine.id), "reason": "The prerequisite belongs to another worker."
        ])))
        #expect(released["status"]?.stringValue == "todo")
        #expect(released["claimedBy"] == nil)
        #expect(try ledger.log(taskID: mine.id).last?.message == "The prerequisite belongs to another worker.")

        let other = Fixtures.key(.codex, "somebody-else")
        let theirs = try ledger.createTask(title: "Not mine")
        try ledger.claimTask(id: theirs.id, role: "implementer", scope: nil, by: other)
        let refusal = try RPC.failureText(await server.answer(line: RPC.call("tasks.release", [
            "task_id": .int(theirs.id), "reason": "I should not be able to do this."
        ])))
        #expect(refusal.contains("Only \(other.description) can release"))
        #expect(try ledger.task(id: theirs.id)?.claimedBy == other)
    }

    @Test("tasks.complete is holder-only")
    func completeIsHolderOnly() async throws {
        let (server, _, store) = try makeServer()
        let ledger = TaskRepository(store: store)
        let other = Fixtures.key(.codex, "somebody-else")
        let task = try ledger.createTask(title: "Not my finish")
        let held = try ledger.claimTask(
            id: task.id, role: "implementer", scope: nil, by: other
        )
        let refusal = try RPC.failureText(await server.answer(line: RPC.call("tasks.complete", [
            "task_id": .int(task.id),
            "expected_version": .int(held.version),
            "result": "I should not finish this"
        ])))
        #expect(refusal.contains("Only the current holder, \(other.description), can finish"))
        #expect(try ledger.task(id: task.id)?.status == .doing)
    }

    @Test("overview.get is the compact current-project situation")
    func projectOverview() async throws {
        let (server, _, store) = try makeServer()
        let ledger = TaskRepository(store: store)
        let project = "/Users/example/Code/widget"
        _ = try ledger.createTask(title: "Implement", status: .doing, projectKey: project)
        _ = try ledger.createTask(title: "Blocked", status: .blocked, projectKey: project)
        _ = try ledger.createTask(title: "Review", status: .review, projectKey: project)
        _ = try ledger.createTask(title: "Ready", projectKey: project)
        let orphan = try ledger.createTask(title: "Orphaned", projectKey: project)
        try ledger.claimTask(
            id: orphan.id, role: "implementer", scope: nil,
            by: Fixtures.key(.codex, "ended-worker")
        )
        _ = await server.answer(line: RPC.call("auspex.notify", [
            "kind": "blocked", "message": "Choose the migration boundary."
        ]))

        let overview = try RPC.structured(await server.answer(line: RPC.call("overview.get")))
        #expect(overview["project"]?["key"]?.stringValue == project)
        #expect(overview["self"]?["key"]?.stringValue == Self.sessionKey.description)
        #expect(overview["doing"]?.arrayValue?.count == 2) // implement + orphaned claim
        #expect(overview["blocked"]?.arrayValue?.count == 1)
        #expect(overview["review"]?.arrayValue?.count == 1)
        #expect(overview["ready"]?.arrayValue?.count == 1)
        #expect(overview["orphanedClaims"]?.arrayValue?.first?["id"]?.intValue == Int(orphan.id))
        #expect(overview["needsYou"]?.arrayValue?.first?["attention"]?["provenance"]?.stringValue == "self_reported")
    }

    @Test("saying done finishes the task this session was holding")
    func notifyDoneAsksForAReview() async throws {
        let (server, _, store) = try makeServer()
        let task = try RPC.structured(await server.answer(line: RPC.call("tasks.create", [
            "title": "Write the installer"
        ])))
        let id = try #require(task["id"]?.intValue)
        _ = await server.answer(line: RPC.call("tasks.claim", [
            "task_id": .int(Int64(id)), "role": "implementer"
        ]))

        let notice = try RPC.structured(await server.answer(line: RPC.call("auspex.notify", [
            "kind": "done", "message": "fenced writer plus 9 tests"
        ])))
        #expect(notice["bucket"]?.stringValue == "review")
        #expect(notice["reviewing"]?.arrayValue?.compactMap(\.intValue) == [id])

        let stored = try #require(try TaskRepository(store: store).task(id: Int64(id)))
        #expect(stored.status == .review)
        #expect(stored.result == "fenced writer plus 9 tests")
    }

    // MARK: - Projects contain tasks

    @Test("a task filed by an agent lands in the project that agent is working in")
    func tasksAreFiledWhereTheCallerIsWorking() async throws {
        let (server, _, store) = try makeServer()
        let task = try RPC.structured(await server.answer(line: RPC.call("tasks.create", [
            "title": "Sanitize argv before it reaches a log line"
        ])))
        // Nothing was said about a project, and the task is not unfiled.
        #expect(task["project"]?.stringValue == "/Users/example/Code/widget")
        #expect(task["projectName"]?.stringValue == "widget")

        // The same key the board would group this session's own card by, which
        // is the whole point of resolving it here rather than inventing one.
        let mine = try RPC.structured(await server.answer(line: RPC.call("sessions.self")))
        #expect(mine["projectKey"]?.stringValue == task["project"]?.stringValue)

        let stored = try #require(try TaskRepository(store: store).tasks().first)
        #expect(stored.projectKey == "/Users/example/Code/widget")
    }

    @Test("a milestone is filed in the caller's project too, and its tasks with it")
    func milestonesAreInsideProjects() async throws {
        let (server, _, _) = try makeServer()
        let plan = try RPC.structured(await server.answer(line: RPC.call("plans.create", [
            "title": "Ship the MCP surface"
        ])))
        #expect(plan["project"]?.stringValue == "/Users/example/Code/widget")
        #expect(plan["projectName"]?.stringValue == "widget")

        let task = try RPC.structured(await server.answer(line: RPC.call("tasks.create", [
            "title": "Write the installer", "plan": "ship-the-mcp-surface"
        ])))
        #expect(task["project"]?.stringValue == "/Users/example/Code/widget")
    }

    @Test("an orchestrator can file work in another project by naming it")
    func anExplicitProjectIsHonoured() async throws {
        let (server, _, _) = try makeServer()
        let task = try RPC.structured(await server.answer(line: RPC.call("tasks.create", [
            "title": "Port the cart", "project": "/Users/example/Code/storefront-web/"
        ])))
        #expect(task["project"]?.stringValue == "/Users/example/Code/storefront-web")

        // And filtering by that project finds it, while the caller's own does
        // not — two lanes, not one pile.
        let there = try RPC.structured(await server.answer(line: RPC.call("tasks.list", [
            "project": "/Users/example/Code/storefront-web"
        ])))
        #expect(there["tasks"]?.arrayValue?.count == 1)
        let here = try RPC.structured(await server.answer(line: RPC.call("tasks.list", [
            "project": "/Users/example/Code/widget"
        ])))
        #expect(here["tasks"]?.arrayValue?.isEmpty == true)
    }

    @Test("a project nothing answers to is refused rather than filed under the caller's")
    func anUnknownProjectIsRefused() async throws {
        let (server, _, store) = try makeServer()
        let message = try RPC.failureText(await server.answer(line: RPC.call("tasks.create", [
            "title": "Port the cart", "project": "storefornt-web"
        ])))
        #expect(message.contains("No project on the board is 'storefornt-web'"))
        #expect(try TaskRepository(store: store).tasks().isEmpty)
    }

    @Test("claiming a task files it where the claimer is working")
    func aClaimGivesATaskItsProject() async throws {
        let (server, _, store) = try makeServer()
        let ledger = TaskRepository(store: store)
        // Filed by a person on the Tasks page before anybody took it.
        let task = try ledger.createTask(title: "Somebody's job", source: "ui")
        #expect(task.projectKey == nil)

        let claimed = try RPC.structured(await server.answer(line: RPC.call("tasks.claim", [
            "task_id": .int(task.id), "role": "implementer"
        ])))
        #expect(claimed["project"]?.stringValue == "/Users/example/Code/widget")
    }

    @Test("a task can be moved between projects, and the move is in its history")
    func aTaskCanBeRefiled() async throws {
        let (server, _, store) = try makeServer()
        let ledger = TaskRepository(store: store)
        let task = try ledger.createTask(title: "Filed in a hurry", projectKey: "/Users/example/Code/widget")

        let moved = try RPC.structured(await server.answer(line: RPC.call("tasks.update", [
            "task_id": .int(task.id), "project": "/Users/example/Code/storefront-web"
        ])))
        #expect(moved["project"]?.stringValue == "/Users/example/Code/storefront-web")
        #expect(try ledger.log(taskID: task.id).contains { $0.kind == "project" })
    }

    @Test("an empty board says what to do about it instead of returning nothing")
    func emptyListsCarryANote() async throws {
        let (server, _, _) = try makeServer()
        let plans = try RPC.structured(await server.answer(line: RPC.call("plans.list")))
        #expect(plans["plans"]?.arrayValue?.isEmpty == true)
        #expect(plans["note"]?.stringValue?.contains("milestone") == true)
        let tasks = try RPC.structured(await server.answer(line: RPC.call("tasks.list")))
        #expect(tasks["tasks"]?.arrayValue?.isEmpty == true)
        #expect(tasks["note"]?.stringValue?.contains("tasks.create") == true)
    }

    @Test("a claim held by somebody else becomes a visible takeover request")
    func claimConflictIsPending() async throws {
        let (server, _, store) = try makeServer()
        let ledger = TaskRepository(store: store)
        let other = Fixtures.key(.codex, "somebody-else")
        let task = try ledger.createTask(title: "One job")
        try ledger.claimTask(id: task.id, role: "implementer", scope: nil, by: other)

        let pending = try RPC.structured(await server.answer(line: RPC.call("tasks.claim", [
            "task_id": .int(task.id),
            "role": "reviewer",
            "scope": "migration",
            "reason": "I have the compatibility context"
        ])))
        #expect(pending["claimedBy"]?.stringValue == other.description)
        #expect(pending["claimOutcome"]?.stringValue == "pending_takeover")
        let request = try #require(pending["pendingClaims"]?.arrayValue?.first)
        #expect(request["requester"]?.stringValue == Self.sessionKey.description)
        #expect(request["holder"]?.stringValue == other.description)
        #expect(request["status"]?.stringValue == "pending")
        #expect(request["taskVersion"]?.intValue == pending["version"]?.intValue)
        #expect(try ledger.task(id: task.id)?.claimedBy == other)
    }

    @Test("expected_version refuses a stale agent mutation atomically")
    func expectedVersionFencesStaleMCPWrites() async throws {
        let (server, _, store) = try makeServer()
        let ledger = TaskRepository(store: store)
        let task = try ledger.createTask(title: "Keep the newer state")
        let current = try ledger.updateTask(id: task.id, status: .doing)
        #expect(current.version == 2)

        let message = try RPC.failureText(await server.answer(line: RPC.call("tasks.update", [
            "task_id": .int(task.id),
            "expected_version": 1,
            "title": "stale title",
            "depends_on": .array([.int(9_999)])
        ])))
        #expect(message.contains("expected 1, current 2"))
        let stored = try #require(try ledger.task(id: task.id))
        #expect(stored.title == "Keep the newer state")
        #expect(stored.status == .doing)
        #expect(stored.version == 2)

        let fresh = try RPC.structured(await server.answer(line: RPC.call("tasks.update", [
            "task_id": .int(task.id),
            "expected_version": 2,
            "status": "blocked"
        ])))
        #expect(fresh["version"]?.intValue == 3)
        #expect(fresh["status"]?.stringValue == "blocked")
    }

    @Test("tasks.update cannot bypass Review and close the agent's own work")
    func updateCannotSelfClose() async throws {
        let (server, _, store) = try makeServer()
        let task = try TaskRepository(store: store).createTask(title: "Review me")
        let message = try RPC.failureText(await server.answer(line: RPC.call("tasks.update", [
            "task_id": .int(task.id), "status": "done", "expected_version": 1
        ])))
        #expect(message.contains("cannot close its own task"))
        #expect(try TaskRepository(store: store).task(id: task.id)?.status == .todo)
    }

    @Test("a task id that is not a positive number never reaches the store")
    func taskIDIsValidated() async throws {
        let (server, _, _) = try makeServer()
        #expect(
            try RPC.rpcError(await server.answer(line: RPC.call("tasks.complete", ["task_id": 0])))
                .contains("positive whole number")
        )
        #expect(
            try RPC.rpcError(await server.answer(line: RPC.call("tasks.complete", ["task_id": "1"])))
                .contains("positive whole number")
        )
        #expect(
            try RPC.failureText(await server.answer(line: RPC.call("tasks.log", [
                "task_id": 4_242, "message": "hello"
            ]))).contains("No such task 4242")
        )
    }

    @Test("tasks.list filters by plan, column, and claim")
    func taskFilters() async throws {
        let (server, _, store) = try makeServer()
        let ledger = TaskRepository(store: store)
        let plan = try ledger.createPlan(title: "Filters")
        let mine = try ledger.createTask(title: "Mine", planID: plan.id)
        _ = try ledger.createTask(title: "Theirs", planID: plan.id, status: .blocked)
        try ledger.claimTask(id: mine.id, role: "implementer", scope: nil, by: Self.sessionKey)

        let blocked = try RPC.structured(await server.answer(line: RPC.call("tasks.list", [
            "plan": "filters", "status": .array(["blocked"])
        ])))
        #expect(blocked["tasks"]?.arrayValue?.count == 1)

        let ours = try RPC.structured(await server.answer(line: RPC.call("tasks.list", ["mine": true])))
        #expect(ours["tasks"]?.arrayValue?.count == 1)
        #expect(ours["tasks"]?.arrayValue?.first?["title"]?.stringValue == "Mine")
    }

    // MARK: - Read-only

    @Test("a demo replay answers reads and refuses every write by name")
    func demoModeIsReadOnly() async throws {
        let (server, _, store) = try makeServer(readOnly: true)
        for tool in AuspexMCPTools.writingTools.sorted() {
            let message = try RPC.failureText(await server.answer(line: RPC.call(tool, [:])))
            #expect(message.contains("replaying a demo board"), "\(tool) did not refuse")
        }
        // Reads still work.
        let peers = try RPC.structured(await server.answer(line: RPC.call("peers.status")))
        #expect(peers["total"]?.intValue == 1)
        #expect(try TaskRepository(store: store).liveNotices().isEmpty)
    }

    // MARK: - Reads

    @Test("sessions.self says who it thinks you are and how it decided")
    func sessionsSelf() async throws {
        let (server, _, store) = try makeServer()
        let ledger = TaskRepository(store: store)
        let task = try ledger.createTask(title: "Already mine")
        try ledger.claimTask(id: task.id, role: "implementer", scope: nil, by: Self.sessionKey)

        let structured = try RPC.structured(await server.answer(line: RPC.call("sessions.self")))
        #expect(structured["resolved"]?.boolValue == true)
        #expect(structured["session"]?["key"]?.stringValue == Self.sessionKey.description)
        #expect(structured["session"]?["assignment"]?.stringValue == "Wire the MCP surface")
        #expect(structured["clientPID"]?.intValue == Int(Self.bridgePID))
        #expect(structured["tasks"]?.arrayValue?.count == 1)
    }

    @Test("sessions.self admits when it cannot tell, and never guesses")
    func sessionsSelfUnresolved() async throws {
        let (server, _, _) = try makeServer(clientPIDs: [])
        let structured = try RPC.structured(await server.answer(line: RPC.call("sessions.self")))
        #expect(structured["resolved"]?.boolValue == false)
        // No session at all rather than a null one: the payload leaves the key
        // out, which is the shape a client's schema check expects.
        #expect(structured["session"] == nil)
        #expect(structured["evidence"]?.stringValue?.isEmpty == false)
    }

    @Test("sessions.list carries the notice a session filed")
    func sessionsListShowsNotices() async throws {
        let (server, _, _) = try makeServer()
        _ = await server.answer(line: RPC.call("auspex.notify", [
            "kind": "needs_review", "message": "look at the diff"
        ]))
        let structured = try RPC.structured(await server.answer(line: RPC.call("sessions.list")))
        let first = try #require(structured["sessions"]?.arrayValue?.first)
        #expect(first["notice"]?["kind"]?.stringValue == "needs_review")
        #expect(first["notice"]?["message"]?.stringValue == "look at the diff")
    }

    @Test("sessions.list filters by project and returns persisted report freshness")
    func sessionsListShowsReportsAndFiltersProjects() async throws {
        var primary = makeBoard().sessions[0]
        primary.brief.lastAssistantAt = Fixtures.date(120)
        let otherKey = Fixtures.key(.codex, "other-project")
        var other = SessionStateReducer.initialSnapshot(identity: Fixtures.identity(
            key: otherKey,
            cwd: "/Users/example/Code/other",
            gitRoot: "/Users/example/Code/other",
            pid: nil
        ))
        other.state = .thinking
        let board = BoardSnapshot(generatedAt: Fixtures.date(130), sessions: [primary, other])
        let (server, _, store) = try makeServer(board: board)
        try TaskRepository(store: store).recordReport(
            session: Self.sessionKey,
            focus: "Hardening MCP identity",
            progress: "3 of 4",
            now: Fixtures.date(100)
        )

        let listed = try RPC.structured(await server.answer(line: RPC.call("sessions.list", [
            "project": "/Users/example/Code/widget"
        ])))
        #expect(listed["total"]?.intValue == 1)
        let session = try #require(listed["sessions"]?.arrayValue?.first)
        #expect(session["key"]?.stringValue == Self.sessionKey.description)
        #expect(session["report"]?["focus"]?.stringValue == "Hardening MCP identity")
        #expect(session["report"]?["progress"]?.stringValue == "3 of 4")
        #expect(session["report"]?["reportedAt"] != nil)
        #expect(session["report"]?["freshness"]?.stringValue == "superseded")
        #expect(session["report"]?["provenance"]?.stringValue == "self_reported")
    }

    @Test("sessions.get returns safe metadata and linked task context")
    func sessionDetailIsSafe() async throws {
        let (server, _, store) = try makeServer()
        let ledger = TaskRepository(store: store)
        let task = try ledger.createTask(title: "Context work")
        try ledger.claimTask(
            id: task.id, role: "implementer", scope: "safe capsule", by: Self.sessionKey
        )
        try ledger.recordReport(
            session: Self.sessionKey, focus: "Building the capsule", progress: "done"
        )

        let detail = try RPC.structured(await server.answer(line: RPC.call("sessions.get", [
            "session_key": .string(Self.sessionKey.description)
        ])))
        let capsule = try #require(detail["session"])
        #expect(capsule["key"]?.stringValue == Self.sessionKey.description)
        #expect(capsule["report"]?["focus"]?.stringValue == "Building the capsule")
        #expect(capsule["linkedTasks"]?["ids"]?.arrayValue?.compactMap(\.intValue) == [Int(task.id)])
        #expect(detail["tasks"]?.arrayValue?.first?["title"]?.stringValue == "Context work")
        #expect(capsule["assignment"] == nil)
        #expect(capsule["cwd"] == nil)
        #expect(capsule["latestAssistant"] == nil)
    }

    @Test("unattributed callers may create Scratch work but cannot author later mutations")
    func unresolvedWritesFailClosedExceptCreation() async throws {
        let (server, _, _) = try makeServer(clientPIDs: [])
        let created = try RPC.structured(await server.answer(line: RPC.call("tasks.create", [
            "title": "A task from an unattributed coordinator"
        ])))
        let id = try #require(created["id"]?.intValue)
        #expect(created["project"]?.stringValue == TaskProject.scratchKey)

        let update = try RPC.failureText(await server.answer(line: RPC.call("tasks.update", [
            "task_id": .int(Int64(id)), "status": "doing"
        ])))
        #expect(update.contains("process-attributed session"))

        let log = try RPC.failureText(await server.answer(line: RPC.call("tasks.log", [
            "task_id": .int(Int64(id)), "message": "anonymous mutation"
        ])))
        #expect(log.contains("process-attributed session"))
    }

    @Test("identity resolution never skips an unresolvable active peer to another client")
    func callerUsesOnlyTheActivePeer() async throws {
        let (server, _, store) = try makeServer(clientPIDs: [9_999, Self.bridgePID])
        let task = try TaskRepository(store: store).createTask(title: "Do not misattribute")
        let failure = try RPC.failureText(await server.answer(line: RPC.call("tasks.claim", [
            "task_id": .int(task.id), "role": "implementer"
        ])))
        #expect(failure.contains("process 9999"))
        #expect(try TaskRepository(store: store).task(id: task.id)?.claimedBy == nil)
    }

    @Test("peers.status counts a notify as somebody needing you")
    func peersCountsCallers() async throws {
        let (server, _, _) = try makeServer()
        let before = try RPC.structured(await server.answer(line: RPC.call("peers.status")))
        #expect(before["needsYou"]?.intValue == 0)
        #expect(before["working"]?.intValue == 1)

        _ = await server.answer(line: RPC.call("auspex.notify", [
            "kind": "blocked", "message": "the build cannot find the kit"
        ]))
        let after = try RPC.structured(await server.answer(line: RPC.call("peers.status")))
        #expect(after["needsYou"]?.intValue == 1)
        #expect(after["calling"]?.arrayValue?.count == 1)

        // `done` is not a call for a person; it is finished work to read.
        _ = await server.answer(line: RPC.call("auspex.notify", [
            "kind": "done", "message": "finished"
        ]))
        let finished = try RPC.structured(await server.answer(line: RPC.call("peers.status")))
        #expect(finished["needsYou"]?.intValue == 0)
    }

    @Test("sessions.tree answers with the forest and with one branch")
    func sessionsTree() async throws {
        let parent = Fixtures.key(.claudeCode, "parent-session")
        let child = Fixtures.key(.codex, "child-session")
        var parentSnapshot = SessionStateReducer.initialSnapshot(
            identity: Fixtures.identity(key: parent, pid: Self.harnessPID)
        )
        parentSnapshot.state = .delegating(children: 1)
        var childIdentity = Fixtures.identity(key: child, pid: nil)
        childIdentity.parent = parent
        childIdentity.parentLink = .spawnedProcess
        let childSnapshot = SessionStateReducer.initialSnapshot(identity: childIdentity)
        let board = BoardSnapshot(
            generatedAt: Fixtures.date(60), sessions: [parentSnapshot, childSnapshot]
        )
        let (server, _, _) = try makeServer(board: board)

        let forest = try RPC.structured(await server.answer(line: RPC.call("sessions.tree")))
        #expect(forest["sessionCount"]?.intValue == 2)
        let root = try #require(forest["roots"]?.arrayValue?.first)
        #expect(root["key"]?.stringValue == parent.description)
        #expect(root["children"]?.arrayValue?.first?["key"]?.stringValue == child.description)

        let branch = try RPC.structured(await server.answer(line: RPC.call("sessions.tree", [
            "session_key": .string(child.description)
        ])))
        #expect(branch["roots"]?.arrayValue?.first?["key"]?.stringValue == child.description)
    }

    // MARK: - Hooks

    private func hookLine(_ target: HookTarget, _ payload: [String: MCPJSON], pid: pid_t) -> Data {
        Data(HookEvent(
            target: target, pid: pid, receivedAt: Fixtures.date(90), payload: .object(payload)
        ).line().dropLast())
    }

    @Test("a PermissionRequest hook puts the session it names into Needs you")
    func hookFlipsASessionToNeedsYou() async throws {
        let (server, host, _) = try makeServer()

        // The line the short-lived `Auspex --hook claude` process writes.
        #expect(await server.answer(line: hookLine(.claude, [
            "hook_event_name": "PermissionRequest",
            "session_id": .string(Self.sessionKey.sessionID),
            "tool_name": "Bash",
            "cwd": "/Users/example/Code/widget"
        ], pid: Self.harnessPID)) == nil, "a notification: the hook does not wait for an answer")

        let observed = await host.observed
        #expect(observed.count == 1)
        #expect(observed[0].session == Self.sessionKey)
        let reducer = SessionStateReducer()
        var snapshot = try #require(await host.boardSnapshot().sessions.first)
        snapshot = reducer.reduce(snapshot, event: observed[0])
        #expect(snapshot.state == .waitingPermission(tool: "Bash"))

        // And the tool running afterwards takes it back out again.
        _ = await server.answer(line: hookLine(.claude, [
            "hook_event_name": "PostToolUse",
            "session_id": .string(Self.sessionKey.sessionID),
            "tool_name": "Bash"
        ], pid: Self.harnessPID))
        let resolved = await host.observed
        #expect(resolved.count == 2)
        snapshot = reducer.reduce(snapshot, event: resolved[1])
        #expect(snapshot.state != .waitingPermission(tool: "Bash"))
    }

    @Test("a hook with no session id is attributed to the process that ran it")
    func hookResolvesByProcess() async throws {
        let (server, host, _) = try makeServer()
        // Codex's notify carries no session id at all, and the hook is a direct
        // child of the harness — so the pid it reports is the evidence.
        _ = await server.answer(line: hookLine(.codexNotify, [
            "type": "agent-turn-complete",
            "turn-id": "t1"
        ], pid: Self.harnessPID))

        let observed = await host.observed
        #expect(observed.count == 1)
        #expect(observed[0].session == Self.sessionKey)
        #expect(observed[0].kind == .turnEnded(reason: .complete))
    }

    @Test("a hook Auspex cannot attribute changes nothing")
    func hookWithNothingToAttributeTo() async throws {
        let (server, host, _) = try makeServer()
        _ = await server.answer(line: hookLine(.codexNotify, [
            "type": "agent-turn-complete"
        ], pid: 4_242))
        #expect(await host.observed.isEmpty)

        // And a notification that is not a hook event at all is ignored.
        #expect(await server.answer(line: RPC.line("auspex/hookEvent")) == nil)
        #expect(await host.observed.isEmpty)
    }
}
