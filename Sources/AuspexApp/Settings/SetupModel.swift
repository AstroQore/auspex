import AgentSessionKit
import AuspexCore
import Foundation
import Observation

/// What the setup sheet knows: which harnesses are here, what Auspex would
/// write for each, and what has been ticked.
///
/// ## Nothing happens until a button is pressed
///
/// The model reads config files to fill the rows in — that is the same
/// read-only look the Harnesses page has always taken — and writes exactly
/// nothing until ``install()`` is called with a set of selections a person
/// made. Opening the sheet, scrolling it, and closing it leave the machine as
/// it was.
///
/// Selections start *off* for the same reason: a checkbox that is pre-ticked is
/// a decision made on somebody's behalf and then blamed on them.
@MainActor
@Observable
final class SetupModel {
    /// One line of the sheet.
    struct Row: Identifiable, Equatable {
        let harness: Harness
        let piece: HarnessInstaller.Piece
        let path: String?
        let displayPath: String?
        let state: HarnessInstaller.State
        /// The specifics, when a row has any worth naming before it is ticked —
        /// which events a hook registration covers, in the harness's own
        /// vocabulary. A person agreeing to "install harness hooks" is entitled
        /// to know it means eight of them.
        var detail: String?
        /// What the harness will then do about it, when that is not obvious —
        /// Codex will not run a hook it has not been shown, and a person who
        /// ticks this box deserves to hear that from Auspex rather than from
        /// Codex's next launch.
        var note: String?
        /// What happened the last time this row was acted on.
        var outcome: String?
        var didFail = false

        var id: String { "\(harness.rawValue).\(piece.rawValue)" }

        var isActionable: Bool { state.canInstall }
        var isInstalled: Bool { state.isInstalled }
    }

    /// One harness, with its rows.
    struct HarnessGroup: Identifiable, Equatable {
        let harness: Harness
        /// Whether this harness's store was actually found on the machine.
        /// Rows for a harness nobody has installed are still shown — a person
        /// setting up a new laptop is a real case — but sorted below.
        let isDetected: Bool
        var rows: [Row]

        var id: Harness { harness }
    }

    private(set) var groups: [HarnessGroup] = []

    /// The rows a person has ticked, by ``Row/id``.
    var selected: Set<String> = []

    /// Set while an install is running, so the buttons cannot be pressed twice.
    private(set) var isWorking = false

    /// A sentence about the last run, for the footer.
    private(set) var summary: String?

    private var installer: HarnessInstaller?
    private var settingsStore: AuspexSettingsStore?

    /// Whether the sheet should be shown on this launch.
    private(set) var shouldPresent = false

    /// Loads the rows and decides whether to present.
    ///
    /// - Parameter isEnabled: `false` in demo mode, where the sheet must never
    ///   appear: it writes to real harness configs, and a demo writes nothing.
    func load(
        paths: AuspexPaths,
        command: String,
        detected: Set<Harness>,
        isEnabled: Bool
    ) {
        let installer = HarnessInstaller(
            homeDirectory: paths.homeDirectory,
            paths: paths,
            command: command
        )
        self.installer = installer
        let store = AuspexSettingsStore(paths: paths)
        self.settingsStore = store
        refresh(detected: detected)
        shouldPresent = isEnabled && !store.load().didShowSetup
    }

    /// Re-reads every row's state. Cheap — a handful of small files — and done
    /// after every install so the sheet shows what it just did.
    func refresh(detected: Set<Harness>) {
        guard let installer else { return }
        groups = Harness.allCases
            .map { harness in
                HarnessGroup(
                    harness: harness,
                    isDetected: detected.contains(harness),
                    rows: HarnessInstaller.Piece.allCases.map { piece in
                        let offer = installer.offer(harness, piece)
                        let plan = piece == .hooks ? installer.hookPlan(for: harness) : nil
                        return Row(
                            harness: harness,
                            piece: piece,
                            path: offer.path,
                            displayPath: offer.displayPath,
                            state: offer.state,
                            detail: plan?.summary,
                            note: plan?.note
                        )
                    }
                )
            }
            // Detected harnesses first, then alphabetically, so the rows a
            // person can act on are the ones they see without scrolling.
            .sorted {
                if $0.isDetected != $1.isDetected { return $0.isDetected }
                return $0.harness.displayName < $1.harness.displayName
            }
            // A harness with nothing to offer at all — no config file, no
            // instruction file — is left out. A row that can only say "not
            // applicable" twice is a row that teaches nothing.
            .filter { group in group.rows.contains { $0.path != nil } }
    }

    /// Ticks everything that can be installed and is not already.
    func selectEverythingActionable() {
        selected = Set(
            groups.flatMap(\.rows).filter(\.isActionable).map(\.id)
        )
    }

    func clearSelection() {
        selected.removeAll()
    }

    var actionableCount: Int {
        groups.flatMap(\.rows).count(where: \.isActionable)
    }

    // MARK: - Writing

    /// Installs exactly the ticked rows.
    ///
    /// Off the main actor: each row is a read, a backup, an atomic write and a
    /// re-parse, and a person clicking a button should not watch the window
    /// stop redrawing while eight of those happen.
    func install(detected: Set<Harness>) async {
        guard let installer, !isWorking else { return }
        let targets = groups.flatMap(\.rows).filter { selected.contains($0.id) }
        guard !targets.isEmpty else { return }
        isWorking = true
        defer { isWorking = false }

        let reports = await Task.detached(priority: .userInitiated) {
            targets.map { installer.install($0.harness, $0.piece) }
        }.value

        apply(reports)
        selected.removeAll()
        refresh(detected: detected)
        markShown()
    }

    /// Removes one row's write.
    func uninstall(_ row: Row, detected: Set<Harness>) async {
        guard let installer, !isWorking else { return }
        isWorking = true
        defer { isWorking = false }
        let report = await Task.detached(priority: .userInitiated) {
            installer.uninstall(row.harness, row.piece)
        }.value
        apply([report])
        refresh(detected: detected)
    }

    /// Installs one row on its own — the Harnesses page's per-row button.
    func install(_ row: Row, detected: Set<Harness>) async {
        guard let installer, !isWorking else { return }
        isWorking = true
        defer { isWorking = false }
        let report = await Task.detached(priority: .userInitiated) {
            installer.install(row.harness, row.piece)
        }.value
        apply([report])
        refresh(detected: detected)
        markShown()
    }

    private func apply(_ reports: [HarnessInstaller.Report]) {
        let failures = reports.filter { !$0.succeeded }
        let changed = reports.count { $0.didChange }
        if failures.isEmpty {
            summary = changed == 0
                ? "Nothing to change — everything ticked was already in place."
                : "Wrote \(changed) \(changed == 1 ? "change" : "changes"). "
                    + "Backups are in ~/.auspex/backups/."
        } else {
            summary = failures
                .map { "\($0.harness.displayName): \($0.failure ?? "failed")" }
                .joined(separator: " · ")
        }
    }

    /// Remembers that the offer was made, so it is not made again.
    func markShown() {
        shouldPresent = false
        guard let settingsStore else { return }
        var settings = settingsStore.load()
        guard !settings.didShowSetup else { return }
        settings.didShowSetup = true
        try? settingsStore.save(settings)
    }

    /// Opens the sheet from Settings, after it was skipped or completed.
    func present() {
        shouldPresent = true
    }

    /// Closes it without writing anything.
    func skip() {
        selected.removeAll()
        markShown()
    }
}
