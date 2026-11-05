import Foundation
import Testing

@testable import AuspexApp

@Suite("Bundled coordination skill")
struct CoordinationSkillResourceTests {
    @Test("the shipped resource is complete, versioned, and teaches the three roles")
    func bundledPackageLoads() throws {
        let package = try CoordinationSkillResource.package()
        #expect(package.version == "1.3.0")
        #expect(package.contentHash.count == 64)
        #expect(package.files.map(\.relativePath) == ["SKILL.md"])

        let text = try #require(String(data: package.files[0].contents, encoding: .utf8))
        #expect(text.contains("version: \(package.version)"))
        #expect(text.contains("## Supervisor playbook"))
        #expect(text.contains("## Worker playbook"))
        #expect(text.contains("## Reviewer playbook"))
        #expect(text.contains("sessions.self"))
        #expect(text.contains("overview.get"))
        #expect(text.contains("tasks.get"))
        #expect(text.contains("tasks.claim"))
        #expect(text.contains("tasks.release"))
        #expect(text.contains("tasks.complete"))
        #expect(text.contains("expected_version"))
        #expect(text.contains("pending_takeover"))
        #expect(text.contains("do not create or claim an explicit task"))
        #expect(text.contains("MCP unavailable"))
        #expect(text.contains("sessions.self(session_id=<id>)"))
        #expect(text.contains("CODEX_THREAD_ID"))
        // 1.3.0: tasks are briefs a worker can act on and a reviewer can check,
        // and they are filed only to hand work out.
        #expect(text.contains("## How to write a task"))
        #expect(text.contains("acceptance"))
        #expect(text.contains("out_of_scope"))
        #expect(text.contains("deduplicated"))
        #expect(text.contains("include_stale"))
        #expect(text.contains("Create tasks only when you are handing work to"))
    }
}
