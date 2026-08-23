import Foundation
import Testing

@testable import AuspexApp

@Suite("Bundled coordination skill")
struct CoordinationSkillResourceTests {
    @Test("the shipped resource is complete, versioned, and teaches the three roles")
    func bundledPackageLoads() throws {
        let package = try CoordinationSkillResource.package()
        #expect(package.version == "1.0.0")
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
        #expect(text.contains("do not create or claim an explicit task"))
        #expect(text.contains("MCP unavailable"))
    }
}
