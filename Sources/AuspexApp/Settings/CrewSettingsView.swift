import AuspexCore
import SwiftUI

/// Settings → Crew: how often the wall moves.
///
/// ## Why this is one slider and not a switch
///
/// "Animation on/off" is the setting nobody wants. Off is a wall of frozen
/// faces, which is worse than the stiff wall this whole view was built to fix;
/// on is whatever the author thought was tasteful in a room that is not yours.
/// What actually differs between people is how much motion beside their work
/// they can stand, and that is a **rate**, not a mode.
///
/// So the knob scales the **gaps between reactions** and nothing else. Every
/// avatar still lives in its own loop, still blinks on its own rhythm, still
/// drifts its gaze, and still answers a change of state with the same morph. A
/// calm wall is one where things happen less often — not one where they happen
/// in slow motion, which is what scaling the movements would give and which
/// reads as a machine struggling.
///
/// Reduce Motion is not here on purpose. It is a system setting, the crew
/// already honours it by holding a still frame, and a second switch that
/// half-overrode it would be a way of getting the two out of step.
struct CrewSettingsView: View {
    let catalog: ProjectCatalogModel

    private var liveliness: CrewLiveliness { catalog.crewLiveliness }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            picker
            note
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The pane's name and its one line live in the chrome — see
    /// ``AuspexSettingsView``. This is the paragraph underneath them.
    private var header: some View {
        Text(L10n.Settings.Crew.intro)
        .font(AuspexType.body)
        .foregroundStyle(AuspexPalette.textSecondary)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var picker: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker(L10n.Settings.Crew.liveliness, selection: binding) {
                ForEach(CrewLiveliness.allCases, id: \.self) { value in
                    Text(Self.title(value)).tag(value)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 320)

            Text(Self.detail(liveliness))
                .font(AuspexType.body)
                .foregroundStyle(AuspexPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var note: some View {
        Label(
            L10n.Settings.Crew.waitingNote,
            systemImage: "exclamationmark.bubble"
        )
        .font(AuspexType.body)
        .foregroundStyle(AuspexPalette.textTertiary)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var binding: Binding<CrewLiveliness> {
        Binding(
            get: { catalog.crewLiveliness },
            set: { catalog.setCrewLiveliness($0) }
        )
    }

    private static func title(_ value: CrewLiveliness) -> String {
        switch value {
        case .calm: L10n.Settings.Crew.calm
        case .normal: L10n.Settings.Crew.normal
        case .lively: L10n.Settings.Crew.lively
        }
    }

    /// The window in seconds, spelled out, because "calm" on its own is a mood
    /// and this is a number a person can check against what they are seeing.
    private static func detail(_ value: CrewLiveliness) -> String {
        switch value {
        case .calm:
            L10n.Settings.Crew.calmDetail
        case .normal:
            L10n.Settings.Crew.normalDetail
        case .lively:
            L10n.Settings.Crew.livelyDetail
        }
    }
}
