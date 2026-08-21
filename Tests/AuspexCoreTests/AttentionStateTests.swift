import AgentSessionKit
import AgentSessionLive
import Foundation
import Testing

@testable import AuspexCore

/// The attention axis: where a signal comes from, and everything that takes it
/// away again.
///
/// This is the suite the whole change stands on. The old board inferred "done
/// and unseen" from a closed turn, which was true of hundreds of sessions at
/// once and made two counts nobody could act on. What replaces it counts only
/// what something *said* — so the interesting assertions are the negative
/// ones: a turn ending is not a signal, and every signal has an end.
@Suite("AttentionState")
struct AttentionStateTests {
    private let now = Fixtures.epoch

    private func at(_ offset: TimeInterval) -> Date { Fixtures.date(offset) }

    private func notice(
        _ kind: AgentNoticeKind,
        message: String = "over to you",
        createdAt: TimeInterval = -60,
        clearedAt: TimeInterval? = nil
    ) -> AgentNotice {
        AgentNotice(
            session: Fixtures.key(.claudeCode, "s-1"),
            kind: kind,
            message: message,
            createdAt: at(createdAt),
            clearedAt: clearedAt.map(at)
        )
    }

    // MARK: - The three sources

    @Test("an agent that says it is stuck lands in needs-you", arguments: [
        AgentNoticeKind.needsInput, .needsReview, .blocked,
    ])
    func agentCalls(_ kind: AgentNoticeKind) {
        let state = AttentionState.derive(
            state: .idle,
            notice: notice(kind, message: "which enum ships?"),
            lastPromptAt: at(-600),
            now: now
        )
        #expect(state == .needsYou(reason: "which enum ships?", source: .agent))
        #expect(state.wantsPerson)
        // The agent's own sentence, verbatim. It is the only line on the card
        // somebody wrote on purpose.
        #expect(state.message == "which enum ships?")
    }

    @Test("an agent that reports finishing lands in done, not in needs-you")
    func agentReportsDone() {
        let state = AttentionState.derive(
            state: .idle,
            notice: notice(.done, message: "shipped the partial decode"),
            lastPromptAt: at(-600),
            now: now
        )
        #expect(state == .doneReported(summary: "shipped the partial decode", source: .agent))
        #expect(state.isDoneReported)
        #expect(!state.wantsPerson)
    }

    @Test("a harness permission wait is needs-you, from the harness")
    func harnessWait() {
        // A `PermissionRequest` hook, Codex's guardian, Grok's
        // `permission_requested`, Antigravity's status 9 and Grok Bot's
        // `awaitingUserResponse` all arrive as this one state, which is why
        // one code path serves the lot.
        let state = AttentionState.derive(
            state: .waitingPermission(tool: "Bash"),
            notice: nil,
            lastEventAt: at(-30),
            now: now
        )
        #expect(state == .needsYou(reason: "Waiting for permission: Bash", source: .harness))
    }

    @Test("a harness wait with no tool named says so rather than inventing one")
    func harnessWaitWithoutTool() {
        // Grok Bot's roster carries a flag and no name: its bot is waiting on
        // an answer, not on an approval.
        let state = AttentionState.derive(
            state: .waitingPermission(tool: nil),
            notice: nil,
            lastEventAt: at(-30),
            now: now
        )
        #expect(state == .needsYou(reason: "Waiting for an answer", source: .harness))
    }

    @Test("the agent's own words beat the harness's account of the same block")
    func agentBeatsHarness() {
        let state = AttentionState.derive(
            state: .waitingPermission(tool: "Bash"),
            notice: notice(.blocked, message: "the migration needs a decision"),
            lastPromptAt: at(-600),
            lastEventAt: at(-30),
            now: now
        )
        #expect(state == .needsYou(reason: "the migration needs a decision", source: .agent))
    }

    // MARK: - What is not a signal

    @Test("a turn simply ending is not a signal")
    func turnEndedIsNothing() {
        // The change, in one assertion. This used to be the board's second
        // loudest bucket and is now a dot on a card.
        #expect(AttentionState.derive(state: .idle, notice: nil, now: now) == .none)
        #expect(AttentionState.derive(
            state: .ended(reason: .exited), notice: nil, now: now
        ) == .none)
    }

    @Test("working, thinking and delegating say nothing on their own", arguments: [
        SessionState.thinking,
        .toolCalling(name: "Bash"),
        .writingFile(path: "/Users/example/a.swift"),
        .delegating(children: 3),
    ])
    func activityIsNotAttention(_ state: SessionState) {
        #expect(AttentionState.derive(state: state, notice: nil, now: now) == .none)
    }

    @Test("a notice the store already cleared is gone")
    func clearedNotice() {
        #expect(AttentionState.derive(
            state: .idle,
            notice: notice(.blocked, clearedAt: -30),
            now: now
        ) == .none)
    }

    // MARK: - Clearing

    @Test("opening the card clears an agent's call")
    func acknowledgementClears() {
        #expect(AttentionState.derive(
            state: .idle,
            notice: notice(.blocked, createdAt: -600),
            acknowledgedAt: at(-300),
            now: now
        ) == .none)
    }

    @Test("an acknowledgement older than the call does not clear it")
    func staleAcknowledgement() {
        // The agent asked again after you looked. That is a new question.
        let state = AttentionState.derive(
            state: .idle,
            notice: notice(.blocked, createdAt: -60),
            acknowledgedAt: at(-600),
            now: now
        )
        #expect(state.wantsPerson)
    }

    @Test("opening the card clears a receipt too")
    func acknowledgementClearsDone() {
        #expect(AttentionState.derive(
            state: .idle,
            notice: notice(.done, createdAt: -600),
            acknowledgedAt: at(-300),
            now: now
        ) == .none)
    }

    @Test("talking to the session in its own terminal clears it")
    func promptClears() {
        // The one clearing gesture that happens where the *work* is. Nobody
        // should have to visit Auspex to tell it something they have already
        // told the agent.
        #expect(AttentionState.derive(
            state: .thinking,
            notice: notice(.needsInput, createdAt: -600),
            lastPromptAt: at(-120),
            now: now
        ) == .none)
    }

    @Test("a prompt older than the call leaves it standing")
    func earlierPromptDoesNotClear() {
        let state = AttentionState.derive(
            state: .idle,
            notice: notice(.needsInput, createdAt: -60),
            lastPromptAt: at(-600),
            now: now
        )
        #expect(state.wantsPerson)
    }

    @Test("an agent that went back to work has stopped asking")
    func backToWorkClearsNeedsYou() {
        // Whatever it was waiting for arrived somewhere Auspex cannot see, and
        // a card still shouting about it teaches its reader that red means
        // nothing.
        #expect(AttentionState.derive(
            state: .toolCalling(name: "Bash"),
            notice: notice(.blocked, createdAt: -600),
            lastPromptAt: at(-1_200),
            lastEventAt: at(-30),
            now: now
        ) == .none)
    }

    @Test("a second block after the first does not count as going back to work")
    func blockedAgainDoesNotClear() {
        let state = AttentionState.derive(
            state: .waitingPermission(tool: "Bash"),
            notice: notice(.needsInput, createdAt: -600),
            lastPromptAt: at(-1_200),
            lastEventAt: at(-30),
            now: now
        )
        #expect(state.wantsPerson)
    }

    @Test("a receipt survives the agent carrying on")
    func doneSurvivesWork() {
        // The two axes are independent: an agent can finish the task it was
        // given and still have a `swift build` running.
        let state = AttentionState.derive(
            state: .toolCalling(name: "swift"),
            notice: notice(.done, createdAt: -600),
            lastPromptAt: at(-1_200),
            lastEventAt: at(-5),
            now: now
        )
        #expect(state.isDoneReported)
    }

    @Test("a day-old call clears itself")
    func ageOut() {
        #expect(AttentionState.derive(
            state: .idle,
            notice: notice(.blocked, createdAt: -AttentionState.ageOut - 1),
            lastPromptAt: at(-AttentionState.ageOut - 2),
            now: now
        ) == .none)
        // And one just inside the window does not.
        #expect(AttentionState.derive(
            state: .idle,
            notice: notice(.blocked, createdAt: -AttentionState.ageOut + 60),
            lastPromptAt: at(-AttentionState.ageOut - 2),
            now: now
        ).wantsPerson)
    }

    @Test("a day-old permission wait clears itself too")
    func harnessWaitAgesOut() {
        // A session that has been sitting at a prompt since yesterday is not
        // something anybody is going to answer; whatever terminal it was in
        // has almost certainly gone.
        #expect(AttentionState.derive(
            state: .waitingPermission(tool: "Bash"),
            notice: nil,
            lastEventAt: at(-AttentionState.ageOut - 1),
            now: now
        ) == .none)
    }

    @Test("answering in the terminal clears a harness wait")
    func promptClearsHarnessWait() {
        #expect(AttentionState.derive(
            state: .waitingPermission(tool: "Bash"),
            notice: nil,
            lastPromptAt: at(-5),
            lastEventAt: at(-30),
            now: now
        ) == .none)
    }

    @Test("an acknowledgement does not un-block a genuinely blocked session")
    func acknowledgementDoesNotClearHarnessWait() {
        // Clicking a card does not answer a permission prompt. A board that
        // let you dismiss this would be hiding the one thing it exists to
        // show.
        let state = AttentionState.derive(
            state: .waitingPermission(tool: "Bash"),
            notice: nil,
            acknowledgedAt: at(-1),
            lastEventAt: at(-30),
            now: now
        )
        #expect(state == .needsYou(reason: "Waiting for permission: Bash", source: .harness))
    }
}
