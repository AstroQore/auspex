import AuspexCore
import SwiftUI

/// Settings → Appearance: which of the two columns the window is drawn in, and
/// what the sidebar stands on.
///
/// ## Why there is a choice at all
///
/// Auspex forced dark for as long as it had one palette, and the argument for
/// it was honest: a light translation of a dark-only palette is a worse dark
/// palette. It stopped being honest when the palette became a pair. A Mac app
/// that ignores the appearance its Mac is set to is wrong for half of every
/// day — and the board is a window people leave open beside their work, which
/// is the worst place for the one bright rectangle or the one black one.
///
/// So the default is "follow", and the two overrides are for the people who
/// want the wall dark on a light Mac, or this one window bright on a dark one.
///
/// ## Why the swatches are not editable
///
/// They are the answer to "what am I actually looking at", not a theme editor.
/// A person who has just switched to Light wants to see that the accent did
/// not move and the ground did; three squares say that in less time than a
/// sentence. Making them editable would mean a palette with no fixed contrast
/// guarantees, and the contrast guarantees are the reason the two columns can
/// be trusted at all — see `AuspexPalette`.
struct AppearanceSettingsView: View {
    let catalog: ProjectCatalogModel

    /// What the window is *actually* drawn in right now, which is not the same
    /// question as which mode is selected: `system` resolves to one of the two
    /// and the swatches have to show the one that won.
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            modePicker
            swatches
            sidebarToggle
            note
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Header

    /// The paragraph the title row is too short for. The pane's name and its
    /// one line live in the chrome — see ``AuspexSettingsView``.
    private var header: some View {
        Text(
            "Every colour Auspex draws with has a value for each appearance, so the "
                + "board is the same board either way: the same four surface steps, the "
                + "same three text steps, one colour per state and one per harness. "
                + "Only their brightness moves."
        )
        .font(AuspexType.body)
        .foregroundStyle(AuspexPalette.textSecondary)
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: The choice

    private var modePicker: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Window appearance")
                .auspexLabel(AuspexType.label)
                .foregroundStyle(AuspexPalette.textTertiary)

            Picker(
                "Window appearance",
                selection: Binding(
                    get: { catalog.appearance },
                    set: { catalog.setAppearance($0) }
                )
            ) {
                ForEach(AppearanceMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 280, alignment: .leading)

            Text(catalog.appearance.detail)
                .font(AuspexType.caption)
                .foregroundStyle(AuspexPalette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(SettingsCard())
    }

    // MARK: What that resolved to

    private var swatches: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Text("Drawing in")
                    .auspexLabel(AuspexType.label)
                    .foregroundStyle(AuspexPalette.textTertiary)
                Text(colorScheme == .dark ? "Dark" : "Light")
                    .font(AuspexType.pill)
                    .foregroundStyle(AuspexPalette.textSecondary)
            }

            HStack(spacing: 10) {
                Swatch(name: "Accent", color: AuspexPalette.accent)
                Swatch(name: "Background", color: AuspexPalette.canvas)
                Swatch(name: "Foreground", color: AuspexPalette.text)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(SettingsCard())
    }

    /// One colour, named. Read-only on purpose — see the type's docs.
    private struct Swatch: View {
        let name: String
        let color: Color

        var body: some View {
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(color)
                    .frame(width: 26, height: 26)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(AuspexPalette.hairlineStrong, lineWidth: 1)
                    )
                Text(name)
                    .font(AuspexType.caption)
                    .foregroundStyle(AuspexPalette.textSecondary)
            }
            .padding(.trailing, 4)
            .accessibilityElement(children: .combine)
        }
    }

    // MARK: The sidebar's ground

    private var sidebarToggle: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(
                isOn: Binding(
                    get: { catalog.translucentSidebar },
                    set: { catalog.setTranslucentSidebar($0) }
                )
            ) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Translucent sidebar")
                        .font(AuspexType.body)
                        .foregroundStyle(AuspexPalette.textPrimary)
                    Text(
                        "The system's sidebar material under the column, which picks up "
                            + "what is behind the window and drains when the window is not "
                            + "in front. Switch it off for a flat ground that matches the "
                            + "board exactly."
                    )
                    .font(AuspexType.caption)
                    .foregroundStyle(AuspexPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
            .toggleStyle(.checkbox)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(SettingsCard())
    }

    private var note: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(
                "Nothing has to be relaunched. The window, the menu bar panel, the "
                    + "office and the crew all repaint where they stand."
            )
            .font(AuspexType.caption)
            .foregroundStyle(AuspexPalette.textTertiary)
            .fixedSize(horizontal: false, vertical: true)

            if let error = catalog.saveErrorDescription {
                Text("The setting is in effect, but could not be saved: \(error)")
                    .font(AuspexType.caption)
                    .foregroundStyle(AuspexPalette.statePermission)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// The panel every settings group sits in. One shape, so a person learns
/// "boxed thing is one setting" once.
struct SettingsCard: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(AuspexPalette.panel)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(AuspexPalette.hairline, lineWidth: 1)
            )
    }
}
