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
/// the window rather than to the destinations in it; and it knows a pane's *name*
/// and nothing else, so the one subtitle the window had was written beside
/// whichever pane existed first and then introduced every other pane as
/// "characters, and where packages come from".
///
/// So the chrome is the app's own, and it is one shape: a title row carrying
/// ``SettingsPane/title`` and that pane's own ``SettingsPane/subtitle``, a
/// segmented strip (or a compact menu when the column is narrow), a rule, and
/// the pane under it. Every pane is a plain stack of rows — the scroll view,
/// the padding, the ground and
/// the measure are here, once, so no pane can invent its own margins.
struct AuspexSettingsView: View {
    let library: SpriteLibrary
    /// The user layer, for the Ignore pane. The pane writes through it, so the
    /// board reacts to a rule the moment it is added.
    let catalog: ProjectCatalogModel
    /// The one process-wide macOS Login Items registration.
    let loginItem: LoginItemController
    /// What Auspex has written into each harness. `nil` where there is no app
    /// behind the pane — the offscreen renderer, and the previews.
    var setup: SetupModel?
    var detected: Set<Harness> = []
    var socketPath: String?
    /// The pane to open on when nobody has picked one — the offscreen
    /// renderers, which have to be able to photograph a pane that is not the
    /// first one.
    var initialPane: SettingsPane?

    @State private var pane: SettingsPane?

    private var panes: [SettingsPane] { SettingsPane.available(hasSetup: setup != nil) }

    /// The pane on screen. `panes.first` until somebody picks one, and back to
    /// it if the pane they picked is not offered here — which is what happens
    /// to Agents in a render with no app behind it.
    private var shown: SettingsPane {
        if let pane, panes.contains(pane) { return pane }
        if let initialPane, panes.contains(initialPane) { return initialPane }
        return panes.first ?? .appearance
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            titleRow
            BoardScroll {
                content
                    .padding(20)
                    // Capped, then centred. A pane in the board's column of a
                    // 1,680 pt window used to be a 720 pt strip against the
                    // left edge with six hundred points of nothing beside it,
                    // which reads as a layout that failed rather than as a
                    // measure that was chosen.
                    .frame(maxWidth: shown.measure, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .center)
            }
        }
        .frame(minWidth: 460, minHeight: 360)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(AuspexPalette.canvas)
        // Rebuilt when the language changes — this is where it is changed —
        // while `pane` above keeps the reader on the pane they were using.
        .id(catalog.language)
    }

    // MARK: The chrome

    /// The pane's name, the pane's own line, and the way to every other pane.
    ///
    /// The strip is under the title rather than beside it because the panes
    /// and a heading do not both fit across a 460 pt column. At that narrow
    /// measure the complete strip becomes one menu instead of overflowing or
    /// dropping destinations.
    private var titleRow: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 7) {
                    Image(systemName: shown.systemImage)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(AuspexPalette.text3)
                    Text(shown.localizedTitle)
                        .font(AuspexType.paneTitle)
                        .foregroundStyle(AuspexPalette.text)
                }
                Text(shown.localizedSubtitle)
                    .font(AuspexType.body)
                    .foregroundStyle(AuspexPalette.text3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ViewThatFits(in: .horizontal) {
                SegmentedPicker(
                    selection: Binding(get: { shown }, set: { pane = $0 }),
                    options: panes.map { ($0, $0.localizedTitle) }
                )
                .fixedSize()

                Picker(
                    L10n.Settings.paneMenu,
                    selection: Binding(get: { shown }, set: { pane = $0 })
                ) {
                    ForEach(panes) { option in
                        Label(option.localizedTitle, systemImage: option.systemImage).tag(option)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(maxWidth: 220, alignment: .leading)
            }
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
        case .general: GeneralSettingsView(catalog: catalog, loginItem: loginItem)
        case .appearance: AppearanceSettingsView(catalog: catalog)
        case .characters: CharactersSettingsView(library: library)
        case .scene: SceneSettingsView(catalog: catalog)
        case .crew: CrewSettingsView(catalog: catalog)
        case .ignore: IgnoreSettingsView(catalog: catalog)
        case .updates: UpdatesSettingsView(catalog: catalog)
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
            // The prose and the list of pickers keep a paragraph's measure
            // even where the pane has more: a sentence run to 1,400 points is
            // a sentence nobody's eye finds the start of again, and a row
            // whose control is four hundred points from its name is a row
            // read by following a line of nothing. Only the grid, whose whole
            // benefit is more cards abreast, takes the width.
            header.frame(maxWidth: SettingsPane.proseMeasure, alignment: .leading)
            harnessDefaults.frame(maxWidth: SettingsPane.proseMeasure, alignment: .leading)
            packageGrid
            folderNote.frame(maxWidth: SettingsPane.proseMeasure, alignment: .leading)
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

            Text(L10n.Characters.intro)
            .font(AuspexType.body)
            .foregroundStyle(AuspexPalette.textSecondary)
            .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                Button(L10n.Characters.openFolder, systemImage: "folder") { openFolder() }
                Button(L10n.Characters.reload, systemImage: "arrow.clockwise") {
                    CharacterPreview.invalidate()
                    library.reload()
                }
                Spacer(minLength: 0)
            }
            .controlSize(.small)
            .padding(.top, 2)

            if let error = library.selectionErrorDescription {
                Label(
                    L10n.Characters.saveError(error: error),
                    systemImage: "exclamationmark.triangle"
                )
                .font(AuspexType.body)
                .foregroundStyle(AuspexPalette.statePermission)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var headline: String {
        guard !packages.isEmpty else { return L10n.Characters.Headline.none }
        let mine = packages.count { $0.source == .user }
        guard mine > 0 else { return L10n.Characters.Headline.shipped(count: packages.count) }
        return L10n.Characters.Headline.mine(count: packages.count, mine: mine)
    }

    // MARK: Per-harness defaults

    private var harnessDefaults: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsSectionHeader(
                title: L10n.Characters.defaultPerHarness,
                detail: L10n.Characters.defaultDetail
            )
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .overlay(alignment: .bottom) {
                Rectangle().fill(AuspexPalette.hairline).frame(height: 1)
            }
            ForEach(Harness.boardOrder, id: \.self) { harness in
                HarnessCharacterRow(harness: harness, library: library)
                if harness != Harness.boardOrder.last {
                    Divider().overlay(AuspexPalette.hairline)
                }
            }
        }
        .modifier(SettingsCard())
    }

    // MARK: The packages

    @ViewBuilder
    private var packageGrid: some View {
        VStack(alignment: .leading, spacing: 10) {
            SettingsSectionHeader(title: L10n.Characters.installed)
            // The built-in figures come first and are always here. They are a
            // character one can choose, not a footnote about what happens when
            // a character is missing, so they are shown as a card among the
            // packages rather than as a sentence underneath them.
            // 340, not 288. A card is a tile plus a column of text, and at 288
            // the column was 124 points — narrow enough to wrap "Person" into
            // "PERS / ON" and to break the pills. See
            // ``CharacterPreview/cardSize``.
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 340), spacing: 12, alignment: .top)],
                alignment: .leading,
                spacing: 12
            ) {
                BuiltInCharacterCard()
                ForEach(packages) { package in
                    CharacterCard(package: package)
                }
            }
            if packages.isEmpty {
                EmptyStateView(
                    title: L10n.Characters.noPackages,
                    detail: L10n.Characters.noPackagesDetail
                )
                .frame(maxWidth: .infinity)
            }
        }
    }

    private var folderNote: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(L10n.Characters.whereTheyLive)
                .auspexLabel(AuspexType.labelSmall)
                .foregroundStyle(AuspexPalette.textTertiary)
            Text(library.charactersDirectory.path)
                .font(AuspexType.monoSmall)
                .foregroundStyle(AuspexPalette.textSecondary)
                .textSelection(.enabled)
            Text(L10n.Characters.folderNote)
            .font(AuspexType.body)
            .foregroundStyle(AuspexPalette.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
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
            ?? CharacterChoice.localizedBuiltInDisplayName
    }

    var body: some View {
        SettingsRow(labelWidth: 176, actionWidth: SettingsLayout.pickerWidth) {
            HStack(spacing: 8) {
                HarnessBadge(harness: harness, size: 20)
                // Always the full name. Auspex never abbreviates a harness.
                Text(harness.displayName)
                    .font(AuspexType.rowTitle)
                    .foregroundStyle(AuspexPalette.textPrimary)
                    .lineLimit(1)
            }
        } detail: {
            Text(subtitle)
                .font(AuspexType.caption)
                .foregroundStyle(AuspexPalette.textTertiary)
                .lineLimit(2)
        } action: {
            Picker("", selection: binding) {
                Text(L10n.Characters.automaticRecommended).tag(CharacterChoice.automatic)
                Text(CharacterChoice.localizedBuiltInDisplayName).tag(CharacterChoice.builtIn)
                if !choices.isEmpty {
                    Divider()
                    ForEach(choices) { package in
                        Text(package.displayName).tag(CharacterChoice.package(package.id))
                    }
                }
            }
            .labelsHidden()
            .frame(width: SettingsLayout.pickerWidth)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
    }

    private var subtitle: String {
        switch library.selection.choice(for: harness) {
        case .automatic:
            return L10n.Characters.automatic(name: automaticDescription)
        case .builtIn:
            return L10n.Characters.drawnInCode(name: CharacterChoice.localizedBuiltInDisplayName)
        case .package(let id):
            // A choice that outlived its folder. Saying so beats both silently
            // reverting the picker and quietly drawing something else.
            guard library.catalog.package(id: id) != nil else {
                return L10n.Characters.notInstalled(id: id, name: automaticDescription)
            }
            return L10n.Characters.chosen
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
            BuiltInPreviewTile(size: CharacterPreview.cardSize)
            VStack(alignment: .leading, spacing: 6) {
                Text(CharacterChoice.builtInDisplayName)
                    .font(AuspexType.cardTitle)
                    .foregroundStyle(AuspexPalette.textPrimary)
                    .lineLimit(2)
                // Where a package shows its id. The rig has none: it is not a
                // folder, and saying so is more use than an invented one.
                Text(L10n.Characters.builtInCode)
                    .font(AuspexType.monoSmall)
                    .foregroundStyle(AuspexPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)

                FlowLayout(spacing: 5, lineSpacing: 5) {
                    CharacterChip(L10n.Characters.Kind.person, tint: AuspexPalette.stateDelegating)
                    CharacterChip("32 px", tint: AuspexPalette.textSecondary)
                }

                Text(L10n.Characters.allPosesAlways)
                    .font(.system(size: 10))
                    .foregroundStyle(AuspexPalette.textTertiary)

                Text(L10n.Characters.accentNote)
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
            CharacterPreviewTile(package: package, size: CharacterPreview.cardSize)
            VStack(alignment: .leading, spacing: 6) {
                Text(package.displayName)
                    .font(AuspexType.cardTitle)
                    .foregroundStyle(AuspexPalette.textPrimary)
                    .lineLimit(2)
                Text(package.id)
                    .font(AuspexType.monoSmall)
                    .foregroundStyle(AuspexPalette.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                // A flow rather than a stack: three pills in a 200 pt column can
                // need a second line, and a pill that broke its own word into
                // "BUILT- / IN" is what an `HStack` does instead.
                FlowLayout(spacing: 5, lineSpacing: 5) {
                    CharacterChip(package.manifest.kind.localizedDisplayName, tint: accent)
                    CharacterChip(package.source.localizedDisplayName, tint: AuspexPalette.textSecondary)
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
        guard drawn > 0 else { return L10n.Characters.noPoses }
        guard !package.missingCorePoses.isEmpty else { return L10n.Characters.allPoses }
        let missing = package.missingCorePoses.map(\.rawValue).joined(separator: ", ")
        return L10n.Characters.somePoses(drawn: drawn, missing: missing)
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
            .lineLimit(1)
            .fixedSize()
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
                Text(L10n.MenuBar.andMore(count: sorted.count - Self.limit))
                    .font(.system(size: 10))
                    .foregroundStyle(AuspexPalette.textTertiary)
            }
        }
        .padding(.top, 2)
    }
}
