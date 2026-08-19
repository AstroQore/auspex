import Foundation

/// `~/.auspex/settings.json` — the preferences that are not about characters.
///
/// One flat object, read and written whole. It holds the ignore rules today;
/// whatever else earns a switch later goes beside them rather than into a
/// second file, because a preference nobody can find the file for is a
/// preference nobody can undo by hand.
public struct AuspexSettings: Codable, Sendable, Equatable {
    /// What not to show. Order is display order.
    public var ignoreRules: [IgnoreRule]
    /// Whether the board is currently revealing the ignored sessions.
    ///
    /// Persisted because it is a mode rather than a gesture: somebody who
    /// turned it on to check a rule wants it on after a relaunch too, and the
    /// header says how many rows it is adding.
    public var showsIgnored: Bool

    public init(ignoreRules: [IgnoreRule] = [], showsIgnored: Bool = false) {
        self.ignoreRules = ignoreRules
        self.showsIgnored = showsIgnored
    }

    private enum CodingKeys: String, CodingKey {
        case ignoreRules, showsIgnored
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        ignoreRules = (try container.decodeIfPresent(
            [Lenient<IgnoreRule>].self,
            forKey: .ignoreRules
        ) ?? []).compactMap(\.value)
        showsIgnored = try container.decodeIfPresent(Bool.self, forKey: .showsIgnored) ?? false
    }

    public var isEmpty: Bool { ignoreRules.isEmpty && !showsIgnored }
}

/// Reads and writes ``AuspexSettings``, with the same bargain the character
/// selection makes: reading cannot fail, writing can.
public struct AuspexSettingsStore: Sendable {
    private let paths: AuspexPaths

    public init(paths: AuspexPaths = .default) {
        self.paths = paths
    }

    public var url: URL { paths.settingsURL }

    public func load() -> AuspexSettings {
        guard let data = try? Data(contentsOf: url) else { return AuspexSettings() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(AuspexSettings.self, from: data)) ?? AuspexSettings()
    }

    public func save(_ settings: AuspexSettings) throws {
        try paths.ensureBaseDirectory()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(settings).write(to: url, options: [.atomic])
    }
}
