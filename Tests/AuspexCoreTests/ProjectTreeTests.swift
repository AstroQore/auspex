import AgentSessionKit
import AgentSessionLive
import Foundation
import Testing

@testable import AuspexCore

@Suite("ProjectTree")
struct ProjectTreeTests {
    // MARK: - Fixtures

    private func session(
        _ harness: Harness,
        _ id: String,
        cwd: String? = nil,
        gitRoot: String? = nil,
        worktree: String? = nil,
        branch: String? = nil,
        parent: SessionKey? = nil,
        state: SessionState = .thinking,
        isAlive: Bool = true,
        at offset: TimeInterval = 0
    ) -> SessionSnapshot {
        let key = SessionKey(harness: harness, sessionID: id)
        var snapshot = SessionStateReducer.initialSnapshot(
            identity: SessionIdentity(
                key: key,
                sourcePath: "/Users/example/store/\(id).jsonl",
                parent: parent,
                parentLink: parent == nil ? nil : .subagent(toolUseID: nil),
                cwd: cwd,
                gitRoot: gitRoot,
                worktreePath: worktree,
                gitBranch: branch,
                title: "Session \(id)"
            )
        )
        snapshot.state = state
        snapshot.isAlive = isAlive
        snapshot.lastEventAt = Fixtures.date(offset)
        return snapshot
    }

    private func board(_ sessions: [SessionSnapshot]) -> BoardSnapshot {
        BoardSnapshot(generatedAt: Fixtures.date(1_000), sessions: sessions)
    }

    /// The tree as the assembler builds it: over the units the wall draws,
    /// which is what the sidebar has listed since the board became a task
    /// board. A tree built without them would be a tree of empty checkouts.
    private func tree(
        _ board: BoardSnapshot,
        names: [String: String] = [:],
        builder: BoardRowBuilder? = nil
    ) -> ProjectTree {
        let builder = builder ?? BoardRowBuilder(board: board, now: board.generatedAt)
        return ProjectTree.build(
            board: board,
            names: names,
            units: TaskUnitBuilder.units(
                sessions: board.sessions,
                board: board,
                ledger: .empty,
                builder: builder,
                now: board.generatedAt
            )
        )
    }

    // MARK: - Projects

    @Test("three worktrees of one repository are one project with three checkouts")
    func worktreesOfOneRepositoryShareAProject() throws {
        let root = "/Users/example/Code/auspex"
        let frame = board([
            session(
                .claudeCode, "a", cwd: "\(root)/.agents/worktrees/feat-scene",
                gitRoot: root, worktree: "\(root)/.agents/worktrees/feat-scene",
                branch: "feat/scene", at: 30
            ),
            session(
                .codex, "b", cwd: "\(root)/.agents/worktrees/feat-projects-ui",
                gitRoot: root, worktree: "\(root)/.agents/worktrees/feat-projects-ui",
                branch: "feat/projects-ui", at: 20
            ),
            session(.cursor, "c", cwd: root, gitRoot: root, branch: "main", at: 10)
        ])

        let tree = tree(frame)

        #expect(tree.projects.count == 1)
        let project = try #require(tree.projects.first)
        #expect(project.key == root)
        #expect(project.name == "auspex")
        #expect(project.isRepository)
        #expect(project.sessionCount == 3)
        #expect(project.liveCount == 3)
        #expect(project.checkouts.count == 3)
        // The dots are in catalog order, not board order, so a project's
        // identity strip does not reshuffle when one of its agents blocks.
        #expect(project.harnesses == [.codex, .claudeCode, .cursor])
    }

    @Test("an agent worktree is titled by its task, and carries the branch beside it")
    func agentWorktreeIsTitledByItsTask() throws {
        let root = "/Users/example/Code/auspex"
        let path = "\(root)/.agents/worktrees/feat-projects-ui"
        let tree = tree(board([
            session(.codex, "a", cwd: path, gitRoot: root, worktree: path, branch: "feat/projects-ui")
        ]))

        let checkout = try #require(tree.projects.first?.checkouts.first)
        #expect(checkout.agentWorktreeTask == "feat-projects-ui")
        #expect(checkout.title == "feat-projects-ui")
        #expect(checkout.subtitle == "feat/projects-ui")
        #expect(checkout.isWorktree)
    }

    @Test("a plain checkout is titled by its branch and adds nothing beside it")
    func aPlainCheckoutIsTitledByItsBranch() throws {
        let root = "/Users/example/Code/widget"
        let tree = tree(board([
            session(.claudeCode, "a", cwd: root, gitRoot: root, branch: "main")
        ]))

        let checkout = try #require(tree.projects.first?.checkouts.first)
        #expect(checkout.title == "main")
        #expect(checkout.subtitle == nil)
        #expect(!checkout.isWorktree)
    }

    @Test("a directory in no repository is its own project, marked as one")
    func aDirectoryWithNoGitIsStillAProject() throws {
        let tree = tree(board([
            session(.grokBuild, "a", cwd: "/Users/example/Code/infra-terraform")
        ]))

        let project = try #require(tree.projects.first)
        #expect(project.key == "/Users/example/Code/infra-terraform")
        #expect(project.name == "infra-terraform")
        #expect(!project.isRepository)
    }

    @Test("the store's name wins over the path component")
    func storedNamesAreUsed() {
        let root = "/Users/example/Code/auspex"
        let tree = tree(
            board([session(.codex, "a", cwd: root, gitRoot: root)]),
            names: [root: "Auspex"]
        )
        #expect(tree.projects.first?.name == "Auspex")
    }

    // MARK: - Inheritance

    @Test("a child with no directory joins its parent's project and checkout")
    func aChildWithNoDirectoryInheritsItsParentsPlace() throws {
        let root = "/Users/example/Code/auspex"
        let parent = session(.claudeCode, "parent", cwd: root, gitRoot: root, branch: "main", at: 20)
        let child = session(.claudeCode, "child", parent: parent.key, at: 10)

        let tree = tree(board([parent, child]))

        #expect(tree.ungrouped.isEmpty)
        #expect(tree.projects.count == 1)
        let project = try #require(tree.projects.first)
        // One piece of work, two sessions inside it: the child is a step in
        // the parent's job, not a peer of it.
        #expect(project.sessionCount == 1)
        #expect(project.checkouts.count == 1)
        let unit = try #require(project.checkouts.first?.units.first)
        #expect(unit.members.map(\.key) == [parent.key, child.key])
    }

    @Test("a session with no directory and no placed ancestor is ungrouped, not dropped")
    func anOrphanWithNoDirectoryIsKept() {
        let orphan = session(.antigravity, "orphan")
        let tree = tree(board([orphan]))

        #expect(tree.projects.isEmpty)
        #expect(tree.ungrouped.flatMap { $0.members.map(\.key) } == [orphan.key])
        #expect(!tree.isEmpty)
    }

    // MARK: - Order and counts

    @Test("projects are ranked by their most urgent session, not alphabetically")
    func projectsFollowBoardOrder() {
        let frame = board([
            session(.codex, "quiet", cwd: "/Users/example/Code/aardvark", state: .idle, at: 90),
            session(
                .claudeCode, "blocked", cwd: "/Users/example/Code/zebra",
                state: .waitingPermission(tool: "Bash"), at: 10
            )
        ])

        let tree = tree(frame)
        #expect(tree.projects.map(\.name) == ["zebra", "aardvark"])
    }

    @Test("live counts follow the board, and an ended session is not live")
    func liveCountsMatchTheBoard() throws {
        let root = "/Users/example/Code/widget"
        let tree = tree(board([
            session(.codex, "running", cwd: root, gitRoot: root, at: 30),
            session(
                .codex, "over", cwd: root, gitRoot: root,
                state: .ended(reason: .exited), isAlive: false, at: 20
            )
        ]))

        let project = try #require(tree.projects.first)
        #expect(project.sessionCount == 2)
        #expect(project.liveCount == 1)
        #expect(project.checkouts.first?.liveCount == 1)
    }

    // MARK: - What the tree does not list

    @Test("finished sessions leave the tree, and the checkout says how many")
    func finishedSessionsLeaveTheTree() throws {
        let root = "/Users/example/Code/auspex"
        let tree = tree(board([
            session(.claudeCode, "live", cwd: root, gitRoot: root, at: 40),
            session(
                .codex, "over-1", cwd: root, gitRoot: root,
                state: .ended(reason: .exited), isAlive: false, at: 20
            ),
            session(
                .cursor, "over-2", cwd: root, gitRoot: root,
                state: .ended(reason: .exited), isAlive: false, at: 10
            )
        ]))

        let checkout = try #require(tree.projects.first?.checkouts.first)
        #expect(checkout.units.flatMap { $0.members.map(\.key.sessionID) } == ["live"])
        #expect(checkout.hiddenCount == 2)
        // Still counted: the column has to say how much work there was here,
        // and the board's Ended section is where the rows themselves went.
        #expect(checkout.sessionCount == 3)
        #expect(tree.projects.first?.sessionCount == 3)
    }

    @Test("a checkout of nothing but finished work still appears, and says so")
    func aFinishedCheckoutStillAppears() throws {
        let root = "/Users/example/Code/auspex"
        let tree = tree(board([
            session(
                .claudeCode, "over", cwd: root, gitRoot: root,
                state: .ended(reason: .exited), isAlive: false, at: 20
            )
        ]))

        let checkout = try #require(tree.projects.first?.checkouts.first)
        #expect(checkout.units.isEmpty)
        #expect(checkout.hiddenCount == 1)
        #expect(checkout.liveCount == 0)
    }

    @Test("sessions under no project lose their finished ones the same way")
    func ungroupedLosesItsFinishedSessions() {
        let tree = tree(board([
            session(.antigravity, "live", at: 40),
            session(.antigravity, "over", state: .ended(reason: .exited), isAlive: false, at: 10)
        ]))

        #expect(tree.ungrouped.flatMap { $0.members.map(\.key.sessionID) } == ["live"])
        #expect(tree.ungroupedHidden == 1)
    }

    @Test("a checkout's badge counts every session in it, listed or not")
    func badgesCountTheUnlistedSessions() throws {
        let root = "/Users/example/Code/auspex"
        var reported = session(
            .codex, "done", cwd: root, gitRoot: root,
            state: .ended(reason: .exited), isAlive: false, at: 10
        )
        reported.brief.lastAssistantAt = Fixtures.date(10)
        let builder = BoardRowBuilder(
            board: board([reported]),
            notices: [
                reported.key: AgentNotice(
                    session: reported.key,
                    kind: .done,
                    message: "Split the remainder rather than truncating it.",
                    createdAt: Fixtures.date(10)
                )
            ],
            now: Fixtures.date(1_000)
        )
        let tree = tree(board([reported]), builder: builder)

        let checkout = try #require(tree.projects.first?.checkouts.first)
        // Work an agent said it finished is *in review*, and a review is not
        // history: it stays in the column until somebody closes it, whatever
        // its process did. The badge that sends them there lights up too.
        #expect(checkout.units.map(\.status) == [.review])
        #expect(checkout.doneReportedCount == 1)
    }

    @Test("an empty board makes an empty tree")
    func anEmptyBoardMakesAnEmptyTree() {
        let tree = tree(.empty)
        #expect(tree.isEmpty)
        #expect(tree.projects.isEmpty)
        #expect(tree.ungrouped.isEmpty)
    }
}
