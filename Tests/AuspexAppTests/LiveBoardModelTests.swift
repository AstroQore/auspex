import AgentSessionKit
import AgentSessionLive
import AuspexCore
import Foundation
import Testing

@testable import AuspexApp

/// What the window renders after the user layer is applied: which sessions are
/// on the board at all, which project everything is bound to, and whether the
/// two agree.
///
/// Every assertion is preceded by a `settle()`, because the derivation runs on
/// ``BoardFrameAssembler`` rather than on the model's own actor — applying a
/// frame records it and asks for a frame, and what the window draws changes
/// when that comes back.
@MainActor
@Suite("Live board model")
struct LiveBoardModelTests {
    private func session(
        _ id: String,
        harness: Harness = .claudeCode,
        cwd: String?,
        parent: SessionKey? = nil,
        title: String? = nil
    ) -> SessionSnapshot {
        let key = SessionKey(harness: harness, sessionID: id)
        var snapshot = SessionStateReducer.initialSnapshot(
            identity: SessionIdentity(
                key: key,
                sourcePath: "/Users/example/store/\(id).jsonl",
                parent: parent,
                cwd: cwd,
                gitRoot: cwd,
                title: title
            )
        )
        snapshot.state = .thinking
        snapshot.isAlive = true
        snapshot.lastEventAt = Date(timeIntervalSince1970: 1_767_225_600)
        return snapshot
    }

    private func frame(_ sessions: [SessionSnapshot]) -> BoardSnapshot {
        BoardSnapshot(generatedAt: Date(timeIntervalSince1970: 1_767_225_600), sessions: sessions)
    }

    /// A model holding one frame: two projects, three sessions.
    private func model() async -> (LiveBoardModel, [SessionSnapshot]) {
        let sessions = [
            session("1", cwd: "/Users/example/Code/auspex", title: "Build the board"),
            session("2", harness: .codex, cwd: "/Users/example/Code/auspex", title: "Adapters"),
            session("3", cwd: "/Users/example/Code/vendor", title: "chore: sync the vendor tree"),
        ]
        let model = LiveBoardModel()
        model.apply(frame(sessions))
        await model.settle()
        await model.settle()
        return (model, sessions)
    }

    @Test("Every surface reads one filtered frame")
    func ignoredSessionsLeaveTheBoard() async {
        let (model, sessions) = await model()
        #expect(model.board.sessions.count == 3)

        model.setUserLayer(
            claims: .empty,
            rules: IgnoreRules([IgnoreRule(kind: .pathPrefix("/Users/example/Code/vendor"))]),
            showsIgnored: false
        )
        await model.settle()

        #expect(model.board.sessions.count == 2)
        #expect(model.rawBoard.sessions.count == 3)
        #expect(model.ignoredCount == 1)
        #expect(model.ignoredKeys == [sessions[2].key])
        #expect(model.summary.live == 2)
        #expect(model.rowGroups.count == 1)
    }

    @Test("Showing ignored sessions puts them back, still marked")
    func showIgnored() async {
        let (model, sessions) = await model()
        model.setUserLayer(
            claims: .empty,
            rules: IgnoreRules([IgnoreRule(kind: .titleContains("vendor"))]),
            showsIgnored: true
        )
        await model.settle()
        #expect(model.board.sessions.count == 3)
        #expect(model.ignoredKeys == [sessions[2].key])
    }

    @Test("A claimed pair of folders becomes one project, under its own name")
    func claimsPlaceAndRename() async {
        let model = LiveBoardModel()
        model.apply(frame([
            session("1", cwd: "/Users/example/Code/auspex"),
            session("2", cwd: "/Users/example/Code/agent-session-kit"),
        ]))
        await model.settle()
        #expect(model.rowGroups.count == 2)

        let project = AuspexProject(
            name: "Auspex and its kit",
            roots: ["/Users/example/Code/auspex", "/Users/example/Code/agent-session-kit"]
        )
        model.setUserLayer(
            claims: ProjectClaims(projects: [project]),
            rules: .none,
            showsIgnored: false
        )
        await model.settle()

        #expect(model.rowGroups.count == 1)
        #expect(model.rowGroups.first?.title == "Auspex and its kit")
    }

    @Test("Binding to a project narrows the wall and names itself")
    func focusNarrowsTheBoard() async {
        let (model, _) = await model()
        model.focusedProjectKey = "/Users/example/Code/auspex"
        await model.settle()

        #expect(model.rowGroups.count == 1)
        #expect(model.rowGroups.first?.rows.count == 2)
        #expect(model.focusedProjectName == "auspex")
        #expect(model.summary.live == 2)
    }

    @Test("Selecting a session binds to the project it is working in")
    func selectingASessionFocusesItsProject() async {
        let (model, sessions) = await model()
        model.focusProject(of: sessions[2].key)
        #expect(model.focusedProjectKey == "/Users/example/Code/vendor")

        // A subagent with no directory of its own follows its parent, so the
        // binding lands where the parent is rather than nowhere.
        let child = session("4", cwd: nil, parent: sessions[0].key)
        model.apply(frame(sessions + [child]))
        await model.settle()
        await model.settle()
        model.focusProject(of: child.key)
        #expect(model.focusedProjectKey == "/Users/example/Code/auspex")
    }

    @Test("Toggling the same project twice unbinds")
    func togglingClearsTheBinding() async {
        let (model, _) = await model()
        model.toggleFocusedProject("/Users/example/Code/auspex")
        #expect(model.focusedProjectKey == "/Users/example/Code/auspex")
        model.toggleFocusedProject("/Users/example/Code/auspex")
        #expect(model.focusedProjectKey == nil)
    }

    @Test("A rule needs the directory a session reported, not the abbreviated one")
    func directoryPathIsUnabbreviated() async {
        let (model, sessions) = await model()
        #expect(model.directoryPath(of: sessions[0].key) == "/Users/example/Code/auspex")
    }

    // MARK: Off the main actor

    @Test("A burst of frames costs one assembly of the last one")
    func burstCoalescesToTheLatest() async {
        let model = LiveBoardModel()
        var sessions: [SessionSnapshot] = []
        // Fifty frames, each one session longer, applied without yielding —
        // exactly what an ingest burst looks like after the 120 ms coalescing
        // has already thinned it.
        for index in 1...50 {
            sessions.append(session("\(index)", cwd: "/Users/example/Code/auspex"))
            model.apply(frame(sessions))
        }
        await model.settle()

        // The board shows the fiftieth frame, not one of the forty-nine that
        // were superseded while it was being built.
        #expect(model.sessionCount == 50)
        #expect(model.rowGroups.first?.rows.count == 50)

        // And it did not build fifty frames to get there. Fifty `apply` calls
        // without a suspension between them coalesce to a single assembly,
        // because the loop reads the inputs when it runs rather than when it
        // was asked; the bound is loose so that a scheduler that does let the
        // loop in partway through still passes.
        let built = await model.assembler.assembledCount
        #expect(built >= 1)
        #expect(built < 25, "assembled \(built) of 50 frames")
    }

    @Test("A frame older than the one on screen is refused")
    func staleFrameIsIgnored() async {
        let (model, sessions) = await model()
        #expect(model.sessionCount == 3)

        // A frame stamped before the one already applied: what an out-of-order
        // resumption would deliver, and what the sequence guard exists for.
        let stale = BoardFrameAssembler.frame(
            board: frame([sessions[0]]),
            inputs: BoardFrameInputs(),
            sequence: 1
        )
        model.adopt(stale)
        #expect(model.sessionCount == 3)

        // A newer stamp on the same frame is taken, so the guard is about
        // order and not about the frame's contents.
        let fresh = BoardFrameAssembler.frame(
            board: frame([sessions[0]]),
            inputs: BoardFrameInputs(),
            sequence: .max
        )
        model.adopt(fresh)
        #expect(model.sessionCount == 1)
    }

    @Test("A filter clicked and a frame applied reach the same board")
    func uiInputMatchesTheAssembler() async {
        let (model, _) = await model()
        model.focusedProjectKey = "/Users/example/Code/auspex"
        model.groupBy = .harness
        model.bucketFilter = .working
        await model.settle()

        // The same inputs, assembled directly: what the model shows must be
        // what the derivation says, whichever side of it changed.
        let expected = BoardFrameAssembler.frame(
            board: model.rawBoard,
            inputs: BoardFrameInputs(
                groupBy: .harness,
                harnessFilter: [],
                focusedProjectKey: "/Users/example/Code/auspex",
                bucketFilter: .working
            )
        )
        #expect(model.rowGroups == expected.rowGroups)
        #expect(model.summary == expected.summary)
        #expect(model.endedRows == expected.endedRows)
        #expect(model.groups == expected.groups)
    }
}
