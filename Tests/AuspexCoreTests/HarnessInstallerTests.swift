import AgentSessionKit
import Foundation
import Testing

@testable import AuspexCore

/// The installer, against fixture files in a temporary home.
///
/// **Nothing here goes near a real config.** Every test builds its own home
/// directory under `NSTemporaryDirectory()` and points both the installer and
/// its backup root at it, so `~/.claude.json` and `~/.codex/config.toml` on the
/// machine running the suite are never opened, let alone written.
@Suite("Harness installer")
struct HarnessInstallerTests {
    /// A throwaway home, cleaned up by the test that made it.
    private final class Sandbox {
        let home: URL
        init() throws {
            home = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("auspex-installer-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        }
        deinit { try? FileManager.default.removeItem(at: home) }

        func write(_ contents: String, to relative: String) throws {
            let url = home.appendingPathComponent(relative)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try Data(contents.utf8).write(to: url)
        }

        func read(_ relative: String) throws -> String {
            try String(contentsOf: home.appendingPathComponent(relative), encoding: .utf8)
        }

        func exists(_ relative: String) -> Bool {
            FileManager.default.fileExists(atPath: home.appendingPathComponent(relative).path)
        }

        var installer: HarnessInstaller {
            HarnessInstaller(
                homeDirectory: home,
                paths: AuspexPaths(homeDirectory: home),
                command: "/Users/example/Applications/Auspex.app/Contents/MacOS/Auspex"
            )
        }
    }

    // MARK: - JSON

    @Test("registering into a JSON config adds one member and leaves the rest byte-identical")
    func jsonInstallIsSurgical() throws {
        let sandbox = try Sandbox()
        // Shaped like the real thing: per-project state around the servers,
        // an existing server, unusual spacing, and a number that a re-serialise
        // would quietly reformat.
        try sandbox.write("""
            {
              "numStartups": 412,
              "tipsHistory": {"a": 1},
              "projects": {
                "/Users/example/Code/widget": {"mcpServers": {"local": {"command": "x"}}}
              },
              "mcpServers": {
                "vibebar": {"command": "/Users/example/vibe", "args": ["--mcp-stdio"]}
              },
              "autoUpdates": true
            }
            """, to: ".claude.json")

        let report = sandbox.installer.install(.claudeCode, .mcpServer)
        #expect(report.succeeded, "\(report.failure ?? "")")
        #expect(report.didChange)

        let after = try sandbox.read(".claude.json")
        let data = try #require(after.data(using: .utf8))
        let root = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        let servers = try #require(root["mcpServers"] as? [String: Any])
        #expect(servers.keys.sorted() == ["auspex", "vibebar"])
        let entry = try #require(servers["auspex"] as? [String: Any])
        #expect(entry["command"] as? String
            == "/Users/example/Applications/Auspex.app/Contents/MacOS/Auspex")
        #expect(entry["args"] as? [String] == ["--mcp-stdio"])

        // Everything else survives, spelling included.
        #expect(after.contains("\"numStartups\": 412"))
        #expect(after.contains("\"vibebar\": {\"command\": \"/Users/example/vibe\""))
        #expect(after.contains("\"autoUpdates\": true"))
        #expect(root["projects"] != nil)
    }

    @Test("installing twice changes nothing the second time")
    func jsonInstallIsIdempotent() throws {
        let sandbox = try Sandbox()
        try sandbox.write("{\n  \"mcpServers\": {}\n}\n", to: ".claude.json")

        #expect(sandbox.installer.install(.claudeCode, .mcpServer).didChange)
        let once = try sandbox.read(".claude.json")

        let second = sandbox.installer.install(.claudeCode, .mcpServer)
        #expect(second.succeeded)
        #expect(!second.didChange)
        #expect(try sandbox.read(".claude.json") == once)
        #expect(sandbox.installer.offer(.claudeCode, .mcpServer).state == .installed)
    }

    @Test("uninstalling restores the file exactly")
    func jsonUninstallIsExact() throws {
        let sandbox = try Sandbox()
        let original = """
            {
              "numStartups": 412,
              "mcpServers": {
                "vibebar": {"command": "/Users/example/vibe"}
              }
            }
            """
        try sandbox.write(original, to: ".claude.json")

        #expect(sandbox.installer.install(.claudeCode, .mcpServer).didChange)
        #expect(sandbox.installer.uninstall(.claudeCode, .mcpServer).didChange)
        #expect(try sandbox.read(".claude.json") == original)

        // And byte-exact for a file that already ended in a newline, which is
        // every config a tool wrote for itself.
        let withNewline = original + "\n"
        try sandbox.write(withNewline, to: ".cursor/mcp.json")
        #expect(sandbox.installer.install(.cursor, .mcpServer).didChange)
        #expect(sandbox.installer.uninstall(.cursor, .mcpServer).didChange)
        #expect(try sandbox.read(".cursor/mcp.json") == withNewline)
    }

    @Test("a config with no mcpServers at all gets one, and gets it back")
    func jsonAddsTheContainer() throws {
        let sandbox = try Sandbox()
        let original = "{\n  \"numStartups\": 1\n}"
        try sandbox.write(original, to: ".claude.json")

        #expect(sandbox.installer.install(.claudeCode, .mcpServer).succeeded)
        let after = try sandbox.read(".claude.json")
        let afterData = try #require(after.data(using: .utf8))
        let root = try #require(
            try JSONSerialization.jsonObject(with: afterData) as? [String: Any]
        )
        #expect((root["mcpServers"] as? [String: Any])?["auspex"] != nil)
        #expect(root["numStartups"] as? Int == 1)

        // Uninstall leaves the empty container it created. Removing it would
        // mean deciding that an empty `mcpServers` is ours to delete, and it
        // may not be.
        #expect(sandbox.installer.uninstall(.claudeCode, .mcpServer).didChange)
        let final = try sandbox.read(".claude.json")
        let finalData = try #require(final.data(using: .utf8))
        let finalRoot = try #require(
            try JSONSerialization.jsonObject(with: finalData) as? [String: Any]
        )
        #expect((finalRoot["mcpServers"] as? [String: Any])?.isEmpty == true)
    }

    @Test("a missing config file is created, and is valid JSON")
    func jsonCreatesTheFile() throws {
        let sandbox = try Sandbox()
        #expect(!sandbox.exists(".cursor/mcp.json"))
        let report = sandbox.installer.install(.cursor, .mcpServer)
        #expect(report.succeeded, "\(report.failure ?? "")")
        #expect(report.backupPath == nil, "there was nothing to back up")

        let data = try #require(try sandbox.read(".cursor/mcp.json").data(using: .utf8))
        let root = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect((root["mcpServers"] as? [String: Any])?["auspex"] != nil)
    }

    @Test("a config that is not JSON is refused rather than replaced")
    func jsonRefusesGarbage() throws {
        let sandbox = try Sandbox()
        try sandbox.write("this is not json at all", to: ".cursor/mcp.json")

        let offer = sandbox.installer.offer(.cursor, .mcpServer)
        #expect(offer.state == .unreadable("The file is not a JSON object."))

        let report = sandbox.installer.install(.cursor, .mcpServer)
        #expect(!report.succeeded)
        #expect(!report.didChange)
        #expect(try sandbox.read(".cursor/mcp.json") == "this is not json at all")
    }

    @Test("a registration pointing at another binary is named, not silently kept")
    func jsonNoticesAForeignEntry() throws {
        let sandbox = try Sandbox()
        try sandbox.write("""
            {"mcpServers": {"auspex": {"command": "/Users/example/build/Auspex", "args": ["--mcp-stdio"]}}}
            """, to: ".cursor/mcp.json")

        let state = sandbox.installer.offer(.cursor, .mcpServer).state
        #expect(state == .installedElsewhere("/Users/example/build/Auspex"))
        #expect(state.canInstall)

        #expect(sandbox.installer.install(.cursor, .mcpServer).didChange)
        #expect(sandbox.installer.offer(.cursor, .mcpServer).state == .installed)
    }

    // MARK: - TOML

    @Test("a TOML config gets a fenced table appended, and keeps its comments")
    func tomlInstall() throws {
        let sandbox = try Sandbox()
        let original = """
            # my own notes, please keep
            model = "gpt-5"
            notify = ["/Users/example/bin/notify"]

            [mcp_servers.vibebar]
            command = "/Users/example/vibe"
            """
        try sandbox.write(original, to: ".codex/config.toml")

        let report = sandbox.installer.install(.codex, .mcpServer)
        #expect(report.succeeded, "\(report.failure ?? "")")
        let after = try sandbox.read(".codex/config.toml")

        #expect(after.hasPrefix(original))
        #expect(after.contains("# >>> auspex >>>"))
        #expect(after.contains("[mcp_servers.auspex]"))
        #expect(after.contains("# <<< auspex <<<"))
        #expect(after.contains("# my own notes, please keep"))
        #expect(HarnessMCPConfigStore.tomlTableNames(in: after).sorted() == ["auspex", "vibebar"])

        // The backup went under ~/.auspex/, not next to their file.
        let backup = try #require(report.backupPath)
        #expect(backup.contains("/.auspex/backups/"))
        #expect(!sandbox.exists(".codex/config.toml.bak"))

        #expect(!sandbox.installer.install(.codex, .mcpServer).didChange)
        #expect(sandbox.installer.uninstall(.codex, .mcpServer).didChange)
        // The fixture has no final newline; a file Auspex appends to gets one,
        // which is the single documented exception to "restores exactly".
        #expect(try sandbox.read(".codex/config.toml") == original + "\n")
    }

    @Test("a hand-written auspex table outside the fence is left alone")
    func tomlRespectsAHandWrittenEntry() throws {
        let sandbox = try Sandbox()
        try sandbox.write("""
            [mcp_servers.auspex]
            command = "/Users/example/somewhere/else"
            """, to: ".grok/config.toml")

        let state = sandbox.installer.offer(.grokBuild, .mcpServer).state
        #expect(state == .installedElsewhere("an entry Auspex did not write"))
    }

    // MARK: - The protocol note

    @Test("the note is fenced, invisible as markup, and removed exactly")
    func noteRoundTrip() throws {
        let sandbox = try Sandbox()
        let original = """
            # My instructions

            Always use British spelling.
            """
        try sandbox.write(original, to: ".claude/CLAUDE.md")

        #expect(sandbox.installer.offer(.claudeCode, .protocolNote).state == .absent)
        let report = sandbox.installer.install(.claudeCode, .protocolNote)
        #expect(report.succeeded, "\(report.failure ?? "")")

        let after = try sandbox.read(".claude/CLAUDE.md")
        #expect(after.hasPrefix(original))
        #expect(after.contains("<!-- >>> auspex >>> -->"))
        #expect(after.contains("auspex.notify"))
        #expect(after.contains("tasks.claim"))
        // The fence is an HTML comment, not a heading: `# >>> auspex >>>` in a
        // Markdown file would be an H1 in whatever the harness feeds its model.
        #expect(!after.contains("\n# >>> auspex"))

        #expect(sandbox.installer.offer(.claudeCode, .protocolNote).state == .installed)
        #expect(!sandbox.installer.install(.claudeCode, .protocolNote).didChange)

        #expect(sandbox.installer.uninstall(.claudeCode, .protocolNote).didChange)
        #expect(try sandbox.read(".claude/CLAUDE.md") == original + "\n")
    }

    @Test("an older note is replaced in place rather than appended beside")
    func noteIsReplacedNotDuplicated() throws {
        let sandbox = try Sandbox()
        try sandbox.write("""
            # Mine

            <!-- >>> auspex >>> -->
            Something an older Auspex wrote.
            <!-- <<< auspex <<< -->

            More of mine.
            """, to: ".codex/AGENTS.md")

        #expect(
            sandbox.installer.offer(.codex, .protocolNote).state
                == .installedElsewhere("a note from an older Auspex")
        )
        #expect(sandbox.installer.install(.codex, .protocolNote).didChange)

        let after = try sandbox.read(".codex/AGENTS.md")
        #expect(after.components(separatedBy: "<!-- >>> auspex >>> -->").count == 2)
        #expect(!after.contains("Something an older Auspex wrote."))
        #expect(after.contains("More of mine."))
        #expect(after.hasPrefix("# Mine"))
    }

    @Test("a harness with nowhere to write says why instead of failing quietly")
    func unavailableRowsExplainThemselves() throws {
        let sandbox = try Sandbox()
        let cowork = sandbox.installer.offer(.claudeCowork, .mcpServer)
        #expect(cowork.state == .unavailable("MCP is managed by Claude.app."))
        #expect(cowork.path == nil)

        let cursorNote = sandbox.installer.offer(.cursor, .protocolNote)
        guard case .unavailable = cursorNote.state else {
            Issue.record("Cursor has no instruction file Auspex can name")
            return
        }

        let report = sandbox.installer.install(.claudeCowork, .mcpServer)
        #expect(!report.succeeded)
        #expect(!report.didChange)
    }

    @Test("every offer names the exact file before anything is written")
    func offersNameTheirFiles() throws {
        let sandbox = try Sandbox()
        let offers = sandbox.installer.offers(for: Harness.allCases)
        for offer in offers {
            switch offer.state {
            case .unavailable:
                #expect(offer.path == nil)
            default:
                #expect(offer.path?.isEmpty == false, "\(offer.id) offered no path")
                #expect(offer.displayPath?.hasPrefix("/") == true || offer.displayPath?.hasPrefix("~") == true)
            }
        }
        // And nothing was written just by looking.
        #expect(!sandbox.exists(".claude.json"))
        #expect(!sandbox.exists(".codex/config.toml"))
        #expect(!sandbox.exists(".claude/CLAUDE.md"))
    }
}

// MARK: - The text editors themselves

@Suite("Config text editors")
struct ConfigTextEditorTests {
    @Test("a JSON member's span covers exactly its key and value")
    func memberSpans() throws {
        let text = #"{"a": 1, "b": {"c": [1, {"d": "}"}]}, "e": "x"}"#
        let root = try #require(JSONTextEditor.topLevelObjectStart(in: text))
        let members = try #require(JSONTextEditor.members(in: text, objectAt: root))
        #expect(members.map(\.name) == ["a", "b", "e"])
        // The brace inside a string must not close the object.
        let b = try #require(members.first { $0.name == "b" })
        #expect(String(text[b.range]) == #""b": {"c": [1, {"d": "}"}]}"#)
    }

    @Test("an escaped quote in a key does not end the key")
    func escapedKeys() throws {
        let text = #"{"a\"b": 1, "c": 2}"#
        let root = try #require(JSONTextEditor.topLevelObjectStart(in: text))
        let members = try #require(JSONTextEditor.members(in: text, objectAt: root))
        #expect(members.map(\.name) == ["a\"b", "c"])
    }

    @Test("a truncated object is refused rather than half-read")
    func truncatedObject() throws {
        let text = #"{"a": {"b": 1}"#
        let root = try #require(JSONTextEditor.topLevelObjectStart(in: text))
        #expect(JSONTextEditor.members(in: text, objectAt: root) == nil)
    }

    @Test("removing the only member leaves a valid empty object")
    func removeSoleMember() throws {
        let text = "{\n  \"only\": {\"x\": 1}\n}"
        let root = try #require(JSONTextEditor.topLevelObjectStart(in: text))
        let out = try #require(JSONTextEditor.remove(member: "only", in: text, objectAt: root))
        let data = try #require(out.data(using: .utf8))
        let root2 = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(root2.isEmpty)
    }

    @Test("removing the first or last of several leaves valid JSON either way")
    func removeAtEitherEnd() throws {
        for name in ["a", "b", "c"] {
            let text = "{\"a\": 1, \"b\": 2, \"c\": 3}"
            let root = try #require(JSONTextEditor.topLevelObjectStart(in: text))
            let out = try #require(JSONTextEditor.remove(member: name, in: text, objectAt: root))
            let data = try #require(out.data(using: .utf8))
            let decoded = try #require(
                try JSONSerialization.jsonObject(with: data) as? [String: Any]
            )
            #expect(decoded.keys.sorted() == ["a", "b", "c"].filter { $0 != name })
        }
    }

    @Test("a fence is idempotent, replaceable, and removable")
    func fenceLifecycle() {
        let fence = ConfigFence(comment: .hash)
        let original = "keep = true\n"

        let once = fence.applying("added = 1", to: original)
        #expect(fence.applying("added = 1", to: once) == once)
        #expect(fence.body(in: once) == "added = 1")

        let changed = fence.applying("added = 2", to: once)
        #expect(fence.body(in: changed) == "added = 2")
        #expect(changed.components(separatedBy: fence.opening).count == 2)

        #expect(fence.removing(from: changed) == original)
        // Removing a fence that is not there is not an error.
        #expect(fence.removing(from: original) == original)
    }

    @Test("a fence added to an empty file does not start with blank lines")
    func fenceOnAnEmptyFile() {
        let fence = ConfigFence(comment: .html)
        let out = fence.applying("hello", to: "")
        #expect(out == "<!-- >>> auspex >>> -->\nhello\n<!-- <<< auspex <<< -->\n")
        #expect(fence.removing(from: out).isEmpty)
    }
}
