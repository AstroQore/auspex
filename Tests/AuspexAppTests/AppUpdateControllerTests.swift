import AppKit
import AuspexCore
import Foundation
import SwiftUI
import Testing

@testable import AuspexApp

/// The updater's inert path — which is every path this test process can reach,
/// and that is the point.
///
/// Sparkle replaces the running application. A test run, a `swift run` binary,
/// and a `--demo` launch must all be incapable of starting one, and "incapable"
/// has to be a property of the code rather than of nobody having pressed the
/// button. So the assertions here are mostly about what does *not* happen.
@Suite("The updater, when there is nothing to update")
@MainActor
struct AppUpdateControllerTests {
    @Test("A fresh controller offers nothing and claims nothing")
    func inertByDefault() {
        let controller = AppUpdateController()
        #expect(!controller.isActive)
        #expect(!controller.canCheckForUpdates)
        #expect(controller.lastCheckDate == nil)
        #expect(controller.channel == .main)
    }

    @Test("A test process cannot start an updater, even when asked to")
    func aTestProcessNeverStartsSparkle() {
        // `enabled: true` is the live launch's argument. It still does not
        // activate here, because this process is not a packaged Auspex.app: no
        // bundle identifier to name the defaults domain and the install
        // target, and no feed URL to verify anything against. If this ever
        // starts passing, `swift test` has begun scheduling background update
        // checks on whoever ran it.
        let controller = AppUpdateController()
        controller.activate(channel: .dev, enabled: true)
        #expect(!controller.isActive)
        #expect(!controller.canCheckForUpdates)
        #expect(controller.feedURLString == nil)
        // The channel is still recorded: the pane shows what the person chose
        // whether or not there is an updater behind it.
        #expect(controller.channel == .dev)
    }

    @Test("A demo launch is refused activation even in a packaged app")
    func aDemoNeverStartsSparkle() {
        let controller = AppUpdateController()
        controller.activate(channel: .main, enabled: false)
        #expect(!controller.isActive)
    }

    @Test("Checking with no updater behind it does nothing rather than trapping")
    func checkingIsSafeWhenInert() {
        let controller = AppUpdateController()
        controller.checkForUpdates()
        controller.setChecksAutomatically(true)
        #expect(!controller.isActive)
    }

    @Test("Switching the channel is remembered with or without an updater")
    func channelSwitching() {
        let controller = AppUpdateController()
        controller.setChannel(.dev)
        #expect(controller.channel == .dev)
        controller.setChannel(.dev)
        #expect(controller.channel == .dev)
        controller.setChannel(.main)
        #expect(controller.channel == .main)
    }

    @Test("The version the updater shows is the one Core reports")
    func versionMatchesCore() {
        // One string, not two. The menu bar row, the Settings pane and the MCP
        // `version` field all have to be quoting the same build.
        #expect(AppUpdateController().versionDescription == AuspexVersion.versionDescription)
    }

    /// The pane draws in exactly the situation a test process is in — no
    /// updater behind it — and that branch is the one nobody would open by
    /// hand. Hosting it and forcing a layout pass is the cheapest way to find
    /// out that its body evaluates in both appearances.
    ///
    /// `NSHostingView` rather than `ImageRenderer`: the pane is a `ScrollView`,
    /// and `ImageRenderer` hands one no layout pass, so it rasterises the
    /// background and none of the content — a test that would pass with an
    /// empty pane.
    @Test("The Updates pane draws in both appearances", arguments: [AppearanceMode.light, .dark])
    @MainActor
    func paneRenders(appearance: AppearanceMode) throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("auspex-updates-pane-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let catalog = ProjectCatalogModel(paths: AuspexPaths(homeDirectory: home), persists: false)

        // Touching AppKit at all requires the shared application to exist.
        _ = NSApplication.shared
        let host = NSHostingView(
            rootView: UpdatesSettingsView(catalog: catalog).auspexAppearance(appearance)
        )
        host.frame = NSRect(x: 0, y: 0, width: 660, height: 620)
        host.layoutSubtreeIfNeeded()
        let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        #expect(rep.pixelsWide > 0)
        #expect(rep.pixelsHigh > 0)
    }
}
