import Foundation

/// Works out which project a working directory belongs to, by reading the
/// repository's own files.
///
/// ## No `git` subprocess
///
/// Auspex resolves a placement for every session it sees, re-checks it
/// whenever a session reports a new working directory, and does it while a
/// board is being redrawn. A `git rev-parse` per session per change is a
/// process launch per session per change, and on a machine running a dozen
/// agents that is a measurable amount of the user's CPU spent asking a
/// question three text files already answer:
///
/// - `.git` — a directory in the main checkout, a file in a linked worktree.
/// - `<gitdir>/commondir` — where a linked worktree's own directory points
///   back to the repository it belongs to.
/// - `<gitdir>/HEAD` — the branch, or a bare hash when it is detached.
///
/// Everything here reads those and nothing else. It never writes, never runs a
/// command, and never follows a symlink out of the directory it was given.
///
/// ## Caching
///
/// A placement is cached per directory. The `HEAD` file's modification date is
/// the invalidation signal, because it is what actually changes: a branch
/// switch rewrites `HEAD`, while the repository root and the worktree layout
/// are fixed for the life of a checkout. Where there is no `HEAD` to watch —
/// a directory in no repository — the entry simply expires after ``timeToLive``,
/// since the only interesting change is somebody running `git init`.
public actor ProjectResolver {
    /// How long a placement with no `HEAD` file to watch is reused.
    public let timeToLive: TimeInterval

    private let fileManager: FileManager
    private let clock: @Sendable () -> Date
    private var cache: [String: Entry] = [:]

    /// The directory names an agent worktree lives under, paired with the
    /// `worktrees` component that follows. Kept as a set of first components
    /// because the shape is the same for all of them:
    /// `<marker>/worktrees/<task>`.
    public static let agentWorktreeMarkers: Set<String> = [
        ".agents", ".claude", ".codex", ".cursor", ".grok",
    ]

    /// Largest `.git` pointer or `HEAD` file that will be read. Both are one
    /// short line by construction; anything larger is not one of them, and a
    /// resolver has no business pulling it into memory.
    static let maximumPointerFileSize = 8 * 1024

    /// Creates a resolver.
    ///
    /// - Parameters:
    ///   - timeToLive: how long a placement with no `HEAD` to watch is reused.
    ///   - fileManager: injected so a test can point at a temporary tree.
    ///   - clock: injected so a test can drive expiry without sleeping.
    public init(
        timeToLive: TimeInterval = 30,
        fileManager: FileManager = .default,
        clock: @escaping @Sendable () -> Date = Date.init
    ) {
        self.timeToLive = timeToLive
        self.fileManager = fileManager
        self.clock = clock
    }

    // MARK: - Resolving

    /// The placement of `cwd`, from the cache when it is still good.
    public func resolve(cwd: String) -> ProjectPlacement {
        let directory = Self.standardized(cwd)
        if let entry = cache[directory], isFresh(entry) {
            return entry.placement
        }
        let resolved = compute(directory: directory)
        cache[directory] = Entry(
            placement: resolved.placement,
            headPath: resolved.headPath,
            headModified: resolved.headPath.flatMap(modificationDate(ofFile:)),
            resolvedAt: clock()
        )
        return resolved.placement
    }

    /// Resolves several directories, reusing the cache across them.
    public func resolve(cwds: [String]) -> [String: ProjectPlacement] {
        var out: [String: ProjectPlacement] = [:]
        out.reserveCapacity(cwds.count)
        for cwd in cwds where out[cwd] == nil {
            out[cwd] = resolve(cwd: cwd)
        }
        return out
    }

    /// Empties the cache. For a host that has reason to believe the world
    /// moved underneath it, and for tests.
    public func invalidateAll() {
        cache.removeAll(keepingCapacity: true)
    }

    /// How many directories are cached. Test seam.
    public var cachedDirectoryCount: Int { cache.count }

    // MARK: - The walk

    private struct Resolution {
        var placement: ProjectPlacement
        /// The `HEAD` whose mtime invalidates the entry, when there is one.
        var headPath: String?
    }

    private func compute(directory: String) -> Resolution {
        guard let found = findGitDirectory(from: directory) else {
            return Resolution(
                placement: ProjectPlacement(
                    projectRootPath: directory,
                    projectName: (directory as NSString).lastPathComponent,
                    agentWorktreeTask: Self.agentWorktreeTask(in: directory)
                ),
                headPath: nil
            )
        }

        let head = (found.gitDirectory as NSString).appendingPathComponent("HEAD")
        let branch = Self.branch(inHEAD: readPointerFile(head))
        // The task name is a property of where the checkout *is*, so it is read
        // from the worktree path when there is one and from the directory that
        // holds `.git` otherwise — never from a subdirectory the session
        // happened to `cd` into, which would name a source folder.
        let taskPath = found.worktreePath ?? found.gitRoot

        return Resolution(
            placement: ProjectPlacement(
                projectRootPath: found.gitRoot,
                projectName: (found.gitRoot as NSString).lastPathComponent,
                gitRoot: found.gitRoot,
                worktreePath: found.worktreePath,
                branch: branch,
                agentWorktreeTask: Self.agentWorktreeTask(in: taskPath)
            ),
            headPath: head
        )
    }

    private struct GitLocation {
        /// The main repository root — the directory whose `.git` is the real
        /// one, even when the session is in a linked worktree of it.
        var gitRoot: String
        /// The linked worktree's own root, when the session is in one.
        var worktreePath: String?
        /// The directory holding this checkout's `HEAD`.
        var gitDirectory: String
    }

    /// Walks up from `directory` looking for a `.git`, and works out what kind
    /// of checkout it found.
    private func findGitDirectory(from directory: String) -> GitLocation? {
        var current = directory
        while true {
            let dotGit = (current as NSString).appendingPathComponent(".git")
            var isDirectory: ObjCBool = false
            if fileManager.fileExists(atPath: dotGit, isDirectory: &isDirectory) {
                if isDirectory.boolValue {
                    return GitLocation(gitRoot: current, worktreePath: nil, gitDirectory: dotGit)
                }
                if let location = linkedWorktree(at: current, pointer: dotGit) {
                    return location
                }
                // A `.git` file that does not name a gitdir is not something to
                // guess about, but the directory holding it is still the top of
                // *a* checkout.
                return GitLocation(gitRoot: current, worktreePath: nil, gitDirectory: dotGit)
            }
            let parent = (current as NSString).deletingLastPathComponent
            guard !parent.isEmpty, parent != current else { return nil }
            current = parent
        }
    }

    /// Resolves a `.git` *file* — the marker of a linked worktree — back to the
    /// repository it belongs to.
    ///
    /// The file says `gitdir: <path to .git/worktrees/<name>>`, and that
    /// directory holds a `commondir` pointing at the repository's shared `.git`.
    /// The repository root is that directory's parent. When `commondir` is
    /// missing — an older layout, or a submodule, whose gitdir sits under
    /// `.git/modules` instead — the `.git/worktrees/<name>` shape is stripped
    /// off instead, and failing even that the worktree stands alone as its own
    /// project rather than being attached to a guess.
    private func linkedWorktree(at directory: String, pointer: String) -> GitLocation? {
        guard let contents = readPointerFile(pointer) else { return nil }
        guard let gitDirectory = Self.gitDirectory(inPointer: contents, relativeTo: directory) else {
            return nil
        }

        let commonDirFile = (gitDirectory as NSString).appendingPathComponent("commondir")
        var commonDirectory: String?
        if let raw = readPointerFile(commonDirFile) {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                commonDirectory = Self.absolute(trimmed, relativeTo: gitDirectory)
            }
        }
        if commonDirectory == nil {
            let parent = (gitDirectory as NSString).deletingLastPathComponent
            if (parent as NSString).lastPathComponent == "worktrees" {
                commonDirectory = (parent as NSString).deletingLastPathComponent
            }
        }

        guard let commonDirectory else {
            return GitLocation(gitRoot: directory, worktreePath: nil, gitDirectory: gitDirectory)
        }
        let root = (commonDirectory as NSString).deletingLastPathComponent
        guard !root.isEmpty, root != "/" else {
            return GitLocation(gitRoot: directory, worktreePath: nil, gitDirectory: gitDirectory)
        }
        return GitLocation(
            gitRoot: Self.standardized(root),
            worktreePath: directory,
            gitDirectory: gitDirectory
        )
    }

    // MARK: - Parsing

    /// The gitdir a `.git` pointer file names, made absolute.
    static func gitDirectory(inPointer contents: String, relativeTo directory: String) -> String? {
        for line in contents.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("gitdir:") else { continue }
            let value = trimmed.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
            guard !value.isEmpty else { return nil }
            return absolute(value, relativeTo: directory)
        }
        return nil
    }

    /// The branch named by a `HEAD` file, or the short hash when it is
    /// detached. `nil` when the file could not be read or says neither.
    static func branch(inHEAD contents: String?) -> String? {
        guard let contents else { return nil }
        let trimmed = contents.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.hasPrefix("ref:") {
            let reference = trimmed.dropFirst("ref:".count).trimmingCharacters(in: .whitespaces)
            let prefix = "refs/heads/"
            if reference.hasPrefix(prefix) { return String(reference.dropFirst(prefix.count)) }
            return reference.isEmpty ? nil : reference
        }
        // Detached: a bare object id. Shortened the way git shows it, and only
        // when it really is one — a `HEAD` holding anything else is not a fact
        // worth reporting as a branch.
        let isHexadecimal = trimmed.count >= 7
            && trimmed.allSatisfy { $0.isHexDigit && ($0.isNumber || $0.isLowercase) }
        guard isHexadecimal else { return nil }
        return String(trimmed.prefix(shortHashLength))
    }

    /// How much of a detached `HEAD`'s hash is shown. Seven is git's own
    /// minimum, and what a person reads in their own prompt.
    static let shortHashLength = 7

    /// The `<task>` of a `<marker>/worktrees/<task>` path, when `path` is
    /// inside one.
    ///
    /// The deepest match wins: an agent worktree can itself contain another
    /// one, and the innermost is the checkout the session is actually in.
    public static func agentWorktreeTask(in path: String) -> String? {
        let components = (path as NSString).pathComponents
        var task: String?
        var index = 0
        while index + 2 < components.count {
            if agentWorktreeMarkers.contains(components[index]),
               components[index + 1] == "worktrees" {
                task = components[index + 2]
                index += 3
                continue
            }
            index += 1
        }
        return task
    }

    /// Collapses `.` and `..` without resolving symlinks.
    ///
    /// Deliberately not `resolvingSymlinksInPath()`: a session's working
    /// directory is the path the person is looking at, and rewriting
    /// `/var/folders/…` into `/private/var/folders/…` under them would make the
    /// board disagree with their terminal for no gain.
    static func standardized(_ path: String) -> String {
        let standardized = (path as NSString).standardizingPath
        guard standardized.count > 1, standardized.hasSuffix("/") else { return standardized }
        return String(standardized.dropLast())
    }

    private static func absolute(_ path: String, relativeTo directory: String) -> String {
        if path.hasPrefix("/") { return standardized(path) }
        return standardized((directory as NSString).appendingPathComponent(path))
    }

    // MARK: - Files

    /// Reads a one-line pointer file, refusing anything that is not one.
    private func readPointerFile(_ path: String) -> String? {
        guard let attributes = try? fileManager.attributesOfItem(atPath: path),
              let size = attributes[.size] as? NSNumber,
              size.intValue > 0,
              size.intValue <= Self.maximumPointerFileSize,
              attributes[.type] as? FileAttributeType == .typeRegular,
              let data = fileManager.contents(atPath: path)
        else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    private func modificationDate(ofFile path: String) -> Date? {
        (try? fileManager.attributesOfItem(atPath: path))?[.modificationDate] as? Date
    }

    private func isFresh(_ entry: Entry) -> Bool {
        if let headPath = entry.headPath {
            // A repository's layout does not move; its `HEAD` does. Matching
            // mtimes means the branch is the one that was read, which is the
            // only part of the answer that goes stale.
            return modificationDate(ofFile: headPath) == entry.headModified
        }
        return clock().timeIntervalSince(entry.resolvedAt) < timeToLive
    }

    private struct Entry {
        let placement: ProjectPlacement
        let headPath: String?
        let headModified: Date?
        let resolvedAt: Date
    }
}
