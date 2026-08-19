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

        let tree = ProjectTree.build(board: frame)

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
        let tree = ProjectTree.build(board: board([
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
        let tree = ProjectTree.build(board: board([
            session(.claudeCode, "a", cwd: root, gitRoot: root, branch: "main")
        ]))

        let checkout = try #require(tree.projects.first?.checkouts.first)
        #expect(checkout.title == "main")
        #expect(checkout.subtitle == nil)
        #expect(!checkout.isWorktree)
    }

    @Test("a directory in no repository is its own project, marked as one")
    func aDirectoryWithNoGitIsStillAProject() throws {
        let tree = ProjectTree.build(board: board([
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
        let tree = ProjectTree.build(
            board: board([session(.codex, "a", cwd: root, gitRoot: root)]),
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

        let tree = ProjectTree.build(board: board([parent, child]))

        #expect(tree.ungrouped.isEmpty)
        #expect(tree.projects.count == 1)
        let project = try #require(tree.projects.first)
        #expect(project.sessionCount == 2)
        #expect(project.checkouts.count == 1)
        #expect(project.checkouts.first?.sessions.map(\.key) == [parent.key, child.key])
    }

    @Test("a session with no directory and no placed ancestor is ungrouped, not dropped")
    func anOrphanWithNoDirectoryIsKept() {
        let orphan = session(.antigravity, "orphan")
        let tree = ProjectTree.build(board: board([orphan]))

        #expect(tree.projects.isEmpty)
        #expect(tree.ungrouped.map(\.key) == [orphan.key])
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

        let tree = ProjectTree.build(board: frame)
        #expect(tree.projects.map(\.name) == ["zebra", "aardvark"])
    }

    @Test("live counts follow the board, and an ended session is not live")
    func liveCountsMatchTheBoard() throws {
        let root = "/Users/example/Code/widget"
        let tree = ProjectTree.build(board: board([
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

    @Test("an empty board makes an empty tree")
    func anEmptyBoardMakesAnEmptyTree() {
        let tree = ProjectTree.build(board: .empty)
        #expect(tree.isEmpty)
        #expect(tree.projects.isEmpty)
        #expect(tree.ungrouped.isEmpty)
    }
}
