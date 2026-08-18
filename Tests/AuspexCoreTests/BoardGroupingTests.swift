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
}
