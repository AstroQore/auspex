import Foundation
import Testing

@testable import AuspexCore

@Suite("ProjectResolver")
struct ProjectResolverTests {
    @Test("a directory in no repository is its own project")
    func plainDirectory() async throws {
        let root = try GitFixtures.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let scratch = try GitFixtures.makeDirectory(root.appendingPathComponent("scratch"))

        let placement = await ProjectResolver().resolve(cwd: scratch.path)
        #expect(placement.projectRootPath == ProjectResolver.standardized(scratch.path))
        #expect(placement.projectName == "scratch")
        #expect(placement.gitRoot == nil)
        #expect(placement.worktreePath == nil)
        #expect(placement.branch == nil)
        #expect(!placement.isWorktree)
    }

    @Test("a subdirectory resolves to the repository above it, with its branch")
    func mainCheckout() async throws {
        let root = try GitFixtures.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try GitFixtures.makeDirectory(root.appendingPathComponent("widget"))
        try GitFixtures.makeRepository(at: repository, branch: "main")
        let deep = try GitFixtures.makeDirectory(
            repository.appendingPathComponent("Sources/Widget")
        )

        let placement = await ProjectResolver().resolve(cwd: deep.path)
        #expect(placement.projectRootPath == ProjectResolver.standardized(repository.path))
        #expect(placement.gitRoot == ProjectResolver.standardized(repository.path))
        #expect(placement.projectName == "widget")
        #expect(placement.branch == "main")
        #expect(!placement.isWorktree)
        #expect(placement.agentWorktreeTask == nil)
    }

    @Test("a detached HEAD reports the short hash instead of a branch")
    func detachedHead() async throws {
        let root = try GitFixtures.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try GitFixtures.makeDirectory(root.appendingPathComponent("widget"))
        try GitFixtures.makeRepository(
            at: repository,
            branch: nil,
            detachedHead: "0123456789abcdef0123456789abcdef01234567"
        )

        let placement = await ProjectResolver().resolve(cwd: repository.path)
        #expect(placement.branch == "0123456")
    }

    @Test("a branch with slashes survives intact")
    func slashedBranch() async throws {
        let root = try GitFixtures.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try GitFixtures.makeDirectory(root.appendingPathComponent("widget"))
        try GitFixtures.makeRepository(at: repository, branch: "feat/deeply/nested")

        #expect(await ProjectResolver().resolve(cwd: repository.path).branch == "feat/deeply/nested")
    }

    @Test("a linked worktree groups under the repository it was branched from")
    func linkedWorktree() async throws {
        let root = try GitFixtures.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try GitFixtures.makeDirectory(root.appendingPathComponent("widget"))
        try GitFixtures.makeRepository(at: repository, branch: "main")
        let worktree = repository.appendingPathComponent(".agents/worktrees/feat-resizer")
        try GitFixtures.makeWorktree(
            at: worktree, of: repository, named: "feat-resizer", branch: "feat/resizer"
        )

        let placement = await ProjectResolver().resolve(cwd: worktree.path)
        #expect(placement.projectRootPath == ProjectResolver.standardized(repository.path))
        #expect(placement.gitRoot == ProjectResolver.standardized(repository.path))
        #expect(placement.worktreePath == ProjectResolver.standardized(worktree.path))
        #expect(placement.isWorktree)
        #expect(placement.branch == "feat/resizer")
        #expect(placement.agentWorktreeTask == "feat-resizer")
    }

    @Test("a worktree outside the repository still groups under it")
    func worktreeOutsideTheRepository() async throws {
        let root = try GitFixtures.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try GitFixtures.makeDirectory(root.appendingPathComponent("widget"))
        try GitFixtures.makeRepository(at: repository, branch: "main")
        let worktree = root.appendingPathComponent("widget-feat-x")
        try GitFixtures.makeWorktree(at: worktree, of: repository, named: "feat-x")

        let placement = await ProjectResolver().resolve(cwd: worktree.path)
        #expect(placement.projectRootPath == ProjectResolver.standardized(repository.path))
        #expect(placement.isWorktree)
        // Not an agent worktree: the path follows no convention.
        #expect(placement.agentWorktreeTask == nil)
    }

    @Test("a worktree whose commondir is missing falls back to the layout")
    func worktreeWithoutCommonDir() async throws {
        let root = try GitFixtures.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try GitFixtures.makeDirectory(root.appendingPathComponent("widget"))
        try GitFixtures.makeRepository(at: repository, branch: "main")
        let worktree = root.appendingPathComponent("detached-wt")
        try GitFixtures.makeWorktree(
            at: worktree, of: repository, named: "wt", commonDirectory: nil
        )

        let placement = await ProjectResolver().resolve(cwd: worktree.path)
        #expect(placement.gitRoot == ProjectResolver.standardized(repository.path))
        #expect(placement.isWorktree)
    }

    @Test("a session deeper inside a worktree still names the worktree's task")
    func deepInsideAWorktree() async throws {
        let root = try GitFixtures.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try GitFixtures.makeDirectory(root.appendingPathComponent("widget"))
        try GitFixtures.makeRepository(at: repository, branch: "main")
        let worktree = repository.appendingPathComponent(".codex/worktrees/fix-crash")
        try GitFixtures.makeWorktree(
            at: worktree, of: repository, named: "fix-crash", branch: "fix/crash"
        )
        let deep = try GitFixtures.makeDirectory(worktree.appendingPathComponent("Sources/Widget"))

        let placement = await ProjectResolver().resolve(cwd: deep.path)
        #expect(placement.worktreePath == ProjectResolver.standardized(worktree.path))
        #expect(placement.agentWorktreeTask == "fix-crash")
        #expect(placement.branch == "fix/crash")
    }

    @Test("two worktrees of one repository are one project")
    func worktreesShareAProject() async throws {
        let root = try GitFixtures.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try GitFixtures.makeDirectory(root.appendingPathComponent("widget"))
        try GitFixtures.makeRepository(at: repository, branch: "main")
        let first = repository.appendingPathComponent(".agents/worktrees/one")
        let second = repository.appendingPathComponent(".agents/worktrees/two")
        try GitFixtures.makeWorktree(at: first, of: repository, named: "one", branch: "feat/one")
        try GitFixtures.makeWorktree(at: second, of: repository, named: "two", branch: "feat/two")

        let resolver = ProjectResolver()
        let placements = await resolver.resolve(cwds: [
            first.path, second.path, repository.path,
        ])
        #expect(Set(placements.values.map(\.projectRootPath)).count == 1)
        #expect(placements[first.path]?.branch == "feat/one")
        #expect(placements[second.path]?.branch == "feat/two")
        #expect(placements[repository.path]?.isWorktree == false)
    }

    // MARK: - Caching

    @Test("a repeated directory is answered from the cache")
    func cacheReuse() async throws {
        let root = try GitFixtures.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try GitFixtures.makeDirectory(root.appendingPathComponent("widget"))
        try GitFixtures.makeRepository(at: repository, branch: "main")

        let resolver = ProjectResolver()
        _ = await resolver.resolve(cwd: repository.path)
        _ = await resolver.resolve(cwd: repository.path)
        #expect(await resolver.cachedDirectoryCount == 1)
    }

    @Test("rewriting HEAD invalidates the cached branch")
    func headInvalidatesTheCache() async throws {
        let root = try GitFixtures.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try GitFixtures.makeDirectory(root.appendingPathComponent("widget"))
        let gitDirectory = try GitFixtures.makeRepository(at: repository, branch: "main")

        let resolver = ProjectResolver()
        #expect(await resolver.resolve(cwd: repository.path).branch == "main")

        // A checkout rewrites HEAD; the mtime moving is what the resolver
        // watches, so it is set explicitly rather than raced against.
        let head = gitDirectory.appendingPathComponent("HEAD")
        try GitFixtures.write("ref: refs/heads/feat/resizer\n", to: head)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(60)],
            ofItemAtPath: head.path
        )
        #expect(await resolver.resolve(cwd: repository.path).branch == "feat/resizer")
    }

    @Test("a directory with no HEAD to watch expires on the clock instead")
    func timeToLiveExpiry() async throws {
        let root = try GitFixtures.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let scratch = try GitFixtures.makeDirectory(root.appendingPathComponent("scratch"))

        let now = Mutable(Date(timeIntervalSince1970: 0))
        let resolver = ProjectResolver(timeToLive: 30, clock: { now.value })
        #expect(await resolver.resolve(cwd: scratch.path).gitRoot == nil)

        // `git init` under the resolver's feet is invisible until the entry
        // expires, and unmistakable afterwards.
        try GitFixtures.makeRepository(at: scratch, branch: "main")
        #expect(await resolver.resolve(cwd: scratch.path).gitRoot == nil)
        now.value = Date(timeIntervalSince1970: 31)
        #expect(await resolver.resolve(cwd: scratch.path).branch == "main")
    }

    // MARK: - Parsing

    @Test("HEAD is parsed the way git writes it, and refused otherwise")
    func headParsing() {
        #expect(ProjectResolver.branch(inHEAD: "ref: refs/heads/main\n") == "main")
        #expect(ProjectResolver.branch(inHEAD: "  ref: refs/heads/feat/x  ") == "feat/x")
        #expect(ProjectResolver.branch(inHEAD: "ref: refs/remotes/origin/main")
            == "refs/remotes/origin/main")
        #expect(ProjectResolver.branch(inHEAD: "0123456789abcdef0123456789abcdef01234567")
            == "0123456")
        #expect(ProjectResolver.branch(inHEAD: "") == nil)
        #expect(ProjectResolver.branch(inHEAD: nil) == nil)
        // Not a hash and not a ref: nothing worth reporting as a branch.
        #expect(ProjectResolver.branch(inHEAD: "garbage") == nil)
        #expect(ProjectResolver.branch(inHEAD: "0123") == nil)
    }

    @Test("every agent worktree convention is recognised, innermost first")
    func agentWorktreeConventions() {
        for marker in [".agents", ".claude", ".codex", ".cursor", ".grok"] {
            #expect(
                ProjectResolver.agentWorktreeTask(in: "/Users/example/repo/\(marker)/worktrees/task-1")
                    == "task-1"
            )
        }
        #expect(ProjectResolver.agentWorktreeTask(in: "/Users/example/repo") == nil)
        #expect(ProjectResolver.agentWorktreeTask(in: "/Users/example/repo/.agents") == nil)
        #expect(
            ProjectResolver.agentWorktreeTask(in: "/Users/example/repo/.agents/worktrees") == nil
        )
        // Nested: the checkout the session is in is the inner one.
        #expect(
            ProjectResolver.agentWorktreeTask(
                in: "/Users/example/repo/.agents/worktrees/outer/.claude/worktrees/inner"
            ) == "inner"
        )
    }

    @Test("a gitdir pointer is made absolute against the directory holding it")
    func gitDirectoryPointer() {
        #expect(
            ProjectResolver.gitDirectory(
                inPointer: "gitdir: /Users/example/repo/.git/worktrees/wt\n",
                relativeTo: "/Users/example/wt"
            ) == "/Users/example/repo/.git/worktrees/wt"
        )
        #expect(
            ProjectResolver.gitDirectory(
                inPointer: "gitdir: ../repo/.git/worktrees/wt",
                relativeTo: "/Users/example/wt"
            ) == "/Users/example/repo/.git/worktrees/wt"
        )
        #expect(ProjectResolver.gitDirectory(inPointer: "nonsense", relativeTo: "/tmp") == nil)
        #expect(ProjectResolver.gitDirectory(inPointer: "gitdir:", relativeTo: "/tmp") == nil)
    }
}

/// A box a `@Sendable` closure can read a changing value out of, so a test can
/// drive an injected clock without a shared mutable global.
final class Mutable<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Value

    init(_ value: Value) { self.storage = value }

    var value: Value {
        get { lock.withLock { storage } }
        set { lock.withLock { storage = newValue } }
    }
}
