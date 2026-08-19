import Foundation

/// Builds git checkouts by hand, so the resolver suite proves it reads the
/// files rather than proving `git` was installed.
///
/// Everything written here is what git itself writes: a `.git` directory with
/// a `HEAD`, and for a linked worktree the `.git` *file* pointing at
/// `.git/worktrees/<name>` plus the `commondir` that points back. No command is
/// run, and nothing lives outside the temporary directory the test tears down.
enum GitFixtures {
    /// A fresh temporary directory. The caller removes it.
    static func makeTemporaryDirectory() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("auspex-git-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A main checkout: `<root>/.git/` with `HEAD` on `branch`.
    @discardableResult
    static func makeRepository(
        at root: URL,
        branch: String? = "main",
        detachedHead: String? = nil
    ) throws -> URL {
        let gitDirectory = root.appendingPathComponent(".git", isDirectory: true)
        try FileManager.default.createDirectory(
            at: gitDirectory.appendingPathComponent("refs/heads", isDirectory: true),
            withIntermediateDirectories: true
        )
        try writeHEAD(in: gitDirectory, branch: branch, detached: detachedHead)
        return gitDirectory
    }

    /// A linked worktree of `repository`, the way `git worktree add` leaves it:
    /// a `.git` file in the worktree, and `<repo>/.git/worktrees/<name>/` with
    /// its own `HEAD` and a `commondir` of `../..`.
    @discardableResult
    static func makeWorktree(
        at path: URL,
        of repository: URL,
        named name: String,
        branch: String? = "feat/x",
        detachedHead: String? = nil,
        commonDirectory: String? = "../.."
    ) throws -> URL {
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        let linked = repository
            .appendingPathComponent(".git/worktrees", isDirectory: true)
            .appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: linked, withIntermediateDirectories: true)
        try writeHEAD(in: linked, branch: branch, detached: detachedHead)
        if let commonDirectory {
            try write("\(commonDirectory)\n", to: linked.appendingPathComponent("commondir"))
        }
        try write("gitdir: \(linked.path)\n", to: path.appendingPathComponent(".git"))
        return linked
    }

    /// Creates a directory, and every parent it needs.
    @discardableResult
    static func makeDirectory(_ url: URL) throws -> URL {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func write(_ contents: String, to url: URL) throws {
        try Data(contents.utf8).write(to: url)
    }

    private static func writeHEAD(in gitDirectory: URL, branch: String?, detached: String?) throws {
        let head = gitDirectory.appendingPathComponent("HEAD")
        if let detached {
            try write("\(detached)\n", to: head)
        } else if let branch {
            try write("ref: refs/heads/\(branch)\n", to: head)
        }
    }
}
