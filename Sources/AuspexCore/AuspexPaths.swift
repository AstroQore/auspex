import Foundation

/// Single source of truth for everything Auspex writes to disk.
///
/// Auspex observes other agent harnesses by reading their on-disk session
/// stores, and it must never write into them. Every path Auspex *owns* lives
/// under `~/.auspex/`, and every one of them is vended from here — so the
/// write scope is auditable by reading one file, and tests can redirect the
/// whole tree into a temporary directory by injecting a different home.
public struct AuspexPaths: Sendable {
    /// Directory Auspex treats as the user's home. Production uses the real
    /// home; tests pass a temporary directory.
    public let homeDirectory: URL

    /// Permissions applied to `~/.auspex/` and every directory created under
    /// it. Session transcripts are sensitive; keep them owner-only.
    public static let directoryPermissions = 0o700

    /// Paths rooted at the current user's real home directory.
    public static let `default` = AuspexPaths(homeDirectory: AuspexPaths.realHomeDirectory())

    public init(homeDirectory: URL) {
        self.homeDirectory = homeDirectory
    }

    /// The real home directory, resolved from the password database rather
    /// than `$HOME`. `NSHomeDirectory()` is rewritten inside an app sandbox
    /// container; Auspex ships unsandboxed today, but resolving through
    /// `getpwuid` keeps the answer correct if that ever changes, and keeps a
    /// stray `HOME` in a spawned agent's environment from redirecting us.
    public static func realHomeDirectory() -> URL {
        if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir {
            let path = String(cString: dir)
            if !path.isEmpty {
                return URL(fileURLWithPath: path, isDirectory: true)
            }
        }
        return URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
    }

    // MARK: - Owned locations

    /// `~/.auspex` — the only directory tree Auspex writes to.
    public var baseDirectory: URL {
        homeDirectory.appendingPathComponent(".auspex", isDirectory: true)
    }

    /// `~/.auspex/auspex.db` — GRDB store for sessions, events, and tasks.
    public var databaseURL: URL {
        baseDirectory.appendingPathComponent("auspex.db", isDirectory: false)
    }

    /// `~/.auspex/mcp.sock` — Unix domain socket the MCP server listens on.
    /// The `--mcp-stdio` bridge connects here on behalf of MCP clients.
    public var socketURL: URL {
        baseDirectory.appendingPathComponent("mcp.sock", isDirectory: false)
    }

    /// Filesystem path of ``socketURL``. `sockaddr_un.sun_path` is 104 bytes
    /// on Darwin, so callers bind with the string, not the URL.
    public var socketPath: String {
        socketURL.path
    }

    /// `~/.auspex/settings.json` — user preferences.
    public var settingsURL: URL {
        baseDirectory.appendingPathComponent("settings.json", isDirectory: false)
    }

    /// `~/.auspex/logs` — Auspex's own diagnostic logs (never harness logs).
    public var logsDirectory: URL {
        baseDirectory.appendingPathComponent("logs", isDirectory: true)
    }

    /// `~/.auspex/characters` — user-supplied character packages.
    ///
    /// Read constantly and written only by the person who drops a package in.
    /// Auspex creates it on demand — the Settings pane's "Open characters
    /// folder" button and the watcher both need somewhere to point at — and
    /// never puts anything inside it.
    public var charactersDirectory: URL {
        baseDirectory.appendingPathComponent("characters", isDirectory: true)
    }

    /// `~/.auspex/character-selection.json` — which character each harness
    /// wears, plus any per-session overrides.
    ///
    /// Separate from ``settingsURL`` because it is written by a different
    /// surface at a different rhythm: a person picking a character for one
    /// harness should not rewrite the file that holds retention and indexing
    /// preferences.
    public var characterSelectionURL: URL {
        baseDirectory.appendingPathComponent("character-selection.json", isDirectory: false)
    }

    // MARK: - Lazy creation

    /// Creates `~/.auspex/` with 0700 if it does not exist and returns it.
    @discardableResult
    public func ensureBaseDirectory(
        fileManager: FileManager = .default
    ) throws -> URL {
        try ensureDirectory(baseDirectory, fileManager: fileManager)
    }

    /// Creates `~/.auspex/logs/` with 0700 if it does not exist.
    @discardableResult
    public func ensureLogsDirectory(
        fileManager: FileManager = .default
    ) throws -> URL {
        try ensureDirectory(logsDirectory, fileManager: fileManager)
    }

    /// Creates `~/.auspex/characters/` with 0700 if it does not exist.
    @discardableResult
    public func ensureCharactersDirectory(
        fileManager: FileManager = .default
    ) throws -> URL {
        try ensureDirectory(charactersDirectory, fileManager: fileManager)
    }

    /// Creates the parent directory of ``databaseURL`` and returns the file
    /// URL. Call before handing the path to GRDB.
    @discardableResult
    public func ensureDatabaseParentDirectory(
        fileManager: FileManager = .default
    ) throws -> URL {
        try ensureBaseDirectory(fileManager: fileManager)
        return databaseURL
    }

    /// Creates `directory` with 0700 if needed, and tightens the mode of an
    /// existing directory that is more permissive than that.
    ///
    /// Refuses to touch anything outside ``baseDirectory`` — the containment
    /// check is what makes "Auspex only writes under `~/.auspex/`" a property
    /// of the code rather than a convention.
    @discardableResult
    public func ensureDirectory(
        _ directory: URL,
        fileManager: FileManager = .default
    ) throws -> URL {
        guard contains(directory) else {
            throw AuspexPathsError.outsideBaseDirectory(directory)
        }
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: Self.directoryPermissions]
        )
        try fileManager.setAttributes(
            [.posixPermissions: Self.directoryPermissions],
            ofItemAtPath: directory.path
        )
        return directory
    }

    /// True when `url` is ``baseDirectory`` or lives under it.
    public func contains(_ url: URL) -> Bool {
        let base = baseDirectory.standardizedFileURL.path
        let candidate = url.standardizedFileURL.path
        return candidate == base || candidate.hasPrefix(base + "/")
    }
}

public enum AuspexPathsError: Error, CustomStringConvertible {
    /// A caller asked Auspex to create a directory outside `~/.auspex/`.
    case outsideBaseDirectory(URL)

    public var description: String {
        switch self {
        case .outsideBaseDirectory(let url):
            return "Refusing to create \(url.lastPathComponent): outside the Auspex base directory."
        }
    }
}
