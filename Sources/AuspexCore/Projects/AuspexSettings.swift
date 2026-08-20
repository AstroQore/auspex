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
    /// Whether the person has been shown the setup sheet.
    ///
    /// A flag rather than "have we installed anything": the sheet is an *offer*
    /// and skipping it is a complete answer. Deciding to show it again because
    /// nothing was installed would mean re-asking somebody who already said no,
    /// which is the behaviour that teaches people to dismiss dialogs without
    /// reading them.
    public var didShowSetup: Bool

    /// Which parts of the scene's map are drawn.
    ///
    /// A preference about a picture rather than about data, and the reason it
    /// lives here rather than in `@AppStorage` beside the view mode is that it
    /// changes what the *layout* produces: a person who switched the garden
    /// off and finds it back after a relaunch has been told their setting did
    /// not take, and a person who has to find it in `defaults` has been told
    /// nothing at all.
    public var sceneZones: SceneZoneOptions

    public init(
        ignoreRules: [IgnoreRule] = [],
        showsIgnored: Bool = false,
        didShowSetup: Bool = false,
        sceneZones: SceneZoneOptions = .all
    ) {
        self.ignoreRules = ignoreRules
        self.showsIgnored = showsIgnored
        self.didShowSetup = didShowSetup
        self.sceneZones = sceneZones
    }

    private enum CodingKeys: String, CodingKey {
        case ignoreRules, showsIgnored, didShowSetup, sceneZones
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        ignoreRules = (try container.decodeIfPresent(
            [Lenient<IgnoreRule>].self,
            forKey: .ignoreRules
        ) ?? []).compactMap(\.value)
        showsIgnored = try container.decodeIfPresent(Bool.self, forKey: .showsIgnored) ?? false
        didShowSetup = try container.decodeIfPresent(Bool.self, forKey: .didShowSetup) ?? false
        sceneZones = try container.decodeIfPresent(
            SceneZoneOptions.self, forKey: .sceneZones
        ) ?? .all
    }

    public var isEmpty: Bool {
        ignoreRules.isEmpty && !showsIgnored && !didShowSetup && sceneZones == .all
    }
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
