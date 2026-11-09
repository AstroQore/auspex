import AgentSessionKit
import AgentSessionLive
import Foundation
import Testing

@testable import AuspexCore

/// Projectless: the one section every session outside a project files under,
/// whichever of the old per-harness keys — or none — it would have had.
@Suite("PseudoProject")
struct PseudoProjectTests {
    private func session(
        _ harness: Harness,
        _ id: String,
        cwd: String? = nil,
        gitRoot: String? = nil,
        parent: SessionKey? = nil,
        title: String? = nil,
        variant: String? = nil,
        at offset: TimeInterval = 0
    ) -> SessionSnapshot {
        let key = SessionKey(harness: harness, sessionID: id)
        var identity = SessionIdentity(
            key: key,
            sourcePath: "/Users/example/store/\(id)",
            variant: variant,
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

    @Test("every spelling of Projectless is Projectless, and none of them is a path")
    func projectlessKeys() {
        let keys = [
            PseudoProject.projectlessKey,
            PseudoProject.key(for: .grokBot),
            PseudoProject.scratchKey(for: .codex),
            PseudoProject.scratchKey(for: .cursor),
        ]
        for key in keys {
            // A real project key is `gitRoot ?? cwd`, and both are absolute.
            #expect(!key.hasPrefix("/"), "\(key)")
            #expect(PseudoProject.isPseudo(key), "\(key)")
            #expect(PseudoProject.isProjectless(key), "\(key)")
            #expect(PseudoProject.canonical(key) == PseudoProject.projectlessKey, "\(key)")
            #expect(PseudoProject.name(forKey: key) == "Projectless", "\(key)")
            #expect(BoardGrouping.projectName(forPath: key) == "Projectless", "\(key)")
        }
        // The one section names no harness; the keys earlier builds wrote
        // still say whose they were.
        #expect(PseudoProject.harness(forKey: PseudoProject.projectlessKey) == nil)
        #expect(PseudoProject.harness(forKey: PseudoProject.key(for: .grokBot)) == .grokBot)

        for path in ["/Users/example/Code/widget", "/", "harness:", "harness:nonesuch",
                     "scratch:", "scratch:nonesuch"] {
            #expect(!PseudoProject.isPseudo(path), "\(path)")
            #expect(PseudoProject.name(forKey: path) == nil, "\(path)")
            #expect(PseudoProject.canonical(path) == path, "\(path)")
        }
        #expect(BoardGrouping.projectName(forPath: "/Users/example/Code/widget") == "widget")
    }

    @Test("Projectless goes after every project, and keeps the order inside each half")
    func projectlessGoesLast() {
        #expect(PseudoProject.projectlessLast(
            [PseudoProject.projectlessKey, "/b", "harness:grokBot", "/a"]
        ) == ["/b", "/a", PseudoProject.projectlessKey, "harness:grokBot"])
        #expect(PseudoProject.projectlessLast(["/b", "/a"]) == ["/b", "/a"])
    }

    // MARK: - One section

    @Test("a chat folder, a session with no folder, and a cloud bot are one section")
    func threeSourcesOneSection() {
        let thread = session(
            .codex, "desk-1", cwd: "/Users/example/Documents/Codex/2026-08-21/zhe", at: 9)
        let other = session(
            .cursor, "desk-2", cwd: "/Users/example/Documents/Codex/2026-08-18/zai-b", at: 7)
        let folderless = session(.cursor, "nowhere", at: 6)
        let emptyCWD = session(.codex, "guardian-ish", cwd: "", at: 5)
        let bot = session(.grokBot, "bot-1", title: "Scout", at: 8)
        let frame = board(
            [
                // The busiest card on the board is in Projectless, and the
                // section still goes last.
                session(.claudeCode, "a", cwd: "/Users/example/Code/widget", at: 3),
                thread, other, folderless, emptyCWD, bot,
            ],
            sandboxThreads: [thread.key: "zhe", other.key: "zai-b"]
        )

        for item in [thread, other, folderless, emptyCWD, bot] {
            #expect(frame.projectKey(for: item) == PseudoProject.projectlessKey, "\(item.key)")
            #expect(frame.isProjectless(item))
        }
        #expect(frame.ungroupedSessions.isEmpty)

        let groups = BoardGrouping.groups(for: frame, groupBy: .project)
        // One section, not `zhe`, `zai-b`, "Codex · scratch", "Cursor ·
        // scratch", "Grok Bot" and "No project".
        #expect(groups.map(\.title) == ["widget", "Projectless"])
        let projectless = try? #require(groups.last)
        #expect(projectless?.sessions.count == 5)
        #expect(projectless?.subtitle == nil)
        #expect(projectless?.harness == nil)

        let units = TaskUnitBuilder.units(
            sessions: frame.sessions, board: frame, ledger: .empty,
            builder: BoardRowBuilder(board: frame), now: frame.generatedAt
        )
        let wall = TaskUnitGrouping.groups(for: units, board: frame, groupBy: .project)
        #expect(wall.map(\.title) == ["widget", "Projectless"])
        #expect(wall.last?.unitCount == 5)
    }

    @Test("the sidebar draws Projectless as one row whose rows sit straight under it")
    func sidebarHasOneRow() {
        let one = session(
            .codex, "desk-1", cwd: "/Users/example/Documents/Codex/2026-08-21/zhe", at: 8)
        let two = session(
            .codex, "desk-2", cwd: "/Users/example/Documents/Codex/2026-08-18/zai-b", at: 7)
        let bot = session(.grokBot, "bot-1", title: "Scout", at: 6)
        let frame = board(
            [session(.claudeCode, "a", cwd: "/Users/example/Code/widget", at: 2), one, two, bot],
            sandboxThreads: [one.key: "zhe", two.key: "zai-b"]
        )

        let tree = ProjectTree.build(board: frame)
        #expect(tree.ungrouped.isEmpty)
        #expect(tree.projects.map(\.name) == ["widget", "Projectless"])
        let project = try? #require(tree.projects.last)
        #expect(project?.isProjectless == true)
        #expect(project?.isRepository == false)
        #expect(project?.sessionCount == 3)
        #expect(project?.harnesses == [.codex, .grokBot])
        // One checkout, implied rather than drawn: a chat folder's name is a
        // label on its row, not a branch of the tree.
        #expect(project?.checkouts.count == 1)
        #expect(project?.checkouts.first?.isWorktree == false)
        #expect(project?.checkouts.first?.branch == nil)
        #expect(project?.checkouts.first?.path == nil)
        #expect(project?.checkouts.first?.units.map(\.leadHarness) == [.codex, .codex, .grokBot])
    }

    @Test("a row in Projectless says where it ran, and is never titled after the folder")
    func theFolderIsALabel() {
        let thread = session(
            .codex, "0198f7b4-2ce9-7f31-84ad-6b0c7e2915df",
            cwd: "/Users/example/Documents/Codex/2026-08-21/zhe", at: 8)
        let titled = session(
            .codex, "desk-2", cwd: "/Users/example/Documents/Codex/2026-08-21/rota",
            title: "Work out the retry backoff", at: 7)
        let plain = session(.claudeCode, "a", cwd: "/Users/example/Code/widget", at: 10)
        let frame = board([plain, thread, titled], sandboxThreads: [thread.key: "zhe", titled.key: "rota"])

        let rows = BoardRowBuilder(board: frame)
        #expect(rows.row(for: titled).project == "Projectless")
        #expect(rows.row(for: titled).title == "Work out the retry backoff")
        #expect(rows.row(for: titled).directory == "/Users/example/Documents/Codex/2026-08-21/rota")
        // Nothing to call it: neither the folder nor the section is a title.
        let untitled = rows.row(for: thread)
        #expect(untitled.title != "zhe")
        #expect(untitled.title != "Projectless")
        // Everything else still shows the project it groups under.
        #expect(rows.row(for: plain).project == "widget")
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
        #expect(frame.projectKey(for: child) == PseudoProject.projectlessKey)
        #expect(frame.ungroupedSessions.isEmpty)
    }

    @Test("filtering the board by Projectless keeps exactly what is in it")
    func filteringByProjectless() {
        let frame = board([
            session(.claudeCode, "a", cwd: "/Users/example/Code/widget", at: 10),
            session(.grokBot, "bot-1", title: "Scout", at: 8),
            session(.cursor, "nowhere", at: 7),
        ])

        let filtered = BoardGrouping.filtered(
            frame.sessions,
            harnessFilter: [],
            projectFilter: PseudoProject.projectlessKey,
            in: frame
        )
        #expect(filtered.map(\.key.sessionID) == ["bot-1", "nowhere"])
    }

    // MARK: - Helper runs

    @Test("an auto review whose thread is not here is counted, not listed")
    func detachedHelpersAreCounted() {
        let root = "0198f4c2-77bd-7a10-b3e9-5c2d84f10ab6"
        // A guardian rollout whose root aged off the board: no parent link,
        // so it would surface as a piece of work of its own.
        let guardian = session(
            .codex, "0198f6d0-11ac-7e54-8b26-3ad70f9c1e83", cwd: "",
            title: "Review", variant: "auto-review:\(root)", at: 8)
        let chat = session(.cursor, "nowhere", title: "Plan the week", at: 7)
        let frame = board([guardian, chat])

        let units = TaskUnitBuilder.units(
            sessions: frame.sessions, board: frame, ledger: .empty,
            builder: BoardRowBuilder(board: frame), now: frame.generatedAt
        )
        #expect(units.count { $0.isDetachedHelper } == 1)

        let tree = ProjectTree.build(board: frame, units: units)
        let projectless = try? #require(tree.projects.first)
        #expect(projectless?.isProjectless == true)
        #expect(projectless?.helperCount == 1)
        #expect(projectless?.checkouts.flatMap(\.units).map(\.title) == ["Plan the week"])

        let wall = TaskUnitGrouping.groups(for: units, board: frame, groupBy: .project)
        #expect(wall.map(\.title) == ["Projectless"])
        #expect(wall.first?.helperCount == 1)
        #expect(wall.first?.units.map(\.title) == ["Plan the week"])
    }

    @Test("a finished helper is counted with the finished work, on both surfaces")
    func finishedHelpersAreFinishedWork() {
        var guardian = session(
            .codex, "0198f6d0-11ac-7e54-8b26-3ad70f9c1e83", cwd: "",
            title: "Review", variant: "auto-review:0198f4c2-77bd-7a10-b3e9-5c2d84f10ab6", at: 8)
        guardian.state = .ended(reason: .exited)
        guardian.isAlive = false
        let chat = session(.cursor, "nowhere", title: "Plan the week", at: 7)
        let frame = board([guardian, chat])

        let units = TaskUnitBuilder.units(
            sessions: frame.sessions, board: frame, ledger: .empty,
            builder: BoardRowBuilder(board: frame), now: frame.generatedAt
        )
        let projectless = ProjectTree.build(board: frame, units: units).projects.first
        #expect(projectless?.helperCount == 0)
        #expect(projectless?.checkouts.first?.hiddenCount == 1)
        #expect(projectless?.checkouts.first?.units.map(\.title) == ["Plan the week"])
        // The wall is handed the live units, and the Ended section the rest.
        let live = TaskUnitGrouping.split(units).live
        #expect(TaskUnitGrouping.groups(for: units, board: frame, groupBy: .project)
            .first?.helperCount == 0)
        #expect(live.map(\.title) == ["Plan the week"])
    }

    @Test("a helper with its thread on the board folds under the thread instead")
    func attachedHelpersFold() {
        let rootID = "0198f4c2-77bd-7a10-b3e9-5c2d84f10ab6"
        let root = session(.codex, rootID, cwd: "", title: "Plan the week", at: 9)
        let guardian = session(
            .codex, "0198f6d0-11ac-7e54-8b26-3ad70f9c1e83", cwd: "", parent: root.key,
            title: "Review", variant: "auto-review:\(rootID)", at: 8)
        let frame = board([root, guardian])

        let units = TaskUnitBuilder.units(
            sessions: frame.sessions, board: frame, ledger: .empty,
            builder: BoardRowBuilder(board: frame), now: frame.generatedAt
        )
        #expect(units.count == 1)
        #expect(units.first?.memberCount == 2)
        #expect(units.allSatisfy { !$0.isDetachedHelper })
        #expect(ProjectTree.build(board: frame, units: units).projects.first?.helperCount == 0)
    }
}
