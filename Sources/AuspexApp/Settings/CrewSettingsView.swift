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
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                picker
                note
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(AuspexPalette.canvas)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "face.smiling")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(AuspexPalette.textTertiary)
                Text("The crew")
                    .auspexLabel(AuspexType.label)
                    .foregroundStyle(AuspexPalette.textTertiary)
            }
            Text("How lively the wall is")
                .font(AuspexType.display)
                .foregroundStyle(AuspexPalette.textPrimary)
            Text(
                "Every avatar lives in a loop that belongs to what its session is "
                    + "doing — thinking, working, waiting on you — and now and then it "
                    + "breaks out of it: a glance away, a shrug, a yawn. This is how "
                    + "often that happens. It does not change how fast anything moves, "
                    + "and it does not switch anything off."
            )
            .font(AuspexType.body)
            .foregroundStyle(AuspexPalette.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var picker: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Liveliness", selection: binding) {
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
            "A session that is waiting on you keeps its own rhythm whatever this "
                + "says: it is the one state that will not resolve itself, so it goes "
                + "on asking.",
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
        case .calm: "Calm"
        case .normal: "Normal"
        case .lively: "Lively"
        }
    }

    /// The window in seconds, spelled out, because "calm" on its own is a mood
    /// and this is a number a person can check against what they are seeing.
    private static func detail(_ value: CrewLiveliness) -> String {
        switch value {
        case .calm:
            "Something happens to an avatar every fourteen to fifty seconds. "
                + "For a board you work beside rather than watch."
        case .normal:
            "Something happens to an avatar every eight to thirty seconds."
        case .lively:
            "Something happens to an avatar every five to eighteen seconds. "
                + "The wall is never quite still."
        }
    }
}
