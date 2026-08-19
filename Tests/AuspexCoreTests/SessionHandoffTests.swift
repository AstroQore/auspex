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
