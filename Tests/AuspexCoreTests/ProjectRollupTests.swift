import AgentSessionKit
import AgentSessionLive
import Foundation
import GRDB
import Synchronization
import Testing

@testable import AuspexCore

/// Plain directories filed under the workspace that holds them, rather than
/// each becoming a project of its own.
@Suite("ProjectRollup")
struct ProjectRollupTests {
    private let home = "/Users/example"
    private var rules: ScratchRules { ScratchRules(home: home) }

    private func place(
        _ directory: String,
        gitRoot: String? = nil,
        harness: Harness? = .claudeCode,
        userRoots: [String] = [],
        rules: ScratchRules? = nil,
        exists: (String) -> Bool = { _ in true }
    ) -> ProjectRollup.Outcome {
        ProjectRollup.place(
            directory: directory,
            gitRoot: gitRoot,
            harness: harness,
            userRoots: userRoots,
            rules: rules ?? self.rules,
            directoryExists: exists
        )
    }

    // MARK: - Rule 1: a repository

    @Test("a directory in a repository is the repository's, as it always was")
    func repositoryWins() {
        #expect(place("/Users/example/a/b/c/d", gitRoot: "/Users/example/a/b/c")
            == .repository(gitRoot: "/Users/example/a/b/c"))
        // Even under a person's project root: the repository row stays the
        // repository's; the board's own claim is what files it in their project.
        #expect(place(
            "/Users/example/work/repo/src", gitRoot: "/Users/example/work/repo",
            userRoots: ["/Users/example/work"]
        ) == .repository(gitRoot: "/Users/example/work/repo"))
    }

    @Test("a repository inside a desktop conversation is still the conversation")
    func scratchOutranksARepository() {
        let outcome = place(
            "/Users/example/Documents/Codex/2026-08-21/zhe/app",
            gitRoot: "/Users/example/Documents/Codex/2026-08-21/zhe/app",
            harness: .codex
        )
        guard case .projectless(let match) = outcome else {
            Issue.record("expected projectless, got \(outcome)")
            return
        }
        #expect(match.reason == .conversation)
    }

    // MARK: - Rule 2: a person's own project

    @Test("a person's project root claims what is under it, deepest root first")
    func userProjectWins() {
        let roots = ["/Users/example/work", "/Users/example/work/reports/.runs/special"]
        // Deeper than the workspace depth, and inside a hidden folder: the
        // person pinned it, so it is its own project.
        #expect(place("/Users/example/work/reports/.runs/special/x", userRoots: roots)
            == .userProject(root: "/Users/example/work/reports/.runs/special"))
        // Anything else under the broader root is in the broader project,
        // ahead of the workspace roll-up.
        #expect(place("/Users/example/work/reports/.runs/2026-09-30", userRoots: roots)
            == .userProject(root: "/Users/example/work"))
        // Ahead of scratch, too: the person's word is the most specific thing
        // anybody has said about the folder.
        #expect(place("/Users/example", userRoots: ["/Users/example"])
            == .userProject(root: "/Users/example"))
        #expect(ProjectRollup.userRoot(containing: "/Users/example/workx", among: roots) == nil)
    }

    // MARK: - Rule 3: scratch

    @Test("scratch is no project, whatever its depth")
    func scratchIsProjectless() {
        for (directory, harness, reason) in [
            ("/Users/example", Harness.claudeCode, ScratchRules.Reason.home),
            ("/Users/example/Documents/Codex/2026-08-21/zhe", .codex, .conversation),
            ("/Users/example/Library/Application Support/Claude/scratch-workspaces/w/1/scratch-x",
             .claudeCode, .desktopScratch),
            ("/private/tmp/build/x", .cursor, .temporary),
        ] {
            guard case .projectless(let match) = place(directory, harness: harness) else {
                Issue.record("expected projectless for \(directory)")
                continue
            }
            #expect(match.reason == reason, "\(directory)")
        }
    }

    // MARK: - Rule 4: the workspace root

    @Test("a plain directory rolls up to two levels below the home")
    func rollsUpToTheWorkspace() {
        #expect(place("/Users/example/work/studio 101/live-revision-v3")
            == .workspace(root: "/Users/example/work/studio 101"))
        #expect(place("/Users/example/work/motion-test/take-2/out")
            == .workspace(root: "/Users/example/work/motion-test"))
        // At the workspace depth already: it is its own root.
        #expect(place("/Users/example/agents misc/digest-prompt")
            == .workspace(root: "/Users/example/agents misc/digest-prompt"))
        // One level down: that one level is the root.
        #expect(place("/Users/example/foo") == .workspace(root: "/Users/example/foo"))
    }

    @Test("a hidden segment belongs to the folder that holds it")
    func hiddenSegmentsCut() {
        #expect(place("/Users/example/work/reports/.runs/2026-09-30/x")
            == .workspace(root: "/Users/example/work/reports"))
        // The first hidden segment decides, however many follow.
        #expect(place("/Users/example/a/.b/c/.d/e") == .workspace(root: "/Users/example/a"))
        // A hidden folder straight under the home holds nothing but the home,
        // and the home is no project.
        guard case .projectless(let match) = place("/Users/example/.config/tool") else {
            Issue.record("expected projectless")
            return
        }
        #expect(match.reason == .home)
    }

    @Test("away from the home, the base is the volume, the account, or the root")
    func otherBases() {
        #expect(place("/Volumes/Archive/clients/acme/2026/q3")
            == .workspace(root: "/Volumes/Archive/clients/acme"))
        #expect(place("/Users/example-guest/Code/tool/src")
            == .workspace(root: "/Users/example-guest/Code/tool"))
        #expect(place("/opt/build/agent/run-1") == .workspace(root: "/opt/build"))
        // A base itself holds workspaces; it is not one.
        for base in ["/Volumes/Archive", "/", "/Users/example-guest", "/Volumes/Archive/.Trashes/x"] {
            guard case .projectless(let match) = place(base) else {
                Issue.record("expected projectless for \(base)")
                continue
            }
            #expect(match.reason == .root, "\(base)")
        }
    }

    @Test("the root is standardised, and native, so it compares as a key")
    func rootIsStandardised() {
        #expect(ProjectRollup.workspaceRoot(of: "/Users/example/work/reports/", home: home)
            == "/Users/example/work/reports")
        #expect(ProjectRollup.workspaceRoot(of: "/Users/example/work/./x/../reports/y", home: home)
            == "/Users/example/work/reports")
        #expect(ProjectRollup.workspaceRoot(of: "relative/path", home: home) == nil)
    }

    // MARK: - Rule 5: a root that is not here

    @Test("a workspace root that is gone is no project; a run folder that is gone is")
    func missingRoots() {
        let asked = Mutex<[String]>([])
        let gone = place("/Users/example/work/retired/old-run", exists: { path in
            asked.withLock { $0.append(path) }
            return false
        })
        guard case .projectless(let match) = gone else {
            Issue.record("expected projectless")
            return
        }
        #expect(match.reason == .missing)
        #expect(match.directory == "/Users/example/work/retired")
        // The root is what is asked about, not the directory.
        #expect(asked.withLock { $0 } == ["/Users/example/work/retired"])

        // The run folder was cleaned up, the workspace is still there.
        #expect(place(
            "/Users/example/work/reports/.runs/2026-09-01",
            exists: { $0 == "/Users/example/work/reports" }
        ) == .workspace(root: "/Users/example/work/reports"))
    }

    // MARK: - Through the service

    @Test("the service places a run folder under its workspace, keeping the checkout facts")
    func serviceRollsUp() async throws {
        let service = PlacementService(
            resolver: ProjectResolver(homeDirectory: home),
            rules: rules,
            directoryExists: { _ in true }
        )
        let placement = try #require(await service.placement(
            for: Fixtures.key(.codex, "run-1"),
            cwd: "/Users/example/work/reports/.runs/2026-09-30/x"
        ))
        #expect(placement.projectRootPath == "/Users/example/work/reports")
        #expect(placement.projectName == "reports")
        #expect(placement.gitRoot == nil)
        #expect(!placement.isProjectless)
    }

    @Test("a folder the person pins as a project is not rolled up, from the first pass")
    func servicePinnedFolder() async throws {
        let pinned = "/Users/example/work/reports/.runs/special"
        let service = PlacementService(
            resolver: ProjectResolver(homeDirectory: home),
            rules: rules,
            directoryExists: { _ in true },
            projectRoots: [pinned + "/"]
        )
        #expect(await service.projectRoots == [pinned])
        let key = Fixtures.key(.codex, "pinned")
        let first = try #require(await service.placement(for: key, cwd: pinned + "/a"))
        #expect(first.projectRootPath == pinned)

        // Taking the pin away places it again, under the workspace.
        await service.setUserProjectRoots([])
        let second = try #require(await service.placement(for: key, cwd: pinned + "/a"))
        #expect(second.projectRootPath == "/Users/example/work/reports")
        // The same roots again change nothing.
        await service.setUserProjectRoots([])
        #expect(await service.placement(for: key, cwd: pinned + "/a") == nil)
    }

    // MARK: - Through the registry and the board

    @Test("a rolled-up session groups under its workspace on every surface")
    func rolledUpSessionsGroupTogether() async throws {
        let store = try AuspexStore(inMemory: true)
        let registry = SessionRegistry(
            store: store, publishInterval: 0, persistInterval: 0, tickInterval: 0
        )
        var identities: [SessionIdentity] = []
        for index in 0..<3 {
            let key = Fixtures.key(.codex, "run-\(index)")
            var identity = Fixtures.identity(
                key: key, cwd: "/Users/example/work/reports/.runs/2026-09-3\(index)/x"
            )
            identity.gitBranch = nil
            identities.append(identity)
            await registry.ingest(Fixtures.event(.sessionStarted(identity: identity), key: key, at: Double(index)))
        }
        let service = PlacementService(
            resolver: ProjectResolver(homeDirectory: home),
            rules: rules,
            directoryExists: { _ in true }
        )
        #expect(await registry.applyPlacements(await service.placements(for: identities)) == 3)
        await registry.stop()

        let frame = await registry.snapshot()
        for identity in identities {
            let session = try #require(frame.session(for: identity.key))
            #expect(frame.projectKey(for: session) == "/Users/example/work/reports")
            // The checkout facts are the session's own.
            #expect(session.identity.cwd == identity.cwd)
            #expect(session.identity.gitRoot == nil)
        }
        #expect(BoardGrouping.groups(for: frame, groupBy: .project).map(\.title) == ["reports"])

        // One project, one checkout: sixty runs are sixty rows under one
        // heading, not sixty headings.
        let tree = ProjectTree.build(board: frame)
        #expect(tree.projects.map(\.name) == ["reports"])
        #expect(tree.projects.first?.checkouts.count == 1)
        #expect(tree.projects.first?.checkouts.first?.path == "/Users/example/work/reports")

        // And one `projects` row, for the workspace.
        #expect(try store.projects.fetchProjects().map(\.rootPath)
            == ["/Users/example/work/reports"])
    }
}
