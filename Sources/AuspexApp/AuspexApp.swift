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
            // Where every Mac app keeps it: directly under "About Auspex", in
            // the application menu. A person looking for the version and a
            // person looking for the update are the same person, and this is
            // the first place they look.
            CommandGroup(after: .appInfo) {
                Button("Check for Updates\u{2026}") { environment.updates.checkForUpdates() }
                    .disabled(!environment.updates.canCheckForUpdates)
            }
            CommandGroup(after: .toolbar) {
                // The one shortcut this window did not have and every board of
                // this shape eventually grows: a field that reaches anything on
                // the frame by name, and does the two or three things that
                // otherwise need a right-click on a card you have to find
                // first. See ``CommandPalette``.
                Button("Go to Task\u{2026}") {
                    environment.board.isPaletteOpen.toggle()
                }
                .keyboardShortcut("k", modifiers: .command)
                Button("Open Task") {
                    guard let unit = environment.board.selectedUnit else { return }
                    environment.board.openUnitID = unit.id
                }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(environment.board.selectedUnit == nil)
                // ⇧⌘K is already Mark All as Seen, which is the attention
                // model's escape hatch and cannot move. Closing pairs with
                // opening instead, which is the more useful adjacency anyway.
                Button("Close Task") {
                    guard let unit = environment.board.selectedUnit, unit.isInReview else { return }
                    environment.tasks.close(unit: unit)
                }
                .keyboardShortcut(.return, modifiers: [.command, .shift])
                .disabled(environment.board.selectedUnit?.isInReview != true)
                Divider()
                Button(trajectoryCommandTitle) {
                    if environment.board.viewMode == .trajectory {
                        environment.board.closeTrajectory()
                    } else {
                        environment.board.openTrajectory()
                    }
                }
                .keyboardShortcut("t", modifiers: .command)
                .disabled(!environment.board.canOpenTrajectory)
                // The attention model's escape hatch, and it has to be
                // reachable at any window width. The header carries a button
                // for it too, but the header's chips are the first thing to
                // give way when the window narrows and the button goes with
                // them — a clearing gesture that only exists on a wide screen
                // is a clearing gesture people learn to do without, which
                // leaves a board of stale red.
                Button("Mark All as Seen") { environment.board.markAllSeen() }
                    .keyboardShortcut("k", modifiers: [.command, .shift])
                    .disabled(!environment.board.hasAttention)
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
            // The pane is flexible and the container picks a size — the board's
            // column gives it the whole column, and a settings *window* has to
            // be told, because a window with no content size of its own opens
            // at whatever AppKit last remembered.
            .frame(width: 660, height: 620)
            // The Settings window is its own scene and inherits nothing from
            // the main one, so a person who set Auspex to dark on a light Mac
            // would otherwise open a light Settings window to change it in.
            .auspexAppearance(environment.appearance)
        }

        MenuBarExtra {
            MenuBarContent(environment: environment)
                .auspexAppearance(environment.appearance)
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
            ForEach(Self.segments(summary), id: \.symbol) { segment in
                Image(systemName: segment.symbol)
                Text(verbatim: segment.count)
            }
        }
        .accessibilityLabel(Self.accessibilityLabel(summary))
    }

    /// The counts the status item actually shows, as values.
    ///
    /// A function rather than four `if`s in the body, so the one thing a person
    /// sees of this app when they are looking at something else can be
    /// asserted on without a menu bar. `idle` is last and `ended` is absent:
    /// the status item answers *is anything stuck* and *did anything finish*,
    /// and a number for history in the menu bar would be the smallest, most
    /// permanent piece of chrome on the screen quoting the least urgent thing
    /// on the board.
    static func segments(_ summary: BoardSummary) -> [(symbol: String, count: String)] {
        var segments: [(symbol: String, count: String)] = []
        if summary.needsYou > 0 {
            segments.append(("exclamationmark.triangle.fill", "\(summary.needsYou)"))
        }
        if summary.doneReported > 0 {
            segments.append(("checkmark.circle", "\(summary.doneReported)"))
        }
        if summary.working > 0 {
            segments.append(("play.fill", "\(summary.working)"))
        }
        if summary.idle > 0 {
            segments.append(("hourglass", "\(summary.idle)"))
        }
        return segments
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

    static func accessibilityLabel(_ summary: BoardSummary) -> String {
        var parts = ["Auspex"]
        if summary.needsYou > 0 { parts.append("\(summary.needsYou) needs you") }
        if summary.doneReported > 0 { parts.append("\(summary.doneReported) done") }
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
        // Live sessions, plus anything an agent has spoken about. A session
        // that ended quietly is history and belongs on the board's collapsed
        // section; one that filed a receipt or a question on its way out is the
        // errand this panel exists to hand over.
        let notices = board.notices
        let attention = board.attention
        let sessions = TaskLedger.sorted(
            board.board.sessions.filter {
                TaskLedger.wantsAttention($0, attention: attention[$0.key] ?? .none)
            },
            attention: attention,
            notices: notices
        )
        let summary = board.summary

        VStack(alignment: .leading, spacing: 2) {
            header(
                count: summary.live,
                needsYou: summary.needsYou,
                doneReported: summary.doneReported
            )

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
                        attention: attention[session.key] ?? .none,
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
            .buttonStyle(.auspex)
            // No shortcut, so the right-hand column carries the version
            // instead. The two questions a person has about an update — what
            // am I on, is there a newer one — are then answered by one row.
            Button { environment.updates.checkForUpdates() } label: {
                MenuBarCommandLabel(
                    title: "Check for Updates\u{2026}",
                    shortcut: environment.updates.versionDescription
                )
            }
            .buttonStyle(.auspex)
            .disabled(!environment.updates.canCheckForUpdates)
            MenuBarCommand(title: "Quit", key: "q", modifiers: .command) {
                NSApplication.shared.terminate(nil)
            }
        }
        .padding(8)
        .frame(width: 340)
        .background(AuspexPalette.bg1)
        // Hand-drawn rows, like the board's. The panel is not a menu, so
        // AppKit would ring whatever was clicked in it last.
        .auspexControlFocus()
    }

    private func header(count: Int, needsYou: Int, doneReported: Int) -> some View {
        HStack(spacing: 8) {
            Text("Live")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(AuspexPalette.text)
            Text("\(count)")
                .font(AuspexType.monoCount)
                .auspexTabularDigits()
                .foregroundStyle(AuspexPalette.text3)
            Spacer(minLength: 4)
            if doneReported > 0 {
                HStack(spacing: 5) {
                    Text(verbatim: "✓")
                        .font(.system(size: 10, weight: .black))
                        .foregroundStyle(AuspexPalette.stateWriting)
                    Text("\(doneReported) done")
                        .font(AuspexType.caption)
                        .foregroundStyle(AuspexPalette.stateWriting)
                }
            }
            if needsYou > 0 {
                HStack(spacing: 5) {
                    Text(verbatim: "!")
                        .font(.system(size: 10, weight: .black))
                        .foregroundStyle(AuspexPalette.statePermission)
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
    /// Whether a person has something to do about it, and why — the board's
    /// own answer, passed in rather than re-derived, so the panel and the wall
    /// cannot disagree about which sessions are asking.
    var attention: AttentionState = .none
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
                if attention.isSignalling {
                    AttentionBadge(attention: attention, size: 15)
                }
                if let notice, notice.kind.wantsPerson, attention.wantsPerson {
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
        .buttonStyle(.auspex)
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
        if let message = attention.message { return message }
        if let notice { return notice.message }
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
        .buttonStyle(.auspex)
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
