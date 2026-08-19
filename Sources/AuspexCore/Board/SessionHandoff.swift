import AgentSessionKit
import AgentSessionLive
import Foundation

/// How a person gets back to a session they were reminded of.
///
/// The board's last job. Once it has answered *what did I ask for* and *is it
/// finished*, the only thing left is *take me there* — and every harness
/// answers that differently, or not at all.
///
/// Everything here is **string construction**. Nothing spawns a process, opens
/// an application, or touches the clipboard; that belongs to the app layer,
/// behind a click. Keeping the construction in Core is what makes the quoting
/// testable, and the quoting is the part that matters: a working directory
/// comes off another tool's disk and ends up inside a shell command inside an
/// AppleScript string, which is two levels of escaping and two chances to turn
/// a path with an apostrophe in it into something that runs.
public enum SessionHandoff {
    // MARK: - Resume

    /// The shell line that reopens a session, or why there is none.
    ///
    /// Straight through to `AgentSessionLive`'s ``SessionResume``, which knows
    /// the per-harness answer. Wrapped here only so the app layer has one door
    /// for every handoff rather than importing the live layer for one of them.
    public static func resume(for identity: SessionIdentity) -> SessionResumeAvailability {
        SessionResume.availability(for: identity)
    }

    /// The AppleScript that opens Terminal.app on a shell line.
    ///
    /// Terminal.app specifically. macOS has no "default terminal" the way it
    /// has a default browser — no UTI, no `LSCopyDefaultApplication…` answer —
    /// so the choice is between the one terminal every Mac has and guessing
    /// from what is installed. A person who prefers another one still gets the
    /// command on the clipboard, which is why the app copies it as well as
    /// running it.
    ///
    /// `do script` with no `in` clause opens a new window, which is what a
    /// resumed session wants: dropping it into whatever tab happens to be
    /// front would interrupt whatever is running there.
    public static func terminalScript(shellLine: String) -> String {
        """
        tell application "Terminal"
            activate
            do script "\(appleScriptEscaped(shellLine))"
        end tell
        """
    }

    /// Escapes a string for the inside of an AppleScript double-quoted
    /// literal: backslashes first, then quotes.
    ///
    /// Order matters. Escaping quotes first would then escape the backslashes
    /// this step just added, doubling them.
    public static func appleScriptEscaped(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    // MARK: - Editors

    /// A command-line editor launcher found on this machine.
    public struct Editor: Hashable, Sendable {
        /// What to call it in a menu.
        public let name: String
        /// The absolute path to the executable.
        public let executablePath: String

        public init(name: String, executablePath: String) {
            self.name = name
            self.executablePath = executablePath
        }
    }

    /// The editors Auspex will offer to open a working directory in, in
    /// preference order.
    ///
    /// Only two, and both are the CLI shims their apps install deliberately.
    /// Auspex does not go looking through `/Applications`: an app being
    /// present is not consent to launch it, and a shim on the path is as close
    /// to "I use this from a terminal" as a machine can say.
    public static let knownEditors: [(name: String, executable: String)] = [
        ("Cursor", "cursor"),
        ("VS Code", "code")
    ]

    /// Where a GUI app has to look for a CLI shim.
    ///
    /// A launched-from-Finder process inherits a minimal `PATH` that contains
    /// none of these, so `which` would answer "no" on a machine that has both.
    /// The list is the two Homebrew prefixes and the two conventional local
    /// ones, and nothing else — Auspex will not run something out of a
    /// directory a person did not install it into.
    public static let editorSearchPaths = [
        "/opt/homebrew/bin",
        "/usr/local/bin",
        "/usr/bin",
        "/opt/local/bin"
    ]

    /// The first known editor whose shim is installed, or `nil`.
    public static func detectEditor(
        searchPaths: [String] = editorSearchPaths,
        isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) -> Editor? {
        for editor in knownEditors {
            for directory in searchPaths {
                let path = directory + "/" + editor.executable
                if isExecutable(path) {
                    return Editor(name: editor.name, executablePath: path)
                }
            }
        }
        return nil
    }

    // MARK: - Where the work is

    /// The directory a handoff should land in: the worktree the session is
    /// actually operating in, then its working directory, then the repository
    /// root.
    ///
    /// The worktree comes first because that is where the files a person is
    /// about to look at are. A session that entered `.agents/worktrees/feat-x`
    /// has a `cwd` of the worktree too, but a host that resolved the placement
    /// separately may know the worktree and not have seen the `cd`.
    public static func workingDirectory(for identity: SessionIdentity) -> String? {
        let candidates = [identity.worktreePath, identity.cwd, identity.gitRoot]
        return candidates.compactMap { $0 }.first { !$0.isEmpty }
    }
}
