import AuspexCore
import Foundation
import Observation
import Sparkle

/// Owns Sparkle's updater and the small amount of state the app's surfaces
/// show about it.
///
/// ## Why there is one of these and it is shared
///
/// Sparkle's updater is a process-wide thing: it owns a scheduled check, a
/// download, and — at the end — a helper that replaces the running app. Two of
/// them in one process is two schedulers racing for the same bundle. The app
/// scene, the menu bar panel and the Settings pane all need to reach it, and
/// the Settings window is its own scene that inherits nothing from the main
/// one, so a shared instance is what keeps them describing the same updater
/// rather than three.
///
/// ## Why it can be inert
///
/// Nothing here starts unless the process is a properly configured `.app` and
/// the launch is a real one. A `swift run` binary has no `Info.plist`, so
/// Sparkle has no feed, no public key and no bundle to replace. A `--demo`
/// launch reads nothing and writes nothing by contract, and a background
/// update check writes a timestamp into the app's defaults — small, but it is
/// still a write the demo promised not to make. Both cases get a controller
/// that answers every question honestly and does nothing.
@MainActor
@Observable
final class AppUpdateController: NSObject, SPUUpdaterDelegate {
    /// The one updater in this process.
    static let shared = AppUpdateController()

    /// Whether "Check for Updates…" would do anything right now — false while
    /// a check or an install is already in flight, and false forever in a
    /// build with no feed behind it.
    private(set) var canCheckForUpdates = false

    /// When Sparkle last asked the feed, or `nil` if it never has.
    private(set) var lastCheckDate: Date?

    /// Whether the daily background check is on.
    private(set) var checksAutomatically = false

    /// Which release stream the feed is filtered to.
    private(set) var channel: UpdateChannel = .standard

    /// Whether there is a real updater behind this object.
    private(set) var isActive = false

    /// What the version row says: `0.1.0 (7)`.
    var versionDescription: String { AuspexVersion.versionDescription }

    /// Where the feed is read from, for the pane's footnote. `nil` outside a
    /// packaged build.
    var feedURLString: String? {
        Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String
    }

    private var updaterController: SPUStandardUpdaterController?
    private var canCheckObservation: NSKeyValueObservation?

    /// Use ``shared``. This exists so the inert path can be tested without a
    /// process-wide singleton the next test would inherit — building a second
    /// one and never activating it costs nothing, and two *activated* ones
    /// cannot happen because activation needs a packaged bundle.
    override init() {
        super.init()
    }

    /// Starts the updater, once, if this build can have one.
    ///
    /// Idempotent, and safe to call from a launch that should not update: it
    /// returns having changed nothing rather than leaving a half-started
    /// updater whose scheduled check fires later anyway.
    func activate(channel: UpdateChannel, enabled: Bool) {
        self.channel = channel
        guard !isActive, enabled, Self.isPackagedForUpdates else { return }

        let controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: self,
            userDriverDelegate: nil
        )
        updaterController = controller
        isActive = true
        checksAutomatically = controller.updater.automaticallyChecksForUpdates
        lastCheckDate = controller.updater.lastUpdateCheckDate
        // `canCheckForUpdates` flips off for the length of a check and back on
        // after it, which is exactly what the button's disabled state wants —
        // and it is the one piece of Sparkle state that is KVO-observable, so
        // it is read that way rather than polled.
        canCheckObservation = controller.updater.observe(
            \.canCheckForUpdates,
            options: [.initial, .new]
        ) { [weak self] updater, _ in
            MainActor.assumeIsolated {
                self?.canCheckForUpdates = updater.canCheckForUpdates
            }
        }
    }

    /// Asks the feed now, and shows Sparkle's own dialog for whatever comes
    /// back — including "you are up to date", which is the answer a person who
    /// pressed this button is owed.
    func checkForUpdates() {
        guard let updaterController else { return }
        updaterController.checkForUpdates(nil)
    }

    /// Switches the stream, and tells Sparkle to look again.
    ///
    /// The reset is the point: without it, somebody who switched to the
    /// preview stream would sit on the old build until tomorrow's scheduled
    /// check, having been shown a picker that appeared to do nothing.
    func setChannel(_ channel: UpdateChannel) {
        guard self.channel != channel else { return }
        self.channel = channel
        updaterController?.updater.resetUpdateCycleAfterShortDelay()
    }

    /// Turns the daily background check on or off.
    ///
    /// Sparkle stores this in the app's own defaults, not in `settings.json`:
    /// it is Sparkle's setting, Sparkle's Info.plist default seeds it, and a
    /// second copy in our file would be a second answer to the same question.
    func setChecksAutomatically(_ on: Bool) {
        checksAutomatically = on
        updaterController?.updater.automaticallyChecksForUpdates = on
    }

    // MARK: - SPUUpdaterDelegate

    /// Stable is Sparkle's untagged default channel, which it always
    /// considers. Dev *adds* the `dev` tag on top, so a preview user still
    /// receives a newer stable release. See ``UpdateChannel``.
    func allowedChannels(for updater: SPUUpdater) -> Set<String> {
        channel.additionalSparkleChannels
    }

    func updater(
        _ updater: SPUUpdater,
        didFinishUpdateCycleFor updateCheck: SPUUpdateCheck,
        error: (any Error)?
    ) {
        lastCheckDate = updater.lastUpdateCheckDate
        checksAutomatically = updater.automaticallyChecksForUpdates
    }

    // MARK: - Whether this build can update itself

    /// True only for a real `Auspex.app` carrying a feed URL.
    ///
    /// Both halves matter. The bundle identifier is what Sparkle names the
    /// defaults domain and the installer target by, and a `swift run` binary
    /// inherits whatever identifier the launching process had. The feed URL is
    /// what says this bundle was packaged by `build_app.sh` from the real
    /// `Info.plist` rather than assembled by hand.
    private static var isPackagedForUpdates: Bool {
        let bundle = Bundle.main
        guard bundle.bundleIdentifier == AuspexVersion.bundleIdentifier else { return false }
        guard let feed = bundle.object(forInfoDictionaryKey: "SUFeedURL") as? String,
              !feed.isEmpty
        else { return false }
        return true
    }
}
