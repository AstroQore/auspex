import AuspexCore
import SwiftUI

/// Settings → Updates: what this copy is, where a newer one would come from,
/// and which stream it is allowed to come from.
///
/// ## Why the channel is a setting and not a build
///
/// The alternative is two downloads — a "stable Auspex" and a "beta Auspex" —
/// and a person who wanted to try a preview would have to go and get the other
/// one, then go and get the first one back. One app, one feed, and a switch
/// that decides which items in that feed count is the version of this that
/// somebody can undo in four seconds.
///
/// Stable is deliberately not `["main"]`: no item in the feed carries that
/// tag. Dev *adds* the preview items to the stable ones rather than replacing
/// them, which is why a preview user still gets tomorrow's stable fix. See
/// ``UpdateChannel``.
///
/// ## Why "Check now" can be disabled
///
/// A build that is not a packaged, signed `Auspex.app` has no feed URL and no
/// public key, so there is nothing for Sparkle to verify an update against and
/// no bundle for it to replace — a `swift run` binary, or the `--demo` launch,
/// which promises to write nothing at all. Rather than offering a button that
/// silently does nothing, the pane says which of those it is.
struct UpdatesSettingsView: View {
    /// Where the choice is written down. `settings.json`, next to every other
    /// preference that decides what the app *is* rather than what it is
    /// showing.
    let catalog: ProjectCatalogModel

    /// The updater itself. Shared, because there is one per process — see
    /// ``AppUpdateController``.
    private var updates: AppUpdateController { .shared }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                versionRow
                channelPicker
                automaticToggle
                note
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(AuspexPalette.canvas)
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.down.circle")
                    .font(.system(size: 10, weight: .semibold))
                Text("Updates").auspexLabel()
            }
            .foregroundStyle(AuspexPalette.textTertiary)

            Text("Two streams, one signed feed")
                .font(AuspexType.display)
                .foregroundStyle(AuspexPalette.textPrimary)

            Text(
                "Auspex reads one update feed and installs nothing without asking. Every "
                    + "build in it is signed with the project's EdDSA key and checked "
                    + "against the key compiled into this copy before a single byte is "
                    + "unpacked, so an update that was tampered with in transit is refused "
                    + "rather than run."
            )
            .font(AuspexType.body)
            .foregroundStyle(AuspexPalette.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: What this copy is

    private var versionRow: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Auspex \(updates.versionDescription)")
                        .font(AuspexType.body)
                        .foregroundStyle(AuspexPalette.textPrimary)
                    Text(lastCheckDescription)
                        .font(AuspexType.caption)
                        .foregroundStyle(AuspexPalette.textTertiary)
                }
                Spacer(minLength: 8)
                Button("Check now", systemImage: "arrow.triangle.2.circlepath") {
                    updates.checkForUpdates()
                }
                .buttonStyle(.auspex)
                .font(AuspexType.pill)
                .foregroundStyle(
                    updates.canCheckForUpdates
                        ? AuspexPalette.stateThinking
                        : AuspexPalette.textTertiary
                )
                .disabled(!updates.canCheckForUpdates)
            }

            if !updates.isActive {
                Text(inactiveExplanation)
                    .font(AuspexType.caption)
                    .foregroundStyle(AuspexPalette.stateStale)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(SettingsCard())
    }

    /// When Sparkle last asked, in the words a person would use. "Never" is a
    /// real answer and says so: a fresh install that has not reached its first
    /// scheduled check has not failed at anything.
    private var lastCheckDescription: String {
        guard let date = updates.lastCheckDate else {
            return "No check yet. The first one runs shortly after launch."
        }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return "Last checked \(formatter.localizedString(for: date, relativeTo: Date()))."
    }

    /// Why there is no updater behind this pane, in the one sentence that
    /// tells the reader what to do about it.
    private var inactiveExplanation: String {
        if updates.feedURLString == nil {
            return "This copy was not packaged as an app bundle, so it has no update "
                + "feed and no key to verify one with. Build it with "
                + "Scripts/build_app.sh and run Auspex.app."
        }
        return "This is a demo launch. It reads nothing and writes nothing, "
            + "including Sparkle's own check timestamp, so the updater is not running."
    }

    // MARK: Which stream

    private var channelPicker: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Update channel")
                .auspexLabel(AuspexType.label)
                .foregroundStyle(AuspexPalette.textTertiary)

            Picker(
                "Update channel",
                selection: Binding(
                    get: { catalog.updateChannel },
                    set: { channel in
                        catalog.setUpdateChannel(channel)
                        updates.setChannel(channel)
                    }
                )
            ) {
                ForEach(UpdateChannel.allCases) { channel in
                    Text(channel.title).tag(channel)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 280, alignment: .leading)

            Text(catalog.updateChannel.detail)
                .font(AuspexType.caption)
                .foregroundStyle(AuspexPalette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(SettingsCard())
    }

    // MARK: Whether to look on its own

    private var automaticToggle: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(
                isOn: Binding(
                    get: { updates.checksAutomatically },
                    set: { updates.setChecksAutomatically($0) }
                )
            ) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Check for updates automatically")
                        .font(AuspexType.body)
                        .foregroundStyle(AuspexPalette.textPrimary)
                    Text(
                        "Once a day, in the background. Nothing is downloaded or installed "
                            + "without a person saying yes to it first — this is a board people "
                            + "leave open for days, and an app that replaced itself under a "
                            + "running session would take the session's window with it."
                    )
                    .font(AuspexType.caption)
                    .foregroundStyle(AuspexPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
            .toggleStyle(.checkbox)
            .disabled(!updates.isActive)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(SettingsCard())
    }

    private var note: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let feed = updates.feedURLString {
                Text("Feed: \(feed)")
                    .font(AuspexType.monoSmall)
                    .foregroundStyle(AuspexPalette.textTertiary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(
                "The channel is kept in ~/.auspex/settings.json. Whether to check on a "
                    + "schedule is Sparkle's own setting and lives in the app's defaults, "
                    + "because a second copy of it here would be a second answer to the "
                    + "same question."
            )
            .font(AuspexType.caption)
            .foregroundStyle(AuspexPalette.textTertiary)
            .fixedSize(horizontal: false, vertical: true)

            if let error = catalog.saveErrorDescription {
                Text("The channel is in effect, but could not be saved: \(error)")
                    .font(AuspexType.caption)
                    .foregroundStyle(AuspexPalette.statePermission)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
