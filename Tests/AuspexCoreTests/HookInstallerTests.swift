import AgentSessionKit
import Foundation
import Testing

@testable import AuspexCore

/// The hook installers, against fixture files in a temporary home.
///
/// **Nothing here goes near a real config.** Every test builds its own home
/// under `NSTemporaryDirectory()` and points the installer, its backups and its
/// hook files at it, so `~/.claude/settings.json`, `~/.cursor/hooks.json`,
/// `~/.grok/hooks/` and `~/.codex/config.toml` on the machine running the suite
/// are never opened, let alone written.
@Suite("Harness hooks")
struct HookInstallerTests {
    private final class Sandbox {
        let home: URL
        /// A binary path that is not on this machine and never will be.
        let binary = "/Users/example/Applications/Auspex.app/Contents/MacOS/Auspex"

        init() throws {
            home = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("auspex-hooks-\(UUID().uuidString)", isDirectory: true)
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
                command: binary
            )
        }

        func json(_ relative: String) throws -> [String: Any] {
            let data = try #require(try read(relative).data(using: .utf8))
            return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        }
    }

    // MARK: - Claude Code

    @Test("Claude's table gets one entry per event and nobody else's is touched")
    func claudeInstall() throws {
        let sandbox = try Sandbox()
        // Shaped like a working machine: another tool already hooks two of the
        // same events, and there are settings around them that a re-serialise
        // would quietly reformat.
        let original = """
            {
              "env": {"CLAUDE_CODE_DISABLE_TERMINAL_TITLE": "1"},
              "hooks": {
                "Notification": [
                  {"matcher": "*", "hooks": [{"type": "command", "command": "/Users/example/bin/other"}]}
                ],
                "Stop": [
                  {"hooks": [{"type": "command", "command": "/Users/example/bin/other"}]}
                ]
              },
              "effortLevel": "high"
            }
            """
        try sandbox.write(original, to: ".claude/settings.json")

        #expect(sandbox.installer.offer(.claudeCode, .hooks).state == .absent)
        let report = sandbox.installer.install(.claudeCode, .hooks)
        #expect(report.succeeded, "\(report.failure ?? "")")
        #expect(report.didChange)
        #expect(report.backupPath?.contains("/.auspex/backups/") == true)

        let root = try sandbox.json(".claude/settings.json")
        let table = try #require(root["hooks"] as? [String: Any])
        for event in ["SessionStart", "SessionEnd", "PermissionRequest", "PostToolUse",
                      "Stop", "SubagentStart", "SubagentStop", "Notification"] {
            let entries = try #require(table[event] as? [[String: Any]], "\(event) is missing")
            let commands = entries
                .compactMap { $0["hooks"] as? [[String: Any]] }
                .flatMap { $0.compactMap { $0["command"] as? String } }
            #expect(commands.contains { $0.contains("--hook claude") }, "\(event)")
        }
        // Theirs is still there, in both the events Auspex joined.
        let after = try sandbox.read(".claude/settings.json")
        #expect(after.components(separatedBy: "/Users/example/bin/other").count == 3)
        #expect(after.contains("\"effortLevel\": \"high\""))
        #expect(after.contains("CLAUDE_CODE_DISABLE_TERMINAL_TITLE"))

        // Installed, idempotent, and exactly reversible.
        #expect(sandbox.installer.offer(.claudeCode, .hooks).state == .installed)
        let second = sandbox.installer.install(.claudeCode, .hooks)
        #expect(second.succeeded)
        #expect(!second.didChange)
        #expect(try sandbox.read(".claude/settings.json") == after)

        #expect(sandbox.installer.uninstall(.claudeCode, .hooks).didChange)
        #expect(try sandbox.read(".claude/settings.json") == original)
    }

    @Test("a settings file that does not exist is created, and taken away again")
    func claudeCreatesAndRemovesTheFile() throws {
        let sandbox = try Sandbox()
        #expect(!sandbox.exists(".claude/settings.json"))

        let report = sandbox.installer.install(.claudeCode, .hooks)
        #expect(report.succeeded, "\(report.failure ?? "")")
        #expect(report.backupPath == nil, "there was nothing to back up")
        let table = try #require(try sandbox.json(".claude/settings.json")["hooks"] as? [String: Any])
        #expect(table.count == 8)

        // Nothing of the person's is in it, so leaving an empty husk behind
        // would be leaving litter with Auspex's name on it.
        #expect(sandbox.installer.uninstall(.claudeCode, .hooks).didChange)
        #expect(!sandbox.exists(".claude/settings.json"))
    }

    @Test("an entry from another Auspex is replaced rather than doubled")
    func claudeReplacesAForeignBinary() throws {
        let sandbox = try Sandbox()
        try sandbox.write("""
            {
              "hooks": {
                "Stop": [
                  {"hooks": [{"type": "command", "command": "\\"/Users/example/build/Auspex\\" --hook claude"}]}
                ]
              }
            }
            """, to: ".claude/settings.json")

        let state = sandbox.installer.offer(.claudeCode, .hooks).state
        #expect(state == .installedElsewhere("/Users/example/build/Auspex"))
        #expect(state.canInstall)

        #expect(sandbox.installer.install(.claudeCode, .hooks).didChange)
        let after = try sandbox.read(".claude/settings.json")
        #expect(!after.contains("/Users/example/build/Auspex"))
        #expect(sandbox.installer.offer(.claudeCode, .hooks).state == .installed)

        let stop = try #require(
            try sandbox.json(".claude/settings.json")["hooks"] as? [String: Any]
        )["Stop"] as? [[String: Any]]
        #expect(stop?.count == 1, "the old entry was replaced, not joined")
    }

    @Test("a half-installed set reads as out of date rather than as installed")
    func claudeNoticesAMissingEvent() throws {
        let sandbox = try Sandbox()
        #expect(sandbox.installer.install(.claudeCode, .hooks).succeeded)

        // A person edited one event out by hand.
        var text = try sandbox.read(".claude/settings.json")
        let root = try #require(JSONTextEditor.topLevelObjectStart(in: text))
        let hooks = try #require(
            JSONTextEditor.valueStart(ofMemberNamed: "hooks", in: text, objectAt: root)
        )
        text = try #require(
            JSONTextEditor.remove(member: "SubagentStop", in: text, objectAt: hooks)
        )
        try sandbox.write(text, to: ".claude/settings.json")

        #expect(
            sandbox.installer.offer(.claudeCode, .hooks).state
                == .installedElsewhere("an older Auspex's set of events")
        )
        #expect(sandbox.installer.install(.claudeCode, .hooks).didChange)
        #expect(sandbox.installer.offer(.claudeCode, .hooks).state == .installed)
    }

    @Test("a settings file that is not JSON is refused rather than replaced")
    func claudeRefusesGarbage() throws {
        let sandbox = try Sandbox()
        try sandbox.write("half a file {", to: ".claude/settings.json")

        #expect(sandbox.installer.offer(.claudeCode, .hooks).state
            == .unreadable("The file is not a JSON object."))
        let report = sandbox.installer.install(.claudeCode, .hooks)
        #expect(!report.succeeded)
        #expect(try sandbox.read(".claude/settings.json") == "half a file {")
    }

    // MARK: - Cursor

    @Test("Cursor's bare-command entries go in beside another tool's")
    func cursorInstall() throws {
        let sandbox = try Sandbox()
        let original = """
            {
              "hooks": {
                "afterFileEdit": [
                  {"command": "/Users/example/bin/other --source cursor"}
                ]
              },
              "version": 1
            }
            """
        try sandbox.write(original, to: ".cursor/hooks.json")

        #expect(sandbox.installer.install(.cursor, .hooks).succeeded)
        let table = try #require(try sandbox.json(".cursor/hooks.json")["hooks"] as? [String: Any])
        let edits = try #require(table["afterFileEdit"] as? [[String: Any]])
        #expect(edits.count == 2)
        #expect(edits.contains { ($0["command"] as? String)?.contains("--hook cursor") == true })
        // None of Cursor's permission-gating hooks: an observer does not stand
        // on the path that decides whether a command runs.
        #expect(table["beforeShellExecution"] == nil)
        #expect(table["beforeReadFile"] == nil)

        #expect(sandbox.installer.uninstall(.cursor, .hooks).didChange)
        #expect(try sandbox.read(".cursor/hooks.json") == original)
    }

    // MARK: - Grok

    @Test("Grok gets a file of its own, and loses it again")
    func grokInstall() throws {
        let sandbox = try Sandbox()
        #expect(sandbox.installer.offer(.grokBuild, .hooks).state == .absent)
        #expect(sandbox.installer.offer(.grokBuild, .hooks).path?.hasSuffix(
            ".grok/hooks/auspex.json"
        ) == true)

        let report = sandbox.installer.install(.grokBuild, .hooks)
        #expect(report.succeeded, "\(report.failure ?? "")")
        let table = try #require(
            try sandbox.json(".grok/hooks/auspex.json")["hooks"] as? [String: Any]
        )
        #expect(table.keys.sorted() == GrokHookInstaller(
            home: sandbox.home, paths: AuspexPaths(homeDirectory: sandbox.home),
            binary: sandbox.binary
        ).plan().events.sorted())
        #expect(sandbox.installer.offer(.grokBuild, .hooks).state == .installed)
        #expect(!sandbox.installer.install(.grokBuild, .hooks).didChange)

        #expect(sandbox.installer.uninstall(.grokBuild, .hooks).didChange)
        #expect(!sandbox.exists(".grok/hooks/auspex.json"))
        // Another tool's hook file in the same directory is not ours to touch.
        #expect(!sandbox.exists(".grok/hooks/other.json"))
    }

    // MARK: - Codex

    @Test("an existing notify is wrapped, and put back exactly on removal")
    func codexWrapsWhatWasThere() throws {
        let sandbox = try Sandbox()
        let original = """
            # my own notes
            model = "gpt-5"
            notify = ["/Users/example/bin/notify", "turn-ended"]

            [mcp_servers.vibebar]
            command = "/Users/example/vibe"
            notify = ["this one is a different setting"]
            """
        try sandbox.write(original, to: ".codex/config.toml")

        #expect(sandbox.installer.offer(.codex, .hooks).state == .absent)
        let report = sandbox.installer.install(.codex, .hooks)
        #expect(report.succeeded, "\(report.failure ?? "")")

        let after = try sandbox.read(".codex/config.toml")
        #expect(after.contains("# >>> auspex-notify >>>"))
        #expect(after.contains(
            "notify = [\"\(sandbox.binary)\", \"--hook\", \"codex-notify\", \"--then\", "
                + "\"/Users/example/bin/notify\", \"turn-ended\"]"
        ))
        #expect(after.contains("# was: notify = [\"/Users/example/bin/notify\", \"turn-ended\"]"))
        // The one inside a table is a different setting with the same name.
        #expect(after.contains("notify = [\"this one is a different setting\"]"))
        #expect(after.contains("# my own notes"))

        #expect(sandbox.installer.offer(.codex, .hooks).state == .installed)
        #expect(!sandbox.installer.install(.codex, .hooks).didChange)

        #expect(sandbox.installer.uninstall(.codex, .hooks).didChange)
        #expect(try sandbox.read(".codex/config.toml") == original)
    }

    @Test("an empty notify slot is filled without a chain")
    func codexFillsAnEmptySlot() throws {
        let sandbox = try Sandbox()
        let original = "model = \"gpt-5\"\n"
        try sandbox.write(original, to: ".codex/config.toml")

        #expect(sandbox.installer.install(.codex, .hooks).succeeded)
        let after = try sandbox.read(".codex/config.toml")
        #expect(after.contains(
            "notify = [\"\(sandbox.binary)\", \"--hook\", \"codex-notify\"]"
        ))
        #expect(!after.contains("--then"))
        #expect(!after.contains("# was:"))

        #expect(sandbox.installer.uninstall(.codex, .hooks).didChange)
        #expect(try sandbox.read(".codex/config.toml") == original)
    }

    @Test("a notify spread over several lines is refused, not rewritten")
    func codexRefusesAMultiLineNotify() throws {
        let sandbox = try Sandbox()
        let original = """
            notify = [
              "/Users/example/bin/notify",
            ]
            """
        try sandbox.write(original, to: ".codex/config.toml")

        guard case let .unreadable(reason) = sandbox.installer.offer(.codex, .hooks).state else {
            Issue.record("a multi-line notify should be refused")
            return
        }
        #expect(reason.contains("several lines"))
        #expect(!sandbox.installer.install(.codex, .hooks).succeeded)
        #expect(try sandbox.read(".codex/config.toml") == original)
    }

    @Test("moving the binary rewrites the wrapper and keeps the chain")
    func codexRewrapsForANewBinary() throws {
        let sandbox = try Sandbox()
        try sandbox.write(
            "notify = [\"/Users/example/bin/notify\"]\n", to: ".codex/config.toml"
        )
        #expect(sandbox.installer.install(.codex, .hooks).succeeded)

        let moved = HarnessInstaller(
            homeDirectory: sandbox.home,
            paths: AuspexPaths(homeDirectory: sandbox.home),
            command: "/Users/example/build/Auspex"
        )
        #expect(moved.offer(.codex, .hooks).state
            == .installedElsewhere(sandbox.binary))
        #expect(moved.install(.codex, .hooks).didChange)

        let after = try sandbox.read(".codex/config.toml")
        #expect(after.contains("\"/Users/example/build/Auspex\""))
        #expect(after.contains("\"--then\", \"/Users/example/bin/notify\""))
        #expect(after.components(separatedBy: "# >>> auspex-notify >>>").count == 2)
        #expect(moved.uninstall(.codex, .hooks).didChange)
        #expect(try sandbox.read(".codex/config.toml")
            == "notify = [\"/Users/example/bin/notify\"]\n")
    }

    // MARK: - Codex, with the hook table switched on

    /// The real file's shape, with a fabricated tool in it: Codex's hook table
    /// is Claude Code's schema, and on a machine that has the feature on there
    /// is usually already a notifier in it.
    private static let codexHooksFile = """
        {
          "hooks": {
            "PermissionRequest": [
              {
                "hooks": [
                  {"command": "'/Users/example/bin/bridge' --source codex", "timeout": 7200, "type": "command"}
                ]
              }
            ],
            "SessionStart": [
              {
                "hooks": [
                  {"command": "'/Users/example/bin/bridge' --source codex", "timeout": 5, "type": "command"}
                ],
                "matcher": "startup|resume|clear"
              }
            ]
          }
        }
        """

    /// `[features] hooks = true`, plus the shape of the rest of the file:
    /// tables above and below, and a `notify` that must stay untouched because
    /// the wrapper is not what gets installed on this machine.
    private static let codexFeaturesOn = """
        model = "gpt-5"
        notify = ["/Users/example/bin/notify"]

        [features]
        memories = true
        hooks = true

        [mcp_servers.other]
        command = "/Users/example/other"
        """

    @Test("with the hooks feature on, Codex gets table entries and its notify is left alone")
    func codexInstallsIntoTheHookTable() throws {
        let sandbox = try Sandbox()
        try sandbox.write(Self.codexFeaturesOn, to: ".codex/config.toml")
        try sandbox.write(Self.codexHooksFile, to: ".codex/hooks.json")

        let offer = sandbox.installer.offer(.codex, .hooks)
        #expect(offer.state == .absent)
        #expect(offer.path?.hasSuffix(".codex/hooks.json") == true)

        let plan = try #require(sandbox.installer.hookPlan(for: .codex))
        #expect(plan.events == ["SessionStart", "SessionEnd", "PermissionRequest", "PostToolUse", "Stop"])
        // Not the gate: an observer does not stand on the path that decides
        // whether a tool call runs.
        #expect(!plan.events.contains("PreToolUse"))
        #expect(plan.note?.contains("review") == true)

        let report = sandbox.installer.install(.codex, .hooks)
        #expect(report.succeeded, "\(report.failure ?? "")")
        #expect(report.path?.hasSuffix(".codex/hooks.json") == true)
        #expect(report.backupPath?.contains("/.auspex/backups/") == true)

        let table = try #require(try sandbox.json(".codex/hooks.json")["hooks"] as? [String: Any])
        for event in plan.events {
            let entries = try #require(table[event] as? [[String: Any]], "\(event) is missing")
            let commands = entries
                .compactMap { $0["hooks"] as? [[String: Any]] }
                .flatMap { $0.compactMap { $0["command"] as? String } }
            #expect(commands.contains { $0.contains("--hook codex") }, "\(event)")
            // Never `--hook codex-notify`: the two mechanisms are different
            // targets, and removing one must not remove the other.
            #expect(!commands.contains { $0.contains("codex-notify") }, "\(event)")
        }
        // Theirs is still there, in both events Auspex joined, matcher and all.
        let after = try sandbox.read(".codex/hooks.json")
        #expect(after.components(separatedBy: "/Users/example/bin/bridge").count == 3)
        #expect(after.contains("\"matcher\": \"startup|resume|clear\""))
        // And config.toml was not opened at all: no fence, no wrapped notify.
        let config = try sandbox.read(".codex/config.toml")
        #expect(config == Self.codexFeaturesOn)

        #expect(sandbox.installer.offer(.codex, .hooks).state == .installed)
        let second = sandbox.installer.install(.codex, .hooks)
        #expect(second.succeeded)
        #expect(!second.didChange)
        #expect(try sandbox.read(".codex/hooks.json") == after)

        #expect(sandbox.installer.uninstall(.codex, .hooks).didChange)
        #expect(try sandbox.read(".codex/hooks.json") == Self.codexHooksFile)
        #expect(try sandbox.read(".codex/config.toml") == Self.codexFeaturesOn)
    }

    @Test("removing takes back the wrapper too, for a machine that turned the feature on later")
    func codexUninstallReachesBothMechanisms() throws {
        let sandbox = try Sandbox()
        // The wrapper was installed while the feature was off.
        try sandbox.write("notify = [\"/Users/example/bin/notify\"]\n", to: ".codex/config.toml")
        #expect(sandbox.installer.install(.codex, .hooks).succeeded)
        #expect(try sandbox.read(".codex/config.toml").contains("--hook"))

        // Then the person switched it on, and Auspex registered the table.
        var config = try sandbox.read(".codex/config.toml")
        config += "\n[features]\nhooks = true\n"
        try sandbox.write(config, to: ".codex/config.toml")
        #expect(sandbox.installer.offer(.codex, .hooks).state == .absent, "the table has nothing yet")
        #expect(sandbox.installer.install(.codex, .hooks).succeeded)
        #expect(sandbox.exists(".codex/hooks.json"))

        // One Remove, and neither is left behind.
        #expect(sandbox.installer.uninstall(.codex, .hooks).didChange)
        #expect(!sandbox.exists(".codex/hooks.json"), "a file only Auspex wrote is not litter to leave")
        let restored = try sandbox.read(".codex/config.toml")
        #expect(!restored.contains("--hook"))
        #expect(!restored.contains(">>> auspex-notify"))
        #expect(restored.contains("notify = [\"/Users/example/bin/notify\"]"))
    }

    @Test("the feature gate is read from config.toml, and nothing else is mistaken for it")
    func codexFeatureGate() {
        #expect(CodexHookInstaller.hooksFeatureEnabled(in: "[features]\nhooks = true\n"))
        #expect(CodexHookInstaller.hooksFeatureEnabled(in: "features.hooks = true\n"))
        #expect(CodexHookInstaller.hooksFeatureEnabled(in: "[features]\nhooks = true # on\n"))
        #expect(!CodexHookInstaller.hooksFeatureEnabled(in: "[features]\nhooks = false\n"))
        #expect(!CodexHookInstaller.hooksFeatureEnabled(in: ""))
        // The trust state Codex keeps for hooks it has already been shown is
        // not the switch that turns them on.
        #expect(!CodexHookInstaller.hooksFeatureEnabled(
            in: "[hooks.state]\n\n[hooks.state.\"a:stop:0:0\"]\ntrusted_hash = \"sha256:00\"\n"
        ))
        // A profile's copy is for a profile that may not be the one running.
        #expect(!CodexHookInstaller.hooksFeatureEnabled(in: "[profiles.x.features]\nhooks = true\n"))
    }

    @Test("with the feature off, the notify wrapper is still what is offered")
    func codexFallsBackToNotify() throws {
        let sandbox = try Sandbox()
        try sandbox.write("[features]\nhooks = false\nmemories = true\n", to: ".codex/config.toml")

        let plan = try #require(sandbox.installer.hookPlan(for: .codex))
        #expect(plan.path.hasSuffix(".codex/config.toml"))
        #expect(plan.events == ["agent-turn-complete"])
        #expect(sandbox.installer.install(.codex, .hooks).succeeded)
        #expect(try sandbox.read(".codex/config.toml").contains("--hook\", \"codex-notify\""))
        #expect(!sandbox.exists(".codex/hooks.json"), "an inert file is not worth writing into")
    }

    // MARK: - Ownership

    @Test("an entry is ours when it runs an Auspex with this target, and not otherwise")
    func ownership() {
        #expect(HookCommand.isOurs("\"/x/Auspex\" --hook claude", target: .claude))
        #expect(HookCommand.isOurs("/x/y/Auspex --hook claude", target: .claude))
        // Right binary, wrong harness: two Auspex entries in one table are for
        // two different harnesses, and removing Cursor's must not remove
        // Claude's.
        #expect(!HookCommand.isOurs("\"/x/Auspex\" --hook cursor", target: .claude))
        // Codex's two mechanisms are two targets. Both can be in one home, and
        // removing the table's entries must not touch the notify wrapper.
        #expect(HookCommand.isOurs("\"/x/Auspex\" --hook codex", target: .codex))
        #expect(!HookCommand.isOurs("\"/x/Auspex\" --hook codex-notify", target: .codex))
        #expect(!HookCommand.isOurs("\"/x/Auspex\" --hook codex", target: .codexNotify))
        // Somebody else's tool that happens to take a --hook flag.
        #expect(!HookCommand.isOurs("/x/other --hook claude", target: .claude))
        #expect(!HookCommand.isOurs("/x/Auspex --mcp-stdio", target: .claude))
        // A path with a space in it survives being quoted.
        #expect(HookCommand.tokenize("\"/A B/Auspex\" --hook grok")
            == ["/A B/Auspex", "--hook", "grok"])
    }

    @Test("harnesses with no hook mechanism say so rather than offering one")
    func unavailableHarnesses() throws {
        let sandbox = try Sandbox()
        for harness in [Harness.antigravity, .geminiCLI, .grokBot, .claudeCowork] {
            let offer = sandbox.installer.offer(harness, .hooks)
            #expect(offer.path == nil, "\(harness.rawValue)")
            guard case .unavailable = offer.state else {
                Issue.record("\(harness.rawValue) offered hooks it does not have")
                continue
            }
            #expect(!sandbox.installer.install(harness, .hooks).succeeded)
        }
        // And nothing was written just by looking.
        #expect(!sandbox.exists(".claude/settings.json"))
        #expect(!sandbox.exists(".cursor/hooks.json"))
        #expect(!sandbox.exists(".grok/hooks/auspex.json"))
        #expect(!sandbox.exists(".codex/config.toml"))
    }
}
