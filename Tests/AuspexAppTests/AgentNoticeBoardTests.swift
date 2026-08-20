import AgentSessionKit
import AgentSessionLive
import AuspexCore
import Foundation
import Testing

@testable import AuspexApp

/// What happens to the board when an agent calls for a person: which bucket
/// the card lands in, what the numbers across the top say, and when the call
/// stops being live.
@MainActor
@Suite("Agent notices on the board")
struct AgentNoticeBoardTests {
    private static let epoch = Date(timeIntervalSince1970: 1_767_225_600)
    private static let key = SessionKey(harness: .claudeCode, sessionID: "session-1")

    private func session(
        state: SessionState = .idle,
        lastPromptAt: TimeInterval = 0,
        lastTurnEndedAt: TimeInterval? = nil
    ) -> SessionSnapshot {
        var snapshot = SessionStateReducer.initialSnapshot(
            identity: SessionIdentity(
                key: Self.key,
                sourcePath: "/Users/example/store/session-1.jsonl",
                cwd: "/Users/example/Code/auspex",
                title: "Wire the MCP surface"
            )
        )
        snapshot.state = state
        snapshot.isAlive = true
        snapshot.lastEventAt = Self.epoch.addingTimeInterval(60)
        snapshot.brief.firstPrompt = "Wire the MCP surface"
        snapshot.brief.lastPromptAt = Self.epoch.addingTimeInterval(lastPromptAt)
        snapshot.brief.lastTurnEndedAt = lastTurnEndedAt.map(Self.epoch.addingTimeInterval)
        return snapshot
    }

    private func frame(_ sessions: [SessionSnapshot]) -> BoardSnapshot {
        BoardSnapshot(generatedAt: Self.epoch.addingTimeInterval(60), sessions: sessions)
    }

    private func notice(
        _ kind: AgentNoticeKind,
        _ message: String = "Which of the two migrations should I keep?",
        at offset: TimeInterval = 10
    ) -> AgentNotice {
        AgentNotice(
            session: Self.key,
            kind: kind,
            message: message,
            createdAt: Self.epoch.addingTimeInterval(offset)
        )
    }

    private func visibleRow(_ model: LiveBoardModel) -> BoardRow? {
        model.rowGroups.flatMap(\.rows).first { $0.key == Self.key }
    }

    // MARK: - The bucket

    @Test("a call for a person moves an idle card into needs-you")
    func notifyMovesTheCard() throws {
        let model = LiveBoardModel()
        model.apply(frame([session(state: .idle)]))
        #expect(model.summary.needsYou == 0)
        #expect(model.summary.idle == 1)
        #expect(TaskLedger.bucket(of: try #require(visibleRow(model))) == .idle)

        model.apply(notice: notice(.needsInput))

        let after = try #require(visibleRow(model))
        #expect(after.notice?.kind == .needsInput)
        #expect(after.needsPerson)
        #expect(TaskLedger.bucket(of: after) == .needsYou)
        // Moved, not added: the five chips still add up to the one card.
        #expect(model.summary.needsYou == 1)
        #expect(model.summary.idle == 0)
        #expect(model.summary.live == 1)
    }

    @Test("a call from a session that looks busy still counts as blocked")
    func notifyBeatsTheInferredState() {
        let model = LiveBoardModel()
        model.apply(frame([session(state: .thinking)]))
        #expect(model.summary.working == 1)

        model.apply(notice: notice(.blocked, "the build cannot find the kit"))
        #expect(model.summary.needsYou == 1)
        #expect(model.summary.working == 0)
    }

    @Test("done is a receipt, not a call: it lands in done-unseen")
    func doneLandsInDoneUnseen() throws {
        let model = LiveBoardModel()
        model.apply(frame([session(state: .idle)]))
        model.apply(notice: notice(.done, "migration and 12 tests landed", at: 30))

        let row = try #require(visibleRow(model))
        #expect(TaskLedger.bucket(of: row) == .doneUnseen)
        #expect(model.summary.doneUnseen == 1)
        #expect(model.summary.needsYou == 0)
    }

    @Test("opening the card is what makes a done receipt read")
    func doneClearsWhenSeen() {
        let model = LiveBoardModel()
        model.apply(frame([session(state: .idle)]))
        model.apply(notice: notice(.done, "finished", at: 30))
        #expect(model.summary.doneUnseen == 1)

        model.markSeen(Self.key, at: Self.epoch.addingTimeInterval(40))
        #expect(model.summary.doneUnseen == 0)
    }

    // MARK: - Auto-clear

    @Test("answering the session clears its question on the next frame")
    func promptClearsANeedsInputNotice() {
        let model = LiveBoardModel()
        model.apply(frame([session(state: .idle, lastPromptAt: 0)]))
        model.apply(notice: notice(.needsInput, at: 10))
        #expect(model.summary.needsYou == 1)

        // The person typed into the session's own terminal; the tailer folds a
        // new prompt and the frame carries it.
        model.apply(frame([session(state: .thinking, lastPromptAt: 20)]))

        #expect(model.notices.isEmpty)
        #expect(model.summary.needsYou == 0)
        #expect(visibleRow(model)?.notice == nil)
    }

    @Test("a blocker is not answered by the person talking about something else")
    func promptDoesNotClearABlocker() {
        let model = LiveBoardModel()
        model.apply(frame([session(state: .idle, lastPromptAt: 0)]))
        model.apply(notice: notice(.blocked, "no network", at: 10))

        model.apply(frame([session(state: .thinking, lastPromptAt: 20)]))
        #expect(model.notices.count == 1)
        #expect(model.summary.needsYou == 1)
    }

    @Test("a prompt older than the question does not answer it")
    func stalepromptDoesNotClear() {
        let model = LiveBoardModel()
        model.apply(frame([session(state: .idle, lastPromptAt: 0)]))
        model.apply(notice: notice(.needsInput, at: 100))
        model.apply(frame([session(state: .idle, lastPromptAt: 50)]))
        #expect(model.notices.count == 1)
    }

    @Test("dismissing from the card takes it off the board")
    func dismissClears() {
        let model = LiveBoardModel()
        model.apply(frame([session(state: .idle)]))
        model.apply(notice: notice(.needsReview, "please look at the diff"))
        #expect(model.summary.needsYou == 1)

        model.dismissNotice(Self.key)
        #expect(model.notices.isEmpty)
        #expect(model.summary.needsYou == 0)
        #expect(visibleRow(model)?.notice == nil)
    }

    // MARK: - Reports

    @Test("a report replaces the inferred line until the session speaks again")
    func reportOverridesTheSaidLine() {
        var snapshot = session(state: .thinking)
        snapshot.brief.latestAssistant = "Reading the adapter."
        snapshot.brief.lastAssistantAt = Self.epoch.addingTimeInterval(5)
        let model = LiveBoardModel()
        model.apply(frame([snapshot]))
        #expect(visibleRow(model)?.reportedFocus == nil)

        model.apply(report: AgentReport(
            session: Self.key,
            focus: "rewriting the tailer",
            progress: "step 2 of 5",
            createdAt: Self.epoch.addingTimeInterval(10)
        ))
        #expect(visibleRow(model)?.reportedFocus == "rewriting the tailer · step 2 of 5")

        // The model has spoken since. An observation newer than the claim wins.
        snapshot.brief.latestAssistant = "Done with the cursor handling."
        snapshot.brief.lastAssistantAt = Self.epoch.addingTimeInterval(20)
        model.apply(frame([snapshot]))
        #expect(visibleRow(model)?.reportedFocus == nil)
        #expect(visibleRow(model)?.latestAssistant == "Done with the cursor handling.")
    }

    // MARK: - Ordering

    @Test("a calling session sorts above everything else on the board")
    func callersSortFirst() {
        let other = SessionKey(harness: .codex, sessionID: "session-2")
        var second = SessionStateReducer.initialSnapshot(
            identity: SessionIdentity(
                key: other,
                sourcePath: "/Users/example/store/session-2.jsonl",
                cwd: "/Users/example/Code/auspex",
                title: "Something busy"
            )
        )
        second.state = .toolCalling(name: "Bash")
        second.isAlive = true
        second.lastEventAt = Self.epoch.addingTimeInterval(120)

        let model = LiveBoardModel()
        model.apply(frame([session(state: .idle), second]))
        #expect(model.rowGroups.flatMap(\.rows).first?.key == other)

        model.apply(notice: notice(.needsInput))
        #expect(model.rowGroups.flatMap(\.rows).first?.key == Self.key)
    }
}
