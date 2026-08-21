import AgentSessionKit
import AgentSessionLive
import Foundation
import Testing

@testable import AuspexCore

@Suite("BoardSummary")
struct BoardSummaryTests {
    private func session(
        _ id: String,
        state: SessionState,
        isAlive: Bool = true
    ) -> SessionSnapshot {
        var snapshot = SessionStateReducer.initialSnapshot(
            identity: SessionIdentity(
                key: SessionKey(harness: .claudeCode, sessionID: id),
                sourcePath: "/Users/example/store/\(id).jsonl",
                cwd: "/Users/example/Code/widget"
            )
        )
        snapshot.state = state
        snapshot.isAlive = isAlive
        snapshot.lastEventAt = Fixtures.date(0)
        return snapshot
    }

    // MARK: - Folding

    @Test("thinking, tooling, writing, and delegating all count as working")
    func workingFoldsFourStates() {
        let counts = BoardSnapshot.Counts(sessions: [
            session("a", state: .thinking),
            session("b", state: .toolCalling(name: "Bash")),
            session("c", state: .writingFile(path: "/Users/example/Code/widget/main.swift")),
            session("d", state: .delegating(children: 2))
        ])
        let summary = BoardSummary(counts: counts)

        // The distinction between them is what the cards are for. A header
        // that split them would make the reader add three numbers up before
        // they could answer the question they came with.
        #expect(summary.working == 4)
        #expect(summary.needsYou == 0)
        #expect(summary.idle == 0)
        #expect(summary.ended == 0)
    }

    @Test("each of the other three kinds counts exactly one state")
    func theOtherKindsAreOneStateEach() {
        let summary = BoardSummary(counts: BoardSnapshot.Counts(sessions: [
            session("a", state: .waitingPermission(tool: "Bash")),
            session("b", state: .idle),
            session("c", state: .idle),
            session("d", state: .ended(reason: .exited), isAlive: false)
        ]))

        #expect(summary.needsYou == 1)
        #expect(summary.idle == 2)
        #expect(summary.ended == 1)
        #expect(summary.working == 0)
    }

    @Test("live is everything that has not finished")
    func liveExcludesOnlyTheFinished() {
        let summary = BoardSummary(counts: BoardSnapshot.Counts(sessions: [
            session("a", state: .waitingPermission(tool: "Bash")),
            session("b", state: .thinking),
            session("c", state: .idle),
            session("d", state: .ended(reason: .exited), isAlive: false),
            session("e", state: .ended(reason: .killed), isAlive: false)
        ]))

        #expect(summary.live == 3)
        #expect(summary.ended == 2)
    }

    @Test("a summary of a frame agrees with a summary of its counts")
    func frameAndCountsAgree() {
        let board = BoardSnapshot(
            generatedAt: Fixtures.date(10),
            sessions: [
                session("a", state: .thinking),
                session("b", state: .waitingPermission(tool: "Bash"))
            ]
        )
        #expect(BoardSummary(board: board) == BoardSummary(counts: board.counts))
    }

    // MARK: - Chips

    @Test("a chip with nothing in it is dropped")
    func emptyChipsAreDropped() {
        let summary = BoardSummary(counts: BoardSnapshot.Counts(sessions: [
            session("a", state: .thinking)
        ]))
        let kinds = summary.chips.map(\.kind)

        // A red chip that is always on screen is a red chip nobody looks at,
        // and the same goes for the green one beside it.
        #expect(kinds == [.working])
        #expect(summary.chips.first?.value == 1)
    }

    @Test("chips read in urgency order, and history is not one of them")
    func chipsAreInUrgencyOrder() {
        let summary = BoardSummary(counts: BoardSnapshot.Counts(sessions: [
            session("a", state: .idle),
            session("b", state: .thinking),
            session("c", state: .waitingPermission(tool: "Bash")),
            session("d", state: .ended(reason: .exited), isAlive: false)
        ]))

        // The finished session is counted and gets no chip: the fold at the
        // bottom of the board is where history is read.
        #expect(summary.chips.map(\.kind) == [.needsYou, .working, .idle])
        #expect(summary.chips.map(\.value) == [1, 1, 1])
        #expect(summary.ended == 1)
    }

    @Test("an empty board shows no chips at all")
    func emptyBoardShowsNothing() {
        let summary = BoardSummary(board: .empty)
        #expect(summary.chips.isEmpty)
        #expect(summary.live == 0)
    }

    @Test("every kind has a label, and `value(for:)` agrees with the chips")
    func kindsAreLabelledAndConsistent() {
        let summary = BoardSummary(counts: BoardSnapshot.Counts(sessions: [
            session("a", state: .waitingPermission(tool: "Bash")),
            session("b", state: .toolCalling(name: "Bash")),
            session("c", state: .idle),
            session("d", state: .ended(reason: .exited), isAlive: false)
        ]))
        for kind in BoardSummary.Kind.allCases {
            #expect(!kind.label.isEmpty)
        }
        for chip in summary.chips {
            #expect(summary.value(for: chip.kind) == chip.value)
        }
    }
}
