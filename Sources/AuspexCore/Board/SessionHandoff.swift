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

    // MARK: - Which terminal

    /// A terminal emulator Auspex knows how to open a command in.
    ///
    /// macOS has no "default terminal" the way it has a default browser — no
    /// UTI, no `LSCopyDefaultApplication…` answer — so there is nothing to
    /// ask. What is left is knowing a handful of them by name, and the
    /// clipboard for everyone else.
    public struct Terminal: Hashable, Sendable, Identifiable {
        /// How a command gets into it.
        public enum Entry: Hashable, Sendable {
            /// It has a scripting dictionary that will run a line.
            case appleScript
            /// It has no way to be told to run anything, but it will open a
            /// window on a directory. The command goes to the clipboard and
            /// the person presses ⌘V.
            case urlOnDirectory(scheme: String)
        }

        /// What to call it in a menu item.
        public let name: String
        /// Its bundle identifier, for `NSWorkspace` and for the frontmost
        /// check.
        public let bundleIdentifier: String
        /// How to get a command into it.
        public let entry: Entry

        public var id: String { bundleIdentifier }

        public init(name: String, bundleIdentifier: String, entry: Entry) {
            self.name = name
            self.bundleIdentifier = bundleIdentifier
            self.entry = entry
        }

        /// Whether the command can be handed over, or only the window.
        public var runsCommands: Bool { entry == .appleScript }
    }

    /// Terminal.app: the one every Mac has, and the fallback for every case
    /// below.
    public static let terminalApp = Terminal(
        name: "Terminal",
        bundleIdentifier: "com.apple.Terminal",
        entry: .appleScript
    )

    /// The terminals Auspex will open a resume command in, in the order it
    /// would pick between them when nothing else decides.
    ///
    /// iTerm2 before Warp before Terminal.app, because installing either of
    /// the first two is a decision and having the third is not. Warp is last
    /// of the three that gets tried and first of the ones that cannot be told
    /// to run a command — it has no scripting dictionary, so what it gets is a
    /// window on the right directory and the command on the clipboard.
    public static let knownTerminals: [Terminal] = [
        Terminal(name: "iTerm", bundleIdentifier: "com.googlecode.iterm2", entry: .appleScript),
        Terminal(name: "Warp", bundleIdentifier: "dev.warp.Warp-Stable", entry: .urlOnDirectory(scheme: "warp")),
        terminalApp
    ]

    /// The known terminal with this bundle identifier, or `nil`.
    public static func terminal(bundleIdentifier: String?) -> Terminal? {
        guard let bundleIdentifier else { return nil }
        return knownTerminals.first { $0.bundleIdentifier == bundleIdentifier }
    }

    /// Which terminal to open a resume command in.
    ///
    /// - Parameters:
    ///   - lastUsed: the bundle identifier of the last known terminal the
    ///     person was actually in. This is the answer whenever there is one:
    ///     "the terminal you were in a minute ago" beats any ranking, and
    ///     asking which application is frontmost *at the moment of the click*
    ///     would only ever answer "Auspex".
    ///   - isInstalled: whether an application with a bundle identifier is on
    ///     this machine. Injected, because the suite must not depend on what
    ///     the machine running it happens to have.
    ///
    /// Never returns `nil`: Terminal.app is part of the operating system.
    public static func chooseTerminal(
        lastUsed: String?,
        isInstalled: (String) -> Bool
    ) -> Terminal {
        if let remembered = terminal(bundleIdentifier: lastUsed), isInstalled(remembered.bundleIdentifier) {
            return remembered
        }
        return knownTerminals.first { isInstalled($0.bundleIdentifier) } ?? terminalApp
    }

    /// The AppleScript that runs `shellLine` in `terminal`, or `nil` for a
    /// terminal that cannot be told to run anything.
    ///
    /// iTerm2's dictionary is not Terminal.app's: there is no `do script`, and
    /// a window has to be created before a session exists to write into. Both
    /// scripts open a *new window* rather than reusing the front one, because
    /// typing into whatever tab happens to be at the front would interrupt
    /// whatever is running there.
    public static func terminalScript(for terminal: Terminal, shellLine: String) -> String? {
        guard terminal.entry == .appleScript else { return nil }
        switch terminal.bundleIdentifier {
        case terminalApp.bundleIdentifier:
            return terminalScript(shellLine: shellLine)
        case "com.googlecode.iterm2":
            return """
            tell application "iTerm"
                activate
                set auspexWindow to (create window with default profile)
                tell current session of auspexWindow
                    write text "\(appleScriptEscaped(shellLine))"
                end tell
            end tell
            """
        default:
            return nil
        }
    }

    /// The URL that opens `terminal` on `directory`, for the terminals that
    /// have no scripting entry point.
    ///
    /// `nil` when the terminal takes a script instead, or when the session
    /// recorded no directory to open — a window in the wrong place is not
    /// worth the app switch.
    public static func terminalURL(for terminal: Terminal, directory: String?) -> URL? {
        guard case let .urlOnDirectory(scheme) = terminal.entry,
              let directory, !directory.isEmpty,
              let encoded = directory.addingPercentEncoding(withAllowedCharacters: pathValueCharacters)
        else { return nil }
        return URL(string: "\(scheme)://action/new_tab?path=\(encoded)")
    }

    /// What may appear unescaped in the `path` query value of a terminal URL.
    ///
    /// `urlQueryAllowed` minus the characters that mean something *to a query
    /// string* — otherwise a directory with a `&` or a `+` in its name
    /// silently becomes two parameters or a space.
    private static let pathValueCharacters: CharacterSet = {
        var set = CharacterSet.urlQueryAllowed
        set.remove(charactersIn: "&=+?#")
        return set
    }()

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
