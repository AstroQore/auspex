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
    // MARK: - The plan window

    private func quoted(
        _ harness: Harness,
        _ id: String,
        percent: Double,
        at offset: TimeInterval,
        recordedAt: TimeInterval
    ) -> SessionSnapshot {
        var snapshot = session(harness, id, at: offset)
        snapshot.quota = SessionQuota(
            usedPercent: percent,
            resetsAt: Fixtures.date(recordedAt + 7_800),
            plan: "pro",
            at: Fixtures.date(recordedAt)
        )
        return snapshot
    }

    @Test("the freshest claim wins, not the newest session")
    func freshestQuotaWins() throws {
        let board = BoardSnapshot(generatedAt: Fixtures.date(200), sessions: [
            // Newer session, older reading.
            quoted(.codex, "recent", percent: 12, at: 190, recordedAt: 20),
            // Older session, newer reading — a limit is an account-wide fact,
            // and this is the row that knows the most about it.
            quoted(.codex, "older", percent: 43.2, at: 30, recordedAt: 180)
        ])

        let row = try #require(
            HarnessStatus.rows(harnesses: [.codex], board: board).first
        )
        let quota = try #require(row.quota)
        #expect(quota.usedPercent == 43.2)
        #expect(quota.at == Fixtures.date(180))
        #expect(quota.label(now: Fixtures.date(180)) == "used 43 % · resets in 2 h 10 m · plan pro")
    }

    @Test("a harness whose store records no limit has no line")
    func noQuotaNoLine() throws {
        let board = BoardSnapshot(generatedAt: Fixtures.date(100), sessions: [
            session(.claudeCode, "one", at: 40),
            quoted(.codex, "two", percent: 5, at: 40, recordedAt: 40)
        ])
        let rows = HarnessStatus.rows(harnesses: [.claudeCode, .codex], board: board)
        // Claude Code writes rate limits nowhere. A row saying "limit unknown"
        // on every harness but one would be eight lines of nothing.
        #expect(rows.first?.quota == nil)
        #expect(rows.last?.quota != nil)
    }

    @Test("an empty board has no limits to report")
    func emptyBoard() {
        #expect(HarnessStatus.rows(harnesses: [.codex], board: .empty).first?.quota == nil)
    }

}
