import AgentSessionKit
import AgentSessionLive
import Foundation
import Testing

@testable import AuspexCore

/// Fixtures for the ledger: sessions with a brief and a state, and the rows
/// derived from them.
private enum Ledger {
    static let now = Fixtures.epoch

    static func session(
        _ id: String,
        state: SessionState,
        turnEndedAt: TimeInterval? = nil,
        lastEventAt: TimeInterval? = 0,
        firstPrompt: String? = "do the thing",
        latestPrompt: String? = nil,
        latestAssistant: String? = nil,
        title: String? = nil,
        harness: Harness = .claudeCode
    ) -> SessionSnapshot {
        let key = SessionKey(harness: harness, sessionID: id)
        var snapshot = SessionStateReducer.initialSnapshot(
            identity: SessionIdentity(
                key: key,
                sourcePath: "/Users/example/store/\(id).jsonl",
                cwd: "/Users/example/Code/widget",
                title: title
            )
        )
        snapshot.state = state
        snapshot.isAlive = !state.isEnded
        snapshot.lastEventAt = lastEventAt.map(Fixtures.date)
        if state.isEnded { snapshot.endedAt = snapshot.lastEventAt }
        snapshot.brief = SessionBrief(
            firstPrompt: firstPrompt,
            firstPromptAt: firstPrompt == nil ? nil : Fixtures.date(-600),
            latestPrompt: latestPrompt ?? firstPrompt,
            lastPromptAt: Fixtures.date(-60),
            latestAssistant: latestAssistant,
            lastAssistantAt: latestAssistant == nil ? nil : Fixtures.date(-30),
            lastTurnEndedAt: turnEndedAt.map(Fixtures.date)
        )
        return snapshot
    }

    static func board(_ sessions: [SessionSnapshot]) -> BoardSnapshot {
        BoardSnapshot(generatedAt: now, sessions: sessions)
    }

    static func rows(
        _ sessions: [SessionSnapshot],
        seenAt: [SessionKey: Date] = [:]
    ) -> [BoardRow] {
        let board = board(sessions)
        let builder = BoardRowBuilder(board: board, seenAt: seenAt)
        return builder.rows(for: sessions)
    }
}

@Suite("TaskLedger · done and unseen")
struct UnseenDoneTests {
    @Test("a closed turn nobody has opened is unseen")
    func neverOpened() {
        #expect(TaskLedger.isUnseenDone(
            state: .idle, lastTurnEndedAt: Fixtures.date(0), lastSeenAt: nil
        ,
            isChild: false,
            hasAssignment: true))
    }

    @Test("opening it after the turn closed clears the flag")
    func openedAfterwards() {
        #expect(TaskLedger.isUnseenDone(
            state: .idle, lastTurnEndedAt: Fixtures.date(0), lastSeenAt: Fixtures.date(1)
        ,
            isChild: false,
            hasAssignment: true) == false)
    }

    @Test("a turn that closed since the last look is unseen again")
    func closedAgainAfterReading() {
        #expect(TaskLedger.isUnseenDone(
            state: .idle, lastTurnEndedAt: Fixtures.date(10), lastSeenAt: Fixtures.date(5)
        ,
            isChild: false,
            hasAssignment: true))
    }

    @Test("a session that has never closed a turn is not done")
    func noTurnEver() {
        #expect(TaskLedger.isUnseenDone(
            state: .idle, lastTurnEndedAt: nil, lastSeenAt: nil
        ,
            isChild: false,
            hasAssignment: true) == false)
    }

    @Test("only a session that has stopped counts as done", arguments: [
        SessionState.thinking,
        .toolCalling(name: "Bash"),
        .writingFile(path: "/Users/example/a.swift"),
        .delegating(children: 1),
    ])
    func stillWorkingIsNotDone(_ state: SessionState) {
        // A turn that closed and another that opened is a session mid-answer,
        // not one waiting to be read.
        #expect(TaskLedger.isUnseenDone(
            state: state, lastTurnEndedAt: Fixtures.date(0), lastSeenAt: nil
        ,
            isChild: false,
            hasAssignment: true) == false)
    }

    @Test("being blocked outranks being done")
    func waitingIsNotDone() {
        #expect(TaskLedger.isUnseenDone(
            state: .waitingPermission(tool: "Bash"),
            lastTurnEndedAt: Fixtures.date(0),
            lastSeenAt: nil
        ,
            isChild: false,
            hasAssignment: true) == false)
    }

    @Test("a subagent's turn is a step in somebody's task, not a task")
    func childrenAreNotAssignments() {
        // Twelve children of one prompt would bury the one row that is
        // actually the person's.
        #expect(TaskLedger.isUnseenDone(
            state: .idle,
            lastTurnEndedAt: Fixtures.date(0),
            lastSeenAt: nil,
            isChild: true,
            hasAssignment: true
        ) == false)
    }

    @Test("a session with nothing to show for itself is not flagged")
    func noAssignmentIsNotFlagged() {
        // "done · 3 h ago" with no line above it sends a person to look at
        // something in order to find out what it was.
        #expect(TaskLedger.isUnseenDone(
            state: .idle,
            lastTurnEndedAt: Fixtures.date(0),
            lastSeenAt: nil,
            isChild: false,
            hasAssignment: false
        ) == false)
    }

    @Test("either kind of parent evidence makes a session a child")
    func bothLinksCount() {
        var identity = Fixtures.identity()
        #expect(!TaskLedger.isChild(identity))
        identity.parent = Fixtures.key(.claudeCode, "the-parent")
        #expect(TaskLedger.isChild(identity))

        var linkOnly = Fixtures.identity()
        // A link can be recorded before the parent's own key is known.
        linkOnly.parentLink = .spawnedProcess
        #expect(TaskLedger.isChild(linkOnly))
    }

    @Test("the whole-snapshot form asks all four questions")
    func snapshotFormAppliesEveryRule() {
        var session = Fixtures.snapshot()
        session.brief = SessionBrief(
            firstPrompt: "Make the resizer stop snapping back",
            firstPromptAt: Fixtures.date(0),
            lastTurnEndedAt: Fixtures.date(10)
        )
        #expect(TaskLedger.isUnseenDone(session, lastSeenAt: nil))
        #expect(TaskLedger.bucket(of: session, lastSeenAt: nil) == .doneUnseen)

        var child = session
        child.identity.parent = Fixtures.key(.claudeCode, "the-parent")
        #expect(!TaskLedger.isUnseenDone(child, lastSeenAt: nil))
        #expect(TaskLedger.bucket(of: child, lastSeenAt: nil) == .idle)
        // And it drops off the surface that asks what still wants attention.
        #expect(TaskLedger.wantsAttention(child, lastSeenAt: nil))
        var endedChild = child
        endedChild.state = .ended(reason: .exited)
        #expect(!TaskLedger.wantsAttention(endedChild, lastSeenAt: nil))

        var anonymous = session
        anonymous.brief.firstPrompt = nil
        anonymous.brief.firstPromptAt = nil
        #expect(!TaskLedger.isUnseenDone(anonymous, lastSeenAt: nil))
    }

    @Test("both shapes of done: still open, and exited", arguments: [
        SessionState.idle, .ended(reason: .exited),
    ])
    func idleAndEndedBothCount(_ state: SessionState) {
        #expect(TaskLedger.isUnseenDone(
            state: state, lastTurnEndedAt: Fixtures.date(0), lastSeenAt: nil
        ,
            isChild: false,
            hasAssignment: true))
    }
}

@Suite("TaskLedger · buckets")
struct TaskLedgerBucketTests {
    @Test("every state lands in exactly one bucket")
    func bucketsPerState() {
        #expect(TaskLedger.bucket(state: .waitingPermission(tool: nil), isUnseenDone: false)
            == .needsYou)
        #expect(TaskLedger.bucket(state: .thinking, isUnseenDone: false) == .working)
        #expect(TaskLedger.bucket(state: .toolCalling(name: "Bash"), isUnseenDone: false)
            == .working)
        #expect(TaskLedger.bucket(state: .writingFile(path: nil), isUnseenDone: false) == .working)
        #expect(TaskLedger.bucket(state: .delegating(children: 2), isUnseenDone: false) == .working)
        #expect(TaskLedger.bucket(state: .idle, isUnseenDone: false) == .idle)
        #expect(TaskLedger.bucket(state: .ended(reason: .exited), isUnseenDone: false) == .done)
    }

    @Test("unseen moves a stopped session out of idle and done")
    func unseenTakesPrecedence() {
        #expect(TaskLedger.bucket(state: .idle, isUnseenDone: true) == .doneUnseen)
        #expect(TaskLedger.bucket(state: .ended(reason: .exited), isUnseenDone: true)
            == .doneUnseen)
    }

    @Test("blocked wins over unseen, whatever a caller claims")
    func blockedWins() {
        #expect(TaskLedger.bucket(state: .waitingPermission(tool: "Bash"), isUnseenDone: true)
            == .needsYou)
    }

    @Test("the counts add up to the rows")
    func countsAreATotalPartition() {
        let rows = Ledger.rows([
            Ledger.session("a", state: .waitingPermission(tool: "Bash")),
            Ledger.session("b", state: .idle, turnEndedAt: 0),
            Ledger.session("c", state: .thinking),
            Ledger.session("d", state: .idle),
            Ledger.session("e", state: .ended(reason: .exited)),
        ])
        let counts = TaskLedger.counts(of: rows)
        #expect(counts == [.needsYou: 1, .doneUnseen: 1, .working: 1, .idle: 1, .done: 1])
        #expect(counts.values.reduce(0, +) == rows.count)
    }

    @Test("the menu bar keeps the live ones and the unread finished ones")
    func attentionSet() {
        let unread = Ledger.session("a", state: .ended(reason: .exited), turnEndedAt: 0)
        let read = Ledger.session("b", state: .ended(reason: .exited), turnEndedAt: 0)
        let live = Ledger.session("c", state: .thinking)

        #expect(TaskLedger.wantsAttention(unread, lastSeenAt: nil))
        #expect(TaskLedger.wantsAttention(read, lastSeenAt: Fixtures.date(60)) == false)
        #expect(TaskLedger.wantsAttention(live, lastSeenAt: Fixtures.date(60)))
    }
}

@Suite("TaskLedger · order")
struct TaskLedgerOrderTests {
    @Test("needs-you, then done-unseen, then working, then idle, then history")
    func bucketOrder() {
        let rows = Ledger.rows([
            Ledger.session("history", state: .ended(reason: .exited), lastEventAt: 5),
            Ledger.session("idle", state: .idle, lastEventAt: 4),
            Ledger.session("working", state: .toolCalling(name: "Bash"), lastEventAt: 3),
            Ledger.session("unseen", state: .idle, turnEndedAt: 2, lastEventAt: 2),
            Ledger.session("blocked", state: .waitingPermission(tool: "Bash"), lastEventAt: 1),
        ], seenAt: [
            SessionKey(harness: .claudeCode, sessionID: "idle"): Fixtures.date(100),
            SessionKey(harness: .claudeCode, sessionID: "history"): Fixtures.date(100),
        ])

        #expect(TaskLedger.sorted(rows).map(\.key.sessionID)
            == ["blocked", "unseen", "working", "idle", "history"])
    }

    @Test("a working session does not outrank one that finished an hour ago")
    func unseenBeatsBusy() {
        // The whole point. `BoardSnapshot.sorted` ranks by state, so the
        // `swift build` wins there; the ledger knows the other one is an
        // errand and this one is not.
        let rows = Ledger.rows([
            Ledger.session("busy", state: .toolCalling(name: "Bash"), lastEventAt: 600),
            Ledger.session("finished", state: .idle, turnEndedAt: -3_600, lastEventAt: -3_600),
        ])
        #expect(TaskLedger.sorted(rows).map(\.key.sessionID) == ["finished", "busy"])
    }

    @Test("the unseen ones are ordered by when their turn closed, newest first")
    func unseenOrderedByTurnEnd() {
        let rows = Ledger.rows([
            Ledger.session("older", state: .idle, turnEndedAt: 10, lastEventAt: 900),
            Ledger.session("newer", state: .idle, turnEndedAt: 60, lastEventAt: 100),
        ])
        // `lastEventAt` would put `older` first; the bucket's own clock is the
        // one that matters for a row that is about having finished.
        #expect(TaskLedger.sorted(rows).map(\.key.sessionID) == ["newer", "older"])
    }

    @Test("identical rows keep a stable order rather than shuffling")
    func stableTieBreak() {
        let rows = Ledger.rows([
            Ledger.session("bbb", state: .thinking, lastEventAt: 0),
            Ledger.session("aaa", state: .thinking, lastEventAt: 0),
        ])
        #expect(TaskLedger.sorted(rows).map(\.key.sessionID) == ["aaa", "bbb"])
        #expect(TaskLedger.sorted(rows.reversed()).map(\.key.sessionID) == ["aaa", "bbb"])
    }

    @Test("the snapshot order and the row order agree")
    func snapshotAndRowOrderMatch() {
        let sessions = [
            Ledger.session("history", state: .ended(reason: .exited), lastEventAt: 5),
            Ledger.session("working", state: .thinking, lastEventAt: 3),
            Ledger.session("unseen", state: .idle, turnEndedAt: 2, lastEventAt: 2),
            Ledger.session("blocked", state: .waitingPermission(tool: nil), lastEventAt: 1),
        ]
        let seen = [SessionKey(harness: .claudeCode, sessionID: "history"): Fixtures.date(100)]
        // The menu bar sorts snapshots and the wall sorts rows. One board.
        #expect(
            TaskLedger.sorted(sessions, seenAt: seen).map(\.key.sessionID)
                == TaskLedger.sorted(Ledger.rows(sessions, seenAt: seen)).map(\.key.sessionID)
        )
    }

    @Test("filtering to a bucket keeps the order it was given")
    func filterPreservesOrder() {
        let rows = TaskLedger.sorted(Ledger.rows([
            Ledger.session("a", state: .idle, turnEndedAt: 10),
            Ledger.session("b", state: .thinking),
            Ledger.session("c", state: .idle, turnEndedAt: 60),
        ]))
        #expect(TaskLedger.rows(rows, in: .doneUnseen).map(\.key.sessionID) == ["c", "a"])
        #expect(TaskLedger.rows(rows, in: .working).map(\.key.sessionID) == ["b"])
        #expect(TaskLedger.rows(rows, in: .needsYou).isEmpty)
    }
}

@Suite("BoardRow · the ledger fields")
struct BoardRowLedgerTests {
    @Test("a session with no harness title is headed by what it was asked to do")
    func assignmentBecomesTheTitle() {
        let row = Ledger.rows([
            Ledger.session("a", state: .idle, firstPrompt: "Backfill observed_at")
        ])[0]
        #expect(row.title == "Backfill observed_at")
        #expect(row.assignedTask == "Backfill observed_at")
    }

    @Test("a harness title still wins")
    func harnessTitleWins() {
        let row = Ledger.rows([
            Ledger.session("a", state: .idle, firstPrompt: "Backfill observed_at", title: "Backfill")
        ])[0]
        #expect(row.title == "Backfill")
        #expect(row.assignedTask == "Backfill observed_at")
    }

    @Test("the project is the last resort, not the second")
    func projectIsTheLastResort() {
        // Five sessions in one checkout used to be five identically-headed
        // cards. The assignment is what tells them apart.
        let row = Ledger.rows([
            Ledger.session("a", state: .idle, firstPrompt: nil, title: nil)
        ])[0]
        #expect(row.title == "widget")
    }

    @Test("the asked line is dropped when it would repeat the headline")
    func latestPromptSuppressedWhenRedundant() {
        let onlyOnePrompt = Ledger.rows([
            Ledger.session("a", state: .idle, firstPrompt: "Backfill observed_at")
        ])[0]
        #expect(onlyOnePrompt.latestPrompt == nil)

        let titledWithSamePrompt = Ledger.rows([
            Ledger.session(
                "b", state: .idle,
                firstPrompt: "First", latestPrompt: "Backfill", title: "Backfill"
            )
        ])[0]
        #expect(titledWithSamePrompt.latestPrompt == nil)
    }

    @Test("a follow-up that says something new is kept")
    func followUpKept() {
        let row = Ledger.rows([
            Ledger.session(
                "a", state: .idle,
                firstPrompt: "Wire the board", latestPrompt: "Now add the trace inspector",
                latestAssistant: "The inspector needs the tool-call ledger.",
                title: "Build the live board"
            )
        ])[0]
        #expect(row.latestPrompt == "Now add the trace inspector")
        #expect(row.latestAssistant == "The inspector needs the tool-call ledger.")
    }

    @Test("the unseen flag follows the seen-at map the builder was handed")
    func unseenFlagFromSeenMap() {
        let key = SessionKey(harness: .claudeCode, sessionID: "a")
        let session = Ledger.session("a", state: .idle, turnEndedAt: 10)

        #expect(Ledger.rows([session])[0].isUnseenDone)
        #expect(Ledger.rows([session], seenAt: [key: Fixtures.date(20)])[0].isUnseenDone == false)
        #expect(Ledger.rows([session], seenAt: [key: Fixtures.date(5)])[0].isUnseenDone)
    }
}

@Suite("BoardSummary · the done-unseen chip")
struct BoardSummaryLedgerTests {
    @Test("the chips read in the order the questions are asked")
    func chipOrder() {
        #expect(BoardSummary.Kind.allCases.map(\.rawValue)
            == ["needsYou", "doneUnseen", "working", "idle", "done"])
        #expect(BoardSummary.Kind.doneUnseen.label == "done unseen")
    }

    @Test("a summary over sessions counts what has not been read")
    func countsFromSessions() {
        let sessions = [
            Ledger.session("a", state: .idle, turnEndedAt: 10),
            Ledger.session("b", state: .idle, turnEndedAt: 10),
            Ledger.session("c", state: .thinking),
            Ledger.session("d", state: .waitingPermission(tool: nil)),
        ]
        let seen = [SessionKey(harness: .claudeCode, sessionID: "b"): Fixtures.date(20)]
        let summary = BoardSummary(sessions: sessions, seenAt: seen)

        #expect(summary.doneUnseen == 1)
        #expect(summary.idle == 2)
        #expect(summary.working == 1)
        #expect(summary.needsYou == 1)
        // Deliberately overlapping: `idle` answers "how much is sitting open",
        // `doneUnseen` answers "how much is waiting to be read".
        #expect(summary.value(for: .doneUnseen) == 1)
        #expect(summary.value(for: .idle) == 2)
    }

    @Test("the rows form and the sessions form agree")
    func rowsAndSessionsAgree() {
        let sessions = [
            Ledger.session("a", state: .idle, turnEndedAt: 10),
            Ledger.session("b", state: .ended(reason: .exited), turnEndedAt: 10),
            Ledger.session("c", state: .toolCalling(name: "Bash")),
        ]
        #expect(BoardSummary(rows: Ledger.rows(sessions)) == BoardSummary(sessions: sessions, seenAt: [:]))
    }

    @Test("an empty done-unseen chip is dropped, and done at zero is kept")
    func zeroChips() {
        let quiet = BoardSummary(sessions: [Ledger.session("a", state: .thinking)], seenAt: [:])
        #expect(quiet.chips.map(\.kind) == [.working, .done])
    }
}
