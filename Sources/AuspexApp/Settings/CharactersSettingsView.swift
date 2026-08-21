import AgentSessionKit
import AppKit
import AuspexCore
import SwiftUI

/// The Settings window, and the Settings section of the board's column — one
/// view, shown in two places.
///
/// ## Why it is not a `TabView` any more
///
/// A `TabView` puts the strip wherever the platform puts it, which in the
/// board's column was directly on the header's hairline; it sizes the strip to
/// the window rather than to the six words in it; and it knows a pane's *name*
/// and nothing else, so the one subtitle the window had was written beside
/// whichever pane existed first and then introduced every other pane as
/// "characters, and where packages come from".
///
/// So the chrome is the app's own, and it is one shape: a title row carrying
/// ``SettingsPane/title`` and that pane's own ``SettingsPane/subtitle``, a
/// segmented strip sized to its six words, a rule, and the pane under it. Every
/// pane is a plain stack of rows — the scroll view, the padding, the ground and
/// the measure are here, once, so no pane can invent its own margins.
struct AuspexSettingsView: View {
    let library: SpriteLibrary
    /// The user layer, for the Ignore pane. The pane writes through it, so the
    /// board reacts to a rule the moment it is added.
    let catalog: ProjectCatalogModel
    /// What Auspex has written into each harness. `nil` where there is no app
    /// behind the pane — the offscreen renderer, and the previews.
    var setup: SetupModel?
    var detected: Set<Harness> = []
    var socketPath: String?

    @State private var pane: SettingsPane?

    /// How wide a column of settings copy is allowed to get.
    ///
    /// The window is 660 points and the board's column can be twice that. A
    /// paragraph run to 1300 points is a paragraph nobody finishes, so the
    /// content stops here and the extra width stays as margin.
    private static let measure: CGFloat = 720

    private var panes: [SettingsPane] { SettingsPane.available(hasSetup: setup != nil) }

    /// The pane on screen. `panes.first` until somebody picks one, and back to
    /// it if the pane they picked is not offered here — which is what happens
    /// to Agents in a render with no app behind it.
    private var shown: SettingsPane {
        guard let pane, panes.contains(pane) else { return panes.first ?? .appearance }
        return pane
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            titleRow
            BoardScroll {
                content
                    .padding(20)
                    .frame(maxWidth: Self.measure, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(minWidth: 460, minHeight: 360)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(AuspexPalette.canvas)
    }

    // MARK: The chrome

    /// The pane's name, the pane's own line, and the way to the other five.
    ///
    /// The strip is under the title rather than beside it because six segments
    /// and a heading do not both fit across a 460 pt column, and a strip that
    /// starts dropping words is worse than a strip on its own row.
    private var titleRow: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 7) {
                    Image(systemName: shown.systemImage)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(AuspexPalette.text3)
                    Text(shown.title)
                        .font(AuspexType.paneTitle)
                        .foregroundStyle(AuspexPalette.text)
                }
                Text(shown.subtitle)
                    .font(AuspexType.body)
                    .foregroundStyle(AuspexPalette.text3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            SegmentedPicker(
                selection: Binding(get: { shown }, set: { pane = $0 }),
                options: panes.map { ($0, $0.title) }
            )
            .fixedSize()
        }
        .padding(.horizontal, 20)
        .padding(.top, 18)
        .padding(.bottom, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .bottom) {
            Rectangle().fill(AuspexPalette.line).frame(height: 1)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch shown {
        case .agents:
            if let setup {
                AgentsSettingsView(
                    model: setup,
                    catalog: catalog,
                    detected: detected,
                    socketPath: socketPath,
                    onOpenSetup: { setup.present() }
                )
            }
        case .appearance: AppearanceSettingsView(catalog: catalog)
        case .characters: CharactersSettingsView(library: library)
        case .scene: SceneSettingsView(catalog: catalog)
        case .crew: CrewSettingsView(catalog: catalog)
        case .ignore: IgnoreSettingsView(catalog: catalog)
        }
    }
}

/// Settings → Characters: what the office's people look like, and where to put
/// your own.
///
/// ## What it is for
///
/// Two questions. *What can Auspex draw* — answered by the grid, which shows
/// every package's frame 0 at four times size, where it came from, and
/// anything the loader could not make sense of. And *who wears what* — answered
/// by the harness list, which is the only setting most people will ever touch.
///
/// ## Why the warnings are on screen and not in a log
///
/// A character package is hand-made, usually by generating pixels and dropping
/// a folder in. Every mistake it can have — a strip one pixel too short, a
/// manifest that says four frames over a six-frame walk — is invisible in the
/// office, because the office falls back to the built-in rig and carries on.
/// This is the one surface that can say what went wrong, so it says all of it.
struct CharactersSettingsView: View {
    let library: SpriteLibrary

    private var packages: [CharacterPackage] { library.catalog.packages }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            harnessDefaults
            packageGrid
            folderNote
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task { library.startWatching() }
    }

    // MARK: Header

    /// What the pane's own title row cannot say: how many packages there are
    /// right now, and the two buttons that change that. The name of the pane
    /// and the sentence about what it is for are up in the chrome — see
    /// ``AuspexSettingsView``.
    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(headline)
                .font(AuspexType.cardTitle)
                .foregroundStyle(AuspexPalette.textPrimary)

            Text(
                "Every agent in the office is drawn either from a character package — a folder "
                    + "with a character.json and one frame strip per pose — or from Auspex's own "
                    + "figures, which are composed in code from the harness's accent. Drop a "
                    + "package into the characters folder and it appears here without a "
                    + "relaunch. The built-in figures are always installed, never miss a pose, "
                    + "and can be chosen for a harness exactly the way a package can."
            )
            .font(AuspexType.body)
            .foregroundStyle(AuspexPalette.textSecondary)
            .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                Button("Open characters folder", systemImage: "folder") { openFolder() }
                Button("Reload", systemImage: "arrow.clockwise") {
                    CharacterPreview.invalidate()
                    library.reload()
                }
                Spacer(minLength: 0)
            }
            .controlSize(.small)
            .padding(.top, 2)

            if let error = library.selectionErrorDescription {
                Label(
                    "Your choice is in effect but could not be saved: \(error)",
                    systemImage: "exclamationmark.triangle"
                )
                .font(AuspexType.body)
                .foregroundStyle(AuspexPalette.statePermission)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var headline: String {
        guard !packages.isEmpty else { return "The built-in figures, and no packages yet." }
        let mine = packages.count { $0.source == .user }
        let noun = packages.count == 1 ? "package" : "packages"
        guard mine > 0 else { return "\(packages.count) \(noun), all shipped with Auspex." }
        return "\(packages.count) \(noun), \(mine) of them yours."
    }

    // MARK: Per-harness defaults

    private var harnessDefaults: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader(
                "Default per harness",
                detail: "Automatic uses whichever package names the harness, "
                    + "and the built-in figures while none does."
            )
            ForEach(Harness.boardOrder, id: \.self) { harness in
                HarnessCharacterRow(harness: harness, library: library)
                if harness != Harness.boardOrder.last {
                    Divider().overlay(AuspexPalette.hairline)
                }
            }
        }
        .background(AuspexPalette.well)
        .overlay(Rectangle().strokeBorder(AuspexPalette.hairline, lineWidth: 1))
    }

    // MARK: The packages

    @ViewBuilder
    private var packageGrid: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("Installed", detail: nil, inset: false)
            // The built-in figures come first and are always here. They are a
            // character one can choose, not a footnote about what happens when
            // a character is missing, so they are shown as a card among the
            // packages rather than as a sentence underneath them.
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 288), spacing: 12, alignment: .top)],
                alignment: .leading,
                spacing: 12
            ) {
                BuiltInCharacterCard()
                ForEach(packages) { package in
                    CharacterCard(package: package)
                }
            }
            if packages.isEmpty {
                Text(
                    "No packages yet. One is a folder holding character.json and idle.png, "
                        + "thinking.png, typing.png, writing.png, delegating.png, blocked.png, "
                        + "stale.png and ended.png — any of which may be missing, because a "
                        + "pose nobody has drawn falls back to the figures above."
                )
                .font(AuspexType.body)
                .foregroundStyle(AuspexPalette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .panelChrome()
            }
        }
    }

    private var folderNote: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Where they live")
                .auspexLabel(AuspexType.labelSmall)
                .foregroundStyle(AuspexPalette.textTertiary)
            Text(library.charactersDirectory.path)
                .font(AuspexType.monoSmall)
                .foregroundStyle(AuspexPalette.textSecondary)
                .textSelection(.enabled)
            Text(
                "Auspex only ever reads this folder. A package here replaces a built-in one "
                    + "with the same id."
            )
            .font(AuspexType.body)
            .foregroundStyle(AuspexPalette.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func sectionHeader(
        _ title: String,
        detail: String?,
        inset: Bool = true
    ) -> some View {
        HStack(spacing: 8) {
            Text(title).auspexLabel(AuspexType.labelSmall)
            if let detail {
                Text(detail)
                    .font(.system(size: 10))
                    .foregroundStyle(AuspexPalette.textTertiary)
            }
            Spacer(minLength: 4)
        }
        .foregroundStyle(AuspexPalette.textTertiary)
        .padding(.horizontal, inset ? 12 : 0)
        .padding(.vertical, inset ? 6 : 0)
        .overlay(alignment: .bottom) {
            if inset {
                Rectangle().fill(AuspexPalette.hairline).frame(height: 1)
            }
        }
    }

    /// Opens `~/.auspex/characters/`, creating it first. The folder is only
    /// made when a person asks for it — an empty directory nobody put anything
    /// in is litter in someone's home.
    private func openFolder() {
        guard let url = library.ensureCharactersDirectory() else { return }
        NSWorkspace.shared.open(url)
    }
}

/// One harness and the character its sessions are drawn as.
private struct HarnessCharacterRow: View {
    let harness: Harness
    let library: SpriteLibrary

    /// The packages that can be chosen here: the ones that name this harness,
    /// plus every package that names none — a pet belongs to no vendor.
    private var choices: [CharacterPackage] {
        library.catalog.packages(for: harness)
    }

    /// What Automatic resolves to for this harness right now — the name that
    /// makes "Automatic" a statement rather than a shrug.
    private var automaticDescription: String {
        library.catalog.automaticPackage(for: harness)?.displayName
            ?? CharacterChoice.builtInDisplayName
    }

    var body: some View {
        HStack(spacing: 10) {
            HarnessBadge(harness: harness, size: 20)
            VStack(alignment: .leading, spacing: 1) {
                // Always the full name. Auspex never abbreviates a harness.
                Text(harness.displayName)
                    .font(AuspexType.rowTitle)
                    .foregroundStyle(AuspexPalette.textPrimary)
                Text(subtitle)
                    .font(.system(size: 10))
                    .foregroundStyle(AuspexPalette.textTertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Picker("", selection: binding) {
                Text("Automatic (recommended)").tag(CharacterChoice.automatic)
                Text(CharacterChoice.builtInDisplayName).tag(CharacterChoice.builtIn)
                if !choices.isEmpty {
                    Divider()
                    ForEach(choices) { package in
                        Text(package.displayName).tag(CharacterChoice.package(package.id))
                    }
                }
            }
            .labelsHidden()
            .frame(width: 210)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }

    private var subtitle: String {
        switch library.selection.choice(for: harness) {
        case .automatic:
            return "Automatic · \(automaticDescription)"
        case .builtIn:
            return "\(CharacterChoice.builtInDisplayName) · drawn in code"
        case .package(let id):
            // A choice that outlived its folder. Saying so beats both silently
            // reverting the picker and quietly drawing something else.
            guard library.catalog.package(id: id) != nil else {
                return "\(id) is not installed · using \(automaticDescription)"
            }
            return "Chosen"
        }
    }

    private var binding: Binding<CharacterChoice> {
        Binding(
            get: { library.selection.choice(for: harness) },
            set: { library.setChoice($0, for: harness) }
        )
    }
}

/// Auspex's own figures, as a card among the packages.
///
/// It is here because the procedural rig is a *look a person can choose*, not
/// the consolation prize for an empty folder. A grid that showed only packages
/// would say the office has nothing installed until somebody draws something,
/// which has never been true — and would make "Auspex built-in" in the picker
/// above a name with no picture attached to it.
private struct BuiltInCharacterCard: View {
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            BuiltInPreviewTile()
            VStack(alignment: .leading, spacing: 6) {
                Text(CharacterChoice.builtInDisplayName)
                    .font(AuspexType.cardTitle)
                    .foregroundStyle(AuspexPalette.textPrimary)
                // Where a package shows its id. The rig has none: it is not a
                // folder, and saying so is more use than an invented one.
                Text("Built-in · drawn in code")
                    .font(AuspexType.monoSmall)
                    .foregroundStyle(AuspexPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 5) {
                    CharacterChip("Person", tint: AuspexPalette.stateDelegating)
                    CharacterChip("32 px", tint: AuspexPalette.textSecondary)
                }

                Text("All 8 poses, always.")
                    .font(.system(size: 10))
                    .foregroundStyle(AuspexPalette.textTertiary)

                Text(
                    "Composed from each harness's own accent — the figure above is the shape, "
                        + "not the colour."
                )
                .font(.system(size: 10))
                .foregroundStyle(AuspexPalette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .panelChrome()
    }
}

/// One package: what it looks like, where it came from, and what is wrong.
private struct CharacterCard: View {
    let package: CharacterPackage

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            CharacterPreviewTile(package: package)
            VStack(alignment: .leading, spacing: 6) {
                Text(package.displayName)
                    .font(AuspexType.cardTitle)
                    .foregroundStyle(AuspexPalette.textPrimary)
                Text(package.id)
                    .font(AuspexType.monoSmall)
                    .foregroundStyle(AuspexPalette.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                HStack(spacing: 5) {
                    CharacterChip(package.manifest.kind.displayName, tint: accent)
                    CharacterChip(package.source.displayName, tint: AuspexPalette.textSecondary)
                    CharacterChip("\(package.cell) px", tint: AuspexPalette.textSecondary)
                }

                if let harness = package.harness {
                    HStack(spacing: 5) {
                        HarnessBadge(harness: harness, size: 14)
                        Text(harness.displayName)
                            .font(.system(size: 10))
                            .foregroundStyle(AuspexPalette.textSecondary)
                    }
                }

                Text(poseSummary)
                    .font(.system(size: 10))
                    .foregroundStyle(AuspexPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)

                if !package.problems.isEmpty {
                    ProblemList(problems: package.problems)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .panelChrome(
            isHighlighted: package.hasErrors,
            highlightColor: AuspexPalette.statePermission
        )
    }

    private var accent: Color {
        package.harness?.style.accent ?? AuspexPalette.stateDelegating
    }

    private var poseSummary: String {
        let drawn = CharacterPose.core.count - package.missingCorePoses.count
        guard drawn > 0 else { return "No poses drawn yet." }
        guard !package.missingCorePoses.isEmpty else { return "All 8 poses drawn." }
        let missing = package.missingCorePoses.map(\.rawValue).joined(separator: ", ")
        return "\(drawn) of 8 poses drawn. Built-in for: \(missing)."
    }

}

/// One outlined word on a character card.
private struct CharacterChip: View {
    let text: String
    let tint: Color

    init(_ text: String, tint: Color) {
        self.text = text
        self.tint = tint
    }

    var body: some View {
        Text(text)
            .auspexLabel(AuspexType.labelSmall)
            .foregroundStyle(tint)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .overlay(Capsule().strokeBorder(tint.opacity(0.35), lineWidth: 1))
    }
}

/// The loader's complaints, errors first.
///
/// Capped, because a folder of eight strips at the wrong size produces eight
/// identical lines and the ninth one is what a person stops reading at.
private struct ProblemList: View {
    let problems: [CharacterProblem]

    private static let limit = 4

    /// Errors first, and within each severity the order the loader found them
    /// in — which is manifest fields, then poses in alphabetical order. Sorting
    /// by message instead would scramble a list of near-identical lines into
    /// something that reads as random.
    private var sorted: [CharacterProblem] {
        problems.enumerated()
            .sorted {
                $0.element.severity == $1.element.severity
                    ? $0.offset < $1.offset
                    : $0.element.severity > $1.element.severity
            }
            .map(\.element)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(sorted.prefix(Self.limit)) { problem in
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Image(
                        systemName: problem.severity == .error
                            ? "exclamationmark.octagon.fill"
                            : "exclamationmark.triangle"
                    )
                    .font(.system(size: 8))
                    Text(problem.message)
                        .font(.system(size: 10))
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)
                }
                .foregroundStyle(
                    problem.severity == .error
                        ? AuspexPalette.statePermission
                        : AuspexPalette.stateStale
                )
            }
            if sorted.count > Self.limit {
                Text("and \(sorted.count - Self.limit) more")
                    .font(.system(size: 10))
                    .foregroundStyle(AuspexPalette.textTertiary)
            }
        }
        .padding(.top, 2)
    }
}
