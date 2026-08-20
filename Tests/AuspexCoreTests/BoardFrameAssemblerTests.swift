import AgentSessionKit
import AgentSessionLive
import Foundation
import Testing

@testable import AuspexCore

/// The derivation that used to live on the main actor, now that it is a
/// function of two values.
///
/// Two properties matter and neither is about speed. It must be **total** —
/// every session in the frame lands somewhere — and it must be **deterministic**,
/// because a board that produced a different order for the same inputs would
/// reshuffle under the reader's cursor whenever a frame arrived that changed
/// nothing.
@Suite("Board frame assembler")
struct BoardFrameAssemblerTests {
    private func session(
        _ id: String,
        harness: Harness = .claudeCode,
        state: SessionState = .thinking,
        cwd: String? = "/Users/example/Code/widget",
        parent: SessionKey? = nil,
        title: String? = nil,
        at offset: TimeInterval = 0
    ) -> SessionSnapshot {
        var snapshot = SessionStateReducer.initialSnapshot(
            identity: SessionIdentity(
                key: SessionKey(harness: harness, sessionID: id),
                sourcePath: "/Users/example/store/\(id).jsonl",
                parent: parent,
                cwd: cwd,
                gitRoot: cwd,
                title: title
            )
        )
        snapshot.state = state
        snapshot.isAlive = !state.isEnded
        snapshot.lastEventAt = Fixtures.date(offset)
        return snapshot
    }

    /// Two projects, five sessions, one of them delegated and one finished.
    private var fixture: BoardSnapshot {
        BoardSnapshot(
            generatedAt: Fixtures.date(100),
            sessions: [
                session("a", title: "Build the board", at: 10),
                session(
                    "b",
                    harness: .codex,
                    state: .waitingPermission(tool: "Bash"),
                    title: "Adapters",
                    at: 20
                ),
                session("c", cwd: nil, parent: SessionKey(harness: .claudeCode, sessionID: "a"), at: 5),
                session(
                    "d",
                    state: .ended(reason: .exited),
                    cwd: "/Users/example/Code/vendor",
                    title: "Sync",
                    at: 30
                ),
                session("e", harness: .cursor, cwd: "/Users/example/Code/vendor", title: "Docs", at: 8),
            ]
        )
    }

    // MARK: Determinism

    @Test("the same board and the same inputs produce the same frame")
    func sameInputsSameFrame() {
        let inputs = BoardFrameInputs(groupBy: .project)
        let first = BoardFrameAssembler.frame(board: fixture, inputs: inputs, sequence: 7)
        let second = BoardFrameAssembler.frame(board: fixture, inputs: inputs, sequence: 7)
        #expect(first == second)
    }

    @Test("every grouping axis is stable across repeated derivations")
    func everyAxisIsStable() {
        for axis in BoardGroupBy.allCases {
            let inputs = BoardFrameInputs(groupBy: axis)
            let first = BoardFrameAssembler.frame(board: fixture, inputs: inputs)
            let second = BoardFrameAssembler.frame(board: fixture, inputs: inputs)
            #expect(first.rowGroups == second.rowGroups, "\(axis) reshuffled")
            #expect(first.tree == second.tree, "\(axis) reshuffled the tree")
        }
    }

    // MARK: What one frame says

    @Test("a frame carries the wall, the ended rows, the counts and the tree at once")
    func oneFrameAnswersEverySurface() {
        let frame = BoardFrameAssembler.frame(
            board: fixture,
            inputs: BoardFrameInputs(groupBy: .project)
        )

        // The finished session leaves the grid entirely and collects below it.
        let onTheWall = frame.rowGroups.flatMap(\.rows).map(\.key.sessionID)
        #expect(!onTheWall.contains("d"))
        #expect(frame.endedRows.map(\.key.sessionID) == ["d"])

        // Every session is in the index and in the tree — a derivation that
        // dropped one would be a card nobody can select.
        #expect(frame.sessionIndex.count == 5)
        let inTheTree = frame.tree.projects.flatMap(\.checkouts).flatMap(\.sessions).count
            + frame.tree.ungrouped.count
        #expect(inTheTree == 5)

        // The blocked session is what the header counts, and the delegated one
        // is placed under the project its parent is in rather than in the
        // residue.
        #expect(frame.summary.needsYou == 1)
        #expect(frame.tree.ungrouped.isEmpty)
        #expect(frame.tree.projects.count == 2)
    }

    @Test("the sections a filter empties are dropped rather than drawn empty")
    func bucketFilterDropsEmptySections() {
        let filtered = BoardFrameAssembler.frame(
            board: fixture,
            inputs: BoardFrameInputs(groupBy: .project, bucketFilter: .needsYou)
        )
        #expect(filtered.rowGroups.count == 1)
        #expect(filtered.rowGroups.flatMap(\.rows).map(\.key.sessionID) == ["b"])
        // Counted before the filter: a chip that zeroed the others when clicked
        // would leave no way back to them.
        #expect(filtered.summary.working > 0)
    }

    @Test("an ignore rule takes a session out of every part of the frame")
    func ignoredSessionLeavesEverySurface() {
        let frame = BoardFrameAssembler.frame(
            board: fixture,
            inputs: BoardFrameInputs(
                rules: IgnoreRules([IgnoreRule(kind: .pathPrefix("/Users/example/Code/vendor"))]),
                groupBy: .project
            )
        )
        #expect(frame.ignoredKeys.count == 2)
        #expect(frame.board.sessions.count == 3)
        #expect(frame.sessionIndex.count == 3)
        #expect(frame.tree.projects.count == 1)
        #expect(frame.endedRows.isEmpty)
    }

    @Test("the person's own name for a project beats the store's")
    func claimsRenameTheTree() {
        let project = AuspexProject(
            name: "Everything",
            roots: ["/Users/example/Code/widget", "/Users/example/Code/vendor"]
        )
        let frame = BoardFrameAssembler.frame(
            board: fixture,
            inputs: BoardFrameInputs(
                claims: ProjectClaims(projects: [project]),
                groupBy: .project,
                projectNames: ["/Users/example/Code/widget": "From the store"]
            )
        )
        #expect(frame.rowGroups.count == 1)
        #expect(frame.rowGroups.first?.title == "Everything")
        #expect(frame.tree.projects.map(\.name) == ["Everything"])
    }

    // MARK: The actor around it

    @Test("the actor stamps what it built and counts it")
    func actorCountsAndStamps() async {
        let assembler = BoardFrameAssembler()
        #expect(await assembler.assembledCount == 0)

        let frame = await assembler.assemble(
            board: fixture,
            inputs: BoardFrameInputs(),
            sequence: 42
        )
        #expect(frame.sequence == 42)
        #expect(await assembler.assembledCount == 1)

        // Same answer through the actor as through the function it wraps: the
        // executor is where the work runs, not part of what it produces.
        #expect(frame == BoardFrameAssembler.frame(
            board: fixture,
            inputs: BoardFrameInputs(),
            sequence: 42
        ))
    }
}
