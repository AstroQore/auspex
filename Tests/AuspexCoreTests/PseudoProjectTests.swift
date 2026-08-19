import AgentSessionKit
import AgentSessionLive
import Foundation
import Testing

@testable import AuspexCore

/// The section a harness with no working directory gets.
///
/// Grok Bot is the only one, and it is the case that would otherwise land a
/// dozen conversations under a heading that means "could not be placed".
@Suite("PseudoProject")
struct PseudoProjectTests {
    private func session(
        _ harness: Harness,
        _ id: String,
        cwd: String? = nil,
        gitRoot: String? = nil,
        parent: SessionKey? = nil,
        title: String? = nil,
        at offset: TimeInterval = 0
    ) -> SessionSnapshot {
        let key = SessionKey(harness: harness, sessionID: id)
        var identity = SessionIdentity(
            key: key,
            sourcePath: "/Users/example/store/\(id)",
            cwd: cwd,
            gitRoot: gitRoot,
            title: title
        )
        identity.parent = parent
        if parent != nil { identity.parentLink = .subagent(toolUseID: nil) }
        var snapshot = SessionStateReducer.initialSnapshot(identity: identity)
        snapshot.state = .idle
        snapshot.isAlive = true
        snapshot.lastEventAt = Fixtures.date(offset)
        return snapshot
    }

    private func board(_ sessions: [SessionSnapshot]) -> BoardSnapshot {
        BoardSnapshot(generatedAt: Fixtures.date(100), sessions: sessions)
    }

    // MARK: - The key

    @Test("only Grok Bot's store has no working directory in it")
    func onlyGrokBotHasNoDirectory() {
        for harness in Harness.allCases where harness != .grokBot {
            #expect(harness.recordsWorkingDirectory, "\(harness.rawValue)")
        }
        #expect(!Harness.grokBot.recordsWorkingDirectory)
    }

    @Test("a pseudo key cannot be mistaken for a directory")
    func keysDoNotLookLikePaths() {
        let key = PseudoProject.key(for: .grokBot)
        // A real project key is `gitRoot ?? cwd`, and both are absolute.
        #expect(!key.hasPrefix("/"))
        #expect(PseudoProject.isPseudo(key))
        #expect(PseudoProject.harness(forKey: key) == .grokBot)
        #expect(PseudoProject.name(forKey: key) == "Grok Bot")

        for path in ["/Users/example/Code/widget", "/", "harness:", "harness:nonesuch"] {
            #expect(!PseudoProject.isPseudo(path), "\(path)")
            #expect(PseudoProject.name(forKey: path) == nil, "\(path)")
        }
    }

    // MARK: - Grouping

    @Test("a Grok Bot conversation groups under Grok Bot, not under No project")
    func grokBotSessionsGetTheirOwnSection() {
        let frame = board([
            session(.claudeCode, "a", cwd: "/Users/example/Code/widget", at: 10),
            session(.grokBot, "bot-1", title: "Scout", at: 8),
            session(.grokBot, "bot-2", title: "Archivist", at: 6)
        ])

        let groups = BoardGrouping.groups(for: frame, groupBy: .project)

        #expect(groups.map(\.title) == ["widget", "Grok Bot"])
        #expect(!groups.contains { $0.title == BoardGrouping.noProjectTitle })
        let bots = try? #require(groups.last)
        #expect(bots?.sessions.count == 2)
        // Nothing to show under the title: the harness name is the whole of
        // what there is to say, and there is no path.
        #expect(bots?.subtitle == nil)
        #expect(bots?.harness == .grokBot)
        #expect(frame.ungroupedSessions.isEmpty)
    }

    @Test("a session whose directory is merely missing is still the residue")
    func missingDirectoriesStayUngrouped() {
        // A subagent whose parent has aged off the board: the directory is
        // unknown, not absent by design, and saying so is the honest answer.
        let orphan = session(
            .claudeCode, "orphan",
            parent: SessionKey(harness: .claudeCode, sessionID: "gone"), at: 4
        )
        let frame = board([session(.grokBot, "bot-1", title: "Scout", at: 8), orphan])

        let groups = BoardGrouping.groups(for: frame, groupBy: .project)

        #expect(groups.map(\.title) == ["Grok Bot", BoardGrouping.noProjectTitle])
        #expect(frame.ungroupedSessions.map(\.key) == [orphan.key])
    }

    @Test("the pseudo key is never shown to anybody")
    func theKeyIsNeverRendered() {
        // Every surface that names a project — the board's section header,
        // the sidebar row, the trace header, the scene's floor plate — comes
        // through this one function.
        #expect(BoardGrouping.projectName(forPath: PseudoProject.key(for: .grokBot)) == "Grok Bot")
        #expect(BoardGrouping.projectName(forPath: "/Users/example/Code/widget") == "widget")
    }

    @Test("the sidebar puts the bots under a project row rather than in the residue")
    func sidebarTreeHasTheSection() {
        let frame = board([
            session(.grokBot, "bot-1", title: "Scout", at: 8),
            session(.grokBot, "bot-2", title: "Archivist", at: 6)
        ])

        let tree = ProjectTree.build(board: frame)

        #expect(tree.ungrouped.isEmpty)
        #expect(tree.projects.map(\.name) == ["Grok Bot"])
        let project = try? #require(tree.projects.first)
        #expect(project?.sessionCount == 2)
        #expect(project?.harnesses == [.grokBot])
        // Not a repository, and its one checkout is implied rather than
        // drawn — there is no branch, no worktree, and no directory to name.
        #expect(project?.isRepository == false)
        #expect(project?.checkouts.count == 1)
        #expect(project?.checkouts.first?.isWorktree == false)
        #expect(project?.checkouts.first?.agentWorktreeTask == nil)
    }

    @Test("filtering the board by the pseudo project keeps exactly the bots")
    func filteringByThePseudoProject() {
        let frame = board([
            session(.claudeCode, "a", cwd: "/Users/example/Code/widget", at: 10),
            session(.grokBot, "bot-1", title: "Scout", at: 8)
        ])

        let filtered = BoardGrouping.filtered(
            frame.sessions,
            harnessFilter: [],
            projectFilter: PseudoProject.key(for: .grokBot),
            in: frame
        )
        #expect(filtered.map(\.key.sessionID) == ["bot-1"])
    }
}
