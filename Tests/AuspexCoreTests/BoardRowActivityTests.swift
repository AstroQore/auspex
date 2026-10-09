import AgentSessionKit
import AgentSessionLive
import Foundation
import Testing

@testable import AuspexCore

/// The card's own line for a harness that reports only "somebody is needed".
@Suite("BoardRow, tool-less permission")
struct ToollessPermissionRowTests {
    private func waiting(tool: String?) -> SessionSnapshot {
        let key = SessionKey(harness: .grokBot, sessionID: "bot-1")
        var snapshot = SessionStateReducer.initialSnapshot(
            identity: SessionIdentity(key: key, sourcePath: "/Users/example/store/bot-1.blob")
        )
        snapshot.state = .waitingPermission(tool: tool)
        snapshot.isAlive = true
        return snapshot
    }

    @Test("a permission with no tool asks for an answer, not for a tool")
    func toollessPermissionIsNotATool() {
        // Grok Bot's roster carries a flag and never a tool name. "a tool"
        // would be inventing the one fact the store does not have.
        #expect(BoardRowBuilder.activity(for: waiting(tool: nil)) == "an answer")
        #expect(BoardRowBuilder.activity(for: waiting(tool: "Bash")) == "Bash")
    }
}

/// What a card shows for a session the pipeline never folded a brief for.
@Suite("BoardRow, a brief rebuilt from the store")
struct BoardRowRebuiltBriefTests {
    private let key = Fixtures.key(.claudeCode, "pre-brief-session")
    private let assignment = "Make the resizer stop snapping back"

    /// A session as the v2 migration left one: an identity, a state, and an
    /// empty brief, because nothing was folding briefs when it ran.
    private func session(title: String? = nil) -> SessionSnapshot {
        var snapshot = SessionStateReducer.initialSnapshot(
            identity: Fixtures.identity(key: key, title: title)
        )
        snapshot.state = .idle
        snapshot.lastEventAt = Fixtures.date(60)
        return snapshot
    }

    private func board(_ session: SessionSnapshot) -> BoardSnapshot {
        BoardSnapshot(generatedAt: Fixtures.date(100), sessions: [session])
    }

    private var rebuilt: SessionBrief {
        SessionBrief(
            firstPrompt: assignment,
            firstPromptAt: Fixtures.date(1),
            latestAssistant: "The snap-back was a stale layout pass.",
            lastAssistantAt: Fixtures.date(90),
            lastTurnEndedAt: Fixtures.date(120)
        )
    }

    @Test("an empty brief falls back to the one the store can prove")
    func fallsBackWhenTheBriefIsEmpty() {
        let session = session()
        let builder = BoardRowBuilder(board: board(session), briefs: [key: rebuilt])
        let row = builder.row(for: session)

        #expect(row.assignedTask == assignment)
        #expect(row.latestAssistant == "The snap-back was a stale layout pass.")
        #expect(row.lastTurnEndedAt == Fixtures.date(120))
        // Nothing has been opened, and a turn closed: this is the state the
        // ledger exists to surface.
        #expect(row.isQuietReply)
        // The headline is read off the same brief the body is, so the
        // assignment is never printed twice.
        #expect(row.title == assignment)
    }

    @Test("with no fallback the card says what it always said")
    func withoutAFallbackNothingChanges() {
        let session = session()
        let row = BoardRowBuilder(board: board(session)).row(for: session)

        #expect(row.assignedTask == nil)
        #expect(row.lastTurnEndedAt == nil)
        #expect(!row.isQuietReply)
        #expect(row.title == "widget")
    }

    @Test("a harness's own title still outranks a rebuilt assignment")
    func theHarnessTitleStillWins() {
        let session = session(title: "Fix the widget resizer")
        let builder = BoardRowBuilder(board: board(session), briefs: [key: rebuilt])
        let row = builder.row(for: session)

        #expect(row.title == "Fix the widget resizer")
        #expect(row.assignedTask == assignment)
    }

    @Test("a session with a brief of its own is never second-guessed")
    func aLiveBriefIsNotDisplaced() {
        var session = session()
        session.brief = SessionBrief(
            firstPrompt: "What the pipeline actually folded",
            firstPromptAt: Fixtures.date(10)
        )
        let builder = BoardRowBuilder(board: board(session), briefs: [key: rebuilt])
        let row = builder.row(for: session)

        #expect(row.assignedTask == "What the pipeline actually folded")
        #expect(row.lastTurnEndedAt == nil)
    }
}

/// What an open call is aimed at, which a permission wait's own line omits.
@Suite("BoardRow, tool target")
struct BoardRowToolTargetTests {
    private func session(_ state: SessionState, calls: [PendingToolCall]) -> SessionSnapshot {
        let key = Fixtures.key(.claudeCode, "target-1")
        var snapshot = SessionStateReducer.initialSnapshot(identity: Fixtures.identity(key: key))
        snapshot.state = state
        snapshot.isAlive = true
        for call in calls { snapshot.pending.openToolCalls[call.id] = call }
        return snapshot
    }

    private func call(_ id: String, _ name: String, _ target: String?, at offset: TimeInterval)
        -> PendingToolCall {
        PendingToolCall(id: id, name: name, kind: .shell, target: target, startedAt: Fixtures.date(offset))
    }

    @Test("a permission wait names the call to its own tool")
    func permissionFindsItsCall() {
        let snapshot = session(
            .waitingPermission(tool: "Bash"),
            calls: [call("a", "Bash", "gh pr merge", at: 1), call("b", "Read", "notes.md", at: 2)]
        )
        #expect(BoardRowBuilder.toolTarget(for: snapshot) == "gh pr merge")
    }

    @Test("a tool call names its most recent target; idle names none")
    func toolCallAndIdle() {
        let calls = [call("a", "Read", "one.swift", at: 1), call("b", "Read", "two.swift", at: 2)]
        #expect(BoardRowBuilder.toolTarget(for: session(.toolCalling(name: "Read"), calls: calls))
            == "two.swift")
        #expect(BoardRowBuilder.toolTarget(for: session(.idle, calls: calls)) == nil)
        #expect(BoardRowBuilder.toolTarget(
            for: session(.waitingPermission(tool: nil), calls: calls)) == nil)
    }
}
