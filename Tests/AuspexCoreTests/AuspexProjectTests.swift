import AgentSessionKit
import AgentSessionLive
import Foundation
import Testing

@testable import AuspexCore

/// The user layer: what a project claims, who wins when two claim the same
/// directory, and what survives a round trip through `~/.auspex/projects.json`.
@Suite("Auspex projects")
struct AuspexProjectTests {
    // MARK: - Fixtures

    private func session(
        _ id: String = "aaaaaaaa-1111-2222-3333-444444444444",
        harness: Harness = .claudeCode,
        cwd: String? = nil,
        gitRoot: String? = nil,
        worktree: String? = nil,
        parent: SessionKey? = nil,
        title: String? = nil
    ) -> SessionSnapshot {
        let key = SessionKey(harness: harness, sessionID: id)
        var identity = SessionIdentity(
            key: key,
            sourcePath: "/Users/example/store/\(id).jsonl",
            parent: parent,
            cwd: cwd,
            gitRoot: gitRoot,
            title: title
        )
        identity.worktreePath = worktree
        var snapshot = SessionStateReducer.initialSnapshot(identity: identity)
        snapshot.isAlive = true
        return snapshot
    }

    private func board(_ sessions: [SessionSnapshot], claims: ProjectClaims) -> BoardSnapshot {
        BoardSnapshot(generatedAt: Fixtures.date(0), sessions: sessions, claims: claims)
    }

    private func project(
        _ name: String,
        roots: [String],
        pinned: Bool = false,
        createdAt: TimeInterval = 0
    ) -> AuspexProject {
        AuspexProject(
            name: name,
            roots: roots,
            isPinned: pinned,
            createdAt: Fixtures.date(createdAt)
        )
    }

    // MARK: - Paths

    @Test("A root is normalised once, and a sibling with a shared prefix is not inside it")
    func normalisesAndContains() {
        #expect(ProjectPath.normalize("/Users/example/Code/auspex/") == "/Users/example/Code/auspex")
        #expect(ProjectPath.normalize("  /Users/example/Code/./auspex ")
            == "/Users/example/Code/auspex")
        #expect(ProjectPath.contains("/Users/example/Code", "/Users/example/Code/auspex"))
        #expect(ProjectPath.contains("/Users/example/Code", "/Users/example/Code"))
        #expect(!ProjectPath.contains("/Users/example/Code", "/Users/example/Codex"))
        #expect(!ProjectPath.contains("", "/Users/example"))
    }

    // MARK: - Claims

    @Test("A user claim beats the git root the resolver would have used")
    func userClaimWinsOverAutomaticPlacement() {
        let claims = ProjectClaims(projects: [
            project("Storefront", roots: ["/Users/example/Code/storefront-web"])
        ])
        let session = session(cwd: "/Users/example/Code/storefront-web/apps/web",
                              gitRoot: "/Users/example/Code/storefront-web")
        let frame = board([session], claims: claims)

        #expect(frame.projectKey(for: session) == "/Users/example/Code/storefront-web")
        #expect(frame.projectDisplayName(forKey: "/Users/example/Code/storefront-web")
            == "Storefront")
    }

    @Test("Two directories in two repositories can be claimed into one project")
    func oneProjectClaimsSeveralRoots() {
        let claims = ProjectClaims(projects: [
            project(
                "Checkout",
                roots: ["/Users/example/Code/storefront-web", "/Users/example/Code/payments-api"]
            )
        ])
        let web = session("1", cwd: "/Users/example/Code/storefront-web")
        let api = session("2", harness: .codex, cwd: "/Users/example/Code/payments-api")
        let frame = board([web, api], claims: claims)

        #expect(frame.projectKey(for: web) == frame.projectKey(for: api))
        #expect(frame.byProject.count == 1)
    }

    @Test("The longest claim wins when two projects overlap")
    func longestPrefixWins() {
        let claims = ProjectClaims(projects: [
            project("Everything", roots: ["/Users/example/Code"], createdAt: 0),
            project("Auspex", roots: ["/Users/example/Code/auspex"], createdAt: 10),
        ])
        let inner = session(cwd: "/Users/example/Code/auspex/Sources")
        let outer = session("2", cwd: "/Users/example/Code/other")
        let frame = board([inner, outer], claims: claims)

        #expect(frame.projectKey(for: inner) == "/Users/example/Code/auspex")
        #expect(frame.projectKey(for: outer) == "/Users/example/Code")
    }

    @Test("Two claims of equal length go to the project that existed first")
    func equalClaimsGoToTheOlderProject() {
        let claims = ProjectClaims(projects: [
            project("Second", roots: ["/Users/example/Code/shared"], createdAt: 100),
            project("First", roots: ["/Users/example/Code/shared"], createdAt: 10),
        ])
        #expect(claims.name(forKey: claims.key(forPath: "/Users/example/Code/shared") ?? "")
            == "First")
    }

    @Test("A worktree parked outside its repository is claimed by the tree it sits in")
    func claimsSeeTheWorktreeAsWellAsTheRepository() {
        let claims = ProjectClaims(projects: [
            project("Scratch", roots: ["/Users/example/scratch"])
        ])
        let session = session(
            cwd: "/Users/example/scratch/wt-1",
            gitRoot: "/Users/example/Code/auspex",
            worktree: "/Users/example/scratch/wt-1"
        )
        #expect(board([session], claims: claims).projectKey(for: session)
            == "/Users/example/scratch")
    }

    @Test("A subagent with no directory follows its parent into the user's project")
    func childrenInheritTheClaim() {
        let claims = ProjectClaims(projects: [
            project("Auspex", roots: ["/Users/example/Code/auspex"])
        ])
        let parent = session("1", cwd: "/Users/example/Code/auspex")
        let child = session("2", parent: parent.key)
        let frame = board([parent, child], claims: claims)

        #expect(frame.projectKey(for: child) == "/Users/example/Code/auspex")
    }

    @Test("Nothing claimed leaves every placement exactly as it was")
    func emptyClaimsChangeNothing() {
        let session = session(cwd: "/Users/example/Code/auspex")
        let plain = BoardSnapshot(generatedAt: Fixtures.date(0), sessions: [session])
        #expect(plain.claims.isEmpty)
        #expect(plain.projectKey(for: session) == "/Users/example/Code/auspex")
        #expect(plain.projectDisplayName(forKey: "/Users/example/Code/auspex") == "auspex")
    }

    @Test("A pinned project sorts before the board's own order")
    func pinnedProjectsComeFirst() {
        let claims = ProjectClaims(projects: [
            project("Pinned", roots: ["/Users/example/Code/quiet"], pinned: true)
        ])
        // The busy project is first in board order; the pinned quiet one is
        // promoted over it.
        let busy = session("1", cwd: "/Users/example/Code/busy")
        let quiet = session("2", cwd: "/Users/example/Code/quiet")
        let frame = board([busy, quiet], claims: claims)
        let groups = BoardGrouping.groups(for: frame, groupBy: .project)

        #expect(groups.first?.title == "Pinned")
        #expect(ProjectTree.build(board: frame).projects.first?.key
            == "/Users/example/Code/quiet")
        #expect(ProjectTree.build(board: frame).projects.first?.isPinned == true)
    }

    // MARK: - Editing

    @Test("Adding a root normalises it and adding an imported member adds its root too")
    func editingAProject() {
        var project = project("Auspex", roots: [])
        project.addRoot("/Users/example/Code/auspex/")
        project.addRoot("/Users/example/Code/auspex")
        #expect(project.roots == ["/Users/example/Code/auspex"])

        project.add(member: HarnessProjectRef(harness: .codex, path: "/Users/example/Code/kit"))
        #expect(project.roots.count == 2)
        #expect(project.members.count == 1)

        project.removeRoot("/Users/example/Code/kit")
        #expect(project.roots == ["/Users/example/Code/auspex"])
        #expect(project.members.isEmpty)
    }

    @Test("A project with no roots claims nothing and keys on itself")
    func rootlessProjectClaimsNothing() {
        let project = project("Empty", roots: [])
        let claims = ProjectClaims(projects: [project])
        #expect(claims.isEmpty)
        #expect(project.key.hasPrefix(AuspexProject.unclaimedPrefix))
        #expect(claims.key(forPath: "/Users/example") == nil)
    }

    // MARK: - Persistence

    @Test("Projects survive a round trip through ~/.auspex/projects.json")
    func projectsRoundTrip() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("auspex-projects-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let store = AuspexProjectStore(paths: AuspexPaths(homeDirectory: home))

        #expect(store.load().isEmpty)

        var project = project("Checkout", roots: ["/Users/example/Code/storefront-web"])
        project.colorHex = "#4C8DFF"
        project.isPinned = true
        project.createdBy = .imported
        project.add(
            member: HarnessProjectRef(
                harness: .claudeCode,
                path: "/Users/example/Code/storefront-web",
                lastSeen: Fixtures.date(5)
            )
        )
        try store.save([project])

        let loaded = try #require(store.load().first)
        #expect(loaded.id == project.id)
        #expect(loaded.name == "Checkout")
        #expect(loaded.colorHex == "#4C8DFF")
        #expect(loaded.isPinned)
        #expect(loaded.createdBy == .imported)
        #expect(loaded.roots == ["/Users/example/Code/storefront-web"])
        #expect(loaded.members.first?.harness == .claudeCode)
        #expect(loaded.members.first?.lastSeen == Fixtures.date(5))
    }

    @Test("One unreadable project costs itself rather than the file")
    func aBrokenEntryDoesNotEmptyTheFile() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("auspex-projects-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let paths = AuspexPaths(homeDirectory: home)
        try paths.ensureBaseDirectory()
        try """
            {"projects": [
                {"nonsense": true},
                {"id": "00000000-0000-0000-0000-000000000001", "name": "Kept",
                 "roots": ["/Users/example/Code/kept"]}
            ]}
            """.write(to: paths.projectsURL, atomically: true, encoding: .utf8)

        let loaded = AuspexProjectStore(paths: paths).load()
        #expect(loaded.count == 1)
        #expect(loaded.first?.name == "Kept")
    }
}
