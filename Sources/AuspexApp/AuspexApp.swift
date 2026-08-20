import AgentSessionKit
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

    @State private var environment = AppEnvironment.launched()

    /// What the menu item says. It toggles, so it names what pressing it
    /// would do rather than where the reader already is.
    private var trajectoryCommandTitle: String {
        environment.board.viewMode == .trajectory
            ? "Close Trajectory"
            : "Open Trajectory"
    }

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
        // A menu item and not a hidden button with a shortcut on it. The
        // shortcut has to work from the board — which is where a person is
        // when they want the trajectory — and a binding that only exists
        // inside the mode it opens can only ever close it. A menu item is
        // also the one place on macOS where a shortcut is discoverable.
        .commands {
            CommandGroup(after: .toolbar) {
                Button(trajectoryCommandTitle) {
                    if environment.board.viewMode == .trajectory {
                        environment.board.closeTrajectory()
                    } else {
                        environment.board.openTrajectory()
                    }
                }
                .keyboardShortcut("t", modifiers: .command)
                .disabled(!environment.board.canOpenTrajectory)
            }
        }

        Settings {
            AuspexSettingsView(
                library: SpriteLibrary.shared,
                catalog: environment.catalog,
                setup: environment.setup,
                detected: environment.harnesses.detected,
                socketPath: environment.mcp?.socketPath
            )
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

/// The menu bar's title: the bird, and the counts that matter.
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
        // The board's own order: what is stuck on me, what finished while I
        // was elsewhere, what is in flight, what is sitting open. The menu bar
        // and the header answer the same questions in the same sequence, so
        // one glance teaches the other.
        HStack(spacing: 3) {
            if let mark = MenuBarLabel.templateMark {
                Image(nsImage: mark)
            } else {
                Image(systemName: "bird.fill")
            }
            if summary.needsYou > 0 {
                Image(systemName: "exclamationmark.triangle.fill")
                Text("\(summary.needsYou)")
            }
            if summary.doneUnseen > 0 {
                Image(systemName: "checkmark.circle")
                Text("\(summary.doneUnseen)")
            }
            if summary.working > 0 {
                Image(systemName: "play.fill")
                Text("\(summary.working)")
            }
            if summary.idle > 0 {
                Image(systemName: "hourglass")
                Text("\(summary.idle)")
            }
        }
        .accessibilityLabel(accessibilityLabel(summary))
    }

    /// The menu bar glyph: the bird as a template image, so the system tints
    /// it for light and dark menu bars the way it tints every other status
    /// item. 18 × 18 pt, from `Resources/MenuBar/menubar.pdf`.
    nonisolated(unsafe) static let templateMark: NSImage? = {
        guard let url = Bundle.module.url(forResource: "menubar-template", withExtension: "pdf", subdirectory: "Brand"),
              let image = NSImage(contentsOf: url) else { return nil }
        image.isTemplate = true
        image.size = NSSize(width: 18, height: 18)
        return image
    }()

    private func accessibilityLabel(_ summary: BoardSummary) -> String {
        var parts = ["Auspex"]
        if summary.needsYou > 0 { parts.append("\(summary.needsYou) needs you") }
        if summary.doneUnseen > 0 { parts.append("\(summary.doneUnseen) done unseen") }
        if summary.working > 0 { parts.append("\(summary.working) working") }
        if summary.idle > 0 { parts.append("\(summary.idle) idle") }
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
        let board = environment.board
        let seenAt = board.seenAt
        // Live sessions, plus the finished ones nobody has read. A session
        // that ended and was looked at is history and belongs on the board's
        // collapsed section; one that ended and was not is the errand this
        // panel exists to hand over.
        // Notices are the fourth reason a session belongs here, beside live,
        // blocked and unread: an agent that called for a person is the single
        // most urgent thing this panel can show.
        let notices = board.notices
        let sessions = TaskLedger.sorted(
            board.board.sessions.filter {
                TaskLedger.wantsAttention(
                    $0, lastSeenAt: seenAt[$0.key], notice: notices[$0.key]
                )
            },
            seenAt: seenAt,
            notices: notices
        )
        let summary = board.summary

        VStack(alignment: .leading, spacing: 2) {
            header(count: summary.live, needsYou: summary.needsYou, doneUnseen: summary.doneUnseen)

            if sessions.isEmpty {
                Text(environment.mode == .demo ? "Demo starting…" : "No live sessions")
                    .font(AuspexType.body)
                    .foregroundStyle(AuspexPalette.text3)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
            } else {
                ForEach(sessions.prefix(Self.listLimit), id: \.key) { session in
                    MenuBarRow(
                        session: session,
                        isUnseenDone: TaskLedger.isUnseenDone(
                            session, lastSeenAt: seenAt[session.key]
                        ),
                        notice: notices[session.key]
                    ) { open(session.key) }
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

    private func header(count: Int, needsYou: Int, doneUnseen: Int) -> some View {
        HStack(spacing: 8) {
            Text("Live")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(AuspexPalette.text)
            Text("\(count)")
                .font(AuspexType.monoCount)
                .auspexTabularDigits()
                .foregroundStyle(AuspexPalette.text3)
            Spacer(minLength: 4)
            if doneUnseen > 0 {
                HStack(spacing: 5) {
                    StateDot(color: AuspexPalette.stateWriting.opacity(0.8), glows: false)
                    Text("\(doneUnseen) done unseen")
                        .font(AuspexType.caption)
                        .foregroundStyle(AuspexPalette.stateWriting.opacity(0.8))
                }
            }
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
    var isUnseenDone = false
    /// What the agent itself said, when it called. It replaces the inferred
    /// subtitle: a sentence somebody wrote on purpose beats one Auspex
    /// assembled out of a state and a project name.
    var notice: AgentNotice?
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
                if isUnseenDone, notice == nil { UnseenDot() }
                if let notice, notice.kind.wantsPerson {
                    NoticePill(kind: notice.kind)
                } else {
                    StatePill(state: session.state, isStale: session.isStale)
                        .fixedSize()
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 40)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("\(session.key.harness.displayName) — \(session.state.label)")
    }

    /// What the harness called it, or what it was told to do. A project name
    /// is the last resort: on a machine with four sessions in one checkout it
    /// is the same row four times.
    private var title: String {
        if let title = session.identity.title, !title.isEmpty { return title }
        if let task = session.brief.firstPrompt, !task.isEmpty { return task }
        return BoardGrouping.projectName(for: session) ?? session.key.sessionID
    }

    /// What it last said, or failing that where it is and what it is doing.
    ///
    /// The reply first, because this panel is read to decide whether to open
    /// the window — and "two of them are not in the changelog" decides that,
    /// while "storefront-web · idle" does not.
    private var subtitle: String {
        if let notice { return notice.message }
        if isUnseenDone, let said = session.brief.latestAssistant, !said.isEmpty {
            return said
        }
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
