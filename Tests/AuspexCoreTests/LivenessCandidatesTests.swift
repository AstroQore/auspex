import AgentSessionKit
import AgentSessionLive
import Testing

@testable import AuspexCore

@Suite("Liveness candidate scope")
struct LivenessCandidatesTests {
    @Test("only recent reversible process-gone endings remain in the probe set")
    func excludesEndedHistory() {
        var thinking = SessionStateReducer.initialSnapshot(
            identity: Fixtures.identity(key: Fixtures.key(.claudeCode, "thinking"))
        )
        thinking.state = .thinking
        var idle = SessionStateReducer.initialSnapshot(
            identity: Fixtures.identity(key: Fixtures.key(.codex, "idle"))
        )
        idle.state = .idle
        var ended = SessionStateReducer.initialSnapshot(
            identity: Fixtures.identity(key: Fixtures.key(.cursor, "ended"))
        )
        ended.state = .ended(reason: .exited)
        ended.endedAt = Fixtures.date(9)
        var recentGone = SessionStateReducer.initialSnapshot(
            identity: Fixtures.identity(key: Fixtures.key(.grokBuild, "recent-gone"))
        )
        recentGone.state = .ended(reason: .processGone)
        recentGone.endedAt = Fixtures.date(-40)
        var oldGone = SessionStateReducer.initialSnapshot(
            identity: Fixtures.identity(key: Fixtures.key(.grokBot, "old-gone"))
        )
        oldGone.state = .ended(reason: .processGone)
        oldGone.endedAt = Fixtures.date(-51)

        let board = BoardSnapshot(
            generatedAt: Fixtures.date(10),
            sessions: [ended, oldGone, recentGone, idle, thinking]
        )
        let candidates = LivenessCandidates.identities(in: board).map(\.key)
        #expect(candidates.count == 3)
        #expect(Set(candidates) == [idle.key, thinking.key, recentGone.key])

        let direct = LivenessCandidates.identities(
            in: board.sessions,
            now: board.generatedAt
        )
        #expect(Set(direct.map(\.key)) == Set(candidates))
    }
}
