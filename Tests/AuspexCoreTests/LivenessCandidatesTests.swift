import AgentSessionKit
import AgentSessionLive
import Testing

@testable import AuspexCore

@Suite("Liveness candidate scope")
struct LivenessCandidatesTests {
    @Test("ended history is never re-probed while live and resumable sessions remain")
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

        let board = BoardSnapshot(
            generatedAt: Fixtures.date(10), sessions: [ended, idle, thinking]
        )
        let candidates = LivenessCandidates.identities(in: board).map(\.key)
        #expect(candidates.count == 2)
        #expect(Set(candidates) == [idle.key, thinking.key])
    }
}
