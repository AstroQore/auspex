import AgentSessionLive
import AppKit
import AuspexCore
import SwiftUI

/// The Auspex application.
///
/// A main window with the board, and a menu bar extra that keeps the counts
/// reachable while the window is closed — which is the normal case for this
/// app. A person does not sit and watch the board; they glance at the menu bar
/// and open the window when something is blocked.
struct AuspexApp: App {
    static let mainWindowID = "auspex.main"

    @State private var environment = AppEnvironment(mode: AppLaunchOptions.current().mode)

    var body: some Scene {
        WindowGroup(id: Self.mainWindowID) {
            RootView()
                .environment(environment)
                .frame(minWidth: 900, minHeight: 520)
                .preferredColorScheme(nil)
        }
        .defaultSize(width: 1_440, height: 900)
        .windowToolbarStyle(.unified(showsTitle: true))

        MenuBarExtra {
            MenuBarContent(environment: environment)
        } label: {
            MenuBarLabel(board: environment.board)
        }
    }
}

/// The menu bar's title: an eye, and the counts that matter.
///
/// Three numbers at most, and only the non-zero ones — live, delegating,
/// blocked. A status item that always shows `0 0 0` teaches its reader to stop
/// looking at it, which defeats the point of having one.
///
/// Symbols rather than colour: the menu bar renders its label as a template
/// image, so colour would be flattened away. The exclamation mark carries the
/// urgency on its own.
struct MenuBarLabel: View {
    let board: LiveBoardModel

    var body: some View {
        let counts = board.board.counts
        HStack(spacing: 3) {
            Image(systemName: "eye")
            if counts.live > 0 {
                Text("\(counts.live)")
            }
            if counts.delegating > 0 {
                Image(systemName: "arrow.triangle.branch")
                Text("\(counts.delegating)")
            }
            if counts.waitingPermission > 0 {
                Image(systemName: "exclamationmark.triangle.fill")
                Text("\(counts.waitingPermission)")
            }
        }
        .accessibilityLabel(accessibilityLabel(counts))
    }

    private func accessibilityLabel(_ counts: BoardSnapshot.Counts) -> String {
        var parts = ["Auspex"]
        if counts.live > 0 { parts.append("\(counts.live) live") }
        if counts.delegating > 0 { parts.append("\(counts.delegating) delegating") }
        if counts.waitingPermission > 0 {
            parts.append("\(counts.waitingPermission) waiting for permission")
        }
        return parts.joined(separator: ", ")
    }
}

/// Contents of the menu bar extra's menu.
///
/// The live sessions, most urgent first, each one a button that opens the
/// window onto that session. That is the whole job: the menu bar answers
/// *is anything stuck*, and clicking answers *what is it stuck on*.
struct MenuBarContent: View {
    let environment: AppEnvironment
    @Environment(\.openWindow) private var openWindow

    /// Long enough to be useful, short enough that the menu never scrolls.
    private static let listLimit = 12

    var body: some View {
        let sessions = environment.board.board.sessions.filter { !$0.state.isEnded }

        if sessions.isEmpty {
            Text(environment.mode == .demo ? "Demo starting…" : "No live sessions")
        } else {
            ForEach(sessions.prefix(Self.listLimit), id: \.key) { session in
                Button {
                    open(session.key)
                } label: {
                    // The mark *and* the full name. A menu draws its images as
                    // monochrome templates, so two harnesses that share a
                    // vendor mark are indistinguishable here without the name —
                    // and a menu row that could not be copied out as readable
                    // text would be worse than a slightly long one.
                    Label {
                        Text(
                            "\(session.key.harness.displayName)  ·  "
                                + "\(menuTitle(for: session))  ·  \(session.state.label)"
                        )
                    } icon: {
                        HarnessLogo.image(for: session.key.harness, size: 16)
                            ?? HarnessLogo.fallback(for: session.key.harness)
                    }
                }
            }
            if sessions.count > Self.listLimit {
                Text("and \(sessions.count - Self.listLimit) more")
            }
        }

        Divider()

        Button("Open Auspex") { open(nil) }
            .keyboardShortcut("o")

        Divider()

        Button("Quit Auspex") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q")
    }

    private func menuTitle(for session: SessionSnapshot) -> String {
        if let title = session.identity.title, !title.isEmpty {
            return title.count > 44 ? String(title.prefix(43)) + "…" : title
        }
        return BoardGrouping.projectName(for: session) ?? session.key.sessionID
    }

    private func open(_ key: SessionKey?) {
        if let key { environment.board.selectedKey = key }
        NSApplication.shared.activate(ignoringOtherApps: true)
        openWindow(id: AuspexApp.mainWindowID)
    }
}
