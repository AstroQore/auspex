import AgentSessionKit
import AgentSessionLive
import Foundation
import Testing

@testable import AuspexCore

/// Fixtures for the ledger: sessions with a brief and a state, and the rows
/// derived from them.
enum Ledger {
    static let now = Fixtures.epoch

    static func session(
        _ id: String,
        state: SessionState,
        turnEndedAt: TimeInterval? = nil,
        lastEventAt: TimeInterval? = 0,
        lastPromptAt: TimeInterval? = -60,
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
            lastPromptAt: lastPromptAt.map(Fixtures.date),
            latestAssistant: latestAssistant,
            lastAssistantAt: latestAssistant == nil ? nil : Fixtures.date(-30),
            lastTurnEndedAt: turnEndedAt.map(Fixtures.date)
        )
        return snapshot
    }

    static func key(_ id: String, _ harness: Harness = .claudeCode) -> SessionKey {
        SessionKey(harness: harness, sessionID: id)
    }

    /// A live call from one session's agent.
    static func notice(
        _ id: String,
        _ kind: AgentNoticeKind,
        message: String = "over to you",
        at: TimeInterval = -10
    ) -> AgentNotice {
        AgentNotice(session: key(id), kind: kind, message: message, createdAt: Fixtures.date(at))
    }

    static func board(_ sessions: [SessionSnapshot]) -> BoardSnapshot {
        BoardSnapshot(generatedAt: now, sessions: sessions)
    }

    static func rows(
        _ sessions: [SessionSnapshot],
        seenAt: [SessionKey: Date] = [:],
        notices: [SessionKey: AgentNotice] = [:],
        acknowledgedAt: [SessionKey: Date] = [:]
    ) -> [BoardRow] {
        let board = board(sessions)
        let builder = BoardRowBuilder(
            board: board,
            seenAt: seenAt,
            notices: notices,
            acknowledgedAt: acknowledgedAt
        )
        return builder.rows(for: sessions)
    }

    /// The attention map a frame would carry for these sessions.
    static func attention(
        _ sessions: [SessionSnapshot],
        notices: [SessionKey: AgentNotice] = [:],
        acknowledgedAt: [SessionKey: Date] = [:]
    ) -> [SessionKey: AttentionState] {
        var map: [SessionKey: AttentionState] = [:]
        for session in sessions {
            let state = TaskLedger.attention(
                of: session,
                notice: notices[session.key],
                acknowledgedAt: acknowledgedAt[session.key],
                now: now
            )
            guard state.isSignalling else { continue }
            map[session.key] = state
        }
        return map
    }
}

/// The faint dot, and the fact that it is only a dot.
@Suite("TaskLedger · the quiet reply")
struct QuietReplyTests {
    @Test("an idle session whose turn closed and was never opened")
    func neverOpened() {
        #expect(TaskLedger.isQuietReply(
            state: .idle,
            lastTurnEndedAt: Fixtures.date(0),
            lastSeenAt: nil,
            isChild: false,
            hasAssignment: true
        ))
    }

    @Test("opening it after the turn closed clears the dot")
    func openedAfterwards() {
        #expect(TaskLedger.isQuietReply(
            state: .idle,
            lastTurnEndedAt: Fixtures.date(0),
            lastSeenAt: Fixtures.date(1),
            isChild: false,
            hasAssignment: true
        ) == false)
    }

    @Test("a turn that closed since the last look brings it back")
    func closedAgainAfterReading() {
        #expect(TaskLedger.isQuietReply(
            state: .idle,
            lastTurnEndedAt: Fixtures.date(10),
            lastSeenAt: Fixtures.date(5),
            isChild: false,
            hasAssignment: true
        ))
    }

    @Test("a session still working, blocked, or over gets no dot", arguments: [
        SessionState.thinking,
        .toolCalling(name: "Bash"),
        .writingFile(path: "/Users/example/a.swift"),
        .delegating(children: 1),
        .waitingPermission(tool: "Bash"),
        .ended(reason: .exited),
    ])
    func onlyIdle(_ state: SessionState) {
        // Ended is in the collapsed fold, where a dot would be decoration; the
        // rest are mid-answer and not waiting on anybody.
        #expect(TaskLedger.isQuietReply(
            state: state,
            lastTurnEndedAt: Fixtures.date(0),
            lastSeenAt: nil,
            isChild: false,
            hasAssignment: true
        ) == false)
    }

    @Test("a subagent's turn is a step in somebody's task, not a task")
    func childrenAreNotAssignments() {
        #expect(TaskLedger.isQuietReply(
            state: .idle,
            lastTurnEndedAt: Fixtures.date(0),
            lastSeenAt: nil,
            isChild: true,
            hasAssignment: true
        ) == false)
    }

    @Test("a session with nothing to show for itself gets no dot")
    func noAssignmentIsNotFlagged() {
        #expect(TaskLedger.isQuietReply(
            state: .idle,
            lastTurnEndedAt: Fixtures.date(0),
            lastSeenAt: nil,
            isChild: false,
            hasAssignment: false
        ) == false)
    }

    @Test("a quiet reply is a dot and nothing else — no bucket, no count")
    func neverCounted() {
        // The whole point of the change. A machine that has been running
        // agents all week has hundreds of these, and a bucket that large is a
        // bucket nobody reads.
        let session = Ledger.session("a", state: .idle, turnEndedAt: 10)
        let row = Ledger.rows([session])[0]
        #expect(row.isQuietReply)
        #expect(row.attention == .none)
        #expect(TaskLedger.bucket(of: row) == .idle)
        #expect(BoardSummary(rows: [row]).doneReported == 0)
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
}

@Suite("TaskLedger · buckets")
struct TaskLedgerBucketTests {
    @Test("every state lands in exactly one bucket")
    func bucketsPerState() {
        func bucket(_ state: SessionState) -> TaskLedger.Bucket {
            TaskLedger.bucket(attention: .none, state: state)
        }
        #expect(bucket(.waitingPermission(tool: nil)) == .needsYou)
        #expect(bucket(.thinking) == .working)
        #expect(bucket(.toolCalling(name: "Bash")) == .working)
        #expect(bucket(.writingFile(path: nil)) == .working)
        #expect(bucket(.delegating(children: 2)) == .working)
        #expect(bucket(.idle) == .idle)
        #expect(bucket(.ended(reason: .exited)) == .ended)
    }

    @Test("attention outranks activity, in both directions")
    func attentionWins() {
        let call = AttentionState.needsYou(reason: "which one?", source: .agent)
        let done = AttentionState.doneReported(summary: "shipped", source: .agent)
        #expect(TaskLedger.bucket(attention: call, state: .thinking) == .needsYou)
        #expect(TaskLedger.bucket(attention: call, state: .ended(reason: .exited)) == .needsYou)
        // Attention and activity are independent: an agent that reports
        // finishing while a build is still running is both, and the receipt is
        // the more useful of the two.
        #expect(TaskLedger.bucket(attention: done, state: .toolCalling(name: "swift")) == .doneReported)
        #expect(TaskLedger.bucket(attention: done, state: .ended(reason: .exited)) == .doneReported)
    }

    @Test("the counts add up to the rows")
    func countsAreATotalPartition() {
        let sessions = [
            Ledger.session("a", state: .waitingPermission(tool: "Bash")),
            Ledger.session("b", state: .idle, turnEndedAt: 0),
            Ledger.session("c", state: .thinking),
            Ledger.session("d", state: .idle),
            Ledger.session("e", state: .ended(reason: .exited)),
        ]
        let rows = Ledger.rows(sessions, notices: [Ledger.key("b"): Ledger.notice("b", .done)])
        let counts = TaskLedger.counts(of: rows)
        #expect(counts == [.needsYou: 1, .doneReported: 1, .working: 1, .idle: 1, .ended: 1])
        #expect(counts.values.reduce(0, +) == rows.count)
    }

    @Test("the menu bar keeps the live ones and anything that spoke")
    func attentionSet() {
        let reported = Ledger.session("a", state: .ended(reason: .exited), turnEndedAt: 0)
        let quiet = Ledger.session("b", state: .ended(reason: .exited), turnEndedAt: 0)
        let live = Ledger.session("c", state: .thinking)

        #expect(TaskLedger.wantsAttention(
            reported,
            attention: .doneReported(summary: "shipped", source: .agent)
        ))
        // An ended session that never said anything is history, and history
        // belongs in the fold rather than in a panel about what is outstanding.
        #expect(TaskLedger.wantsAttention(quiet, attention: .none) == false)
        #expect(TaskLedger.wantsAttention(live, attention: .none))
    }
}

@Suite("TaskLedger · order")
struct TaskLedgerOrderTests {
    /// One board with one of everything, sorted.
    private func ordered() -> [String] {
        let sessions = [
            Ledger.session("history", state: .ended(reason: .exited), lastEventAt: 5),
            Ledger.session("idle", state: .idle, lastEventAt: 4),
            Ledger.session("working", state: .toolCalling(name: "Bash"), lastEventAt: 3),
            Ledger.session("reported", state: .idle, lastEventAt: 2),
            Ledger.session("blocked", state: .waitingPermission(tool: "Bash"), lastEventAt: 1),
        ]
        let rows = Ledger.rows(
            sessions,
            notices: [Ledger.key("reported"): Ledger.notice("reported", .done)]
        )
        return TaskLedger.sorted(rows).map(\.key.sessionID)
    }

    @Test("needs-you, then reported, then working, then idle, then history")
    func bucketOrder() {
        #expect(ordered() == ["blocked", "reported", "working", "idle", "history"])
    }

    @Test("a working session does not outrank one that reported an hour ago")
    func reportedBeatsBusy() {
        // The whole point. `BoardSnapshot.sorted` ranks by state, so the
        // `swift build` wins there; the ledger knows the other one is an
        // errand and this one is not.
        let sessions = [
            Ledger.session("busy", state: .toolCalling(name: "Bash"), lastEventAt: 600),
            Ledger.session("finished", state: .idle, lastEventAt: -3_600, lastPromptAt: -7_200),
        ]
        let rows = Ledger.rows(
            sessions,
            notices: [Ledger.key("finished"): Ledger.notice("finished", .done, at: -3_600)]
        )
        #expect(TaskLedger.sorted(rows).map(\.key.sessionID) == ["finished", "busy"])
    }

    @Test("the signalling ones are ordered by when they spoke, newest first")
    func orderedBySignal() {
        let sessions = [
            Ledger.session("older", state: .idle, lastEventAt: 900, lastPromptAt: -7_200),
            Ledger.session("newer", state: .idle, lastEventAt: 100, lastPromptAt: -7_200),
        ]
        // `lastEventAt` would put `older` first; the bucket's own clock is when
        // the thing that put it there was said.
        let rows = Ledger.rows(sessions, notices: [
            Ledger.key("older"): Ledger.notice("older", .done, at: -600),
            Ledger.key("newer"): Ledger.notice("newer", .done, at: -60),
        ])
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
            Ledger.session("reported", state: .idle, lastEventAt: 2),
            Ledger.session("blocked", state: .waitingPermission(tool: nil), lastEventAt: 1),
        ]
        let notices = [Ledger.key("reported"): Ledger.notice("reported", .done)]
        let attention = Ledger.attention(sessions, notices: notices)
        // The menu bar sorts snapshots and the wall sorts rows. One board.
        #expect(
            TaskLedger.sorted(sessions, attention: attention, notices: notices)
                .map(\.key.sessionID)
                == TaskLedger.sorted(Ledger.rows(sessions, notices: notices))
                    .map(\.key.sessionID)
        )
    }

    @Test("filtering to a bucket keeps the order it was given")
    func filterPreservesOrder() {
        let sessions = [
            Ledger.session("a", state: .idle, lastPromptAt: -7_200),
            Ledger.session("b", state: .thinking),
            Ledger.session("c", state: .idle, lastPromptAt: -7_200),
        ]
        let rows = TaskLedger.sorted(Ledger.rows(sessions, notices: [
            Ledger.key("a"): Ledger.notice("a", .done, at: -600),
            Ledger.key("c"): Ledger.notice("c", .done, at: -60),
        ]))
        #expect(TaskLedger.rows(rows, in: .doneReported).map(\.key.sessionID) == ["c", "a"])
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

    @Test("the reply dot follows the seen-at map the builder was handed")
    func quietReplyFromSeenMap() {
        let key = Ledger.key("a")
        let session = Ledger.session("a", state: .idle, turnEndedAt: 10)

        #expect(Ledger.rows([session])[0].isQuietReply)
        #expect(Ledger.rows([session], seenAt: [key: Fixtures.date(20)])[0].isQuietReply == false)
        #expect(Ledger.rows([session], seenAt: [key: Fixtures.date(5)])[0].isQuietReply)
    }

    @Test("a row carries the attention its frame derived")
    func rowCarriesAttention() {
        let session = Ledger.session("a", state: .idle, lastPromptAt: -7_200)
        let row = Ledger.rows(
            [session],
            notices: [Ledger.key("a"): Ledger.notice("a", .blocked, message: "which enum?")]
        )[0]
        #expect(row.attention == .needsYou(reason: "which enum?", source: .agent))
        #expect(row.needsPerson)
    }
}

@Suite("BoardSummary · the two loud chips")
struct BoardSummaryLedgerTests {
    @Test("the chips read in the order the questions are asked")
    func chipOrder() {
        #expect(BoardSummary.Kind.allCases.map(\.rawValue)
            == ["needsYou", "doneReported", "working", "idle", "ended"])
        #expect(BoardSummary.Kind.doneReported.label == "done")
        #expect(BoardSummary.Kind.needsYou.isAttention)
        #expect(BoardSummary.Kind.idle.isAttention == false)
    }

    @Test("a summary over sessions counts what was said, not what was inferred")
    func countsFromSessions() {
        let sessions = [
            // Idle with a closed turn nobody has read: the old `done unseen`,
            // and now simply idle.
            Ledger.session("a", state: .idle, turnEndedAt: 10),
            Ledger.session("b", state: .idle, lastPromptAt: -7_200),
            Ledger.session("c", state: .thinking),
            Ledger.session("d", state: .waitingPermission(tool: nil)),
        ]
        let notices = [Ledger.key("b"): Ledger.notice("b", .done)]
        let summary = BoardSummary(
            sessions: sessions,
            attention: Ledger.attention(sessions, notices: notices)
        )

        #expect(summary.doneReported == 1)
        #expect(summary.idle == 1)
        #expect(summary.working == 1)
        #expect(summary.needsYou == 1)
        // The five numbers partition the board: every session is in exactly
        // one, so the chips can never add up to more than the wall holds.
        #expect(summary.needsYou + summary.doneReported + summary.working
            + summary.idle + summary.ended == sessions.count)
    }

    @Test("the rows form and the sessions form agree")
    func rowsAndSessionsAgree() {
        let sessions = [
            Ledger.session("a", state: .idle, turnEndedAt: 10),
            Ledger.session("b", state: .ended(reason: .exited), turnEndedAt: 10),
            Ledger.session("c", state: .toolCalling(name: "Bash")),
        ]
        let notices = [Ledger.key("b"): Ledger.notice("b", .done)]
        #expect(
            BoardSummary(rows: Ledger.rows(sessions, notices: notices))
                == BoardSummary(
                    sessions: sessions,
                    attention: Ledger.attention(sessions, notices: notices)
                )
        )
    }

    @Test("a zero chip is dropped, and ended never gets one at all")
    func zeroChips() {
        let quiet = BoardSummary(
            sessions: [Ledger.session("a", state: .thinking)],
            attention: [:]
        )
        #expect(quiet.chips.map(\.kind) == [.working])

        let over = BoardSummary(
            sessions: [Ledger.session("a", state: .ended(reason: .exited))],
            attention: [:]
        )
        // The fold at the bottom of the board counts the history. A header
        // chip for it would be the loudest row in the window quoting the least
        // urgent number in it.
        #expect(over.chips.isEmpty)
        #expect(over.ended == 1)
    }

    @Test("the chip labels are the words the menu bar and the scene use")
    func labels() {
        for kind in BoardSummary.Kind.allCases {
            #expect(!kind.label.isEmpty)
        }
        let summary = BoardSummary(
            needsYou: 2, doneReported: 1, working: 3, idle: 4, ended: 5
        )
        for chip in summary.chips {
            #expect(summary.value(for: chip.kind) == chip.value)
        }
        #expect(summary.chips.map(\.value) == [2, 1, 3, 4])
        #expect(summary.live == 10)
    }
}
