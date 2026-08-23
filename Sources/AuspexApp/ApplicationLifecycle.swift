import AppKit
import CoreServices

/// Reads the launch Apple event instead of guessing from argv or time of day.
/// LaunchServices puts `keyAELaunchedAsLogInItem` on `kAEOpenApplication`
/// specifically so an app can avoid opening an untitled/main window at login.
enum ApplicationLaunchContext {
    static func isLoginItem(_ event: NSAppleEventDescriptor?) -> Bool {
        event?.paramDescriptor(forKeyword: AEKeyword(keyAELaunchedAsLogInItem)) != nil
    }
}

/// The AppKit seam around SwiftUI's initial WindowGroup.
///
/// `applicationShouldOpenUntitledFile` is the platform's supported veto for a
/// login-item launch. The `applicationDidFinishLaunching` hide is deliberately
/// defensive: it covers a future SwiftUI lifecycle change without relying on
/// a private environment variable or making every launch background-only.
@MainActor
final class AuspexApplicationDelegate: NSObject, NSApplicationDelegate {
    private(set) var launchedAsLoginItem = false

    func applicationWillFinishLaunching(_ notification: Notification) {
        captureLaunchContext()
    }

    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool {
        captureLaunchContext()
        return !launchedAsLoginItem
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        captureLaunchContext()
        guard launchedAsLoginItem else { return }

        // Menu-bar-only until the person asks to see the board. No focus is
        // stolen at login, and no extra helper or entitlement is involved.
        NSApp.setActivationPolicy(.accessory)
        for window in NSApp.windows where window.canBecomeMain {
            window.orderOut(nil)
        }
    }

    private func captureLaunchContext() {
        guard !launchedAsLoginItem else { return }
        launchedAsLoginItem = ApplicationLaunchContext.isLoginItem(
            NSAppleEventManager.shared().currentAppleEvent
        )
    }
}

@MainActor
enum ApplicationPresence {
    /// A login launch deliberately uses accessory policy. The first explicit
    /// "Open Auspex" gesture returns it to an ordinary foreground Mac app.
    static func prepareToShowMainWindow() {
        if NSApp.activationPolicy() == .accessory {
            NSApp.setActivationPolicy(.regular)
        }
        NSApp.activate(ignoringOtherApps: true)
    }
}
