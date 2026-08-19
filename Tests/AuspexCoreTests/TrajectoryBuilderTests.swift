import AgentSessionKit
import AgentSessionLive
import Foundation
import Testing

@testable import AuspexCore

@Suite("TrajectoryBuilder")
struct TrajectoryBuilderTests {
    /// Writes a script through the store and reads it back as stored events.
    ///
    /// The same bargain `TraceEntryTests` makes: `StoredEvent` is only
    /// constructible from a database row, so the fold is exercised over the
    /// real round trip rather than over hand-built rows that could drift from
    /// the schema.
    private func stored(
        _ events: [AgentEvent],
        key: SessionKey = Fixtures.key()
    ) throws -> [StoredEvent] {
        let store = try AuspexStore(inMemory: true)
        let repository = SessionRepository(store: store)
        try repository.upsert(snapshot: SessionStateReducer.initialSnapshot(
            identity: Fixtures.identity(key: key)
        ))
        try repository.insertEvents(events)
        return try repository.firstEvents(key: key, limit: 5_000)
    }

    /// One full turn: a prompt, three model requests, two tool calls, one of
    /// which fails, and the accounting at the end.
    private func script(key: SessionKey = Fixtures.key()) -> [AgentEvent] {
        [
            Fixtures.event(.sessionStarted(identity: Fixtures.identity(key: key)), key: key, at: 0),
            Fixtures.event(.turnStarted, key: key, at: 1),
            Fixtures.event(.userPrompt(preview: "Add the trajectory view"), key: key, at: 1),
            Fixtures.event(
                .textBody(role: .user, text: "Add the trajectory view, please", toolCallID: nil),
                key: key, at: 1
            ),
            Fixtures.event(.thinking, key: key, at: 2),
            Fixtures.event(.assistantText(preview: "Reading the repository first."), key: key, at: 3),
            Fixtures.event(
                .toolCallStarted(
                    id: "c1", name: "Read", kind: .fileRead, target: "Store/SessionRepository.swift"
                ),
                key: key, at: 4,
                raw: RawRef(
                    path: "/Users/example/.claude/projects/widget/t.jsonl",
                    byteOffset: 4_096
                )
            ),
            Fixtures.event(
                .textBody(role: .toolResult, text: "public struct SessionRepository {\n…", toolCallID: "c1"),
                key: key, at: 6
            ),
            Fixtures.event(.toolCallFinished(id: "c1", isError: false), key: key, at: 6),
            Fixtures.event(.thinking, key: key, at: 7),
            Fixtures.event(
                .toolCallStarted(id: "c2", name: "Bash", kind: .shell, target: "swift test"),
                key: key, at: 9
            ),
            Fixtures.event(.toolCallFinished(id: "c2", isError: true), key: key, at: 12),
            Fixtures.event(
                .assistantText(preview: "One fixture has a null timestamp."), key: key, at: 13
            ),
            Fixtures.event(
                .usage(model: "a-test-model", inputTokens: 1_000, outputTokens: 200, cachedTokens: 500),
                key: key, at: 14
            ),
            Fixtures.event(.turnEnded(reason: .complete), key: key, at: 15),
            Fixtures.event(.sessionEnded(reason: .exited), key: key, at: 16)
        ]
    }

    // MARK: - Steps

    @Test("every event that is a step becomes one, and the rest do not")
    func rolesFollowTheLog() throws {
        let builder = TrajectoryBuilder.build(from: try stored(script()))

        #expect(builder.steps.map(\.role) == [
            .system,      // session started
            .user,        // the prompt
            .assistant,   // thinking
            .assistant,   // the first message
            .tool,        // Read
            .assistant,   // thinking again
            .tool,        // Bash
            .assistant,   // the last message
            .system       // session ended
        ])
        // A turn boundary, a usage record, and a text body are facts *about*
        // steps rather than steps of their own; folding them into rows would
        // make a nine-step turn read as fourteen.
        #expect(builder.steps.count == 9)
    }

    @Test("a tool call collapses into one step carrying its duration and result")
    func toolCallsCollapse() throws {
        let builder = TrajectoryBuilder.build(from: try stored(script()))
        let read = try #require(builder.steps.first { $0.toolCallID == "c1" })

        #expect(read.title == "Read")
        #expect(read.argsPreview == "Store/SessionRepository.swift")
        #expect(read.duration == 2)
        #expect(read.isError == false)
        #expect(read.resultPreview == "public struct SessionRepository {")
        #expect(read.body?.contains("SessionRepository") == true)
        #expect(read.raw?.path.hasSuffix("t.jsonl") == true)
        #expect(read.raw?.offset == 4_096)
    }

    @Test("a failed call is marked, and its turn says so")
    func failuresPropagateToTheTurn() throws {
        let builder = TrajectoryBuilder.build(from: try stored(script()))
        let bash = try #require(builder.steps.first { $0.toolCallID == "c2" })

        #expect(bash.isError)
        #expect(bash.duration == 3)
        #expect(builder.turns.last?.hasError == true)
        // The gutter marks a failure once per turn; a turn with no failure in
        // it must not be marked because a *later* turn failed.
        #expect(builder.turns.first?.hasError == false)
    }

    @Test("a prompt carries its full text, not just the preview")
    func promptsCarryTheirBody() throws {
        let builder = TrajectoryBuilder.build(from: try stored(script()))
        let prompt = try #require(builder.steps.first { $0.role == .user })

        #expect(prompt.title == "Add the trajectory view")
        #expect(prompt.body == "Add the trajectory view, please")
    }

    // MARK: - Turns

    @Test("everything before the first turn is turn zero")
    func preambleIsTurnZero() throws {
        let builder = TrajectoryBuilder.build(from: try stored(script()))

        #expect(builder.turns.map(\.index) == [0, 1])
        #expect(builder.turns[0].stepRange == 0...0)
        #expect(builder.steps[0].turn == 0)
        #expect(builder.steps[1].turn == 1)
        // The closing banner belongs to the turn it happened in, not to a turn
        // of its own — a session that ends after its last turn closed would
        // otherwise grow a phantom column on the timeline.
        #expect(builder.steps.last?.turn == 1)
        #expect(builder.turns[1].stepRange.upperBound == builder.steps.count - 1)
    }

    @Test("a turn counts its requests and sums its tokens")
    func turnsCountRequestsAndTokens() throws {
        let builder = TrajectoryBuilder.build(from: try stored(script()))
        let turn = try #require(builder.turns.last)

        // Prompt → model, tool result → model, tool result → model. Three
        // calls to a model for one thing a person asked for.
        #expect(turn.requestCount == 3)
        #expect(turn.tokens?.input == 1_000)
        #expect(turn.tokens?.output == 200)
        #expect(turn.tokens?.cached == 500)
        // The turn ended when the log said it did, not when the session
        // afterwards exited.
        #expect(turn.end == Fixtures.date(15))
    }

    // MARK: - Requests

    @Test("a request opens with the turn and again after every tool call")
    func requestBoundariesFollowTheTools() throws {
        let builder = TrajectoryBuilder.build(from: try stored(script()))

        #expect(builder.requests.map(\.index) == [1, 2, 3])
        #expect(builder.requests[0].started == Fixtures.date(1))
        #expect(builder.requests[0].ended == Fixtures.date(4))
        #expect(builder.requests[1].started == Fixtures.date(6))
        #expect(builder.requests[1].ended == Fixtures.date(9))
        #expect(builder.requests[2].started == Fixtures.date(12))
        #expect(builder.requests[2].ended == Fixtures.date(15))
    }

    @Test("timing is measured between observed records, never guessed")
    func timingIsMeasured() throws {
        let builder = TrajectoryBuilder.build(from: try stored(script()))
        let first = builder.requests[0]

        // Handed the floor at t=1, said its first thing at t=2.
        #expect(first.timeToFirstToken == 1)
        // First chunk at t=2, last at t=3.
        #expect(first.generation == 1)
        #expect(first.duration == 3)

        // A request whose only chunk was one event has no measurable
        // generation span, and therefore no throughput: reporting zero seconds
        // would make the tokens-per-second below it infinite.
        #expect(builder.requests[1].generation == nil)
        #expect(builder.requests[1].throughput == nil)
    }

    @Test("usage lands on the request it was billed for, and on its step")
    func usageLandsOnTheRequest() throws {
        let builder = TrajectoryBuilder.build(from: try stored(script()))

        #expect(builder.requests[0].tokens == nil)
        #expect(builder.requests[2].tokens?.output == 200)
        #expect(builder.requests[2].throughput == nil)  // one chunk, no span

        let billed = try #require(builder.steps.last { $0.tokens != nil })
        #expect(billed.role == .assistant)
        #expect(billed.title == "One fixture has a null timestamp.")
        #expect(billed.tokens?.input == 1_000)
    }

    @Test("a harness that reports no usage leaves every token field nil")
    func missingUsageStaysNil() throws {
        let key = Fixtures.key(.cursor, "b8d31f0a4c7e2916")
        let builder = TrajectoryBuilder.build(from: try stored([
            Fixtures.event(.turnStarted, key: key, at: 0),
            Fixtures.event(.userPrompt(preview: "Rename the stepper"), key: key, at: 0),
            Fixtures.event(.assistantText(preview: "Renamed it."), key: key, at: 2),
            Fixtures.event(.turnEnded(reason: .complete), key: key, at: 3)
        ], key: key))

        #expect(builder.turns.allSatisfy { $0.tokens == nil })
        #expect(builder.requests.allSatisfy { $0.tokens == nil })
        #expect(builder.steps.allSatisfy { $0.tokens == nil })
        #expect(builder.requests.allSatisfy { $0.throughput == nil })
    }

    @Test("usage that arrives after its request closed still lands on it")
    func lateUsageIsNotDropped() throws {
        let key = Fixtures.key()
        let builder = TrajectoryBuilder.build(from: try stored([
            Fixtures.event(.turnStarted, key: key, at: 0),
            Fixtures.event(.assistantText(preview: "Done."), key: key, at: 1),
            Fixtures.event(.turnEnded(reason: .complete), key: key, at: 2),
            // Several harnesses write the accounting record after the turn.
            Fixtures.event(
                .usage(model: nil, inputTokens: 40, outputTokens: 9, cachedTokens: 0),
                key: key, at: 3
            )
        ], key: key))

        #expect(builder.requests.last?.tokens?.output == 9)
        #expect(builder.turns.last?.tokens?.input == 40)
    }

    // MARK: - Incremental

    @Test("folding in pieces gives exactly what folding all at once gives")
    func incrementalEqualsFullRebuild() throws {
        let events = try stored(script())
        let whole = TrajectoryBuilder.build(from: events)

        for chunkSize in [1, 2, 3, 5, 7, 11] {
            var incremental = TrajectoryBuilder()
            var index = 0
            while index < events.count {
                let end = min(index + chunkSize, events.count)
                incremental.append(Array(events[index..<end]))
                index = end
            }
            #expect(incremental.steps == whole.steps, "chunk size \(chunkSize)")
            #expect(incremental.turns == whole.turns, "chunk size \(chunkSize)")
            #expect(incremental.requests == whole.requests, "chunk size \(chunkSize)")
            #expect(incremental.lastEventID == whole.lastEventID, "chunk size \(chunkSize)")
        }
    }

    @Test("re-offering events already folded changes nothing")
    func overlappingWindowsAreIdempotent() throws {
        let events = try stored(script())
        var builder = TrajectoryBuilder()
        builder.append(Array(events.prefix(8)))
        let afterFirst = builder.steps

        // A caller that re-reads an overlapping window — which is exactly what
        // a debounced refresh does when a frame arrives mid-flush — must not
        // double-count.
        builder.append(Array(events.prefix(8)))
        #expect(builder.steps == afterFirst)

        builder.append(events)
        #expect(builder.steps == TrajectoryBuilder.build(from: events).steps)
    }

    @Test("an open turn is republished rather than appended twice")
    func openTurnIsPatchedInPlace() throws {
        let events = try stored(script())
        var builder = TrajectoryBuilder()
        builder.append(Array(events.prefix(6)))
        #expect(builder.turns.count == 2)
        #expect(builder.turns.last?.end == nil)

        builder.append(Array(events.dropFirst(6)))
        #expect(builder.turns.count == 2)
        #expect(builder.turns.last?.end == Fixtures.date(15))
    }

    // MARK: - Search

    @Test("a step indexes its role, its title, its arguments, and its result")
    func stepsAreSearchable() throws {
        let builder = TrajectoryBuilder.build(from: try stored(script()))
        let bash = try #require(builder.steps.first { $0.toolCallID == "c2" })

        #expect(bash.matches(lowercasedQuery: "swift test"))
        #expect(bash.matches(lowercasedQuery: "tool"))
        #expect(bash.matches(lowercasedQuery: ""))
        #expect(!bash.matches(lowercasedQuery: "trajectory"))

        let read = try #require(builder.steps.first { $0.toolCallID == "c1" })
        #expect(read.matches(lowercasedQuery: "sessionrepository"))
    }
}
