import AgentSessionKit
import AgentSessionLive
import Foundation
import Testing

@testable import AuspexCore

@Suite("EndedSessions")
struct EndedSessionsTests {
    private func session(
        _ id: String,
        state: SessionState = .thinking,
        endedAt: TimeInterval? = nil,
        lastEventAt: TimeInterval? = 0
    ) -> SessionSnapshot {
        var snapshot = SessionStateReducer.initialSnapshot(
            identity: SessionIdentity(
                key: SessionKey(harness: .claudeCode, sessionID: id),
                sourcePath: "/Users/example/store/\(id).jsonl",
                cwd: "/Users/example/Code/widget"
            )
        )
        snapshot.state = state
        snapshot.isAlive = !state.isEnded
        snapshot.lastEventAt = lastEventAt.map(Fixtures.date)
        snapshot.endedAt = endedAt.map(Fixtures.date)
        return snapshot
    }

    private func ended(_ id: String, at offset: TimeInterval) -> SessionSnapshot {
        session(id, state: .ended(reason: .exited), endedAt: offset, lastEventAt: offset)
    }

    // MARK: - Splitting

    @Test("only ended sessions leave the grid")
    func splitKeepsEverythingElse() {
        let sessions = [
            session("a", state: .thinking),
            ended("b", at: 10),
            session("c", state: .waitingPermission(tool: "Bash")),
            ended("d", at: 20),
            session("e", state: .idle)
        ]

        let split = EndedSessions.split(sessions)

        #expect(split.active.map(\.key.sessionID) == ["a", "c", "e"])
        #expect(split.ended.map(\.key.sessionID) == ["b", "d"])
    }

    @Test("a stale session stays on the grid")
    func staleIsNotEnded() {
        // A long `swift build` looks exactly like a dead process from the
        // outside. Staleness is a tag on a running card, not a reason to file
        // it under history.
        var stale = session("a", state: .toolCalling(name: "Bash"))
        stale.isStale = true
        stale.isAlive = false

        let split = EndedSessions.split([stale])

        #expect(split.active.count == 1)
        #expect(split.ended.isEmpty)
    }

    @Test("splitting preserves the order of each half")
    func splitPreservesOrder() {
        let sessions = (0..<10).map { index in
            index.isMultiple(of: 2)
                ? session("live-\(index)")
                : ended("done-\(index)", at: TimeInterval(index))
        }

        let split = EndedSessions.split(sessions)

        #expect(split.active.map(\.key.sessionID) == ["live-0", "live-2", "live-4", "live-6", "live-8"])
        #expect(split.ended.map(\.key.sessionID) == ["done-1", "done-3", "done-5", "done-7", "done-9"])
    }

    // MARK: - Ordering and the cap

    @Test("the most recently finished session is first")
    func mostRecentFirst() {
        let ordered = EndedSessions.mostRecentFirst([
            ended("old", at: 10),
            ended("newest", at: 900),
            ended("middle", at: 400)
        ])

        #expect(ordered.map(\.key.sessionID) == ["newest", "middle", "old"])
    }

    @Test("a session with no end time falls back to its last event")
    func fallsBackToLastEvent() {
        let noEndTime = session(
            "no-end", state: .ended(reason: .killed), endedAt: nil, lastEventAt: 500
        )
        let ordered = EndedSessions.mostRecentFirst([ended("older", at: 100), noEndTime])

        #expect(ordered.map(\.key.sessionID) == ["no-end", "older"])
    }

    @Test("sessions that stopped at the same instant keep a stable order")
    func tiesAreBrokenStably() {
        let first = EndedSessions.mostRecentFirst([ended("b", at: 10), ended("a", at: 10)])
        let second = EndedSessions.mostRecentFirst([ended("a", at: 10), ended("b", at: 10)])

        // A collapsed section that reshuffled between frames would be a
        // section nobody could click a row in.
        #expect(first.map(\.key.sessionID) == second.map(\.key.sessionID))
    }

    @Test("the collapsed section shows the twenty most recent")
    func collapsedShowsTheCap() {
        let sessions = (0..<57).map { ended("s\($0)", at: TimeInterval($0)) }

        let visible = EndedSessions.visible(sessions, showingAll: false)

        #expect(visible.count == EndedSessions.collapsedLimit)
        #expect(visible.first?.key.sessionID == "s56")
        #expect(visible.last?.key.sessionID == "s37")
        #expect(EndedSessions.hiddenCount(sessions, showingAll: false) == 37)
    }

    @Test("showing all shows all, and hides nothing")
    func showingAllShowsEverything() {
        let sessions = (0..<57).map { ended("s\($0)", at: TimeInterval($0)) }

        #expect(EndedSessions.visible(sessions, showingAll: true).count == 57)
        #expect(EndedSessions.hiddenCount(sessions, showingAll: true) == 0)
    }

    @Test("fewer finished sessions than the cap hides nothing")
    func underTheCapHidesNothing() {
        let sessions = (0..<3).map { ended("s\($0)", at: TimeInterval($0)) }

        #expect(EndedSessions.visible(sessions, showingAll: false).count == 3)
        #expect(EndedSessions.hiddenCount(sessions, showingAll: false) == 0)
    }

    // MARK: - The board's use of it

    @Test("the grid can be built without the finished sessions")
    func groupingCanExcludeEnded() {
        let board = BoardSnapshot(
            generatedAt: Fixtures.date(1_000),
            sessions: [
                session("live", state: .thinking),
                ended("done", at: 100)
            ]
        )

        let withEnded = BoardGrouping.groups(for: board, groupBy: .project)
        let withoutEnded = BoardGrouping.groups(
            for: board, groupBy: .project, includesEnded: false
        )

        #expect(withEnded.flatMap(\.sessions).count == 2)
        #expect(withoutEnded.flatMap(\.sessions).map(\.key.sessionID) == ["live"])
    }

    @Test("a board of nothing but finished sessions produces no sections")
    func allEndedProducesNoSections() {
        let board = BoardSnapshot(
            generatedAt: Fixtures.date(1_000),
            sessions: [ended("a", at: 10), ended("b", at: 20)]
        )

        // Not one empty section with a zero in it: the collapsed section below
        // the grid is where these belong, and a header over nothing would be a
        // header the reader has to work out.
        #expect(BoardGrouping.groups(for: board, groupBy: .project, includesEnded: false).isEmpty)
        #expect(BoardGrouping.groups(for: board, groupBy: .project).count == 1)
    }
}
