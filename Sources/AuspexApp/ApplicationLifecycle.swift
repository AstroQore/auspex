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

/// The foreground action for a second Finder/Dock open while the process is
/// still alive from a quiet login launch. Kept as values so the lifecycle
/// decision is testable without changing this Mac's activation policy.
enum ApplicationReopenPlan: Equatable {
    case appKitDefault
    case revealHiddenMainWindow
    case requestMainWindow

    static func resolve(
        isAccessory: Bool,
        hasHiddenMainWindow: Bool
    ) -> Self {
        guard isAccessory else { return .appKitDefault }
        return hasHiddenMainWindow ? .revealHiddenMainWindow : .requestMainWindow
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
    private var suppressesInitialMainWindow = false

    func applicationWillFinishLaunching(_ notification: Notification) {
        captureLaunchContext()
    }

    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool {
        captureLaunchContext()
        guard suppressesInitialMainWindow else { return true }
        // The veto belongs to the launch event, not to the lifetime of the
        // process. Keeping it set would make a later Finder/Dock open look as
        // though the person had never asked to see the app.
        suppressesInitialMainWindow = false
        return false
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
        suppressesInitialMainWindow = false
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows _: Bool
    ) -> Bool {
        let hiddenMainWindow = sender.windows.first {
            !$0.isVisible && $0.canBecomeMain && !($0 is NSPanel)
        }
        let plan = ApplicationReopenPlan.resolve(
            isAccessory: sender.activationPolicy() == .accessory,
            hasHiddenMainWindow: hiddenMainWindow != nil
        )

        switch plan {
        case .appKitDefault:
            return true
        case .revealHiddenMainWindow:
            launchedAsLoginItem = false
            ApplicationPresence.prepareToShowMainWindow(application: sender)
            hiddenMainWindow?.makeKeyAndOrderFront(nil)
            return false
        case .requestMainWindow:
            launchedAsLoginItem = false
            ApplicationPresence.prepareToShowMainWindow(application: sender)
            // Let AppKit/SwiftUI create the WindowGroup now that the one-shot
            // login-launch veto is gone.
            return true
        }
    }

    private func captureLaunchContext() {
        guard !launchedAsLoginItem else { return }
        let isLoginItem = ApplicationLaunchContext.isLoginItem(
            NSAppleEventManager.shared().currentAppleEvent
        )
        launchedAsLoginItem = isLoginItem
        suppressesInitialMainWindow = isLoginItem
    }
}

@MainActor
enum ApplicationPresence {
    /// A login launch deliberately uses accessory policy. The first explicit
    /// "Open Auspex" gesture returns it to an ordinary foreground Mac app.
    static func prepareToShowMainWindow(application: NSApplication = NSApp) {
        if application.activationPolicy() == .accessory {
            application.setActivationPolicy(.regular)
        }
        application.activate(ignoringOtherApps: true)
    }
}
