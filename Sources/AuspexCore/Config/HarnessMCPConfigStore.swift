import AgentSessionKit
import Foundation

/// Reads which MCP servers each harness has been told about.
///
/// ## Read-only, and narrowly so
///
/// These are other tools' configuration files. Auspex opens them, takes the
/// server *names*, and closes them. It never writes one, never creates a
/// missing one, and never touches anything in the file but the table it came
/// for — the house rule about harness directories (`AGENTS.md` § 6) is not
/// suspended because the file happens to be configuration rather than a
/// transcript. Registering Auspex's own MCP server is M3's job, and when it
/// arrives it will be an action a person takes, not something a status page
/// does while being looked at.
///
/// ## Why a scanner and not a TOML library
///
/// Two of the five files are TOML, and the question asked of them is "which
/// `[mcp_servers.<name>]` tables are in here". A full parser would pull in a
/// dependency, and would also *fail the whole file* on a construct it did not
/// like — which is the wrong answer for a status page, because a config Auspex
/// cannot fully parse is still a config whose server list is legible. The
/// scanner below reads section headers and nothing else, so a table it does not
/// understand costs it that table rather than the file.
public struct HarnessMCPConfigStore: Sendable {
    /// The home directory the paths are resolved under. Injected so a test can
    /// point at a temporary tree, and resolved through ``AuspexPaths`` in
    /// production for the reason the house rules give.
    public let homeDirectory: URL

    /// The server name Auspex will register as, in M3.
    public static let auspexServerName = "auspex"

    /// Largest config file that will be read.
    ///
    /// `~/.claude.json` is the outlier — it holds per-project state as well as
    /// MCP configuration and grows to hundreds of kilobytes — and 16 MB is
    /// well past any of them. A file larger than this is not a config, and a
    /// status page has no business pulling it into memory.
    public static let maximumFileSize = 16 * 1024 * 1024

    /// Creates a store.
    ///
    /// Only the home directory is injectable, because it is the only thing a
    /// test needs: point it at a temporary tree and write the fixtures in.
    /// A `FileManager` seam would buy nothing and would cost this type its
    /// `Sendable` conformance, which is what lets a page read these files off
    /// the main actor.
    public init(homeDirectory: URL = AuspexPaths.realHomeDirectory()) {
        self.homeDirectory = homeDirectory
    }

    // MARK: - Locations

    /// Where a harness keeps its MCP configuration, and in what format.
    ///
    /// `nil` for the harnesses whose configuration Auspex cannot honestly
    /// name — see ``externallyManagedNote(for:)``. A harness that shares
    /// another's *store* usually shares its configuration too, and is given
    /// the same location rather than a second guess; the exception is Claude
    /// Cowork, which shares Claude Code's transcript format but not its
    /// config file.
    public static func location(for harness: Harness, home: URL) -> MCPConfigLocation? {
        func path(_ components: String...) -> String {
            components.reduce(home) { $0.appendingPathComponent($1) }.path
        }
        switch harness {
        case .claudeCode:
            return MCPConfigLocation(path: path(".claude.json"), format: .json, isScoped: true)
        case .claudeCowork:
            // Cowork's servers come from Claude.app's own settings, inside the
            // app's container. `~/.claude.json` is the CLI's file, and a
            // Cowork row pointing at it would report the wrong servers with
            // full confidence. Nothing is read rather than something is
            // guessed.
            return nil
        case .codex, .chatgptWork:
            return MCPConfigLocation(path: path(".codex", "config.toml"), format: .toml)
        case .cursor:
            return MCPConfigLocation(path: path(".cursor", "mcp.json"), format: .json)
        case .grokBuild:
            return MCPConfigLocation(path: path(".grok", "config.toml"), format: .toml)
        case .antigravity, .geminiCLI:
            // AntiGravity's per-install directories symlink this one file, so
            // the shared location is the honest thing to name.
            return MCPConfigLocation(
                path: path(".gemini", "config", "mcp_config.json"),
                format: .json
            )
        case .grokBot:
            // The cloud bot client. Its tools run server-side, so there is no
            // local MCP file to name — and `~/.grok/config.toml` is Grok
            // Build's, a different product that only shares a company.
            return nil
        }
    }

    /// Why a harness has no config file here, in the words a page shows.
    ///
    /// `nil` whenever ``location(for:home:)`` names a file, because then the
    /// page can show the file instead. Two harnesses have no file to name:
    /// Claude Cowork, whose MCP servers are configured inside Claude.app, and
    /// Grok Bot, whose tools run on xAI's servers. In both cases naming where
    /// the configuration actually lives is the only thing Auspex can say
    /// without opening a container it has no business reading.
    public static func externallyManagedNote(for harness: Harness) -> String? {
        switch harness {
        case .claudeCowork: "managed by Claude.app"
        case .grokBot: "managed by xAI, server-side"
        default: nil
        }
    }

    // MARK: - Reading

    /// What `harness` has configured, or `nil` when it has no config file at
    /// all in its design.
    public func config(for harness: Harness) -> HarnessMCPConfig? {
        guard let location = Self.location(for: harness, home: homeDirectory) else { return nil }
        return read(location, for: harness)
    }

    /// The configs for several harnesses, in the order given.
    public func configs(for harnesses: [Harness]) -> [HarnessMCPConfig] {
        harnesses.compactMap(config(for:))
    }

    private func read(_ location: MCPConfigLocation, for harness: Harness) -> HarnessMCPConfig {
        guard let data = readFile(at: location.path) else {
            return HarnessMCPConfig(
                harness: harness,
                location: location,
                exists: FileManager.default.fileExists(atPath: location.path),
                serverNames: [],
                scopedServerNames: [],
                didParse: false
            )
        }
        // An empty file is a config with nothing in it, not a broken one:
        // AntiGravity ships a zero-byte `mcp_config.json` on a fresh install.
        guard !data.isEmpty else {
            return HarnessMCPConfig(
                harness: harness,
                location: location,
                exists: true,
                serverNames: [],
                scopedServerNames: [],
                didParse: true
            )
        }

        switch location.format {
        case .json:
            guard let names = Self.jsonServerNames(in: data, includesScopes: location.isScoped)
            else {
                return HarnessMCPConfig(
                    harness: harness,
                    location: location,
                    exists: true,
                    serverNames: [],
                    scopedServerNames: [],
                    didParse: false
                )
            }
            return HarnessMCPConfig(
                harness: harness,
                location: location,
                exists: true,
                serverNames: names.global,
                scopedServerNames: names.scoped,
                didParse: true
            )
        case .toml:
            let names = Self.tomlServerNames(in: String(decoding: data, as: UTF8.self))
            return HarnessMCPConfig(
                harness: harness,
                location: location,
                exists: true,
                serverNames: names,
                scopedServerNames: [],
                didParse: true
            )
        }
    }

    /// Reads a config file, refusing anything that is not a plain file of a
    /// sane size.
    ///
    /// Symlinks are resolved first, because `attributesOfItem(atPath:)` reports
    /// on the link rather than its target — and at least one harness ships its
    /// config as a link. AntiGravity's per-install `mcp_config.json` files all
    /// point at the shared one.
    private func readFile(at path: String) -> Data? {
        let fileManager = FileManager.default
        let path = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        guard let attributes = try? fileManager.attributesOfItem(atPath: path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? NSNumber,
              size.intValue <= Self.maximumFileSize
        else { return nil }
        return fileManager.contents(atPath: path)
    }

    // MARK: - JSON

    /// The `mcpServers` keys in a JSON config, and the ones nested under
    /// per-project scopes.
    ///
    /// Both are sorted and deduplicated. The split is kept because the two
    /// answer different questions: a server configured globally is available to
    /// every session that harness runs, while one configured under a project
    /// path is available in that directory alone — and a status page that
    /// merged them would tell a person a server is on when it is not.
    ///
    /// - Returns: `nil` when the file is not JSON at all, which is a different
    ///   answer from "JSON with no servers in it".
    static func jsonServerNames(
        in data: Data,
        includesScopes: Bool
    ) -> (global: [String], scoped: [String])? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        let global = serverKeys(in: root["mcpServers"])

        guard includesScopes, let projects = root["projects"] as? [String: Any] else {
            return (global, [])
        }
        var scoped: Set<String> = []
        for (_, value) in projects {
            guard let project = value as? [String: Any] else { continue }
            scoped.formUnion(serverKeys(in: project["mcpServers"]))
        }
        return (global, scoped.sorted())
    }

    /// The keys of an `mcpServers` object, sorted. Anything that is not an
    /// object contributes nothing rather than throwing: a harness that wrote
    /// `"mcpServers": null` has no servers, and that is a complete answer.
    private static func serverKeys(in value: Any?) -> [String] {
        guard let object = value as? [String: Any] else { return [] }
        return object.keys.sorted()
    }

    // MARK: - TOML

    /// The `<name>`s of every `[mcp_servers.<name>]` table in a TOML config.
    ///
    /// Deliberately a scanner over section headers:
    ///
    /// - `[mcp_servers.foo.env]` is a sub-table of `foo`, not a server called
    ///   `foo.env`, so only the component after the table name is taken.
    /// - A quoted name (`[mcp_servers."my-server"]`) is unquoted, because that
    ///   is how TOML spells a name with a dot or a dash in it.
    /// - `[mcp_servers]` followed by `name = { … }` is the inline spelling of
    ///   the same thing, and is read too.
    /// - Everything else — values, comments, arrays of tables, other sections —
    ///   is skipped without an opinion.
    ///
    /// The result is sorted and deduplicated.
    static func tomlServerNames(in text: String, table: String = "mcp_servers") -> [String] {
        var names: Set<String> = []
        var isInsideTable = false

        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }

            if line.hasPrefix("[") {
                // `[[x]]` is an array of tables; `mcp_servers` is never one,
                // but skipping the extra bracket keeps the parse honest.
                let body = line.hasPrefix("[[") ? line.dropFirst(2) : line.dropFirst()
                guard let parts = sectionPath(in: body) else {
                    isInsideTable = false
                    continue
                }
                isInsideTable = parts == [table]
                if parts.count >= 2, parts[0] == table, !parts[1].isEmpty {
                    names.insert(parts[1])
                }
                continue
            }

            guard isInsideTable, let key = inlineKey(in: line) else { continue }
            names.insert(key)
        }
        return names.sorted()
    }

    /// The dotted key of a section header, given everything after its opening
    /// bracket. `nil` when the header does not close or holds no key.
    private static func sectionPath(in body: some StringProtocol) -> [String]? {
        var parts: [String] = []
        var current = ""
        var quote: Character?
        var didClose = false

        for character in body {
            if let open = quote {
                if character == open {
                    quote = nil
                } else {
                    current.append(character)
                }
                continue
            }
            switch character {
            case "\"", "'":
                quote = character
            case ".":
                parts.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            case "]":
                didClose = true
            default:
                current.append(character)
            }
            if didClose { break }
        }

        guard didClose else { return nil }
        parts.append(current.trimmingCharacters(in: .whitespaces))
        let cleaned = parts.filter { !$0.isEmpty }
        return cleaned.isEmpty ? nil : cleaned
    }

    /// The key of an inline `name = { … }` assignment, when the line is one.
    ///
    /// Only the inline-table form counts. A scalar assignment inside
    /// `[mcp_servers]` is a setting for the table itself, not a server.
    private static func inlineKey(in line: String) -> String? {
        guard let equals = line.firstIndex(of: "=") else { return nil }
        let value = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
        guard value.hasPrefix("{") else { return nil }
        let key = unquoted(line[..<equals].trimmingCharacters(in: .whitespaces))
        return key.isEmpty ? nil : key
    }

    /// Strips one matching pair of quotes, when there is one.
    private static func unquoted(_ text: String) -> String {
        for quote: Character in ["\"", "'"] where text.count > 1
            && text.first == quote && text.last == quote {
            return String(text.dropFirst().dropLast())
        }
        return text
    }
}

/// Where one harness keeps its MCP configuration.
public struct MCPConfigLocation: Hashable, Sendable {
    /// The absolute path of the file.
    public let path: String
    /// How to read it.
    public let format: Format
    /// Whether the file can also configure servers per project directory, as
    /// Claude Code's does.
    public let isScoped: Bool

    /// The two shapes these files come in.
    public enum Format: String, Hashable, Sendable {
        case json
        case toml
    }

    public init(path: String, format: Format, isScoped: Bool = false) {
        self.path = path
        self.format = format
        self.isScoped = isScoped
    }
}

/// What one harness has been told about MCP servers.
public struct HarnessMCPConfig: Hashable, Sendable, Identifiable {
    /// The harness this is about.
    public let harness: Harness
    /// Where it was read from.
    public let location: MCPConfigLocation
    /// Whether the file is there at all. A harness with no config file has not
    /// been set up for MCP, which is a different thing from one configured with
    /// no servers.
    public let exists: Bool
    /// Servers configured for every session this harness runs, sorted.
    public let serverNames: [String]
    /// Servers configured for one project directory only, sorted.
    public let scopedServerNames: [String]
    /// Whether the file was understood. `false` means it is there and Auspex
    /// could not read it — which the page says plainly rather than showing an
    /// empty list that looks like "no servers".
    public let didParse: Bool

    public var id: Harness { harness }

    public init(
        harness: Harness,
        location: MCPConfigLocation,
        exists: Bool,
        serverNames: [String],
        scopedServerNames: [String],
        didParse: Bool
    ) {
        self.harness = harness
        self.location = location
        self.exists = exists
        self.serverNames = serverNames
        self.scopedServerNames = scopedServerNames
        self.didParse = didParse
    }

    /// How many servers are configured, at any scope.
    public var serverCount: Int { serverNames.count + scopedServerNames.count }

    /// Whether Auspex's own MCP server is registered here. It will not be until
    /// M3 ships one to register.
    public var registersAuspex: Bool {
        serverNames.contains(HarnessMCPConfigStore.auspexServerName)
            || scopedServerNames.contains(HarnessMCPConfigStore.auspexServerName)
    }
}
