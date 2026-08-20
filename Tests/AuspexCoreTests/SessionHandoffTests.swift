import AgentSessionKit
import AgentSessionLive
import Foundation
import Testing

@testable import AuspexCore

@Suite("SessionHandoff · resume")
struct SessionHandoffResumeTests {
    private func identity(
        _ harness: Harness,
        id: String = "11111111-2222-3333-4444-555555555555",
        cwd: String? = "/Users/example/Code/widget",
        worktree: String? = nil,
        variant: String? = nil
    ) -> SessionIdentity {
        SessionIdentity(
            key: SessionKey(harness: harness, sessionID: id),
            sourcePath: "/Users/example/store/session.jsonl",
            variant: variant,
            cwd: cwd,
            worktreePath: worktree
        )
    }

    @Test("the harnesses with a CLI hand back a command that lands in the right directory")
    func resumableHarnesses() {
        #expect(SessionHandoff.resume(for: identity(.claudeCode)).shellLine
            == "cd '/Users/example/Code/widget' && claude --resume 11111111-2222-3333-4444-555555555555")
        #expect(SessionHandoff.resume(for: identity(.codex)).command
            == "codex resume 11111111-2222-3333-4444-555555555555")
        #expect(SessionHandoff.resume(for: identity(.chatgptWork)).command
            == "codex resume 11111111-2222-3333-4444-555555555555")
        #expect(SessionHandoff.resume(for: identity(.grokBuild)).command
            == "grok --resume 11111111-2222-3333-4444-555555555555")
    }

    @Test("the harnesses without one say why, in a sentence", arguments: [
        Harness.claudeCowork, .cursor, .grokBot,
    ])
    func unresumableHarnesses(_ harness: Harness) {
        let availability = SessionHandoff.resume(for: identity(harness))
        #expect(availability.shellLine == nil)
        // The reason is what a disabled menu item shows. An empty one, or the
        // generic fallback, would be a menu item that explains nothing.
        let reason = availability.reason ?? ""
        #expect(reason.count > 20)
        #expect(reason.contains(harness.displayName.split(separator: " ").first.map(String.init) ?? ""))
    }

    @Test("AntiGravity resumes from the CLI and explains itself from the IDE")
    func antigravityVariants() {
        #expect(SessionHandoff.resume(for: identity(.antigravity, variant: "cli")).command
            == "agy --conversation 11111111-2222-3333-4444-555555555555")
        #expect(SessionHandoff.resume(for: identity(.antigravity, variant: "ide")).shellLine == nil)
    }

    @Test("a session with no recorded directory resumes where the terminal already is")
    func noDirectory() {
        #expect(SessionHandoff.resume(for: identity(.codex, cwd: nil)).shellLine
            == "codex resume 11111111-2222-3333-4444-555555555555")
    }

    @Test("a directory with an apostrophe in it is quoted, not refused")
    func quotedDirectory() {
        let line = SessionHandoff.resume(for: identity(.codex, cwd: "/Users/example/it's mine"))
            .shellLine
        #expect(line == "cd '/Users/example/it'\\''s mine' && codex resume 11111111-2222-3333-4444-555555555555")
    }
}

@Suite("SessionHandoff · where the work is")
struct SessionHandoffDirectoryTests {
    private func identity(
        cwd: String? = nil,
        worktree: String? = nil,
        gitRoot: String? = nil
    ) -> SessionIdentity {
        SessionIdentity(
            key: SessionKey(harness: .claudeCode, sessionID: "a"),
            sourcePath: "/Users/example/store/a.jsonl",
            cwd: cwd,
            gitRoot: gitRoot,
            worktreePath: worktree
        )
    }

    @Test("the worktree wins, then the working directory, then the repository")
    func precedence() {
        #expect(SessionHandoff.workingDirectory(for: identity(
            cwd: "/Users/example/Code/auspex",
            worktree: "/Users/example/Code/auspex/.agents/worktrees/feat-x",
            gitRoot: "/Users/example/Code/auspex"
        )) == "/Users/example/Code/auspex/.agents/worktrees/feat-x")

        #expect(SessionHandoff.workingDirectory(for: identity(
            cwd: "/Users/example/Code/auspex", gitRoot: "/Users/example/Code"
        )) == "/Users/example/Code/auspex")

        #expect(SessionHandoff.workingDirectory(for: identity(gitRoot: "/Users/example/Code"))
            == "/Users/example/Code")
    }

    @Test("a session whose store records no directory has none")
    func none() {
        // Grok Bot. Its conversations run on xAI's servers.
        #expect(SessionHandoff.workingDirectory(for: identity()) == nil)
        #expect(SessionHandoff.workingDirectory(for: identity(cwd: "")) == nil)
    }
}

@Suite("SessionHandoff · Terminal")
struct SessionHandoffTerminalTests {
    @Test("a plain command goes into the script unchanged")
    func plainCommand() {
        let script = SessionHandoff.terminalScript(shellLine: "codex resume abc")
        #expect(script.contains("do script \"codex resume abc\""))
        #expect(script.hasPrefix("tell application \"Terminal\""))
        #expect(script.hasSuffix("end tell"))
    }

    @Test("quotes and backslashes are escaped for AppleScript, in that order")
    func escaping() {
        // Backslashes first. Escaping quotes first would then double every
        // backslash this step adds, and the script would not compile.
        #expect(SessionHandoff.appleScriptEscaped(#"a"b"#) == #"a\"b"#)
        #expect(SessionHandoff.appleScriptEscaped(#"a\b"#) == #"a\\b"#)
        #expect(SessionHandoff.appleScriptEscaped(#"a\"b"#) == #"a\\\"b"#)
        #expect(SessionHandoff.appleScriptEscaped("plain") == "plain")
    }

    @Test("a shell-quoted directory survives the second level of quoting")
    func nestedQuoting() {
        // `cd '…'` is already POSIX-quoted; wrapping it in an AppleScript
        // string literal is the second escape, and the place a path with an
        // apostrophe would otherwise become something that runs.
        let shellLine = "cd '/Users/example/it'\\''s mine' && codex resume abc"
        let script = SessionHandoff.terminalScript(shellLine: shellLine)
        #expect(script.contains(#"cd '/Users/example/it'\\''s mine' && codex resume abc"#))
        // Exactly one pair of unescaped quotes around the argument.
        #expect(script.components(separatedBy: "do script \"").count == 2)
    }
}

@Suite("SessionHandoff · editors")
struct SessionHandoffEditorTests {
    @Test("nothing installed means nothing offered")
    func noEditor() {
        #expect(SessionHandoff.detectEditor(searchPaths: ["/opt/nowhere"]) { _ in false } == nil)
    }

    @Test("Cursor is preferred over VS Code when both are installed")
    func preference() {
        let editor = SessionHandoff.detectEditor(searchPaths: ["/opt/homebrew/bin"]) { _ in true }
        #expect(editor?.name == "Cursor")
        #expect(editor?.executablePath == "/opt/homebrew/bin/cursor")
    }

    @Test("the first search path that has one wins")
    func searchOrder() {
        let editor = SessionHandoff.detectEditor(
            searchPaths: ["/opt/homebrew/bin", "/usr/local/bin"]
        ) { $0 == "/usr/local/bin/code" }
        #expect(editor?.name == "VS Code")
        #expect(editor?.executablePath == "/usr/local/bin/code")
    }

    @Test("only the two CLI shims are ever looked for")
    func onlyKnownShims() {
        // An app being present in /Applications is not consent to launch it.
        // A shim on the path is as close to "I use this from a terminal" as a
        // machine can say.
        var probed: [String] = []
        _ = SessionHandoff.detectEditor(searchPaths: ["/opt/homebrew/bin"]) {
            probed.append($0)
            return false
        }
        #expect(probed == ["/opt/homebrew/bin/cursor", "/opt/homebrew/bin/code"])
    }
}

/// Which terminal a resume opens in, and how the command gets into it.
///
/// Every case injects its own "is this installed", because the machine running
/// the suite has its own answer and the point of the test is the ranking, not
/// that machine.
@Suite("SessionHandoff · which terminal")
struct SessionHandoffTerminalChoiceTests {
    private let iTerm = "com.googlecode.iterm2"
    private let warp = "dev.warp.Warp-Stable"
    private let terminal = "com.apple.Terminal"

    @Test("the terminal the person was last in wins over any ranking")
    func lastUsedWins() {
        let chosen = SessionHandoff.chooseTerminal(lastUsed: warp) { _ in true }
        #expect(chosen.bundleIdentifier == warp)
    }

    @Test("a remembered terminal that is no longer installed falls back to the ranking")
    func lastUsedUninstalled() {
        let chosen = SessionHandoff.chooseTerminal(lastUsed: iTerm) { $0 != self.iTerm }
        #expect(chosen.bundleIdentifier == warp)
    }

    @Test("with nothing remembered, an installed terminal beats the built-in one")
    func ranking() {
        #expect(SessionHandoff.chooseTerminal(lastUsed: nil) { _ in true }.bundleIdentifier == iTerm)
        #expect(
            SessionHandoff.chooseTerminal(lastUsed: nil) { $0 != self.iTerm }.bundleIdentifier == warp
        )
    }

    /// The fallback the type documents: Terminal.app is part of the operating
    /// system, so the answer is never "no terminal".
    @Test("with nothing installed at all, Terminal.app is still the answer")
    func fallback() {
        let chosen = SessionHandoff.chooseTerminal(lastUsed: "com.example.nothing") { _ in false }
        #expect(chosen.bundleIdentifier == terminal)
        #expect(chosen.runsCommands)
    }

    @Test("something that is not a terminal is never remembered as one")
    func unknownIdentifier() {
        #expect(SessionHandoff.terminal(bundleIdentifier: "com.apple.Safari") == nil)
        #expect(SessionHandoff.terminal(bundleIdentifier: nil) == nil)
    }

    @Test("iTerm gets its own script, because it has no `do script`")
    func iTermScript() throws {
        let iTermApp = try #require(SessionHandoff.knownTerminals.first { $0.bundleIdentifier == iTerm })
        let script = try #require(
            SessionHandoff.terminalScript(for: iTermApp, shellLine: "claude --resume abc")
        )
        #expect(script.contains("tell application \"iTerm\""))
        #expect(script.contains("create window with default profile"))
        #expect(script.contains("write text \"claude --resume abc\""))
        #expect(script.contains("do script") == false)
    }

    @Test("a terminal that cannot be told to run anything has no script")
    func warpHasNoScript() {
        let warpApp = SessionHandoff.knownTerminals.first { $0.bundleIdentifier == warp }!
        #expect(SessionHandoff.terminalScript(for: warpApp, shellLine: "claude") == nil)
        #expect(warpApp.runsCommands == false)
    }

    @Test("it gets a window on the working directory instead")
    func warpURL() {
        let warpApp = SessionHandoff.knownTerminals.first { $0.bundleIdentifier == warp }!
        let url = SessionHandoff.terminalURL(for: warpApp, directory: "/Users/example/Code/widget")
        #expect(url?.absoluteString == "warp://action/new_tab?path=/Users/example/Code/widget")
        #expect(SessionHandoff.terminalURL(for: warpApp, directory: nil) == nil)
        #expect(SessionHandoff.terminalURL(for: warpApp, directory: "") == nil)
        #expect(SessionHandoff.terminalURL(for: SessionHandoff.terminalApp, directory: "/tmp") == nil)
    }

    /// A directory name with a `&` or a `+` in it would otherwise become two
    /// query parameters, or a space.
    @Test("a directory with query punctuation in its name is encoded, not split")
    func warpURLEncoding() {
        let warpApp = SessionHandoff.knownTerminals.first { $0.bundleIdentifier == warp }!
        let url = SessionHandoff.terminalURL(for: warpApp, directory: "/Users/example/a&b+c d?e")
        let text = url?.absoluteString ?? ""
        #expect(text.contains("%26") && text.contains("%2B") && text.contains("%3F"))
        #expect(text.contains("%20"))
        #expect(url?.query()?.hasPrefix("path=") == true)
    }
}
