import AgentSessionKit
import AgentSessionLive
import Foundation
import Testing

@testable import AuspexCore

@Suite("Project ⊃ Task")
struct TaskProjectTests {
    private static let worker = Fixtures.key(.codex, "worker-1")
    private static let bot = Fixtures.key(.grokBot, "bot-1")

    private func board(
        cwd: String? = "/Users/example/Code/auspex",
        gitRoot: String? = "/Users/example/Code/auspex",
        key: SessionKey = worker,
        claims: ProjectClaims = .empty
    ) -> BoardSnapshot {
        let snapshot = SessionStateReducer.initialSnapshot(
            identity: Fixtures.identity(key: key, cwd: cwd, gitRoot: gitRoot)
        )
        return BoardSnapshot(generatedAt: Fixtures.date(0), sessions: [snapshot], claims: claims)
    }

    // MARK: - Resolving

    @Test("a task with no project named lands where the caller is working")
    func resolvesFromTheCallingSession() {
        let board = board()
        #expect(
            TaskProject.resolve(explicit: nil, session: Self.worker, board: board)
                == "/Users/example/Code/auspex"
        )
    }

    @Test("the same key the board groups the session's own card by")
    func agreesWithTheBoard() {
        let board = board(cwd: "/Users/example/Code/auspex/.agents/worktrees/feat-x")
        let resolved = TaskProject.resolve(explicit: nil, session: Self.worker, board: board)
        #expect(resolved == board.sessions.first.flatMap { board.projectKey(for: $0) })
    }

    @Test("a harness with no working directory files under the harness, never nowhere")
    func pseudoProjectRatherThanUnfiled() {
        let board = board(cwd: nil, gitRoot: nil, key: Self.bot)
        let key = TaskProject.resolve(explicit: nil, session: Self.bot, board: board)
        #expect(key == PseudoProject.key(for: .grokBot))
        #expect(TaskProject.displayName(forKey: key, in: board) == Harness.grokBot.displayName)
        #expect(TaskProject.subtitle(forKey: key) == nil)
    }

    @Test("a caller Auspex cannot place at all gets the scratch project, not a NULL")
    func scratchIsTheLastResort() {
        let board = BoardSnapshot(generatedAt: Fixtures.date(0), sessions: [])
        let key = TaskProject.resolve(explicit: nil, session: nil, board: board)
        #expect(key == TaskProject.scratchKey)
        #expect(TaskProject.displayName(forKey: key, in: board) == "Scratch")
        #expect(TaskProject.subtitle(forKey: key) == nil)
        // Never a path, so it can never collide with one.
        #expect(!key.hasPrefix("/"))
    }

    // MARK: - Naming one

    @Test("a path is normalised, and a person's claim over it wins")
    func explicitPathGoesThroughTheClaims() {
        let project = AuspexProject(
            name: "Everything",
            roots: ["/Users/example/Code"],
            createdAt: Fixtures.date(-100)
        )
        let board = board(claims: ProjectClaims(projects: [project]))
        #expect(
            TaskProject.key(named: "/Users/example/Code/auspex/", in: board)
                == "/Users/example/Code"
        )
        #expect(TaskProject.key(named: "Everything", in: board) == "/Users/example/Code")
        #expect(TaskProject.key(named: project.id.uuidString, in: board) == "/Users/example/Code")
    }

    @Test("a project named by its board name resolves to the board's own key")
    func explicitNameMatchesTheBoard() {
        let board = board()
        #expect(TaskProject.key(named: "auspex", in: board) == "/Users/example/Code/auspex")
        #expect(TaskProject.key(named: "AUSPEX", in: board) == "/Users/example/Code/auspex")
        #expect(TaskProject.key(named: "not-a-project", in: board) == nil)
        #expect(TaskProject.key(named: "   ", in: board) == nil)
    }

    @Test("a pseudo key survives a round trip through the argument")
    func explicitPseudoKey() {
        let board = board()
        let key = PseudoProject.key(for: .grokBot)
        #expect(TaskProject.key(named: key, in: board) == key)
        #expect(TaskProject.key(named: TaskProject.scratchKey, in: board) == TaskProject.scratchKey)
    }
}
