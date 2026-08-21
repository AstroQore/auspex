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
