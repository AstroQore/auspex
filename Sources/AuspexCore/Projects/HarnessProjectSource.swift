import AgentSessionKit
import AgentSessionLive
import Foundation
import SQLite3

/// A harness's own list of the directories it has worked in.
///
/// Every harness keeps one, because every harness needs to remember per-project
/// settings, and it is a far better seed for "which projects do I care about"
/// than a live board is: it survives the sessions that made it, and it is
/// already the person's own answer to what a project is.
///
/// A protocol with two implementations rather than two functions, because the
/// list of harnesses that have one is not two — Cursor, AntiGravity and Grok
/// Build all keep something similar — and the Projects page should grow a row
/// per source rather than a branch per harness.
///
/// **Read-only, and narrowly.** A source opens the file, takes the paths, and
/// closes it. It never writes, never creates a missing file, and never reads a
/// key it did not come for. `~/.claude.json` is the file where that matters
/// most: it holds account information beside the project list, and only the
/// `projects` key is ever touched.
public protocol HarnessProjectSource: Sendable {
    /// Whose registry this is.
    var harness: Harness { get }
    /// Where it is, for the page to show.
    var location: String { get }
    /// The directories it names, most recently active first where the registry
    /// records that, and alphabetically where it does not.
    func projects() -> [HarnessProjectRef]
}

/// The sources Auspex can import from today.
public enum HarnessProjectRegistry {
    /// One source per harness whose registry Auspex knows how to read.
    public static func sources(home: URL) -> [any HarnessProjectSource] {
        [ClaudeProjectSource(home: home), CodexProjectSource(home: home)]
    }

    /// Largest registry file that will be read. `~/.claude.json` is the
    /// outlier at a few hundred kilobytes; anything past this is not a config.
    static let maximumFileSize = 16 * 1024 * 1024

    /// Reads a registry file, refusing anything that is not a plain file of a
    /// sane size. Symlinks are resolved first, because the attributes of a
    /// link say nothing about its target.
    static func readFile(at path: String) -> Data? {
        let fileManager = FileManager.default
        let path = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        guard let attributes = try? fileManager.attributesOfItem(atPath: path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? NSNumber,
              size.intValue <= maximumFileSize
        else { return nil }
        return fileManager.contents(atPath: path)
    }

    /// Merges refs from several reads of one harness, keeping the newest
    /// `lastSeen` per path and dropping anything that is not an absolute path.
    static func merge(_ refs: [HarnessProjectRef]) -> [HarnessProjectRef] {
        var byPath: [String: HarnessProjectRef] = [:]
        for ref in refs {
            let path = ProjectPath.normalize(ref.path)
            guard path.hasPrefix("/") else { continue }
            let normalized = HarnessProjectRef(
                harness: ref.harness,
                path: path,
                lastSeen: ref.lastSeen
            )
            guard let existing = byPath[path] else {
                byPath[path] = normalized
                continue
            }
            guard let seen = normalized.lastSeen else { continue }
            if existing.lastSeen == nil || existing.lastSeen! < seen {
                byPath[path] = normalized
            }
        }
        return byPath.values.sorted { lhs, rhs in
            switch (lhs.lastSeen, rhs.lastSeen) {
            case (let left?, let right?) where left != right: return left > right
            case (nil, _?): return false
            case (_?, nil): return true
            default: return lhs.path < rhs.path
            }
        }
    }
}

// MARK: - Claude Code

/// Claude Code's registry, which is in two places at once.
///
/// `~/.claude/projects/<encoded cwd>/` is one directory per project, named by
/// the lossy encoding ``ClaudeProjectPath`` undoes — checked against the file
/// system, so `vibe-bar` comes back as `vibe-bar` rather than as `vibe/bar`
/// whenever the directory is still there. `~/.claude.json`'s `projects` object
/// is keyed by the *unencoded* path, so it is exact, and it also names
/// projects whose transcripts have been cleaned up.
///
/// Both are read and merged, because neither is a superset of the other.
public struct ClaudeProjectSource: HarnessProjectSource {
    public let harness: Harness = .claudeCode
    public let home: URL

    public init(home: URL = AuspexPaths.realHomeDirectory()) {
        self.home = home
    }

    /// The directory of transcripts. The JSON file is named beside it in the
    /// page's caption rather than here, because this is the location a person
    /// can go and look at.
    public var location: String {
        home.appendingPathComponent(".claude/projects", isDirectory: true).path
    }

    var configURL: URL { home.appendingPathComponent(".claude.json", isDirectory: false) }

    public func projects() -> [HarnessProjectRef] {
        HarnessProjectRegistry.merge(fromTranscripts() + fromConfig())
    }

    /// One ref per `~/.claude/projects/<encoded>` directory, dated by the
    /// directory's own modification time — which is when a transcript was last
    /// written into it.
    func fromTranscripts(fileManager: FileManager = .default) -> [HarnessProjectRef] {
        let root = URL(fileURLWithPath: location, isDirectory: true)
        guard let entries = try? fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        return entries.compactMap { url in
            let values = try? url.resourceValues(
                forKeys: [.isDirectoryKey, .contentModificationDateKey]
            )
            guard values?.isDirectory == true else { return nil }
            guard let path = ClaudeProjectPath.decode(
                directoryName: url.lastPathComponent,
                fileManager: fileManager
            ) else { return nil }
            return HarnessProjectRef(
                harness: .claudeCode,
                path: path,
                lastSeen: values?.contentModificationDate
            )
        }
    }

    /// The keys of `~/.claude.json`'s `projects` object.
    ///
    /// The file also holds account information, MCP servers, and a per-project
    /// history of everything typed into that project. **Only the keys of
    /// `projects` are read** — not the values, not any other top-level key —
    /// and nothing from this file is logged or stored beyond the paths.
    func fromConfig() -> [HarnessProjectRef] {
        guard let data = HarnessProjectRegistry.readFile(at: configURL.path) else { return [] }
        return Self.projectPaths(inConfig: data).map {
            HarnessProjectRef(harness: .claudeCode, path: $0)
        }
    }

    /// The `projects` keys in a `~/.claude.json`, and nothing else in it.
    ///
    /// Separated from the read so a test can drive it with a fixture, and so
    /// the "only these keys" rule is one function somebody can check.
    static func projectPaths(inConfig data: Data) -> [String] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let projects = root["projects"] as? [String: Any]
        else { return [] }
        return projects.keys.filter { $0.hasPrefix("/") }.sorted()
    }
}

// MARK: - Codex

/// Codex's registry, also in two places.
///
/// `[projects."<path>"]` tables in `~/.codex/config.toml` are what a person
/// configured — trust settings, per-project instructions — and the
/// `local_thread_catalog` table in `~/.codex/sqlite/codex-dev.db` is where its
/// threads actually ran, with the time of the last one.
///
/// The database is opened through ``LiveSQLiteReader``, which opens read-only
/// and falls back to a private copy when Codex is holding a live WAL. Nothing
/// here can write to it.
public struct CodexProjectSource: HarnessProjectSource {
    public let harness: Harness = .codex
    public let home: URL

    public init(home: URL = AuspexPaths.realHomeDirectory()) {
        self.home = home
    }

    public var location: String {
        home.appendingPathComponent(".codex/config.toml", isDirectory: false).path
    }

    var catalogURL: URL {
        home.appendingPathComponent(".codex/sqlite/codex-dev.db", isDirectory: false)
    }

    public func projects() -> [HarnessProjectRef] {
        HarnessProjectRegistry.merge(fromConfig() + fromCatalog())
    }

    func fromConfig() -> [HarnessProjectRef] {
        guard let data = HarnessProjectRegistry.readFile(at: location) else { return [] }
        return Self.projectPaths(inConfig: String(decoding: data, as: UTF8.self))
            .map { HarnessProjectRef(harness: .codex, path: $0) }
    }

    /// The `<path>`s of every `[projects."<path>"]` table.
    ///
    /// The same section scanner the MCP page uses, for the same reason: the
    /// question asked of the file is which tables are in it, and a full TOML
    /// parser would fail the whole file over a construct it disliked — which
    /// for a registry means offering a person none of their projects because
    /// one unrelated setting is new.
    static func projectPaths(inConfig text: String) -> [String] {
        HarnessMCPConfigStore.tomlTableNames(in: text, under: "projects")
            .filter { $0.hasPrefix("/") }
    }

    /// The distinct working directories in `local_thread_catalog`, with the
    /// most recent thread's time in each.
    func fromCatalog() -> [HarnessProjectRef] {
        Self.projectPaths(inCatalog: catalogURL).map {
            HarnessProjectRef(harness: .codex, path: $0.path, lastSeen: $0.lastSeen)
        }
    }

    /// Reads the catalog. Returns nothing when the file is missing or the
    /// table is not the one this expects — a Codex that renamed it is a Codex
    /// whose config file still answers the question.
    static func projectPaths(inCatalog url: URL) -> [(path: String, lastSeen: Date?)] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        return LiveSQLiteReader.read(at: url) { database in
            let statement = try LiveSQLiteReader.prepare(database, """
                SELECT cwd, MAX(source_updated_at) FROM local_thread_catalog
                WHERE cwd IS NOT NULL AND cwd <> ''
                GROUP BY cwd
                ORDER BY 2 DESC
                LIMIT \(LiveSQLiteReader.maxRows)
                """)
            defer { sqlite3_finalize(statement) }

            var out: [(path: String, lastSeen: Date?)] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                guard let path = LiveSQLiteReader.text(statement, 0), path.hasPrefix("/") else {
                    continue
                }
                let updated = sqlite3_column_type(statement, 1) == SQLITE_NULL
                    ? nil
                    : Date(timeIntervalSince1970: sqlite3_column_double(statement, 1))
                out.append((path, updated))
            }
            return out
        } ?? []
    }
}
