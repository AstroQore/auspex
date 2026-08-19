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
///
/// The Settings window is a third scene rather than a page inside the main
/// window. Everything in it is about the *app* — which character each harness
/// wears, where packages come from — and none of it is about the board a person
/// is watching, so it does not belong in a column that would push the board
/// aside to show it.
struct AuspexApp: App {
    static let mainWindowID = "auspex.main"

    @State private var environment = AppEnvironment(mode: AppLaunchOptions.current().mode)

    var body: some Scene {
        WindowGroup(id: Self.mainWindowID) {
            RootView()
                .environment(environment)
                .frame(minWidth: 960, minHeight: 560)
                // The office reads character packages out of
                // `~/.auspex/characters/`, and a person dropping one in expects
                // the room to change, not to be told to relaunch.
                .task { SpriteLibrary.shared.startWatching() }
        }
        .defaultSize(width: 1_440, height: 900)
        // The window's own heading lives in the board's header bar, where it
        // can carry the counts beside it. A title bar that repeated it would
        // be two headings for one screen.
        .windowToolbarStyle(.unified(showsTitle: false))

        Settings {
            AuspexSettingsView(library: SpriteLibrary.shared)
        }

        MenuBarExtra {
            MenuBarContent(environment: environment)
                .preferredColorScheme(.dark)
        } label: {
            MenuBarLabel(board: environment.board)
        }
        // A window rather than a menu. An `NSMenu` draws its images as
        // monochrome templates and its rows as system rows, so two harnesses
        // that share a vendor mark are indistinguishable in it and a state
        // pill is impossible — which throws away the two things this list
        // exists to show.
        .menuBarExtraStyle(.window)
    }
}

/// The menu bar's title: an eye, and the counts that matter.
///
/// Three numbers at most, and only the non-zero ones. A status item that always
/// shows `0 0 0` teaches its reader to stop looking at it, which defeats the
/// point of having one.
///
/// Symbols rather than colour: the menu bar renders its label as a template
/// image, so colour would be flattened away. The exclamation mark carries the
/// urgency on its own.
struct MenuBarLabel: View {
    let board: LiveBoardModel

    var body: some View {
        let summary = board.summary
        HStack(spacing: 3) {
            Image(systemName: "eye")
            if summary.working > 0 {
                Image(systemName: "play.fill")
                Text("\(summary.working)")
            }
            if summary.idle > 0 {
                Image(systemName: "hourglass")
                Text("\(summary.idle)")
            }
            if summary.needsYou > 0 {
                Image(systemName: "exclamationmark.triangle.fill")
                Text("\(summary.needsYou)")
            }
        }
        .accessibilityLabel(accessibilityLabel(summary))
    }

    private func accessibilityLabel(_ summary: BoardSummary) -> String {
        var parts = ["Auspex"]
        if summary.working > 0 { parts.append("\(summary.working) working") }
        if summary.idle > 0 { parts.append("\(summary.idle) idle") }
        if summary.needsYou > 0 { parts.append("\(summary.needsYou) needs you") }
        if parts.count == 1 { parts.append("nothing running") }
        return parts.joined(separator: ", ")
    }
}

/// The menu bar extra's panel.
///
/// The live sessions, most urgent first, each one a button that opens the
/// window onto that session. That is the whole job: the menu bar answers
/// *is anything stuck*, and clicking answers *what is it stuck on*.
struct MenuBarContent: View {
    let environment: AppEnvironment
    @Environment(\.openWindow) private var openWindow

    /// Long enough to be useful, short enough that the panel never scrolls
    /// past the bottom of a laptop screen.
    private static let listLimit = 10

    var body: some View {
        let sessions = environment.board.board.sessions.filter { !$0.state.isEnded }
        let summary = environment.board.summary

        VStack(alignment: .leading, spacing: 2) {
            header(count: summary.live, needsYou: summary.needsYou)

            if sessions.isEmpty {
                Text(environment.mode == .demo ? "Demo starting…" : "No live sessions")
                    .font(AuspexType.body)
                    .foregroundStyle(AuspexPalette.text3)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
            } else {
                ForEach(sessions.prefix(Self.listLimit), id: \.key) { session in
                    MenuBarRow(session: session) { open(session.key) }
                }
                if sessions.count > Self.listLimit {
                    Text("and \(sessions.count - Self.listLimit) more")
                        .font(AuspexType.caption)
                        .foregroundStyle(AuspexPalette.text3)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                }
            }

            Divider().overlay(AuspexPalette.line).padding(.vertical, 6)

            MenuBarCommand(title: "Open Auspex", key: "a", modifiers: [.command, .shift]) {
                open(nil)
            }
            // The one window that is not the board still has to be reachable
            // from here: the menu bar is where this app is used from.
            SettingsLink {
                MenuBarCommandLabel(title: "Settings\u{2026}", shortcut: "\u{2318},")
            }
            .buttonStyle(.plain)
            MenuBarCommand(title: "Quit", key: "q", modifiers: .command) {
                NSApplication.shared.terminate(nil)
            }
        }
        .padding(8)
        .frame(width: 340)
        .background(AuspexPalette.bg1)
    }

    private func header(count: Int, needsYou: Int) -> some View {
        HStack(spacing: 8) {
            Text("Live")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(AuspexPalette.text)
            Text("\(count)")
                .font(AuspexType.monoCount)
                .auspexTabularDigits()
                .foregroundStyle(AuspexPalette.text3)
            Spacer(minLength: 4)
            if needsYou > 0 {
                HStack(spacing: 5) {
                    StateDot(color: AuspexPalette.statePermission, glows: true)
                    Text(needsYou == 1 ? "1 needs you" : "\(needsYou) needs you")
                        .font(AuspexType.caption)
                        .foregroundStyle(AuspexPalette.statePermission)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 10)
    }

    private func open(_ key: SessionKey?) {
        if let key { environment.board.selectedKey = key }
        NSApplication.shared.activate(ignoringOtherApps: true)
        openWindow(id: AuspexApp.mainWindowID)
    }
}

/// One live session in the menu bar panel.
///
/// The mark *and* the full name of what it is doing. Two harnesses that share
/// a vendor mark are told apart by the accent behind it, exactly as they are on
/// the board — which is the point of the panel being a window rather than a
/// menu.
private struct MenuBarRow: View {
    let session: SessionSnapshot
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                HarnessBadge(harness: session.key.harness, size: 18)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(AuspexPalette.text)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Text(subtitle)
                        .font(AuspexType.monoSmall)
                        .foregroundStyle(AuspexPalette.text3)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 6)
                StatePill(state: session.state, isStale: session.isStale)
                    .fixedSize()
            }
            .padding(.horizontal, 12)
            .frame(height: 40)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("\(session.key.harness.displayName) — \(session.state.label)")
    }

    private var title: String {
        if let title = session.identity.title, !title.isEmpty { return title }
        return BoardGrouping.projectName(for: session) ?? session.key.sessionID
    }

    /// Where it is, and what it is doing right now — the two facts that fit
    /// under a title at this width.
    private var subtitle: String {
        var parts: [String] = []
        if let project = BoardGrouping.projectName(for: session) { parts.append(project) }
        if let activity = session.state.activityDescription {
            parts.append(activity)
        } else if session.state.isEnded {
            parts.append("ended")
        }
        return parts.isEmpty ? session.key.sessionID : parts.joined(separator: " · ")
    }
}

/// How a command at the bottom of the panel looks.
///
/// Its own view because `SettingsLink` builds its own button and only takes a
/// label — so the row that opens Settings and the rows beside it would
/// otherwise be two different shapes.
private struct MenuBarCommandLabel: View {
    let title: String
    let shortcut: String

    var body: some View {
        HStack {
            Text(title)
                .font(AuspexType.row)
                .foregroundStyle(AuspexPalette.text2)
            Spacer(minLength: 8)
            Text(shortcut)
                .font(AuspexType.monoSmall)
                .foregroundStyle(AuspexPalette.text3)
        }
        .padding(.horizontal, 12)
        .frame(height: 26)
        .contentShape(Rectangle())
    }
}

/// A command at the bottom of the panel: a word and its shortcut.
private struct MenuBarCommand: View {
    let title: String
    let key: KeyEquivalent
    let modifiers: EventModifiers
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            // Written out from the binding rather than typed in beside it, so
            // a shortcut that changes cannot leave a label claiming the old
            // one.
            MenuBarCommandLabel(
                title: title,
                shortcut: Self.describe(key: key, modifiers: modifiers)
            )
        }
        .buttonStyle(.plain)
        .keyboardShortcut(key, modifiers: modifiers)
    }

    static func describe(key: KeyEquivalent, modifiers: EventModifiers) -> String {
        var text = ""
        if modifiers.contains(.control) { text += "⌃" }
        if modifiers.contains(.option) { text += "⌥" }
        if modifiers.contains(.shift) { text += "⇧" }
        if modifiers.contains(.command) { text += "⌘" }
        return text + String(key.character).uppercased()
    }
}
