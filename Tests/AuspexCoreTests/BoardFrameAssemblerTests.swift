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

    @Test("a frame carries the wall, the ended units, the counts and the tree at once")
    func oneFrameAnswersEverySurface() {
        let frame = BoardFrameAssembler.frame(
            board: fixture,
            inputs: BoardFrameInputs(groupBy: .project)
        )

        // The finished session leaves the grid entirely and collects below it.
        let onTheWall = frame.rowGroups.flatMap(\.rows).map(\.key.sessionID)
        #expect(!onTheWall.contains("d"))
        #expect(frame.endedUnits.map(\.lead.key.sessionID) == ["d"])

        // Every session is in the index — a derivation that dropped one would
        // be a card nobody can select.
        #expect(frame.sessionIndex.count == 5)

        // The tree lists what is still running. The finished session is in the
        // board's Ended section instead of in both places, and the checkout it
        // was in still says it is there.
        let listed = frame.tree.projects.flatMap(\.checkouts).flatMap(\.units)
            + frame.tree.ungrouped
        // Four units lead four sessions; the delegated one is inside its
        // parent's rather than beside it, and the finished one has gone.
        let inTheTree = listed.map(\.lead.sessionID)
            + listed.flatMap { $0.members.map(\.key.sessionID) }
        #expect(Set(inTheTree).count == 4)
        #expect(!inTheTree.contains("d"))
        let finished = frame.tree.projects.flatMap(\.checkouts)
            .reduce(0) { $0 + $1.hiddenCount } + frame.tree.ungroupedHidden
        #expect(finished == 1)
        // Four units: the finished one has left the tree, and the delegated
        // session is inside its parent's rather than beside it.
        let counted = frame.tree.projects.reduce(0) { $0 + $1.sessionCount }
        #expect(counted == 4)

        // The blocked session is what the header counts, and the delegated one
        // is placed under the project its parent is in rather than in the
        // residue.
        #expect(frame.summary.needsYou == 1)
        #expect(frame.tree.ungrouped.isEmpty)
        #expect(frame.tree.projects.count == 2)
    }

    @Test("the crew's groups and the aviary's board are built only for their own mode")
    func modeOutputsAreBuiltForTheirMode() {
        let board = BoardFrameAssembler.frame(board: fixture, inputs: BoardFrameInputs())
        #expect(board.groups.isEmpty)
        #expect(board.sceneBoard.sessions.isEmpty)
        #expect(board.assembledFor == .board)
        // The rows the sidebar and the Tasks page read do not depend on it.
        #expect(!board.rowGroups.isEmpty)

        let crew = BoardFrameAssembler.frame(board: fixture, inputs: BoardFrameInputs(viewMode: .crew))
        #expect(!crew.groups.isEmpty)
        #expect(crew.sceneBoard.sessions.isEmpty)
        #expect(crew.rowGroups == board.rowGroups)

        let scene = BoardFrameAssembler.frame(board: fixture, inputs: BoardFrameInputs(viewMode: .scene))
        #expect(scene.groups.isEmpty)
        #expect(!scene.sceneBoard.sessions.isEmpty)
    }

    @Test("a frame assembled for another mode is never a repeat of the last one")
    func aModeSwitchIsNotARepeat() async {
        let assembler = BoardFrameAssembler()
        let first = await assembler.assemble(board: fixture, inputs: BoardFrameInputs(), sequence: 1)
        let same = await assembler.assemble(board: fixture, inputs: BoardFrameInputs(), sequence: 2)
        #expect(same.isRepeat)
        // The same board, looked at another way: the aviary's picture has to
        // be adopted even though no session moved.
        let scene = await assembler.assemble(
            board: fixture, inputs: BoardFrameInputs(viewMode: .scene), sequence: 3
        )
        #expect(!scene.isRepeat)
        #expect(!scene.sceneBoard.sessions.isEmpty)
        #expect(first.boardRevision == scene.boardRevision)
    }

    @Test("Now's lists are built in every mode, and its office only while the stage is open")
    func nowOutputsFollowTheStage() {
        // The sidebar counts what is asking for the reader in every mode.
        let board = BoardFrameAssembler.frame(board: fixture, inputs: BoardFrameInputs())
        #expect(board.now.counts.needsYou == 1)
        #expect(!board.includesOffice)

        let staged = BoardFrameAssembler.frame(
            board: fixture, inputs: BoardFrameInputs(viewMode: .now, showsStage: true)
        )
        #expect(staged.includesOffice)
        #expect(!staged.sceneBoard.sessions.isEmpty)
        // The permission wait is the one thing on this board that needs a
        // person; the delegated pair is one working row.
        #expect(staged.now.needsYou.map(\.row.key.sessionID) == ["b"])
        #expect(staged.now.working.contains { $0.row.key.sessionID == "a" && $0.subagents == 1 })

        let listOnly = BoardFrameAssembler.frame(
            board: fixture, inputs: BoardFrameInputs(viewMode: .now, showsStage: false)
        )
        #expect(!listOnly.includesOffice)
        #expect(listOnly.sceneBoard.sessions.isEmpty)
        #expect(listOnly.now == staged.now)
    }

    @Test("opening Now's stage is not a repeat, and brings the office with it")
    func openingTheStageIsNotARepeat() async {
        let assembler = BoardFrameAssembler()
        _ = await assembler.assemble(
            board: fixture, inputs: BoardFrameInputs(viewMode: .now, showsStage: false), sequence: 1
        )
        let opened = await assembler.assemble(
            board: fixture, inputs: BoardFrameInputs(viewMode: .now, showsStage: true), sequence: 2
        )
        #expect(!opened.isRepeat)
        #expect(!opened.sceneBoard.sessions.isEmpty)
    }

    @Test("a board's key lookup agrees with a scan of its sessions")
    func keyIndexAgreesWithTheSessions() {
        for session in fixture.sessions {
            #expect(fixture.session(for: session.key) == session)
        }
        #expect(fixture.session(for: SessionKey(harness: .cursor, sessionID: "absent")) == nil)
        // Filtering and placing keep the lookup in step with what is left.
        let kept = fixture.filtered { $0.key.sessionID != fixture.sessions[0].key.sessionID }
        #expect(kept.session(for: fixture.sessions[0].key) == nil)
        for session in kept.sessions { #expect(kept.session(for: session.key) == session) }
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
        #expect(frame.endedUnits.isEmpty)
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

    // MARK: What the assembler says about the frame before

    @Test("a repeat is stamped as one, and shares the values it repeats")
    func repeatedFrameIsStampedAndShared() async {
        let assembler = BoardFrameAssembler()
        let board = fixture
        let first = await assembler.assemble(
            board: board, inputs: BoardFrameInputs(), sequence: 1
        )
        #expect(!first.isRepeat)

        // The same sessions in a frame generated a moment later — exactly what
        // the registry publishes when one session gained an event that changed
        // nothing the window draws.
        let again = BoardSnapshot(
            generatedAt: Fixtures.date(200),
            sessions: board.sessions
        )
        let second = await assembler.assemble(
            board: again, inputs: BoardFrameInputs(), sequence: 2
        )
        #expect(second.isRepeat)
        #expect(second.boardRevision == first.boardRevision)
        // Shared, not merely equal: what the consumer holds is what it already
        // held, so the `==` in an `@Observable` setter is a pointer check.
        #expect(second.rowGroups == first.rowGroups)
        #expect(second.board.generatedAt == first.board.generatedAt)
    }

    @Test("a frame that moves a session says so, and bumps the board")
    func changedFrameIsNotARepeat() async {
        let assembler = BoardFrameAssembler()
        let first = await assembler.assemble(
            board: fixture, inputs: BoardFrameInputs(), sequence: 1
        )

        var sessions = fixture.sessions
        sessions[0].toolCallCount = 9
        let moved = BoardSnapshot(generatedAt: Fixtures.date(200), sessions: sessions)
        let second = await assembler.assemble(
            board: moved, inputs: BoardFrameInputs(), sequence: 2
        )

        #expect(!second.isRepeat)
        #expect(second.boardRevision > first.boardRevision)
    }

    @Test("a filter clicked over an unchanged board is not a repeat")
    func changedInputsAreNotARepeat() async {
        let assembler = BoardFrameAssembler()
        _ = await assembler.assemble(
            board: fixture, inputs: BoardFrameInputs(groupBy: .project), sequence: 1
        )
        let regrouped = await assembler.assemble(
            board: fixture, inputs: BoardFrameInputs(groupBy: .harness), sequence: 2
        )

        // The board said nothing new — the person did.
        #expect(!regrouped.isRepeat)
        #expect(regrouped.boardRevision == 1)
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
