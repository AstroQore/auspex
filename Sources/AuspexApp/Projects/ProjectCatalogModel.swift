import AgentSessionKit
import AgentSessionLive
import AuspexCore
import Foundation
import Observation

/// The user layer, and the one place it is edited.
///
/// Two files under `~/.auspex/` — `projects.json` and `settings.json` — plus
/// the harness registries a person can import from. Every mutation goes
/// through a method here, and every method ends the same way: write the file,
/// rebuild the index, hand it to the board. Nothing else in the app writes
/// either file, and nothing else builds a ``ProjectClaims``.
///
/// ## Why it saves on every edit
///
/// These are small files and rare edits — a project is made once and renamed
/// almost never — so there is no debounce and no dirty flag. A person who
/// renames a project and quits before a timer fires should still find it
/// renamed, and an error that has to be reported is easier to report next to
/// the click that caused it.
///
/// ## In the demo, nothing is stored
///
/// The demo replays a fabricated board and must leave no trace on disk, so it
/// gets a catalog with no stores behind it: the projects and rules it is given
/// live for as long as the process does. That is also what lets
/// `--render-board` be handed a focus and an ignore rule on the command line
/// without writing anything into somebody's home.
@MainActor
@Observable
final class ProjectCatalogModel {
    /// The projects a person has made, oldest first.
    private(set) var projects: [AuspexProject] = []

    /// The index the board places sessions with.
    private(set) var claims: ProjectClaims = .empty

    /// Everything in `settings.json` — the ignore rules and whether they are
    /// currently being revealed.
    private(set) var settings = AuspexSettings()

    /// The active rules, as the board asks about them.
    private(set) var rules: IgnoreRules = .none

    /// What went wrong the last time a file was written, for the page to show.
    /// A failed save is not fatal: the change is in effect either way, and a
    /// person who was not told would find it gone after a relaunch.
    private(set) var saveErrorDescription: String?

    /// Registry entries by harness, once imported. Empty until the import
    /// sheet asks for them, because reading them means opening two files and a
    /// SQLite database.
    private(set) var harnessProjects: [HarnessProjectRef] = []

    /// `true` while a registry read is in flight.
    private(set) var isLoadingHarnessProjects = false

    /// Where each registry was read from, for the sheet's caption.
    private(set) var registryLocations: [(harness: Harness, location: String)] = []

    /// Called after every change, so the board can re-place and re-filter the
    /// frame it is already holding.
    var onChange: ((ProjectClaims, IgnoreRules, Bool) -> Void)?

    private let projectStore: AuspexProjectStore?
    private let settingsStore: AuspexSettingsStore?
    private let home: URL

    /// - Parameters:
    ///   - paths: where the two files live.
    ///   - persists: `false` in the demo, where nothing may be read from or
    ///     written to `~/.auspex/`.
    init(paths: AuspexPaths = .default, persists: Bool = true) {
        home = paths.homeDirectory
        projectStore = persists ? AuspexProjectStore(paths: paths) : nil
        settingsStore = persists ? AuspexSettingsStore(paths: paths) : nil
    }

    /// Reads both files. Called once, as the window comes up.
    func load() {
        projects = projectStore?.load() ?? []
        settings = settingsStore?.load() ?? AuspexSettings()
        rebuild()
    }

    // MARK: - Projects

    /// Makes a project, and returns it so the caller can go on editing it.
    @discardableResult
    func addProject(
        name: String,
        roots: [String] = [],
        colorHex: String? = nil,
        members: [HarnessProjectRef] = [],
        createdBy: AuspexProject.Origin = .user
    ) -> AuspexProject {
        var project = AuspexProject(
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            colorHex: colorHex,
            roots: roots,
            createdBy: createdBy
        )
        for member in members { project.add(member: member) }
        projects.append(project)
        persist()
        return project
    }

    func rename(_ project: AuspexProject, to name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        update(project) { $0.name = name }
    }

    func recolour(_ project: AuspexProject, to hex: String?) {
        update(project) { $0.colorHex = hex }
    }

    func addRoot(_ path: String, to project: AuspexProject) {
        update(project) { $0.addRoot(path) }
    }

    func removeRoot(_ path: String, from project: AuspexProject) {
        update(project) { $0.removeRoot(path) }
    }

    func add(members: [HarnessProjectRef], to project: AuspexProject) {
        update(project) { project in
            for member in members { project.add(member: member) }
        }
    }

    func togglePin(_ project: AuspexProject) {
        update(project) { $0.isPinned.toggle() }
    }

    /// Deletes a project. Its sessions go back to where the resolver put them.
    func delete(_ project: AuspexProject) {
        projects.removeAll { $0.id == project.id }
        persist()
    }

    private func update(_ project: AuspexProject, _ edit: (inout AuspexProject) -> Void) {
        guard let index = projects.firstIndex(where: { $0.id == project.id }) else { return }
        edit(&projects[index])
        persist()
    }

    // MARK: - Ignore rules

    /// Adds a rule, unless one exactly like it is already there — a person who
    /// hits "Ignore this folder" twice meant it once.
    func add(rule: IgnoreRule) {
        guard !settings.ignoreRules.contains(where: { $0.kind == rule.kind }) else { return }
        settings.ignoreRules.append(rule)
        persist()
    }

    func toggle(rule: IgnoreRule) {
        guard let index = settings.ignoreRules.firstIndex(where: { $0.id == rule.id }) else {
            return
        }
        settings.ignoreRules[index].isEnabled.toggle()
        persist()
    }

    func delete(rule: IgnoreRule) {
        settings.ignoreRules.removeAll { $0.id == rule.id }
        persist()
    }

    /// Whether the board is revealing what the rules hide.
    func setShowsIgnored(_ shows: Bool) {
        guard settings.showsIgnored != shows else { return }
        settings.showsIgnored = shows
        persist()
    }

    // MARK: - The scene's map

    /// Which of the scene's annexes are drawn.
    var sceneZones: SceneZoneOptions { settings.sceneZones }

    /// Switches an annex on or off, and remembers it.
    ///
    /// Off is not "hide those sessions": it is "they stay at their desks",
    /// which is the office exactly as it was before the annexes existed. So
    /// there is nothing to warn about and nothing to undo beyond ticking the
    /// box again.
    func setSceneZones(_ zones: SceneZoneOptions) {
        guard settings.sceneZones != zones else { return }
        settings.sceneZones = zones
        persist()
    }

    // MARK: - Process lifecycle

    /// The person's durable request. macOS's ServiceManagement status is the
    /// operational truth shown in Settings; this value exists so replacing an
    /// app bundle does not silently forget a request the person already made.
    var launchAtLogin: Bool { settings.launchAtLogin }

    /// Records the choice only after the system registration action succeeds.
    /// The caller owns that ordering; keeping the write here preserves the
    /// one-writer rule for `settings.json`.
    func setLaunchAtLogin(_ enabled: Bool) {
        guard settings.launchAtLogin != enabled else { return }
        settings.launchAtLogin = enabled
        persist()
    }

    // MARK: - The crew's liveliness

    /// How often the crew's avatars react. The default until somebody says
    /// otherwise.
    var crewLiveliness: CrewLiveliness { settings.crewLiveliness ?? .default }

    /// Sets it, and remembers it.
    ///
    /// Nothing on screen has to be rebuilt: the roster hands the new value to
    /// each driver on the next frame, and a reaction already in flight finishes
    /// — the setting is about the *next* one.
    func setCrewLiveliness(_ value: CrewLiveliness) {
        guard settings.crewLiveliness != value else { return }
        settings.crewLiveliness = value
        persist()
    }

    // MARK: - How far back

    /// How far back the board and the map reach.
    var sessionWindow: SessionWindow { settings.sessionWindow }

    /// Widens or narrows the window, and remembers it.
    ///
    /// Nothing is deleted and nothing is hidden that a person cannot get back
    /// in one click — the store keeps its whole week either way, and the
    /// header says how many sessions the current setting is leaving out.
    func setSessionWindow(_ window: SessionWindow) {
        guard settings.sessionWindow != window else { return }
        settings.sessionWindow = window
        persist()
    }

    // MARK: - Notifications

    /// Whether a reported finish raises a macOS notification.
    var notifiesOnDone: Bool { settings.notifiesOnDone }

    /// Switches the receipts' banners on or off, and remembers it.
    ///
    /// Only the receipts. A session blocked on a person always notifies, and
    /// there is deliberately no switch for that: it is the one thing on this
    /// board that will not resolve itself.
    func setNotifiesOnDone(_ notifies: Bool) {
        guard settings.notifiesOnDone != notifies else { return }
        settings.notifiesOnDone = notifies
        persist()
    }

    // MARK: - The appearance

    /// Which appearance the window is drawn in.
    var appearance: AppearanceMode { settings.appearance }

    /// Sets it, and remembers it.
    ///
    /// Nothing is rebuilt: every colour in the app is a dynamic `NSColor`, so
    /// the change is a repaint that SwiftUI, Core Animation and SpriteKit each
    /// do for themselves the moment the window's appearance changes. The two
    /// places that cannot — a baked grid tile and a `CALayer`'s background —
    /// watch their view's `effectiveAppearance` and rebuild there.
    func setAppearance(_ mode: AppearanceMode) {
        guard settings.appearance != mode else { return }
        settings.appearance = mode
        persist()
    }

    /// Whether the sidebar sits on the system's sidebar material.
    var translucentSidebar: Bool { settings.translucentSidebar }

    /// Whether every task card lists the sessions inside it.
    var showsSubagents: Bool { settings.showsSubagents }

    /// Opens or folds every card's member list, and remembers it.
    ///
    /// One switch for the whole wall, and a chevron per card on top of it: the
    /// global answer is a *density* preference and the per-card one is a
    /// question about one piece of work, and conflating them would mean
    /// opening one card cost you the wall.
    func setShowsSubagents(_ on: Bool) {
        guard settings.showsSubagents != on else { return }
        settings.showsSubagents = on
        persist()
    }

    func setTranslucentSidebar(_ on: Bool) {
        guard settings.translucentSidebar != on else { return }
        settings.translucentSidebar = on
        persist()
    }

    // MARK: - Updates

    /// Which release stream in-app updates come from.
    var updateChannel: UpdateChannel { settings.updateChannel }

    /// Sets it, and remembers it.
    ///
    /// Nothing is downloaded here. `AppUpdateController` watches this and asks
    /// Sparkle to restart its check cycle, so switching to the preview stream
    /// finds a waiting preview build within moments rather than at tomorrow's
    /// scheduled check — a channel picker that appears to do nothing is a
    /// channel picker people press twice.
    func setUpdateChannel(_ channel: UpdateChannel) {
        guard settings.updateChannel != channel else { return }
        settings.updateChannel = channel
        persist()
    }

    // MARK: - Importing

    /// Reads every harness registry, off the main actor.
    ///
    /// Two files and a SQLite database, none of them large, but all of them on
    /// somebody's disk — and the import sheet opens while the board is
    /// animating.
    func loadHarnessProjects() async {
        guard !isLoadingHarnessProjects else { return }
        isLoadingHarnessProjects = true
        let home = home
        let refs = await Task.detached(priority: .userInitiated) { () -> [HarnessProjectRef] in
            HarnessProjectRegistry.sources(home: home).flatMap { $0.projects() }
        }.value
        let locations = HarnessProjectRegistry.sources(home: home)
            .map { (harness: $0.harness, location: $0.location) }
        harnessProjects = refs
        registryLocations = locations
        isLoadingHarnessProjects = false
    }

    /// The registry entries for one harness, most recently active first.
    func harnessProjects(for harness: Harness) -> [HarnessProjectRef] {
        harnessProjects.filter { $0.harness == harness }
    }

    /// Whether a registry path is already claimed by some project, so the
    /// import sheet can say so instead of offering it twice.
    func claimingProject(for path: String) -> AuspexProject? {
        claims.project(forPath: path)
    }

    // MARK: - Publishing

    private func persist() {
        do {
            try projectStore?.save(projects)
            try settingsStore?.save(settings)
            saveErrorDescription = nil
        } catch {
            saveErrorDescription = String(describing: error)
        }
        rebuild()
    }

    private func rebuild() {
        claims = ProjectClaims(projects: projects)
        rules = IgnoreRules(settings.ignoreRules)
        onChange?(claims, rules, settings.showsIgnored)
    }
}
