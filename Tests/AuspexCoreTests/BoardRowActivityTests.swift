import AgentSessionKit
import AgentSessionLive
import Foundation
import Testing

@testable import AuspexCore

/// The card's own line for a harness that reports only "somebody is needed".
@Suite("BoardRow, tool-less permission")
struct ToollessPermissionRowTests {
    private func waiting(tool: String?) -> SessionSnapshot {
        let key = SessionKey(harness: .grokBot, sessionID: "bot-1")
        var snapshot = SessionStateReducer.initialSnapshot(
            identity: SessionIdentity(key: key, sourcePath: "/Users/example/store/bot-1.blob")
        )
        snapshot.state = .waitingPermission(tool: tool)
        snapshot.isAlive = true
        return snapshot
    }

    @Test("a permission with no tool asks for an answer, not for a tool")
    func toollessPermissionIsNotATool() {
        // Grok Bot's roster carries a flag and never a tool name. "a tool"
        // would be inventing the one fact the store does not have.
        #expect(BoardRowBuilder.activity(for: waiting(tool: nil)) == "an answer")
        #expect(BoardRowBuilder.activity(for: waiting(tool: "Bash")) == "Bash")
    }
}
