import AuspexCore
import SwiftUI

/// Settings → Scene: how much map there is.
///
/// ## Why this is two checkboxes and not a picker
///
/// The office is not optional and the annexes are not alternatives to it: the
/// map is one continuous place, and both annexes can be open at once, either
/// on its own, or neither. A segmented control would say "pick a theme", which
/// is the one thing the scene deliberately is not.
///
/// Switching one off does not hide anything either. The sessions that would
/// have walked out there stay at their desks — an idle session slumped at its
/// monitor, a delegating one with its subagents in the bay beside it — which
/// is exactly the office that shipped before the annexes existed. So the
/// wording is about where people *are*, not about what is shown, and there is
/// no warning to give and nothing to undo beyond ticking the box again.
struct SceneSettingsView: View {
    let catalog: ProjectCatalogModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                switches
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
                Image(systemName: "map")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(AuspexPalette.textTertiary)
                Text("The map")
                    .auspexLabel(AuspexType.label)
                    .foregroundStyle(AuspexPalette.textTertiary)
            }
            Text("One place, three parts")
                .font(AuspexType.display)
                .foregroundStyle(AuspexPalette.textPrimary)
            Text(
                "Sessions that are working sit at desks in the office. Everything "
                    + "else walks somewhere you can see it: a family that is delegating "
                    + "meets round a table, and anything resting, asleep, finished, or "
                    + "waiting to be read goes out to the garden."
            )
            .font(AuspexType.body)
            .foregroundStyle(AuspexPalette.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var switches: some View {
        VStack(alignment: .leading, spacing: 12) {
            toggle(
                title: "Meeting room",
                detail: "A session that is delegating walks to a long table and sits at "
                    + "the head of it, with the subagents it spawned down the sides.",
                isOn: catalog.sceneZones.meetingRoom
            ) { on in
                var zones = catalog.sceneZones
                zones.meetingRoom = on
                catalog.setSceneZones(zones)
            }

            toggle(
                title: "Garden",
                detail: "Idle sessions rest on a bench, stale ones doze, anything that "
                    + "finished while you were elsewhere waits holding a note, and "
                    + "anything that is over walks out through the gate.",
                isOn: catalog.sceneZones.garden
            ) { on in
                var zones = catalog.sceneZones
                zones.garden = on
                catalog.setSceneZones(zones)
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(AuspexPalette.panel)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(AuspexPalette.hairline, lineWidth: 1)
        )
    }

    private func toggle(
        title: String,
        detail: String,
        isOn: Bool,
        set: @escaping (Bool) -> Void
    ) -> some View {
        Toggle(isOn: Binding(get: { isOn }, set: set)) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(AuspexType.body)
                    .foregroundStyle(AuspexPalette.textPrimary)
                Text(detail)
                    .font(AuspexType.caption)
                    .foregroundStyle(AuspexPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .toggleStyle(.checkbox)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var note: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(
                "With both switched off, everybody stays at their desk and the map "
                    + "is the office on its own."
            )
            .font(AuspexType.caption)
            .foregroundStyle(AuspexPalette.textTertiary)
            .fixedSize(horizontal: false, vertical: true)

            Text(
                "A session waiting on you never leaves its desk, whichever of these "
                    + "is on. It is the one thing here allowed to interrupt, and it "
                    + "has to do it from somewhere you are already looking."
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
