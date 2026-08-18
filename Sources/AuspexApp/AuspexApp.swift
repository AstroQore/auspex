import AppKit
import SwiftUI

/// The Auspex application.
///
/// A main window with the eventual navigation shape, plus a menu bar extra so
/// the app stays reachable while the window is closed. Deliberately plain:
/// visual design is a later milestone.
struct AuspexApp: App {
    static let mainWindowID = "auspex.main"

    @State private var environment = AppEnvironment()

    var body: some Scene {
        WindowGroup(id: Self.mainWindowID) {
            RootView()
                .environment(environment)
                .frame(minWidth: 720, minHeight: 420)
        }
        .defaultSize(width: 1_040, height: 640)

        MenuBarExtra("Auspex", systemImage: "eye") {
            MenuBarContent()
        }
    }
}

/// Contents of the menu bar extra's menu.
///
/// Its own view so it can pull `openWindow` out of the environment —
/// `MenuBarExtra`'s trailing closure is a view builder, not a scene builder,
/// so environment values are available here but not on `AuspexApp` itself.
struct MenuBarContent: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Open Auspex") {
            NSApplication.shared.activate(ignoringOtherApps: true)
            openWindow(id: AuspexApp.mainWindowID)
        }
        .keyboardShortcut("o")

        Divider()

        Button("Quit Auspex") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q")
    }
}
