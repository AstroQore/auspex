import AgentSessionKit
import AgentSessionLive
import Foundation
import Testing

@testable import AuspexCore

@Suite("ContextCompositionEstimator")
struct ContextCompositionEstimatorTests {
    private func gauge(
        used: Int,
        window: Int? = 200_000,
        source: ContextUsage.Source = .derived
    ) -> ContextGauge {
        ContextGauge(
            usage: ContextUsage(
                used: used, window: window, cached: nil, at: Fixtures.date(0), source: source
            ),
            compactions: 0
        )!
    }

    /// Characters, so a test says what it means: 40,000 characters of prompt
    /// and reply is 10,000 tokens at the estimator's four-to-one.
    private func volume(
        user: Int = 0,
        assistant: Int = 0,
        toolResult: Int = 0,
        events: Int = 4,
        truncated: Bool = false,
        sinceCompaction: Bool = false
    ) -> ContextTextVolume {
        ContextTextVolume(
            userCharacters: user,
            assistantCharacters: assistant,
            toolResultCharacters: toolResult,
            events: events,
            isTruncated: truncated,
            sinceCompaction: sinceCompaction
        )
    }

    @Test("four characters to the token, and the rest is what was left over")
    func measuredAndInferred() throws {
        let composition = try #require(
            ContextCompositionEstimator.estimate(
                volume: volume(user: 8_000, assistant: 32_000, toolResult: 60_000),
                gauge: gauge(used: 100_000)
            )
        )
        // (8,000 + 32,000) / 4 and 60,000 / 4.
        #expect(composition.slice(.messages)?.tokens == 10_000)
        #expect(composition.slice(.toolResults)?.tokens == 15_000)
        // Everything the harness put in the window and wrote nowhere.
        #expect(composition.slice(.everythingElse)?.tokens == 75_000)
        #expect(composition.slice(.free)?.tokens == 100_000)
        #expect(!composition.isOverEstimated)
    }

    @Test("the bands are fractions of the window, and they add up to it")
    func fractionsCoverTheWindow() throws {
        let composition = try #require(
            ContextCompositionEstimator.estimate(
                volume: volume(user: 40_000, toolResult: 40_000),
                gauge: gauge(used: 100_000)
            )
        )
        let total = composition.slices.map(\.fraction).reduce(0, +)
        #expect(abs(total - 1) < 0.0001)
        #expect(composition.slice(.free)?.fraction == 0.5)
    }

    @Test("an over-count is scaled to fit rather than clipped")
    func overEstimateIsScaled() throws {
        // 400,000 characters is 100,000 tokens by the rule of thumb, against a
        // measured fill of 40,000: source and JSON run denser than four
        // characters to the token, and this is what that looks like.
        let composition = try #require(
            ContextCompositionEstimator.estimate(
                volume: volume(user: 200_000, toolResult: 200_000),
                gauge: gauge(used: 40_000)
            )
        )
        #expect(composition.isOverEstimated)
        let messages = try #require(composition.slice(.messages)?.tokens)
        let tools = try #require(composition.slice(.toolResults)?.tokens)
        #expect(messages + tools == 40_000)
        // The ratio between the two is the part worth reading, and it survives.
        #expect(messages == tools)
        #expect(composition.slice(.everythingElse)?.tokens == 0)
    }

    @Test("a window nobody could size has no composition")
    func noWindowNoComposition() {
        #expect(
            ContextCompositionEstimator.estimate(
                volume: volume(user: 8_000), gauge: gauge(used: 100_000, window: nil)
            ) == nil
        )
    }

    @Test("a window the gauge refused is a window the bar cannot be drawn against")
    func overflowedWindowHasNoComposition() {
        // 850,100 out of a reported 200,000: the denominator is wrong, so
        // every band would be wrong with it.
        let overflowed = ContextGauge(
            usage: ContextUsage(
                used: 850_100, window: 200_000, cached: nil,
                at: Fixtures.date(0), source: .derived
            ),
            compactions: 0
        )!
        #expect(overflowed.overflowedWindow)
        #expect(
            ContextCompositionEstimator.estimate(
                volume: volume(user: 8_000), gauge: overflowed
            ) == nil
        )
    }

    @Test("nothing indexed is no bar, rather than a bar that is all remainder")
    func nothingIndexed() {
        #expect(
            ContextCompositionEstimator.estimate(volume: .empty, gauge: gauge(used: 100_000)) == nil
        )
    }

    @Test("a fill Auspex saw almost none of says so")
    func mostlyUnattributed() throws {
        let thin = try #require(
            ContextCompositionEstimator.estimate(
                volume: volume(user: 400, assistant: 400),
                gauge: gauge(used: 96_400)
            )
        )
        // 200 tokens out of 96,400: the remainder is "we did not see this",
        // not a claim about a system prompt.
        #expect(thin.isMostlyUnattributed)

        let full = try #require(
            ContextCompositionEstimator.estimate(
                volume: volume(user: 200_000, toolResult: 100_000),
                gauge: gauge(used: 100_000)
            )
        )
        #expect(!full.isMostlyUnattributed)
    }

    @Test("the flags the caption reads travel with the estimate")
    func flagsTravel() throws {
        let composition = try #require(
            ContextCompositionEstimator.estimate(
                volume: volume(
                    user: 8_000, events: 4_000, truncated: true, sinceCompaction: true
                ),
                gauge: gauge(used: 100_000)
            )
        )
        #expect(composition.isTruncated)
        #expect(composition.sinceCompaction)
        #expect(composition.sampledEvents == 4_000)
        #expect(composition.window == 200_000)
        #expect(composition.used == 100_000)
    }

    @Test("only the two counted bands claim to have been measured")
    func measuredBandsAreMarked() throws {
        let composition = try #require(
            ContextCompositionEstimator.estimate(
                volume: volume(user: 8_000), gauge: gauge(used: 100_000)
            )
        )
        #expect(composition.slice(.messages)?.isMeasured == true)
        #expect(composition.slice(.toolResults)?.isMeasured == true)
        #expect(composition.slice(.everythingElse)?.isMeasured == false)
        #expect(composition.slice(.free)?.isMeasured == false)
    }
}

@Suite("SessionRepository · indexed prose behind a window")
struct ContextTextVolumeTests {
    private let key = Fixtures.key()

    private func repository(_ events: [AgentEvent]) throws -> SessionRepository {
        let store = try AuspexStore(inMemory: true)
        let repository = SessionRepository(store: store)
        try repository.upsert(snapshot: SessionStateReducer.initialSnapshot(
            identity: Fixtures.identity(key: key)
        ))
        try repository.insertEvents(events)
        return repository
    }

    @Test("bodies are counted by role, in characters")
    func countsByRole() throws {
        let repository = try repository([
            Fixtures.event(.textBody(role: .user, text: "abcde", toolCallID: nil), key: key, at: 1),
            Fixtures.event(
                .textBody(role: .assistant, text: "0123456789", toolCallID: nil), key: key, at: 2
            ),
            Fixtures.event(
                .textBody(role: .toolResult, text: "xy", toolCallID: "c1"), key: key, at: 3
            ),
            // Not a body, and not counted.
            Fixtures.event(.userPrompt(preview: "ignored"), key: key, at: 4)
        ])

        let volume = try repository.contextTextVolume(key: key)
        #expect(volume.userCharacters == 5)
        #expect(volume.assistantCharacters == 10)
        #expect(volume.toolResultCharacters == 2)
        #expect(volume.events == 3)
        #expect(!volume.isTruncated)
        #expect(!volume.sinceCompaction)
    }

    @Test("the count starts after the newest compaction")
    func startsAfterCompaction() throws {
        let repository = try repository([
            // Before the compaction: gone from the window, and from the count.
            Fixtures.event(
                .textBody(role: .user, text: String(repeating: "a", count: 400), toolCallID: nil),
                key: key, at: 1
            ),
            Fixtures.event(.compaction, key: key, at: 2),
            Fixtures.event(
                .textBody(role: .user, text: "after", toolCallID: nil), key: key, at: 3
            )
        ])

        let volume = try repository.contextTextVolume(key: key)
        #expect(volume.userCharacters == 5)
        #expect(volume.events == 1)
        #expect(volume.sinceCompaction)
    }

    @Test("a cap keeps the newest bodies and admits it dropped the rest")
    func capKeepsTheNewest() throws {
        let repository = try repository((0..<6).map { index in
            Fixtures.event(
                .textBody(role: .user, text: "abcd", toolCallID: nil),
                key: key, at: TimeInterval(index)
            )
        })

        let volume = try repository.contextTextVolume(key: key, limit: 2)
        #expect(volume.events == 2)
        #expect(volume.userCharacters == 8)
        #expect(volume.isTruncated)
    }

    @Test("a session with nothing indexed answers empty rather than failing")
    func emptySession() throws {
        let repository = try repository([
            Fixtures.event(.thinking, key: key, at: 1)
        ])
        #expect(try repository.contextTextVolume(key: key).isEmpty)
        #expect(try repository.contextTextVolume(key: key, limit: 0) == .empty)
    }
}
