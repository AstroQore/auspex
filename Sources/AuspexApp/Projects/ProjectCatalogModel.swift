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
