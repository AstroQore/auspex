import AgentSessionKit
import AgentSessionLive
import Foundation

/// Synthetic sessions and event scripts for the store and registry suites.
///
/// Everything here is hand-written. No path, id, or transcript line comes from
/// a real session: fixtures live under `/Users/example`, and the prompts are
/// written for the test rather than captured from one.
enum Fixtures {
    /// A fixed instant, so a test that compares timestamps compares values
    /// rather than races. 2026-01-01T00:00:00Z.
    static let epoch = Date(timeIntervalSince1970: 1_767_225_600)

    static func date(_ offset: TimeInterval) -> Date {
        epoch.addingTimeInterval(offset)
    }

    static func key(
        _ harness: Harness = .claudeCode,
        _ id: String = "11111111-2222-3333-4444-555555555555"
    ) -> SessionKey {
        SessionKey(harness: harness, sessionID: id)
    }

    static func identity(
        key: SessionKey = Fixtures.key(),
        cwd: String? = "/Users/example/Code/widget",
        gitRoot: String? = nil,
        title: String? = "Fix the widget resizer",
        model: String? = "a-test-model",
        pid: pid_t? = 4242
    ) -> SessionIdentity {
        SessionIdentity(
            key: key,
            sourcePath: "/Users/example/.claude/projects/widget/\(key.sessionID).jsonl",
            variant: "cli",
            cwd: cwd,
            gitRoot: gitRoot,
            gitBranch: "feat/resizer",
            pid: pid,
            procStart: Fixtures.date(-60),
            title: title,
            model: model,
            entrypoint: "terminal"
        )
    }

    static func event(
        _ kind: AgentEventKind,
        key: SessionKey = Fixtures.key(),
        at offset: TimeInterval,
        sequence: Int64 = 0,
        raw: RawRef? = nil
    ) -> AgentEvent {
        AgentEvent(
            session: key,
            timestamp: Fixtures.date(offset),
            observedAt: Fixtures.date(offset),
            sequence: sequence,
            kind: kind,
            raw: raw
        )
    }

    /// A stored-shaped snapshot: an identity, a state, and counters, with an
    /// empty brief unless a caller fills one in.
    static func snapshot(
        key: SessionKey = Fixtures.key(),
        state: SessionState = .idle
    ) -> SessionSnapshot {
        var snapshot = SessionStateReducer.initialSnapshot(identity: identity(key: key))
        snapshot.state = state
        snapshot.startedAt = Fixtures.date(0)
        snapshot.lastEventAt = Fixtures.date(60)
        snapshot.turnCount = 2
        snapshot.toolCallCount = 5
        snapshot.tokensIn = 100
        snapshot.tokensOut = 20
        return snapshot
    }

    /// One complete turn, start to finish, in the order a reducer expects:
    /// the session appears, a person asks for something, one tool runs, the
    /// turn closes, the session exits.
    static func oneTurnScript(key: SessionKey = Fixtures.key()) -> [AgentEvent] {
        [
            event(.sessionStarted(identity: identity(key: key)), key: key, at: 0),
            event(.userPrompt(preview: "Make the resizer stop snapping back"), key: key, at: 1),
            event(.textBody(role: .user, text: "Make the resizer stop snapping back", toolCallID: nil), key: key, at: 1),
            event(
                .toolCallStarted(id: "call-1", name: "Bash", kind: .shell, target: "swift build"),
                key: key,
                at: 2,
                raw: RawRef(path: "/Users/example/.claude/projects/widget/t.jsonl", byteOffset: 2048)
            ),
            event(.toolCallFinished(id: "call-1", isError: false), key: key, at: 3),
            event(.turnEnded(reason: .complete), key: key, at: 4),
            event(.sessionEnded(reason: .exited), key: key, at: 5)
        ]
    }

    /// The states ``oneTurnScript(key:)`` walks through, per the reducer's
    /// transition table. A finished tool call hands the floor back to the
    /// model, which is `thinking` rather than `idle` — only `turnEnded` means
    /// nothing more is coming.
    static let oneTurnStates: [SessionState] = [
        .idle,
        .thinking,
        .toolCalling(name: "Bash"),
        .thinking,
        .idle,
        .ended(reason: .exited)
    ]

    /// Collapses runs of equal elements, so a comparison is about the order
    /// states were reached and not about how many frames each one spanned.
    static func collapsingRuns<T: Equatable>(_ values: [T]) -> [T] {
        var result: [T] = []
        for value in values where result.last != value {
            result.append(value)
        }
        return result
    }
}
