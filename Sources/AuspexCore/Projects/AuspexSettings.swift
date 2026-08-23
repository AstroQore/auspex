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

    /// Which appearance the window is drawn in.
    ///
    /// Here rather than in `@AppStorage` for the same reason the window is:
    /// it decides what every surface in the app *is*, and the offscreen
    /// renderers have to be able to read it without a window. See
    /// ``AppearanceMode``.
    public var appearance: AppearanceMode

    /// Whether every task card lists the sessions inside it.
    ///
    /// Off. A task card folds its subagents into a strip of dots, which is
    /// what makes a wall of twelve pieces of work readable rather than a wall
    /// of forty processes — and the great majority of the time the *shape* of
    /// a delegation is all anybody needs from it. On is for the person who
    /// reads the board at session granularity and wants the old density back;
    /// a single card still opens on its own chevron either way.
    ///
    /// Here rather than in `@AppStorage` because it changes what the frame
    /// *derives* — the sidebar's tree lists sessions only under an opened task
    /// — and the offscreen renderers have to be able to read it without a
    /// window.
    public var showsSubagents: Bool

    /// Whether the sidebar sits on the system's sidebar material rather than
    /// on the flat canvas token.
    ///
    /// On by default, because it is the most native thing a Mac sidebar can
    /// be: the column picks up what is behind the window and moves with it,
    /// which is what tells a person at a glance which window is in front.
    /// Off is for the second display running a wall of these, where a sidebar
    /// showing somebody's desktop through it is noise.
    public var translucentSidebar: Bool

    /// Which release stream in-app updates come from.
    ///
    /// Here rather than in `@AppStorage` because it decides which binary is
    /// allowed to replace this one. See ``UpdateChannel``.
    public var updateChannel: UpdateChannel

    /// Whether the person asked macOS to launch Auspex when they log in.
    ///
    /// The system registration is still the operational truth; this is the
    /// durable user intent that lets a replaced app bundle repair a lost
    /// registration on its next launch. It changes only after a person clicks
    /// the setting and ServiceManagement accepts the corresponding action.
    public var launchAtLogin: Bool

    public init(
        ignoreRules: [IgnoreRule] = [],
        showsIgnored: Bool = false,
        didShowSetup: Bool = false,
        sceneZones: SceneZoneOptions = .all,
        crewLiveliness: CrewLiveliness? = nil,
        sessionWindow: SessionWindow = .standard,
        notifiesOnDone: Bool = true,
        appearance: AppearanceMode = .standard,
        showsSubagents: Bool = false,
        translucentSidebar: Bool = true,
        updateChannel: UpdateChannel = .standard,
        launchAtLogin: Bool = false
    ) {
        self.showsSubagents = showsSubagents
        self.ignoreRules = ignoreRules
        self.showsIgnored = showsIgnored
        self.didShowSetup = didShowSetup
        self.sceneZones = sceneZones
        self.crewLiveliness = crewLiveliness
        self.sessionWindow = sessionWindow
        self.notifiesOnDone = notifiesOnDone
        self.appearance = appearance
        self.translucentSidebar = translucentSidebar
        self.updateChannel = updateChannel
        self.launchAtLogin = launchAtLogin
    }

    private enum CodingKeys: String, CodingKey {
        case ignoreRules, showsIgnored, didShowSetup, sceneZones, crewLiveliness
        case sessionWindow, notifiesOnDone, appearance, translucentSidebar
        case updateChannel, showsSubagents, launchAtLogin
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
        // An absent key is "follow the system" rather than "dark", so a
        // settings file written while the window was forced dark opens on
        // whatever the Mac is set to — which is the behaviour the setting
        // exists to give people, not one they should have to go and ask for.
        //
        // `try?` rather than `try`, like `crewLiveliness`: this is a file
        // people are invited to edit by hand, and a typo in one word must cost
        // that one word rather than the whole file — a thrown error here would
        // take the ignore rules and the projects binding down with it.
        appearance = (try? container.decode(AppearanceMode.self, forKey: .appearance))
            ?? .standard
        translucentSidebar = (try? container.decode(Bool.self, forKey: .translucentSidebar))
            ?? true
        // Absent means folded, which is what the wall is for.
        showsSubagents = (try? container.decode(Bool.self, forKey: .showsSubagents)) ?? false
        // Absent means stable, which is also what an unrecognised value means:
        // the safe end of this setting is the one that installs less, so a
        // hand-edited typo must not silently opt somebody into preview builds.
        updateChannel = (try? container.decode(UpdateChannel.self, forKey: .updateChannel))
            ?? .standard
        launchAtLogin = (try? container.decode(Bool.self, forKey: .launchAtLogin)) ?? false
    }

    public var isEmpty: Bool {
        ignoreRules.isEmpty && !showsIgnored && !didShowSetup && sceneZones == .all
            && crewLiveliness == nil && sessionWindow == .standard && notifiesOnDone
            && appearance == .standard && translucentSidebar && !showsSubagents
            && updateChannel == .standard && !launchAtLogin
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
