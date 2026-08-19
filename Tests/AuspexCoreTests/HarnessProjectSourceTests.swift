import AgentSessionKit
import AgentSessionLive
import Foundation
import GRDB
import Testing

@testable import AuspexCore

/// Importing from the harnesses' own project registries.
///
/// Every fixture here is written by the test into a temporary home. Nothing
/// reads the machine's real `~/.claude.json` or Codex database, and the paths
/// are all under `/Users/example`.
@Suite("Harness project registries")
struct HarnessProjectSourceTests {
    private func makeHome() throws -> URL {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("auspex-registry-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        return home
    }

    // MARK: - Claude Code

    @Test("Only the projects keys of ~/.claude.json are read")
    func claudeConfigProjectsOnly() throws {
        let data = Data("""
            {
              "oauthAccount": {"emailAddress": "someone@example.com"},
              "userID": "not-read",
              "mcpServers": {"auspex": {"command": "auspex"}},
              "projects": {
                "/Users/example/Code/auspex": {"history": ["not read"]},
                "/Users/example/Code/storefront-web": {},
                "relative/path": {}
              }
            }
            """.utf8)

        #expect(ClaudeProjectSource.projectPaths(inConfig: data) == [
            "/Users/example/Code/auspex",
            "/Users/example/Code/storefront-web",
        ])
    }

    @Test("A config with no projects key yields nothing rather than failing")
    func claudeConfigWithoutProjects() {
        #expect(ClaudeProjectSource.projectPaths(inConfig: Data("{}".utf8)).isEmpty)
        #expect(ClaudeProjectSource.projectPaths(inConfig: Data("not json".utf8)).isEmpty)
    }

    @Test("Transcript directories decode back to the directories they encode")
    func claudeTranscriptDirectories() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }

        // The encoding is lossy, and the decoder settles it against the file
        // system — so the fixture makes the real directory too.
        let real = home.appendingPathComponent("Code/vibe-bar", isDirectory: true)
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        let encoded = ClaudeProjectPath.encode(cwd: real.path)
        try FileManager.default.createDirectory(
            at: home.appendingPathComponent(".claude/projects/\(encoded)", isDirectory: true),
            withIntermediateDirectories: true
        )

        let refs = ClaudeProjectSource(home: home).fromTranscripts()
        #expect(refs.count == 1)
        #expect(refs.first?.path == real.path)
        #expect(refs.first?.harness == .claudeCode)
        #expect(refs.first?.lastSeen != nil)
    }

    @Test("The two Claude sources merge into one entry per directory")
    func claudeSourcesMerge() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let real = home.appendingPathComponent("Code/auspex", isDirectory: true)
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: home.appendingPathComponent(
                ".claude/projects/\(ClaudeProjectPath.encode(cwd: real.path))",
                isDirectory: true
            ),
            withIntermediateDirectories: true
        )
        try """
            {"projects": {"\(real.path)": {}, "/Users/example/Code/only-in-json": {}}}
            """.write(
            to: home.appendingPathComponent(".claude.json"),
            atomically: true,
            encoding: .utf8
        )

        let refs = ClaudeProjectSource(home: home).projects()
        #expect(refs.count == 2)
        // The one with a date sorts first, and it kept the date.
        #expect(refs.first?.path == real.path)
        #expect(refs.first?.lastSeen != nil)
        #expect(refs.last?.path == "/Users/example/Code/only-in-json")
        #expect(refs.last?.lastSeen == nil)
    }

    // MARK: - Codex

    @Test("Every [projects.\"…\"] table in config.toml is a project")
    func codexConfigTables() {
        let paths = CodexProjectSource.projectPaths(inConfig: """
            model = "a-test-model"

            [mcp_servers.auspex]
            command = "auspex"

            [projects."/Users/example/Code/auspex"]
            trust_level = "trusted"

            [projects."/Users/example/Code/auspex".hooks]
            on_start = "echo"

            [projects."/Users/example/my code/.config"]
            trust_level = "trusted"

            [projects."relative"]
            """)

        #expect(paths == [
            "/Users/example/Code/auspex",
            "/Users/example/my code/.config",
        ])
    }

    @Test("The thread catalog gives one entry per directory, newest first")
    func codexCatalog() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let url = home.appendingPathComponent(".codex/sqlite/codex-dev.db")
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        // The shape Codex writes: one row per thread, with the directory it
        // ran in and when it was last touched.
        let queue = try DatabaseQueue(path: url.path)
        try queue.write { db in
            try db.execute(sql: """
                CREATE TABLE local_thread_catalog (
                    host_id TEXT NOT NULL, thread_id TEXT NOT NULL,
                    display_title TEXT NOT NULL, source_created_at REAL NOT NULL,
                    source_updated_at REAL NOT NULL, cwd TEXT NOT NULL,
                    source_kind TEXT NOT NULL,
                    PRIMARY KEY (host_id, thread_id)
                )
                """)
            for (index, row) in [
                ("/Users/example/Code/auspex", 100.0),
                ("/Users/example/Code/auspex", 400.0),
                ("/Users/example/Code/storefront-web", 200.0),
                ("", 900.0),
            ].enumerated() {
                try db.execute(
                    sql: """
                        INSERT INTO local_thread_catalog
                        VALUES ('host', ?, 'a thread', ?, ?, ?, 'rollout')
                        """,
                    arguments: ["t\(index)", row.1, row.1, row.0]
                )
            }
        }

        let refs = CodexProjectSource(home: home).fromCatalog()
        #expect(refs.map(\.path) == [
            "/Users/example/Code/auspex",
            "/Users/example/Code/storefront-web",
        ])
        #expect(refs.first?.lastSeen == Date(timeIntervalSince1970: 400))
        #expect(refs.first?.harness == .codex)
    }

    @Test("A missing catalog and a missing config are empty answers, not errors")
    func missingCodexStores() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let source = CodexProjectSource(home: home)
        #expect(source.projects().isEmpty)
        #expect(CodexProjectSource.projectPaths(inCatalog: source.catalogURL).isEmpty)
    }

    @Test("Both registries are offered, each naming where it read from")
    func registryLists() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let sources = HarnessProjectRegistry.sources(home: home)
        #expect(sources.map(\.harness) == [.claudeCode, .codex])
        #expect(sources[0].location.hasSuffix(".claude/projects"))
        #expect(sources[1].location.hasSuffix(".codex/config.toml"))
    }
}
