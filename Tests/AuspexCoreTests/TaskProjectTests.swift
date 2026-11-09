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

    @Test("a harness with no working directory files under Projectless, never nowhere")
    func pseudoProjectRatherThanUnfiled() {
        let board = board(cwd: nil, gitRoot: nil, key: Self.bot)
        let key = TaskProject.resolve(explicit: nil, session: Self.bot, board: board)
        #expect(key == PseudoProject.projectlessKey)
        #expect(TaskProject.displayName(forKey: key, in: board) == "Projectless")
        #expect(TaskProject.subtitle(forKey: key) == nil)
    }

    @Test("a caller Auspex cannot place at all gets Projectless, not a NULL")
    func projectlessIsTheLastResort() {
        let board = BoardSnapshot(generatedAt: Fixtures.date(0), sessions: [])
        for session in [nil, Self.bot] as [SessionKey?] {
            let key = TaskProject.resolve(explicit: nil, session: session, board: board)
            #expect(key == PseudoProject.projectlessKey)
            #expect(TaskProject.displayName(forKey: key, in: board) == "Projectless")
            #expect(TaskProject.subtitle(forKey: key) == nil)
            // Never a path, so it can never collide with one.
            #expect(!key.hasPrefix("/"))
        }
    }

    @Test("every key an earlier build used for no project reads as Projectless")
    func legacyKeysAreProjectless() {
        let board = BoardSnapshot(generatedAt: Fixtures.date(0), sessions: [])
        for key in [TaskProject.scratchKey, PseudoProject.key(for: .grokBot),
                    PseudoProject.scratchKey(for: .codex), "", nil] as [String?] {
            #expect(TaskProject.canonicalKey(key) == PseudoProject.projectlessKey, "\(key ?? "nil")")
            if let key, !key.isEmpty {
                #expect(TaskProject.isProjectless(key))
                #expect(TaskProject.displayName(forKey: key, in: board) == "Projectless")
            }
        }
        #expect(TaskProject.canonicalKey("/Users/example/Code/auspex") == "/Users/example/Code/auspex")
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

    @Test("a pseudo key, the old scratch key and the word itself all name Projectless")
    func explicitPseudoKey() {
        let board = board()
        for reference in [PseudoProject.projectlessKey, PseudoProject.key(for: .grokBot),
                          TaskProject.scratchKey, "Projectless", "projectless"] {
            #expect(TaskProject.key(named: reference, in: board) == PseudoProject.projectlessKey)
        }
    }
}
