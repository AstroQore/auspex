import AgentSessionKit
import AgentSessionLive
import Foundation
import Testing

@testable import AuspexCore

/// Every fixture here is hand-written into a temporary home. No real config
/// file is opened, and no server name in this suite is one that exists.
@Suite("HarnessMCPConfigStore")
struct HarnessMCPConfigTests {
    // MARK: - Fixtures

    private func makeHome() throws -> URL {
        let home = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("auspex-mcp-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        return home
    }

    private func write(_ contents: String, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(contents.utf8).write(to: url)
    }

    // MARK: - Locations

    @Test("every featured harness with a config file of its own has a location")
    func everyFeaturedHarnessHasALocation() {
        let home = URL(fileURLWithPath: "/Users/example")
        // Claude Cowork is deliberately absent — see
        // `coworkConfigurationIsNotGuessed`.
        for harness in [Harness.claudeCode, .chatgptWork, .codex, .cursor, .grokBuild, .antigravity] {
            let location = HarnessMCPConfigStore.location(for: harness, home: home)
            #expect(location != nil, "\(harness) has no MCP config location")
            #expect(location?.path.hasPrefix("/Users/example/") == true)
            #expect(HarnessMCPConfigStore.externallyManagedNote(for: harness) == nil)
        }
    }

    @Test("the harnesses that share a store share its configuration")
    func variantsShareTheirParentsConfiguration() {
        let home = URL(fileURLWithPath: "/Users/example")
        // ChatGPT Work is a different plan on the same Codex install, and it
        // reads the same `~/.codex/config.toml`.
        #expect(
            HarnessMCPConfigStore.location(for: .chatgptWork, home: home)
                == HarnessMCPConfigStore.location(for: .codex, home: home)
        )
        #expect(
            HarnessMCPConfigStore.location(for: .geminiCLI, home: home)
                == HarnessMCPConfigStore.location(for: .antigravity, home: home)
        )
    }

    @Test("Claude Cowork's configuration is reported as external, never guessed")
    func coworkConfigurationIsNotGuessed() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }

        // A Claude Code config with servers in it. Cowork's MCP servers come
        // from Claude.app's own settings, so reading this file for a Cowork
        // row would report someone else's servers with full confidence.
        try write(
            """
            { "mcpServers": { "notebook": { "command": "notebook-mcp" } } }
            """,
            to: home.appendingPathComponent(".claude.json")
        )
        let store = HarnessMCPConfigStore(homeDirectory: home)

        #expect(HarnessMCPConfigStore.location(for: .claudeCowork, home: home) == nil)
        #expect(store.config(for: .claudeCowork) == nil)
        #expect(HarnessMCPConfigStore.externallyManagedNote(for: .claudeCowork)
            == "managed by Claude.app")
        // The sibling still reads its own file.
        #expect(store.config(for: .claudeCode)?.serverNames == ["notebook"])
    }

    // MARK: - JSON

    @Test("Claude Code's global and per-project servers are kept apart")
    func claudeSeparatesGlobalFromScoped() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }

        try write(
            """
            {
              "hasCompletedOnboarding": true,
              "mcpServers": {
                "notebook": { "command": "notebook-mcp" },
                "atlas": { "type": "http", "url": "https://example.invalid/mcp" }
              },
              "projects": {
                "/Users/example/Code/widget": {
                  "mcpServers": { "widget-tools": { "command": "widget-mcp" } }
                },
                "/Users/example/Code/other": { "mcpServers": {} }
              }
            }
            """,
            to: home.appendingPathComponent(".claude.json")
        )

        let config = try #require(
            HarnessMCPConfigStore(homeDirectory: home).config(for: .claudeCode)
        )
        #expect(config.exists)
        #expect(config.didParse)
        #expect(config.serverNames == ["atlas", "notebook"])
        #expect(config.scopedServerNames == ["widget-tools"])
        #expect(config.serverCount == 3)
        #expect(!config.registersAuspex)
    }

    @Test("a plain mcpServers object is read, and scopes are ignored where there are none")
    func cursorReadsAPlainObject() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }

        try write(
            """
            {"mcpServers": {"linter": {"command": "lint-mcp"}},
             "projects": {"/Users/example/x": {"mcpServers": {"ignored": {}}}}}
            """,
            to: home.appendingPathComponent(".cursor/mcp.json")
        )

        let config = try #require(HarnessMCPConfigStore(homeDirectory: home).config(for: .cursor))
        #expect(config.serverNames == ["linter"])
        // Cursor's file is not scoped, so the `projects` key is not a scope —
        // reading it as one would invent a server the harness cannot see.
        #expect(config.scopedServerNames.isEmpty)
    }

    @Test("a missing file reads as no config rather than as an empty one")
    func aMissingFileIsNotAnEmptyOne() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let config = try #require(HarnessMCPConfigStore(homeDirectory: home).config(for: .cursor))
        #expect(!config.exists)
        #expect(!config.didParse)
        #expect(config.serverCount == 0)
    }

    @Test("a zero-byte config is a config with nothing in it")
    func anEmptyFileParses() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try write("", to: home.appendingPathComponent(".gemini/config/mcp_config.json"))

        let config = try #require(
            HarnessMCPConfigStore(homeDirectory: home).config(for: .antigravity)
        )
        #expect(config.exists)
        #expect(config.didParse)
        #expect(config.serverCount == 0)
    }

    @Test("a file that is not JSON says so rather than reporting no servers")
    func malformedJSONIsReportedAsUnreadable() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try write("{ this is not json", to: home.appendingPathComponent(".cursor/mcp.json"))

        let config = try #require(HarnessMCPConfigStore(homeDirectory: home).config(for: .cursor))
        #expect(config.exists)
        #expect(!config.didParse)
    }

    @Test("a config that registers auspex is recognised at either scope")
    func auspexIsRecognised() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try write(
            #"{"mcpServers": {"auspex": {"command": "Auspex", "args": ["--mcp-stdio"]}}}"#,
            to: home.appendingPathComponent(".cursor/mcp.json")
        )

        let config = try #require(HarnessMCPConfigStore(homeDirectory: home).config(for: .cursor))
        #expect(config.registersAuspex)
    }

    // MARK: - TOML

    @Test("mcp_servers tables are read, and their sub-tables are not servers")
    func tomlTablesAndSubTables() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }

        try write(
            """
            model = "a-test-model"

            # A comment naming [mcp_servers.commented] should not count.
            [projects."/Users/example/Code/widget"]
            trust_level = "trusted"

            [mcp_servers.notebook]
            command = "notebook-mcp"
            args = ["serve"]

            [mcp_servers.notebook.env]
            NOTEBOOK_MODE = "read-only"

            [mcp_servers."atlas.remote"]
            url = "https://example.invalid/mcp"

            [[marketplace.sources]]
            name = "example"
            """,
            to: home.appendingPathComponent(".codex/config.toml")
        )

        let config = try #require(HarnessMCPConfigStore(homeDirectory: home).config(for: .codex))
        #expect(config.didParse)
        #expect(config.serverNames == ["atlas.remote", "notebook"])
        #expect(config.scopedServerNames.isEmpty)
    }

    @Test("a TOML config with no mcp_servers table reports no servers, not a failure")
    func tomlWithoutTheTable() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try write(
            """
            [cli]
            auto_update = true

            [models]
            default = "a-test-model"
            """,
            to: home.appendingPathComponent(".grok/config.toml")
        )

        let config = try #require(HarnessMCPConfigStore(homeDirectory: home).config(for: .grokBuild))
        #expect(config.exists)
        #expect(config.didParse)
        #expect(config.serverNames.isEmpty)
    }

    @Test("the inline spelling of the same table is read too")
    func tomlInlineTables() {
        let names = HarnessMCPConfigStore.tomlTableNames(in: """
            [mcp_servers]
            notebook = { command = "notebook-mcp" }
            "atlas.remote" = { url = "https://example.invalid/mcp" }
            startup_timeout_sec = 20

            [other]
            ignored = { command = "no" }
            """)
        // The scalar setting inside the table is a setting, not a server, and
        // the inline table in another section belongs to that section.
        #expect(names == ["atlas.remote", "notebook"])
    }

    @Test("a header that never closes is skipped rather than swallowing the file")
    func tomlToleratesAnUnclosedHeader() {
        let names = HarnessMCPConfigStore.tomlTableNames(in: """
            [mcp_servers.first]
            command = "a"

            [mcp_servers.broken

            [mcp_servers.second]
            command = "b"
            """)
        #expect(names == ["first", "second"])
    }
}
