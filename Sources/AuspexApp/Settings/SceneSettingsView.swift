import AuspexCore
import SwiftUI

/// Settings → Scene: how much of a company each project is.
///
/// ## Why this is two checkboxes and not a picker
///
/// The desks are not optional and the other rooms are not alternatives to
/// them: a suite is one continuous place, and both rooms can be open at once,
/// either on its own, or neither. A segmented control would say "pick a
/// theme", which is the one thing the scene deliberately is not.
///
/// Switching one off does not hide anything either. The sessions that would
/// have walked next door stay at their desks — an idle session slumped at its
/// monitor, a delegating one with its subagents in the bay beside it — which
/// is exactly the office that shipped before the other rooms existed. So the
/// wording is about where people *are*, not about what is shown, and there is
/// no warning to give and nothing to undo beyond ticking the box again.
///
/// The third control is a different kind of thing and reads as one: the break
/// room's *style*. It changes what the room is furnished with and nothing
/// about who goes there, which is why it is a menu under the switches rather
/// than a third switch beside them.
struct SceneSettingsView: View {
    let catalog: ProjectCatalogModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            switches
            reach
            note
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The pane's name and its one line live in the chrome — see
    /// ``AuspexSettingsView``. This is the paragraph underneath them.
    private var header: some View {
        Text(
            "A project's sessions share a suite: desks for the ones that are "
                + "working, a meeting room for each family that is delegating, and "
                + "one break room where anything resting, asleep, finished, or "
                + "waiting to be read goes — and where the door out is."
        )
        .font(AuspexType.body)
        .foregroundStyle(AuspexPalette.textSecondary)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var switches: some View {
        VStack(alignment: .leading, spacing: 12) {
            toggle(
                title: "Meeting rooms",
                detail: "A session that is delegating walks to a long table in its own "
                    + "project's suite and sits at the head of it, with the subagents it "
                    + "spawned down the sides. A project with three or more sessions has "
                    + "a meeting room whether or not anybody is in it.",
                isOn: catalog.sceneZones.meetingRooms
            ) { on in
                var zones = catalog.sceneZones
                zones.meetingRooms = on
                catalog.setSceneZones(zones)
            }

            toggle(
                title: "Break areas",
                detail: "Idle sessions rest, stale ones doze, anything that finished "
                    + "while you were elsewhere waits by the door holding a note, and "
                    + "anything that is over walks out through it.",
                isOn: catalog.sceneZones.breakAreas
            ) { on in
                var zones = catalog.sceneZones
                zones.breakAreas = on
                catalog.setSceneZones(zones)
            }

            breakStyle
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

    /// What a company's break room is furnished with.
    ///
    /// "Per project" is the default and the one worth defending: the kind is
    /// decided from the project's own path and never changes, so eight
    /// repositories look like eight companies rather than eight copies of one
    /// — and the suite with the sofas is always the same repository, which is
    /// a thing a reader can learn. The other three are for somebody who would
    /// rather every suite matched.
    private var breakStyle: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker(
                "Break area style",
                selection: Binding(
                    get: { catalog.sceneZones.breakStyle },
                    set: { style in
                        var zones = catalog.sceneZones
                        zones.breakStyle = style
                        catalog.setSceneZones(zones)
                    }
                )
            ) {
                Text("Per project (random)").tag(SceneBreakStyle.perProject)
                Text("Garden").tag(SceneBreakStyle.garden)
                Text("Tea room").tag(SceneBreakStyle.teaRoom)
                Text("Lounge").tag(SceneBreakStyle.lounge)
            }
            .pickerStyle(.menu)
            .frame(maxWidth: 260, alignment: .leading)
            .disabled(!catalog.sceneZones.breakAreas)

            Text(
                "Per project picks one of the three from the project's own path and "
                    + "keeps it, so a suite is recognisable before its nameplate is."
            )
            .font(AuspexType.caption)
            .foregroundStyle(AuspexPalette.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.leading, 20)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// How far back the board and the map reach.
    ///
    /// Here as well as in the board's header because the two are the same
    /// setting seen from two places a person can be standing: at the board,
    /// where they notice an afternoon missing, or in Settings, where they came
    /// looking for the knob. One store behind both — see
    /// ``AuspexSettings/sessionWindow``.
    private var reach: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("How far back")
                .auspexLabel(AuspexType.label)
                .foregroundStyle(AuspexPalette.textTertiary)

            Picker(
                "Show sessions active in the last",
                selection: Binding(
                    get: { catalog.sessionWindow },
                    set: { catalog.setSessionWindow($0) }
                )
            ) {
                ForEach(SessionWindow.allCases) { option in
                    Text(option.title).tag(option)
                }
            }
            .pickerStyle(.menu)
            .frame(maxWidth: 260, alignment: .leading)

            Text(
                "Auspex keeps a week of sessions and draws the recent ones. Anything "
                    + "alive, working, or waiting on you is drawn whatever its age — the "
                    + "window only decides how much history stands behind it. Nothing is "
                    + "deleted: widen it and the rest come back."
            )
            .font(AuspexType.caption)
            .foregroundStyle(AuspexPalette.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
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
