import AgentSessionKit
import AgentSessionLive
import AuspexCore
import Foundation
import Testing

@testable import AuspexApp

/// What the window renders after the user layer is applied: which sessions are
/// on the board at all, which project everything is bound to, and whether the
/// two agree.
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
    private func model() -> (LiveBoardModel, [SessionSnapshot]) {
        let sessions = [
            session("1", cwd: "/Users/example/Code/auspex", title: "Build the board"),
            session("2", harness: .codex, cwd: "/Users/example/Code/auspex", title: "Adapters"),
            session("3", cwd: "/Users/example/Code/vendor", title: "chore: sync the vendor tree"),
        ]
        let model = LiveBoardModel()
        model.apply(frame(sessions))
        return (model, sessions)
    }

    @Test("Every surface reads one filtered frame")
    func ignoredSessionsLeaveTheBoard() {
        let (model, sessions) = model()
        #expect(model.board.sessions.count == 3)

        model.setUserLayer(
            claims: .empty,
            rules: IgnoreRules([IgnoreRule(kind: .pathPrefix("/Users/example/Code/vendor"))]),
            showsIgnored: false
        )

        #expect(model.board.sessions.count == 2)
        #expect(model.rawBoard.sessions.count == 3)
        #expect(model.ignoredCount == 1)
        #expect(model.ignoredKeys == [sessions[2].key])
        #expect(model.summary.live == 2)
        #expect(model.rowGroups.count == 1)
    }

    @Test("Showing ignored sessions puts them back, still marked")
    func showIgnored() {
        let (model, sessions) = model()
        model.setUserLayer(
            claims: .empty,
            rules: IgnoreRules([IgnoreRule(kind: .titleContains("vendor"))]),
            showsIgnored: true
        )
        #expect(model.board.sessions.count == 3)
        #expect(model.ignoredKeys == [sessions[2].key])
    }

    @Test("A claimed pair of folders becomes one project, under its own name")
    func claimsPlaceAndRename() {
        let model = LiveBoardModel()
        model.apply(frame([
            session("1", cwd: "/Users/example/Code/auspex"),
            session("2", cwd: "/Users/example/Code/agent-session-kit"),
        ]))
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

        #expect(model.rowGroups.count == 1)
        #expect(model.rowGroups.first?.title == "Auspex and its kit")
    }

    @Test("Binding to a project narrows the wall and names itself")
    func focusNarrowsTheBoard() {
        let (model, _) = model()
        model.focusedProjectKey = "/Users/example/Code/auspex"

        #expect(model.rowGroups.count == 1)
        #expect(model.rowGroups.first?.rows.count == 2)
        #expect(model.focusedProjectName == "auspex")
        #expect(model.summary.live == 2)
    }

    @Test("Selecting a session binds to the project it is working in")
    func selectingASessionFocusesItsProject() {
        let (model, sessions) = model()
        model.focusProject(of: sessions[2].key)
        #expect(model.focusedProjectKey == "/Users/example/Code/vendor")

        // A subagent with no directory of its own follows its parent, so the
        // binding lands where the parent is rather than nowhere.
        let child = session("4", cwd: nil, parent: sessions[0].key)
        model.apply(frame(sessions + [child]))
        model.focusProject(of: child.key)
        #expect(model.focusedProjectKey == "/Users/example/Code/auspex")
    }

    @Test("Toggling the same project twice unbinds")
    func togglingClearsTheBinding() {
        let (model, _) = model()
        model.toggleFocusedProject("/Users/example/Code/auspex")
        #expect(model.focusedProjectKey == "/Users/example/Code/auspex")
        model.toggleFocusedProject("/Users/example/Code/auspex")
        #expect(model.focusedProjectKey == nil)
    }

    @Test("A rule needs the directory a session reported, not the abbreviated one")
    func directoryPathIsUnabbreviated() {
        let (model, sessions) = model()
        #expect(model.directoryPath(of: sessions[0].key) == "/Users/example/Code/auspex")
    }
}
