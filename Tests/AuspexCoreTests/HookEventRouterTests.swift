import AgentSessionKit
import AgentSessionLive
import Foundation
import Testing

@testable import AuspexCore

/// What a hook payload turns into, and what it deliberately does not.
///
/// The payload fixtures are the shapes the real harnesses send — Claude's
/// `hook_event_name` / `session_id` / `tool_name`, Cursor's camel-cased names,
/// Codex's `notify` object — hand-written, with `/Users/example` paths and
/// fabricated ids.
@Suite("Hook events")
struct HookEventRouterTests {
    private static let session = Fixtures.key(.claudeCode, "aaaa1111-2222-3333-4444-555555555555")

    private func hook(
        _ fields: [String: MCPJSON],
        target: HookTarget = .claude,
        pid: pid_t = 900
    ) -> HookEvent {
        HookEvent(
            target: target, pid: pid, receivedAt: Fixtures.date(60), payload: .object(fields)
        )
    }

    private func snapshot(_ state: SessionState = .thinking) -> SessionSnapshot {
        var snapshot = SessionStateReducer.initialSnapshot(
            identity: Fixtures.identity(key: Self.session)
        )
        snapshot.state = state
        snapshot.lastEventAt = Fixtures.date(30)
        return snapshot
    }

    // MARK: - The one thing no transcript records

    @Test("a permission request blocks the session, and the tool running unblocks it")
    func permissionRoundTrip() throws {
        var router = HookEventRouter()
        let reducer = SessionStateReducer()
        var snapshot = snapshot()

        let requested = router.events(
            for: hook([
                "hook_event_name": "PermissionRequest",
                "session_id": .string(Self.session.sessionID),
                "tool_name": "Bash",
                "tool_input": .object(["command": "rm -rf build"])
            ]),
            known: [Self.session],
            fallback: nil
        )
        #expect(requested.count == 1)
        #expect(requested[0].session == Self.session)
        guard case let .permissionRequested(id, tool) = requested[0].kind else {
            Issue.record("expected a permission request, got \(requested[0].kind)")
            return
        }
        #expect(tool == "Bash")
        #expect(id.hasPrefix("hook:"), "ids from hooks cannot collide with a transcript's")
        #expect(router.isWaitingForPermission(Self.session))

        snapshot = reducer.reduce(snapshot, event: requested[0])
        #expect(snapshot.state == .waitingPermission(tool: "Bash"))

        // The person said yes, so the tool ran. That is the only evidence
        // Claude writes down that the wait is over.
        let resolved = router.events(
            for: hook([
                "hook_event_name": "PostToolUse",
                "session_id": .string(Self.session.sessionID),
                "tool_name": "Bash",
                "tool_use_id": "toolu_01"
            ]),
            known: [Self.session],
            fallback: nil
        )
        #expect(resolved.count == 1)
        guard case let .permissionResolved(resolvedID, allowed) = resolved[0].kind else {
            Issue.record("expected a resolution, got \(resolved[0].kind)")
            return
        }
        #expect(resolvedID == id, "the id it was opened with, or the reducer keeps waiting")
        #expect(allowed)
        #expect(!router.isWaitingForPermission(Self.session))

        snapshot = reducer.reduce(snapshot, event: resolved[0])
        #expect(snapshot.state != .waitingPermission(tool: "Bash"))
    }

    @Test("a turn ending clears a permission whose answer was never seen")
    func stopClearsAStrandedPermission() {
        var router = HookEventRouter()
        _ = router.events(
            for: hook([
                "hook_event_name": "PermissionRequest",
                "session_id": .string(Self.session.sessionID),
                "tool_name": "Write"
            ]),
            known: [Self.session], fallback: nil
        )
        let stopped = router.events(
            for: hook([
                "hook_event_name": "Stop",
                "session_id": .string(Self.session.sessionID)
            ]),
            known: [Self.session], fallback: nil
        )
        #expect(stopped.count == 1)
        #expect(stopped[0].kind == .turnEnded(reason: .complete))
        #expect(!router.isWaitingForPermission(Self.session))
    }

    @Test("a resolution for a session that was never blocked says nothing")
    func resolutionWithoutARequest() {
        var router = HookEventRouter()
        let events = router.events(
            for: hook([
                "hook_event_name": "PostToolUse",
                "session_id": .string(Self.session.sessionID),
                "tool_name": "Read"
            ]),
            known: [Self.session], fallback: nil
        )
        #expect(events.isEmpty, "a tool call the tailer already describes is not news")
    }

    // MARK: - Lifecycle

    @Test("a session nobody has seen is seeded; one already on the board is only patched")
    func sessionStart() throws {
        var router = HookEventRouter()
        let payload: [String: MCPJSON] = [
            "hook_event_name": "SessionStart",
            "session_id": .string(Self.session.sessionID),
            "cwd": "/Users/example/Code/widget",
            "transcript_path": .string(
                "/Users/example/.claude/projects/-Users-example-Code-widget/"
                    + "\(Self.session.sessionID).jsonl"
            )
        ]

        let fresh = router.events(for: hook(payload), known: [], fallback: nil)
        #expect(fresh.count == 1)
        guard case let .sessionStarted(identity) = fresh[0].kind else {
            Issue.record("expected a seed, got \(fresh[0].kind)")
            return
        }
        #expect(identity.key == Self.session)
        #expect(identity.cwd == "/Users/example/Code/widget")
        #expect(identity.sourcePath.hasSuffix(".jsonl"))

        let known = router.events(for: hook(payload), known: [Self.session], fallback: nil)
        #expect(known.contains { $0.kind == .liveness(alive: true) })
        #expect(known.contains { if case .identityUpdated = $0.kind { true } else { false } })
        #expect(!known.contains { if case .sessionStarted = $0.kind { true } else { false } })
    }

    @Test("a subagent is named the same way the tailer names it, so one child is one row")
    func subagentKeysMatchTheTailer() throws {
        var router = HookEventRouter()
        let started = router.events(
            for: hook([
                "hook_event_name": "SubagentStart",
                "session_id": .string(Self.session.sessionID),
                "agent_id": "7f3a",
                "agent_type": "Explore"
            ]),
            known: [Self.session], fallback: nil
        )
        #expect(started.count == 1)
        guard case let .subagentStarted(child, agentType, _) = started[0].kind else {
            Issue.record("expected a subagent, got \(started[0].kind)")
            return
        }
        // `ClaudeSourceBuilder` builds `<parent>/agent-<id>` from the directory
        // listing. A hook that spelled it differently would put the same child
        // on the board twice.
        #expect(child.description == "claudeCode:\(Self.session.sessionID)/agent-7f3a")
        #expect(agentType == "Explore")

        // The tailer will report the same child a moment later. Applying both
        // leaves one.
        let reducer = SessionStateReducer()
        var parent = snapshot()
        parent = reducer.reduce(parent, event: started[0])
        parent = reducer.reduce(parent, event: AgentEvent(
            session: Self.session,
            timestamp: Fixtures.date(61),
            kind: .subagentStarted(child: child, agentType: "Explore", toolUseID: "toolu_02")
        ))
        #expect(parent.children == [child])
        #expect(parent.state == .delegating(children: 1))
    }

    @Test("what a subagent does lands on the subagent's row, when it has one")
    func subagentAttribution() {
        var router = HookEventRouter()
        let child = SessionKey(
            harness: .claudeCode, sessionID: "\(Self.session.sessionID)/agent-7f3a"
        )
        let events = router.events(
            for: hook([
                "hook_event_name": "PermissionRequest",
                "session_id": .string(Self.session.sessionID),
                "agent_id": "7f3a",
                "tool_name": "Bash"
            ]),
            known: [Self.session, child],
            fallback: nil
        )
        #expect(events.first?.session == child)

        // And on the parent's when the board has no child row, because a
        // fabricated row is worse than an event one level up.
        var second = HookEventRouter()
        let orphan = second.events(
            for: hook([
                "hook_event_name": "PermissionRequest",
                "session_id": .string(Self.session.sessionID),
                "agent_id": "7f3a",
                "tool_name": "Bash"
            ]),
            known: [Self.session],
            fallback: nil
        )
        #expect(orphan.first?.session == Self.session)
    }

    // MARK: - The other harnesses

    @Test("Cursor's hooks are lifecycle and heartbeat, never a tool count")
    func cursorEvents() {
        var router = HookEventRouter()
        let cursorSession = Fixtures.key(.cursor, "cccc-1111")

        let stopped = router.events(
            for: hook([
                "hook_event_name": "stop",
                "conversation_id": .string(cursorSession.sessionID)
            ], target: .cursor),
            known: [cursorSession], fallback: nil
        )
        #expect(stopped.map(\.kind) == [.turnEnded(reason: .complete)])

        let edited = router.events(
            for: hook([
                "hook_event_name": "afterFileEdit",
                "conversation_id": .string(cursorSession.sessionID)
            ], target: .cursor),
            known: [cursorSession], fallback: nil
        )
        // A note is a heartbeat and nothing else: the tailer will describe the
        // edit, and a `toolCallStarted` here would count it twice.
        #expect(edited.count == 1)
        guard case .note = edited[0].kind else {
            Issue.record("expected a heartbeat, got \(edited[0].kind)")
            return
        }

        let gated = router.events(
            for: hook([
                "hook_event_name": "beforeShellExecution",
                "conversation_id": .string(cursorSession.sessionID)
            ], target: .cursor),
            known: [cursorSession], fallback: nil
        )
        #expect(gated.isEmpty, "Cursor has no permission event, and this is not one")
    }

    @Test("Codex's notify has no session id, so the process it ran in answers")
    func codexResolvesByProcess() {
        var router = HookEventRouter()
        let codex = Fixtures.key(.codex, "0199c0de-0000-7000-8000-000000000001")
        let events = router.events(
            for: hook([
                "type": "agent-turn-complete",
                "turn-id": "t1",
                "last-assistant-message": "Done."
            ], target: .codexNotify),
            known: [codex],
            fallback: codex
        )
        #expect(events.count == 1)
        #expect(events[0].session == codex)
        #expect(events[0].kind == .turnEnded(reason: .complete))
    }

    @Test("Codex's hook table speaks Claude's schema, and its permission is the point")
    func codexHookTableEvents() {
        var router = HookEventRouter()
        let codex = Fixtures.key(.codex, "0199c0de-0000-7000-8000-00000000000a")

        let requested = router.events(
            for: hook([
                "hook_event_name": "PermissionRequest",
                "session_id": .string(codex.sessionID),
                "cwd": "/Users/example/Code/widget",
                "tool_name": "shell",
                "turn_id": "turn_1"
            ], target: .codex),
            known: [codex], fallback: nil
        )
        #expect(requested.count == 1)
        #expect(requested[0].session == codex)
        guard case let .permissionRequested(id, tool) = requested[0].kind else {
            Issue.record("expected a permission request, got \(requested[0].kind)")
            return
        }
        #expect(tool == "shell")
        #expect(router.isWaitingForPermission(codex))

        let resolved = router.events(
            for: hook([
                "hook_event_name": "PostToolUse",
                "session_id": .string(codex.sessionID),
                "tool_name": "shell",
                "tool_use_id": "call_01"
            ], target: .codex),
            known: [codex], fallback: nil
        )
        #expect(resolved.map(\.kind) == [.permissionResolved(id: id, allowed: true)])

        // Boundaries, and no seeded identity: a Codex row is keyed by the
        // rollout thread id its own tailer reads out of a file name.
        let started = router.events(
            for: hook([
                "hook_event_name": "SessionStart",
                "session_id": .string(codex.sessionID),
                "source": "startup",
                "transcript_path": "/Users/example/.codex/sessions/rollout.jsonl"
            ], target: .codex),
            known: [], fallback: nil
        )
        #expect(started.map(\.kind) == [.liveness(alive: true)])
        #expect(!started.contains { if case .sessionStarted = $0.kind { true } else { false } })

        let ended = router.events(
            for: hook([
                "hook_event_name": "SessionEnd",
                "session_id": .string(codex.sessionID),
                "reason": "other"
            ], target: .codex),
            known: [codex], fallback: nil
        )
        #expect(ended.map(\.kind) == [.sessionEnded(reason: .exited)])

        // Registered for none of these, and ignored if one arrives anyway.
        for name in ["PreToolUse", "SubagentStart", "UserPromptSubmit"] {
            #expect(router.events(
                for: hook([
                    "hook_event_name": .string(name),
                    "session_id": .string(codex.sessionID),
                    "agent_id": "7f3a"
                ], target: .codex),
                known: [codex], fallback: nil
            ).isEmpty, "\(name)")
        }
    }

    @Test("one Codex hooks file serves both harnesses, so the board says which row it is")
    func codexHooksResolveChatGPTWork() {
        var router = HookEventRouter()
        let id = "0199c0de-0000-7000-8000-00000000000b"
        let work = Fixtures.key(.chatgptWork, id)
        let events = router.events(
            for: hook([
                "hook_event_name": "Stop",
                "session_id": .string(id)
            ], target: .codex),
            known: [work], fallback: nil
        )
        // `~/.codex/hooks.json` is read by both, and the payload cannot say
        // which; the board already knows, because the rollout's originator did.
        #expect(events.map(\.session) == [work])
        #expect(events.map(\.kind) == [.turnEnded(reason: .complete)])

        // And when neither row exists, the process the hook ran in answers.
        var second = HookEventRouter()
        let byProcess = Fixtures.key(.codex, "0199c0de-0000-7000-8000-00000000000c")
        let fallen = second.events(
            for: hook(["hook_event_name": "Stop"], target: .codex),
            known: [byProcess], fallback: byProcess
        )
        #expect(fallen.map(\.session) == [byProcess])
    }

    @Test("an event Auspex cannot attribute is dropped rather than guessed at")
    func unattributable() {
        var router = HookEventRouter()
        #expect(router.events(
            for: hook(["type": "agent-turn-complete"], target: .codexNotify),
            known: [], fallback: nil
        ).isEmpty)
        #expect(router.events(
            for: hook(["session_id": .string(Self.session.sessionID)]),
            known: [Self.session], fallback: nil
        ).isEmpty, "a payload with no event name says nothing")
        #expect(router.events(
            for: hook([
                "hook_event_name": "SomethingNewerThanThisBuild",
                "session_id": .string(Self.session.sessionID)
            ]),
            known: [Self.session], fallback: nil
        ).isEmpty)
    }

    @Test("the map of blocked sessions is bounded")
    func permissionsAreBounded() {
        var router = HookEventRouter()
        let limit = HookEventRouter.trackedPermissionLimit
        for index in 0...(limit + 4) {
            let key = Fixtures.key(.claudeCode, "session-\(index)")
            _ = router.events(
                for: hook([
                    "hook_event_name": "PermissionRequest",
                    "session_id": .string(key.sessionID),
                    "tool_name": "Bash"
                ]),
                known: [key], fallback: nil
            )
        }
        #expect(!router.isWaitingForPermission(Fixtures.key(.claudeCode, "session-0")))
        #expect(router.isWaitingForPermission(Fixtures.key(.claudeCode, "session-\(limit + 4)")))
    }

    // MARK: - The wire

    @Test("an event survives the trip through the socket unchanged")
    func wireRoundTrip() throws {
        let original = hook([
            "hook_event_name": "Notification",
            "session_id": .string(Self.session.sessionID),
            "message": "Claude needs your permission to use Bash"
        ])
        let line = original.line()
        #expect(line.last == 0x0A, "one framed line")
        let decoded = try JSONDecoder().decode(MCPJSON.self, from: line.dropLast())
        let round = try #require(HookEvent(params: decoded["params"]))
        #expect(round.target == original.target)
        #expect(round.pid == original.pid)
        #expect(round.payload == original.payload)
        #expect(abs(round.receivedAt.timeIntervalSince(original.receivedAt)) < 0.001)

        // A notification with no target at all is not an Auspex hook event.
        #expect(HookEvent(params: .object(["pid": 1])) == nil)
        #expect(HookEvent(params: nil) == nil)
    }
}
