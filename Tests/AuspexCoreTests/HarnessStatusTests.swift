import AgentSessionKit
import AgentSessionLive
import Foundation
import Testing

@testable import AuspexCore

@Suite("HarnessStatus")
struct HarnessStatusTests {
    private func session(
        _ harness: Harness,
        _ id: String,
        state: SessionState = .thinking,
        isAlive: Bool = true,
        at offset: TimeInterval = 0
    ) -> SessionSnapshot {
        var snapshot = SessionStateReducer.initialSnapshot(
            identity: SessionIdentity(
                key: SessionKey(harness: harness, sessionID: id),
                sourcePath: "/Users/example/store/\(id).jsonl"
            )
        )
        snapshot.state = state
        snapshot.isAlive = isAlive
        snapshot.lastEventAt = Fixtures.date(offset)
        return snapshot
    }

    @Test("a row is built for every harness asked for, in the order asked")
    func rowsFollowTheOrderGiven() {
        let rows = HarnessStatus.rows(
            harnesses: [.claudeCode, .codex, .cursor],
            board: .empty
        )
        #expect(rows.map(\.harness) == [.claudeCode, .codex, .cursor])
        #expect(rows.allSatisfy { $0.totalCount == 0 && !$0.isDetected })
    }

    @Test("live and idle are counted separately, and an ended session is neither live nor absent")
    func countsSplitLiveFromIdle() throws {
        let board = BoardSnapshot(generatedAt: Fixtures.date(100), sessions: [
            session(.codex, "running", at: 40),
            session(.codex, "quiet", state: .idle, isAlive: false, at: 30),
            session(.codex, "over", state: .ended(reason: .exited), isAlive: false, at: 20),
            session(.cursor, "elsewhere", at: 10)
        ])

        let row = try #require(
            HarnessStatus.rows(harnesses: [.codex], board: board).first
        )
        #expect(row.liveCount == 1)
        #expect(row.idleCount == 2)
        #expect(row.totalCount == 3)
        #expect(row.lastEventAt == Fixtures.date(40))
    }

    @Test("detection is about the store, not about the board")
    func detectionIsIndependentOfSessions() throws {
        // The case that matters: a harness installed with nothing running must
        // not read as absent, and one with a stale session on the board must
        // not read as installed.
        let board = BoardSnapshot(
            generatedAt: Fixtures.date(100),
            sessions: [session(.cursor, "a", at: 10)]
        )

        let rows = HarnessStatus.rows(
            harnesses: [.codex, .cursor],
            board: board,
            storePaths: [.codex: "/Users/example/.codex/sessions"],
            detected: [.codex]
        )

        #expect(rows[0].isDetected)
        #expect(rows[0].totalCount == 0)
        #expect(rows[0].storePath == "/Users/example/.codex/sessions")
        #expect(!rows[1].isDetected)
        #expect(rows[1].totalCount == 1)
        #expect(rows[1].storePath == nil)
    }

    @Test("a harness with no config file carries no MCP cell at all")
    func missingConfigsAreNil() throws {
        let row = try #require(HarnessStatus.rows(harnesses: [.codex], board: .empty).first)
        #expect(row.mcp == nil)
    }
}
