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

    var body: some View {
        let resume = SessionHandoff.resume(for: identity)
        let directory = SessionHandoff.workingDirectory(for: identity)

        Group {
            switch resume {
            case let .available(command, shellLine):
                Button("Resume in Terminal") {
                    SessionActions.resumeInTerminal(shellLine: shellLine)
                }
                .help("Copies the command and opens Terminal running it")
                Button("Copy resume command") {
                    SessionActions.copy(command)
                }
            case let .unavailable(reason):
                Button("Resume in Terminal") {}
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
        }
    }
}

/// The side-effecting half of the handoff.
///
/// Every string it uses is built by ``SessionHandoff`` in Core, where the
/// quoting is tested. What is left here is the three system calls that cannot
/// be: the pasteboard, an AppleScript, and `NSWorkspace`.
enum SessionActions {
    /// The editor shim on this machine, found once.
    ///
    /// Once, because it is a `stat` of four paths and the answer does not
    /// change while the app runs — and because a context menu is built on
    /// every right-click, which is not a place to go to the filesystem.
    static let editor: SessionHandoff.Editor? = SessionHandoff.detectEditor()

    /// Copies the resume command and opens Terminal running it.
    ///
    /// Both, not either. The clipboard is what makes this useful to somebody
    /// who lives in iTerm, Ghostty, or a tmux session — Terminal.app is the
    /// only terminal macOS guarantees, and it is the only one this can drive
    /// without guessing.
    static func resumeInTerminal(shellLine: String) {
        copy(shellLine)
        let script = SessionHandoff.terminalScript(shellLine: shellLine)
        guard let appleScript = NSAppleScript(source: script) else { return }
        var error: NSDictionary?
        appleScript.executeAndReturnError(&error)
        // A failure here is almost always the automation permission prompt
        // being declined, and the command is already on the clipboard — which
        // is the outcome the person can act on either way. Nothing is logged:
        // the script carries a working directory, and a path is exactly what
        // the house rules keep out of log lines.
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
