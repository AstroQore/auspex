import AgentSessionKit
import AppKit
import AuspexCore
import SwiftUI

/// The Settings window.
///
/// One pane today. It is a `TabView` anyway because the pane a person reaches
/// for is named — "Settings → Characters" — and a window that grows a second
/// tab later should not move the first one.
struct AuspexSettingsView: View {
    let library: SpriteLibrary

    var body: some View {
        TabView {
            CharactersSettingsView(library: library)
                .tabItem { Label("Characters", systemImage: "person.and.background.dotted") }
        }
        .frame(width: 660, height: 620)
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
/// office, because the office falls back to the placeholder rig and carries on.
/// This is the one surface that can say what went wrong, so it says all of it.
struct CharactersSettingsView: View {
    let library: SpriteLibrary

    private var packages: [CharacterPackage] { library.catalog.packages }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                harnessDefaults
                packageGrid
                folderNote
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(AuspexPalette.canvas)
        .task { library.startWatching() }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "person.and.background.dotted")
                    .font(.system(size: 10, weight: .semibold))
                Text("Characters").auspexLabel()
            }
            .foregroundStyle(AuspexPalette.stateDelegating)

            Text(headline)
                .font(AuspexType.display)
                .foregroundStyle(AuspexPalette.textPrimary)

            Text(
                "Every agent in the office is drawn from a character package — a folder with a "
                    + "character.json and one frame strip per pose. Drop your own into the "
                    + "characters folder and it appears here without a relaunch. A pose nobody "
                    + "has drawn falls back to the built-in placeholder figure."
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
        guard !packages.isEmpty else { return "No characters installed." }
        let mine = packages.count { $0.source == .user }
        let noun = packages.count == 1 ? "character" : "characters"
        guard mine > 0 else { return "\(packages.count) \(noun), all built in." }
        return "\(packages.count) \(noun), \(mine) of them yours."
    }

    // MARK: Per-harness defaults

    private var harnessDefaults: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader(
                "Default per harness",
                detail: "Automatic uses whichever package names the harness."
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
            if packages.isEmpty {
                Text(
                    "Nothing to show yet. A package is a folder holding character.json and "
                        + "idle.png, thinking.png, typing.png, writing.png, delegating.png, "
                        + "blocked.png, stale.png and ended.png — any of which may be missing."
                )
                .font(AuspexType.body)
                .foregroundStyle(AuspexPalette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .panelChrome()
            } else {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 288), spacing: 12, alignment: .top)],
                    alignment: .leading,
                    spacing: 12
                ) {
                    ForEach(packages) { package in
                        CharacterCard(package: package)
                    }
                }
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

    private var automaticDescription: String {
        library.catalog.package(for: harness, selection: .init())?.displayName
            ?? "placeholder figure"
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
                Text("Automatic").tag(String?.none)
                if !choices.isEmpty {
                    Divider()
                    ForEach(choices) { package in
                        Text(package.displayName).tag(String?.some(package.id))
                    }
                }
            }
            .labelsHidden()
            .frame(width: 190)
            .disabled(choices.isEmpty)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }

    private var subtitle: String {
        guard let chosen = library.selection.characterID(for: harness) else {
            return "Automatic · \(automaticDescription)"
        }
        guard library.catalog.package(id: chosen) != nil else {
            return "\(chosen) is not installed · using \(automaticDescription)"
        }
        return "Chosen"
    }

    private var binding: Binding<String?> {
        Binding(
            get: { library.selection.characterID(for: harness) },
            set: { library.setCharacter($0, for: harness) }
        )
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
                    chip(package.manifest.kind.displayName, tint: accent)
                    chip(package.source.displayName, tint: AuspexPalette.textSecondary)
                    chip("\(package.cell) px", tint: AuspexPalette.textSecondary)
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
        return "\(drawn) of 8 poses drawn. Placeholder for: \(missing)."
    }

    private func chip(_ text: String, tint: Color) -> some View {
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
