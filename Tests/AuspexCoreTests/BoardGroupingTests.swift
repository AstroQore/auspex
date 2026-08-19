import AgentSessionKit
import AgentSessionLive
import Foundation
import Testing

@testable import AuspexCore

@Suite("BoardGrouping")
struct BoardGroupingTests {
    /// A snapshot with a state, a project, and a last-event time — enough to
    /// exercise both the sort and every grouping axis.
    private func session(
        _ harness: Harness,
        _ id: String,
        state: SessionState = .thinking,
        cwd: String? = "/Users/example/Code/widget",
        gitRoot: String? = nil,
        isAlive: Bool = true,
        at offset: TimeInterval = 0
    ) -> SessionSnapshot {
        let key = SessionKey(harness: harness, sessionID: id)
        var snapshot = SessionStateReducer.initialSnapshot(
            identity: SessionIdentity(
                key: key,
                sourcePath: "/Users/example/store/\(id).jsonl",
                cwd: cwd,
                gitRoot: gitRoot
            )
        )
        snapshot.state = state
        snapshot.isAlive = isAlive
        snapshot.lastEventAt = Fixtures.date(offset)
        return snapshot
    }

    private func board(_ sessions: [SessionSnapshot]) -> BoardSnapshot {
        BoardSnapshot(generatedAt: Fixtures.date(100), sessions: sessions)
    }

    // MARK: - None

    @Test("no grouping produces one section holding every session, in board order")
    func noGroupingKeepsBoardOrder() {
        let frame = board([
            session(.codex, "a", state: .thinking, at: 10),
            session(.claudeCode, "b", state: .waitingPermission(tool: "Bash"), at: 5),
            session(.cursor, "c", state: .idle, at: 20)
        ])

        let groups = BoardGrouping.groups(for: frame, groupBy: .none)

        #expect(groups.count == 1)
        #expect(groups[0].title == BoardGrouping.allSessionsTitle)
        #expect(groups[0].sessions.map(\.key) == frame.sessions.map(\.key))
        // The blocked session sorts first, which is the whole point of the
        // board's order; grouping must not disturb it.
        #expect(groups[0].sessions.first?.state == .waitingPermission(tool: "Bash"))
    }

    @Test("an empty board produces no sections at all")
    func emptyBoardProducesNoSections() {
        #expect(BoardGrouping.groups(for: .empty, groupBy: .none).isEmpty)
        #expect(BoardGrouping.groups(for: .empty, groupBy: .harness).isEmpty)
        #expect(BoardGrouping.groups(for: .empty, groupBy: .project).isEmpty)
    }

    // MARK: - Harness

    @Test("harness sections follow the catalog's declaration order, not the board's")
    func harnessSectionsUseCatalogOrder() {
        // Cursor is last in `Harness.allCases`, and here it is the most urgent
        // session — so board order and catalog order actively disagree.
        let frame = board([
            session(.cursor, "c", state: .waitingPermission(tool: "edit_file"), at: 30),
            session(.claudeCode, "a", state: .thinking, at: 20),
            session(.codex, "b", state: .idle, at: 10)
        ])

        let groups = BoardGrouping.groups(for: frame, groupBy: .harness)

        #expect(groups.map(\.harness) == [.codex, .claudeCode, .cursor])
        #expect(groups.map(\.title) == ["Codex", "Claude Code", "Cursor"])
    }

    @Test("a harness with no sessions gets no section")
    func absentHarnessesAreOmitted() {
        let frame = board([session(.grokBuild, "a")])
        let groups = BoardGrouping.groups(for: frame, groupBy: .harness)
        #expect(groups.count == 1)
        #expect(groups[0].harness == .grokBuild)
    }

    @Test("sessions of one harness stay in board order inside their section")
    func harnessSectionKeepsBoardOrderInside() {
        let frame = board([
            session(.codex, "quiet", state: .idle, at: 40),
            session(.codex, "blocked", state: .waitingPermission(tool: "shell"), at: 5),
            session(.codex, "busy", state: .toolCalling(name: "shell"), at: 20)
        ])

        let groups = BoardGrouping.groups(for: frame, groupBy: .harness)

        #expect(groups[0].sessions.map(\.key.sessionID) == ["blocked", "busy", "quiet"])
    }

    // MARK: - Project

    @Test("the git root wins over the working directory, so worktrees group together")
    func gitRootGroupsWorktreesTogether() {
        let frame = board([
            session(
                .claudeCode, "main",
                cwd: "/Users/example/Code/auspex",
                gitRoot: "/Users/example/Code/auspex",
                at: 30
            ),
            session(
                .codex, "worktree",
                cwd: "/Users/example/Code/auspex/.agents/worktrees/feat-x",
                gitRoot: "/Users/example/Code/auspex",
                at: 20
            )
        ])

        let groups = BoardGrouping.groups(for: frame, groupBy: .project)

        #expect(groups.count == 1)
        #expect(groups[0].title == "auspex")
        #expect(groups[0].subtitle == "/Users/example/Code/auspex")
        #expect(groups[0].sessions.count == 2)
    }

    @Test("project sections lead with the one holding the most urgent session")
    func projectSectionsAreUrgencyOrdered() {
        let frame = board([
            session(.codex, "calm", state: .idle, cwd: "/Users/example/Code/alpha", at: 50),
            session(
                .claudeCode, "stuck",
                state: .waitingPermission(tool: "Bash"),
                cwd: "/Users/example/Code/zulu",
                at: 10
            )
        ])

        let groups = BoardGrouping.groups(for: frame, groupBy: .project)

        // Alphabetically `alpha` would come first; urgency puts `zulu` there.
        #expect(groups.map(\.title) == ["zulu", "alpha"])
    }

    @Test("sessions with neither a git root nor a cwd land in one section, last")
    func rootlessSessionsGoLast() {
        let frame = board([
            session(.codex, "nowhere", state: .waitingPermission(tool: "shell"), cwd: nil, at: 60),
            session(.claudeCode, "somewhere", state: .idle, cwd: "/Users/example/Code/alpha", at: 10)
        ])

        let groups = BoardGrouping.groups(for: frame, groupBy: .project)

        #expect(groups.map(\.title) == ["alpha", BoardGrouping.noProjectTitle])
        #expect(groups.last?.sessions.map(\.key.sessionID) == ["nowhere"])
    }

    @Test("every session lands in exactly one section, on every axis")
    func groupingIsTotalAndDisjoint() {
        let frame = board([
            session(.codex, "a", cwd: "/Users/example/Code/alpha"),
            session(.claudeCode, "b", cwd: nil),
            session(.cursor, "c", cwd: "/Users/example/Code/beta"),
            session(.codex, "d", cwd: "/Users/example/Code/alpha")
        ])

        for axis in BoardGroupBy.allCases {
            let placed = BoardGrouping.groups(for: frame, groupBy: axis).flatMap(\.sessions)
            #expect(placed.count == 4, "axis \(axis.rawValue) lost or duplicated a session")
            #expect(Set(placed.map(\.key)).count == 4)
        }
    }

    // MARK: - Filtering

    @Test("an empty filter keeps everything")
    func emptyFilterKeepsEverything() {
        let frame = board([session(.codex, "a"), session(.cursor, "b")])
        let groups = BoardGrouping.groups(for: frame, groupBy: .none, harnessFilter: [])
        #expect(groups.first?.sessions.count == 2)
    }

    @Test("a filter narrows the board and the section counts follow it")
    func filterNarrowsBoardAndCounts() {
        let frame = board([
            session(.codex, "a", state: .waitingPermission(tool: "shell")),
            session(.cursor, "b", state: .thinking),
            session(.cursor, "c", state: .thinking)
        ])

        let groups = BoardGrouping.groups(for: frame, groupBy: .none, harnessFilter: [.cursor])

        #expect(groups.first?.sessions.count == 2)
        #expect(groups.first?.counts.thinking == 2)
        #expect(groups.first?.counts.waitingPermission == 0)
    }

    @Test("a filter that matches nothing produces no sections rather than an empty one")
    func filterMatchingNothingProducesNoSections() {
        let frame = board([session(.codex, "a")])
        #expect(BoardGrouping.groups(for: frame, groupBy: .harness, harnessFilter: [.cursor]).isEmpty)
    }

    // MARK: - Names

    @Test("a project name is the last path component, trailing slash or not")
    func projectNameTakesLastComponent() {
        #expect(BoardGrouping.projectName(forPath: "/Users/example/Code/auspex") == "auspex")
        #expect(BoardGrouping.projectName(forPath: "/Users/example/Code/auspex/") == "auspex")
        #expect(BoardGrouping.projectName(forPath: "/") == "/")
    }

    @Test("a session with no root and no cwd has no project name")
    func rootlessSessionHasNoProjectName() {
        #expect(BoardGrouping.projectName(for: session(.codex, "a", cwd: nil)) == nil)
    }

    // MARK: - Inherited placement

    /// A snapshot with a parent, for the cases where the tree is the answer.
    private func child(
        _ harness: Harness,
        _ id: String,
        of parent: SessionKey,
        cwd: String? = nil,
        state: SessionState = .thinking,
        at offset: TimeInterval = 0
    ) -> SessionSnapshot {
        var snapshot = session(harness, id, state: state, cwd: cwd, at: offset)
        snapshot.identity.parent = parent
        snapshot.identity.parentLink = .subagent(toolUseID: nil)
        return snapshot
    }

    @Test("a child with no directory groups under its parent's project, not under none")
    func childInheritsItsParentsProject() {
        let parent = session(.claudeCode, "parent", cwd: "/Users/example/Code/auspex", at: 30)
        let frame = board([parent, child(.claudeCode, "child", of: parent.key, cwd: nil, at: 20)])

        let groups = BoardGrouping.groups(for: frame, groupBy: .project)

        // The whole point of asking the frame rather than the session: a
        // subagent has no process and no cwd line, and a section called
        // "No project" would be the wrong answer for something plainly working
        // inside one.
        #expect(groups.map(\.title) == ["auspex"])
        #expect(groups[0].sessions.count == 2)
    }

    // MARK: - Project filter

    @Test("the project filter keeps one project, on every axis")
    func projectFilterAppliesToEveryAxis() {
        let frame = board([
            session(.codex, "here", cwd: "/Users/example/Code/alpha", at: 30),
            session(.cursor, "there", cwd: "/Users/example/Code/beta", at: 20)
        ])

        for axis in BoardGroupBy.allCases {
            let placed = BoardGrouping.groups(
                for: frame, groupBy: axis, projectFilter: "/Users/example/Code/alpha"
            ).flatMap(\.sessions)
            #expect(placed.map(\.key.sessionID) == ["here"], "axis \(axis.rawValue) ignored it")
        }
    }

    @Test("the project filter keeps a child that inherited the project it names")
    func projectFilterKeepsInheritedChildren() {
        let parent = session(.claudeCode, "parent", cwd: "/Users/example/Code/auspex", at: 30)
        let frame = board([parent, child(.claudeCode, "child", of: parent.key, at: 20)])

        let groups = BoardGrouping.groups(
            for: frame, groupBy: .none, projectFilter: "/Users/example/Code/auspex"
        )

        #expect(groups.first?.sessions.count == 2)
    }

    @Test("no project filter is not the same as a filter matching nothing")
    func absentProjectFilterKeepsEverything() {
        let frame = board([session(.codex, "a", cwd: "/Users/example/Code/alpha")])
        #expect(BoardGrouping.groups(for: frame, groupBy: .none).first?.sessions.count == 1)
        #expect(
            BoardGrouping.groups(for: frame, groupBy: .none, projectFilter: "/nope").isEmpty
        )
    }

    // MARK: - Tree

    @Test("a root that delegated gets its own section, with its children nested under it")
    func delegationSectionsNestTheirChildren() throws {
        let root = session(.claudeCode, "root", state: .delegating(children: 1), at: 40)
        let kid = child(.codex, "kid", of: root.key, at: 30)
        let grandchild = child(.codex, "grandchild", of: kid.key, at: 20)
        let frame = board([root, kid, grandchild])

        let groups = BoardGrouping.groups(for: frame, groupBy: .tree)

        #expect(groups.count == 1)
        let group = try #require(groups.first)
        #expect(group.sessions.count == 3)
        let roots = try #require(group.roots)
        #expect(roots.count == 1)
        #expect(roots[0].session.key == root.key)
        #expect(roots[0].descendantCount == 2)
        #expect(roots[0].children.map(\.session.key) == [kid.key])
        #expect(roots[0].children[0].children.map(\.session.key) == [grandchild.key])
        #expect(roots[0].children[0].depth == 1)
    }

    @Test("roots that delegated to nobody share one trailing section")
    func standaloneRootsShareASection() throws {
        let root = session(.claudeCode, "root", state: .delegating(children: 1), at: 40)
        let kid = child(.codex, "kid", of: root.key, at: 30)
        let alone = session(.cursor, "alone", at: 10)
        let frame = board([root, kid, alone])

        let groups = BoardGrouping.groups(for: frame, groupBy: .tree)

        #expect(groups.count == 2)
        #expect(groups.last?.title == BoardGrouping.standaloneTitle)
        #expect(groups.last?.sessions.map(\.key.sessionID) == ["alone"])
        #expect(groups.last?.roots?.allSatisfy { $0.children.isEmpty } == true)
    }

    @Test("a child whose parent the harness filter removed becomes a root of its own")
    func filteringOutAParentPromotesItsChild() throws {
        let root = session(.claudeCode, "root", state: .delegating(children: 1), at: 40)
        let kid = child(.codex, "kid", of: root.key, at: 30)
        let frame = board([root, kid])

        let groups = BoardGrouping.groups(for: frame, groupBy: .tree, harnessFilter: [.codex])

        // A row that vanished because its parent was filtered out would be a
        // filter that hid something it was not asked to hide.
        #expect(groups.count == 1)
        #expect(groups[0].title == BoardGrouping.standaloneTitle)
        #expect(groups[0].sessions.map(\.key.sessionID) == ["kid"])
    }

    @Test("a delegation section is titled by its root and counts what is below it")
    func delegationSectionTitleAndSubtitle() throws {
        var root = session(.claudeCode, "root", state: .delegating(children: 2), at: 40)
        root.identity.title = "Build the live board"
        let frame = board([
            root,
            child(.codex, "a", of: root.key, at: 30),
            child(.cursor, "b", of: root.key, at: 20)
        ])

        let group = try #require(BoardGrouping.groups(for: frame, groupBy: .tree).first)
        #expect(group.title == "Build the live board")
        #expect(group.subtitle == "2 below")
        #expect(group.counts.live == 3)
    }
}
