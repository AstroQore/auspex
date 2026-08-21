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

    private func board(
        _ sessions: [SessionSnapshot],
        sandboxThreads: [SessionKey: String] = [:]
    ) -> BoardSnapshot {
        BoardSnapshot(
            generatedAt: Fixtures.date(100),
            sessions: sessions,
            sandboxThreads: sandboxThreads
        )
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

    // MARK: - Scratch

    @Test("a scratch key is its own kind, and names itself as one")
    func scratchKeys() {
        let scratch = PseudoProject.scratchKey(for: .codex)
        #expect(!scratch.hasPrefix("/"))
        #expect(PseudoProject.isPseudo(scratch))
        #expect(PseudoProject.isScratch(scratch))
        #expect(PseudoProject.harness(forKey: scratch) == .codex)
        #expect(PseudoProject.name(forKey: scratch) == "Codex · scratch")
        #expect(BoardGrouping.projectName(forPath: scratch) == "Codex · scratch")

        // The harness's own section is a different section, and says so.
        let plain = PseudoProject.key(for: .codex)
        #expect(plain != scratch)
        #expect(!PseudoProject.isScratch(plain))
        #expect(PseudoProject.name(forKey: plain) == "Codex")
        for path in ["/Users/example/Code/widget", "scratch:", "scratch:nonesuch"] {
            #expect(!PseudoProject.isScratch(path), "\(path)")
            #expect(PseudoProject.name(forKey: path) == nil, "\(path)")
        }
    }

    @Test("a desktop thread groups under the harness's scratch, not under its folder")
    func sandboxSessionsGetTheScratchSection() {
        let thread = session(
            .codex, "desk-1", cwd: "/Users/example/Documents/Codex/2026-08-21/zhe", at: 8)
        let other = session(
            .codex, "desk-2", cwd: "/Users/example/Documents/Codex/2026-08-18/zai-b", at: 7)
        let frame = board(
            [
                session(.claudeCode, "a", cwd: "/Users/example/Code/widget", at: 10),
                thread, other
            ],
            sandboxThreads: [thread.key: "zhe", other.key: "zai-b"]
        )

        let groups = BoardGrouping.groups(for: frame, groupBy: .project)

        // One section, not two projects called `zhe` and `zai-b`.
        #expect(groups.map(\.title) == ["widget", "Codex · scratch"])
        #expect(!groups.contains { $0.title == BoardGrouping.noProjectTitle })
        let scratch = try? #require(groups.last)
        #expect(scratch?.sessions.count == 2)
        #expect(scratch?.harness == .codex)
        // Not a directory, so there is no path to put under the heading.
        #expect(scratch?.subtitle == nil)
        #expect(frame.ungroupedSessions.isEmpty)
    }

    @Test("the card says which thread it is, since the section already says which harness")
    func theCardShowsTheFolder() {
        let thread = session(
            .codex, "desk-1", cwd: "/Users/example/Documents/Codex/2026-08-21/zhe",
            title: "Work out the retry backoff", at: 8)
        let plain = session(.claudeCode, "a", cwd: "/Users/example/Code/widget", at: 10)
        let frame = board([plain, thread], sandboxThreads: [thread.key: "zhe"])

        let rows = BoardRowBuilder(board: frame)
        #expect(rows.row(for: thread).project == "zhe")
        #expect(rows.row(for: thread).directory == "/Users/example/Documents/Codex/2026-08-21/zhe")
        // Everything else still shows the project it groups under.
        #expect(rows.row(for: plain).project == "widget")
    }

    @Test("a scratch thread whose harness differs gets its own section")
    func scratchIsPerHarness() {
        // The rule is about the *path*, and the two desktop apps share one.
        // Which section a session lands in is decided by whose session it is.
        let codex = session(
            .codex, "desk-1", cwd: "/Users/example/Documents/Codex/2026-08-21/zhe", at: 8)
        let work = session(
            .chatgptWork, "desk-2", cwd: "/Users/example/Documents/Codex/2026-08-21/rota", at: 7)
        let frame = board(
            [codex, work], sandboxThreads: [codex.key: "zhe", work.key: "rota"])

        let groups = BoardGrouping.groups(for: frame, groupBy: .project)
        #expect(groups.map(\.title) == ["Codex · scratch", "ChatGPT Work · scratch"])
    }

    @Test("a person who claims the folder gets their claim")
    func aClaimOutranksTheRule() {
        // The rule replaces the automatic key, and nothing else. Somebody who
        // deliberately put that directory in a project meant it.
        let thread = session(
            .codex, "desk-1", cwd: "/Users/example/Documents/Codex/2026-08-21/zhe", at: 8)
        let claims = ProjectClaims(projects: [
            AuspexProject(
                id: UUID(uuidString: "00000000-0000-0000-0000-0000000000a1")!,
                name: "Backoff study",
                roots: ["/Users/example/Documents/Codex/2026-08-21/zhe"]
            )
        ])
        let frame = BoardSnapshot(
            generatedAt: Fixtures.date(100),
            sessions: [thread],
            claims: claims,
            sandboxThreads: [thread.key: "zhe"]
        )

        let groups = BoardGrouping.groups(for: frame, groupBy: .project)
        #expect(groups.map(\.title) == ["Backoff study"])
    }

    @Test("a subagent of a scratch thread does not inherit a project from it")
    func childrenOfScratchStayInScratch() {
        let parent = session(
            .codex, "desk-1", cwd: "/Users/example/Documents/Codex/2026-08-21/zhe", at: 8)
        let child = session(.codex, "desk-1-child", parent: parent.key, at: 7)
        let frame = board([parent, child], sandboxThreads: [parent.key: "zhe"])

        // The parent has no project to lend, so the child lands where the
        // parent did rather than under a project named after a folder.
        #expect(frame.projectKey(for: child) == PseudoProject.scratchKey(for: .codex))
        #expect(frame.ungroupedSessions.isEmpty)
    }

    @Test("the sidebar lists one row per thread, and calls none of them a worktree")
    func sidebarListsThreads() {
        let one = session(
            .codex, "desk-1", cwd: "/Users/example/Documents/Codex/2026-08-21/zhe", at: 8)
        let two = session(
            .codex, "desk-2", cwd: "/Users/example/Documents/Codex/2026-08-18/zai-b", at: 7)
        let frame = board([one, two], sandboxThreads: [one.key: "zhe", two.key: "zai-b"])

        let tree = ProjectTree.build(board: frame)
        #expect(tree.ungrouped.isEmpty)
        #expect(tree.projects.map(\.name) == ["Codex · scratch"])
        let project = try? #require(tree.projects.first)
        #expect(project?.isRepository == false)
        // One row per conversation folder, so a person can still tell the
        // day's threads apart — and no branch glyph on any of them, because
        // there is no repository for them to be a checkout of.
        #expect(project?.checkouts.count == 2)
        #expect(project?.checkouts.allSatisfy { !$0.isWorktree } == true)
        #expect(project?.checkouts.allSatisfy { $0.branch == nil } == true)
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
