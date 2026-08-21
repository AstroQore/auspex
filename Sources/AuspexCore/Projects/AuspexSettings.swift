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

    /// How often the crew's avatars react.
    ///
    /// Optional, and absent means "whatever the default is today". A person who
    /// never opened the pane has no opinion recorded, so a later change to what
    /// `normal` means reaches them — where a value written on first launch
    /// would have frozen them on the old one.
    public var crewLiveliness: CrewLiveliness?

    /// How far back the board and the map reach.
    ///
    /// Here rather than in `@AppStorage` for the same reason the annexes are:
    /// it changes what every surface is *of*, the header says how much it is
    /// leaving out, and a person who set it to a week and found it back at
    /// twelve hours has been told their setting did not take.
    public var sessionWindow: SessionWindow

    /// Whether an agent reporting that it finished raises a macOS
    /// notification.
    ///
    /// On, and it is the only one of the two attention buckets that has a
    /// switch. A session blocked on a person always notifies: it will make no
    /// further progress until somebody looks, and the whole reason this app
    /// serves an MCP surface is to close the gap between an agent stopping to
    /// ask and a person finding out. A receipt is different — it is good news
    /// that keeps — and somebody running a dozen agents may well want to read
    /// those on the board in their own time rather than one banner at a time.
    public var notifiesOnDone: Bool

    public init(
        ignoreRules: [IgnoreRule] = [],
        showsIgnored: Bool = false,
        didShowSetup: Bool = false,
        sceneZones: SceneZoneOptions = .all,
        crewLiveliness: CrewLiveliness? = nil,
        sessionWindow: SessionWindow = .standard,
        notifiesOnDone: Bool = true
    ) {
        self.ignoreRules = ignoreRules
        self.showsIgnored = showsIgnored
        self.didShowSetup = didShowSetup
        self.sceneZones = sceneZones
        self.crewLiveliness = crewLiveliness
        self.sessionWindow = sessionWindow
        self.notifiesOnDone = notifiesOnDone
    }

    private enum CodingKeys: String, CodingKey {
        case ignoreRules, showsIgnored, didShowSetup, sceneZones, crewLiveliness
        case sessionWindow, notifiesOnDone
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
        crewLiveliness = try? container.decodeIfPresent(
            CrewLiveliness.self, forKey: .crewLiveliness
        )
        // An absent key is the default rather than "all", so a settings file
        // written before the window existed opens on a working day rather than
        // on the week of history that made the window necessary.
        sessionWindow = try container.decodeIfPresent(
            SessionWindow.self, forKey: .sessionWindow
        ) ?? .standard
        // Absent means on, so a settings file written before the switch
        // existed keeps the behaviour it already had.
        notifiesOnDone = try container.decodeIfPresent(
            Bool.self, forKey: .notifiesOnDone
        ) ?? true
    }

    public var isEmpty: Bool {
        ignoreRules.isEmpty && !showsIgnored && !didShowSetup && sceneZones == .all
            && crewLiveliness == nil && sessionWindow == .standard && notifiesOnDone
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
