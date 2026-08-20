import AgentSessionKit
import AgentSessionLive
import AppKit
import AuspexCore
import SwiftUI

/// The menu that gets a person back to a session.
///
/// Attached to a card's context menu and to the trace header's button, so the
/// two cannot offer different things. Every item is a click: nothing here runs
/// on hover, on selection, or on a frame — Auspex reads other tools' stores and
/// must never be the reason one of them starts.
///
/// A harness with no way back shows the item disabled with the reason beside
/// it, rather than hiding it. "Resume" quietly missing from one card and
/// present on the next is a thing a person notices and cannot explain; "Claude
/// Cowork sessions live inside Claude.app and have no command-line resume" is a
/// thing they read once.
struct SessionActionsMenu: View {
    let identity: SessionIdentity

    /// The control model, when this menu is being built somewhere that has
    /// one. `nil` in the offscreen renderers, which draw a session's chrome
    /// into a bitmap and must not offer to signal anything.
    var control: SessionControlModel?

    var body: some View {
        let resume = SessionHandoff.resume(for: identity)
        let directory = SessionHandoff.workingDirectory(for: identity)

        Group {
            switch resume {
            case let .available(command, shellLine):
                Button("Resume in \(SessionActions.terminal.name)") {
                    SessionActions.resume(shellLine: shellLine, directory: directory)
                }
                .help("Copies the command and opens \(SessionActions.terminal.name) running it")
                Button("Copy resume command") {
                    SessionActions.copy(command)
                }
            case let .unavailable(reason):
                Button("Resume in \(SessionActions.terminal.name)") {}
                    .disabled(true)
                    .help(reason)
                Text(reason)
                    .font(AuspexType.caption)
            }

            Divider()

            Button("Reveal working directory in Finder") {
                if let directory { SessionActions.reveal(directory) }
            }
            .disabled(directory == nil)
            .help(directory == nil ? "This session's store records no directory" : "")

            if let editor = SessionActions.editor, let directory {
                Button("Open in \(editor.name)") {
                    SessionActions.open(directory, in: editor)
                }
            }

            if let control {
                Divider()
                SessionSignalItems(identity: identity, control: control)
            }
        }
    }
}

/// The two items that act on the session's process.
///
/// Their own view so that the availability question — which reads a process
/// table — is asked once, when the menu opens, rather than once per item.
///
/// Both are disabled with the reason beside them when there is no process to
/// signal, for the same reason Resume is: a session with no pid is the common
/// case, not an error, and an item that quietly vanishes teaches nobody why.
private struct SessionSignalItems: View {
    let identity: SessionIdentity
    let control: SessionControlModel

    var body: some View {
        let availability = control.availability(for: identity)
        switch availability {
        case let .available(target):
            Button(SessionControl.Signal.interrupt.menuTitle) { control.interrupt(identity) }
                .help(SessionControl.interruptHelp(for: identity.key.harness, pid: target.pid))
            Button(SessionControl.Signal.terminate.menuTitle) { control.requestKill(identity) }
                .help("Asks first, then sends SIGTERM to pid \(target.pid)")
        case let .unavailable(reason):
            Button(SessionControl.Signal.interrupt.menuTitle) {}.disabled(true).help(reason)
            Button(SessionControl.Signal.terminate.menuTitle) {}.disabled(true).help(reason)
        }
    }
}

/// The side-effecting half of the handoff.
///
/// Every string it uses is built by ``SessionHandoff`` in Core, where the
/// quoting is tested. What is left here is the system calls that cannot be:
/// the pasteboard, an AppleScript, `NSWorkspace`, and one notification
/// observer.
@MainActor
enum SessionActions {
    /// The editor shim on this machine, found once.
    ///
    /// Once, because it is a `stat` of four paths and the answer does not
    /// change while the app runs — and because a context menu is built on
    /// every right-click, which is not a place to go to the filesystem.
    nonisolated static let editor: SessionHandoff.Editor? = SessionHandoff.detectEditor()

    /// The terminal a resume would open in right now.
    ///
    /// Read by the menu to name the item — "Resume in iTerm" rather than
    /// "Resume in Terminal" — because an item that says one terminal and opens
    /// another is worse than no item.
    static var terminal: SessionHandoff.Terminal { TerminalChoice.shared.current }

    /// Copies the resume command and opens it in the person's terminal.
    ///
    /// Both, not either. The clipboard is what makes this useful to somebody
    /// who lives in Ghostty, kitty, or a tmux session — and it is the whole of
    /// what a terminal with no scripting dictionary can be given, so the copy
    /// is not a courtesy, it is the mechanism.
    static func resume(shellLine: String, directory: String?) {
        copy(shellLine)
        let terminal = TerminalChoice.shared.current
        if let script = SessionHandoff.terminalScript(for: terminal, shellLine: shellLine) {
            run(script)
            return
        }
        // A terminal that cannot be told to run anything gets a window on the
        // right directory, with the command already on the clipboard. Where
        // even that is not possible — no directory recorded — Terminal.app
        // runs it, because a resume that does nothing at all is the one
        // outcome worth avoiding.
        if let url = SessionHandoff.terminalURL(for: terminal, directory: directory) {
            NSWorkspace.shared.open(url)
        } else {
            run(SessionHandoff.terminalScript(shellLine: shellLine))
        }
    }

    /// Runs an AppleScript, ignoring failure.
    ///
    /// A failure here is almost always the automation permission prompt being
    /// declined, and the command is already on the clipboard — which is the
    /// outcome the person can act on either way. Nothing is logged: the script
    /// carries a working directory, and a path is exactly what the house rules
    /// keep out of log lines.
    private static func run(_ source: String) {
        guard let appleScript = NSAppleScript(source: source) else { return }
        var error: NSDictionary?
        appleScript.executeAndReturnError(&error)
    }

    /// Puts a string on the general pasteboard.
    static func copy(_ value: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(value, forType: .string)
    }

    /// Selects a directory in Finder.
    static func reveal(_ path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    /// Opens a directory in the detected editor.
    ///
    /// Spawned with the directory as its only argument and no shell in
    /// between, so nothing in the path is ever interpreted.
    static func open(_ path: String, in editor: SessionHandoff.Editor) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: editor.executablePath)
        process.arguments = [path]
        try? process.run()
    }
}

/// Which terminal the person actually uses, worked out by watching.
///
/// macOS will not answer "what is the default terminal", so the honest way to
/// find out is to notice. Every time an application comes to the front, this
/// asks whether it is a terminal it knows; when it is, that is the answer from
/// then on. A person who has been in iTerm all morning gets iTerm, and nobody
/// had to be asked.
///
/// Asking which application is frontmost *at the moment of the click* would
/// only ever answer "Auspex", which is why this remembers instead of looking.
///
/// The installed set is the fallback and is read once: applications do not
/// appear while the app is running, and `NSWorkspace.urlForApplication` is a
/// Launch Services round trip that has no business happening inside a menu.
@MainActor
final class TerminalChoice {
    static let shared = TerminalChoice()

    /// The last known terminal that was in front, if one has been.
    private var lastUsed: String?

    private lazy var installed: Set<String> = Set(
        SessionHandoff.knownTerminals
            .map(\.bundleIdentifier)
            .filter { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) != nil }
    )

    private init() {
        // The one currently in front counts too: Auspex is usually launched
        // from a terminal, so at startup the answer is often already there.
        note(NSWorkspace.shared.frontmostApplication?.bundleIdentifier)
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            let bundleIdentifier = app?.bundleIdentifier
            MainActor.assumeIsolated { self?.note(bundleIdentifier) }
        }
    }

    /// The terminal a resume should open in.
    var current: SessionHandoff.Terminal {
        SessionHandoff.chooseTerminal(lastUsed: lastUsed) { installed.contains($0) }
    }

    private func note(_ bundleIdentifier: String?) {
        guard SessionHandoff.terminal(bundleIdentifier: bundleIdentifier) != nil else { return }
        lastUsed = bundleIdentifier
    }
}
