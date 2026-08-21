import AgentSessionKit
import AgentSessionLive
import Foundation
import Testing

@testable import AuspexCore

@Suite("Trajectory · the context lane")
struct TrajectoryContextTests {
    private let key = Fixtures.key()

    private func stored(_ events: [AgentEvent]) throws -> [StoredEvent] {
        let store = try AuspexStore(inMemory: true)
        let repository = SessionRepository(store: store)
        try repository.upsert(snapshot: SessionStateReducer.initialSnapshot(
            identity: Fixtures.identity(key: key)
        ))
        try repository.insertEvents(events)
        return try repository.firstEvents(key: key, limit: 5_000)
    }

    /// A turn per reading: prompt, reply, fill. Enough steps that a reading
    /// anchored to the last one lands somewhere distinguishable.
    private func script() -> [AgentEvent] {
        var events: [AgentEvent] = [
            Fixtures.event(.turnStarted, key: key, at: 0),
            Fixtures.event(.userPrompt(preview: "Start"), key: key, at: 0)
        ]
        let fills = [40_000, 140_000, 184_000]
        for (index, fill) in fills.enumerated() {
            let at = TimeInterval(index * 10 + 1)
            events.append(
                Fixtures.event(.assistantText(preview: "Reply \(index)"), key: key, at: at)
            )
            events.append(
                Fixtures.event(
                    .contextUsage(used: fill, window: 200_000, cached: nil, source: .derived),
                    key: key, at: at
                )
            )
        }
        return events
    }

    // MARK: - Folding

    @Test("a reading is not a step, and lands on the last one that was")
    func readingsAreNotSteps() throws {
        let builder = TrajectoryBuilder.build(from: try stored(script()))
        #expect(builder.contextReadings.count == 3)
        // Nothing happened when the harness wrote a number down, so no step
        // was emitted for it — the same reasoning that keeps `usage` off the
        // timeline.
        #expect(!builder.steps.contains { $0.title.lowercased().contains("context") })
        for reading in builder.contextReadings {
            #expect(builder.steps.indices.contains(reading.stepIndex))
        }
        #expect(builder.contextReadings.map(\.used) == [40_000, 140_000, 184_000])
        #expect(builder.contextReadings.allSatisfy { $0.isDerived })
    }

    @Test("a compaction is both a step and a marker")
    func compactionIsBoth() throws {
        var events = script()
        events.append(Fixtures.event(.compaction, key: key, at: 40))
        let builder = TrajectoryBuilder.build(from: try stored(events))

        #expect(builder.compactionSteps.count == 1)
        let index = try #require(builder.compactionSteps.first)
        #expect(builder.steps[index].title == "Context compacted")
    }

    @Test("a plan limit is not a step at all")
    func quotaIsNotAStep() throws {
        var events = script()
        events.append(
            Fixtures.event(
                .quota(usedPercent: 43, resetsAt: Fixtures.date(9_000), plan: "pro"),
                key: key, at: 41
            )
        )
        let plain = TrajectoryBuilder.build(from: try stored(script()))
        let withQuota = TrajectoryBuilder.build(from: try stored(events))
        #expect(withQuota.steps.count == plain.steps.count)
    }

    // MARK: - Layout

    @Test("readings become a line in unit coordinates, in order")
    func lineIsLaidOut() throws {
        let builder = TrajectoryBuilder.build(from: try stored(script()))
        let spans = TrajectoryLayout.spans(for: builder.steps, scale: .duration, now: nil)
        let line = TrajectoryLayout.contextLine(
            readings: builder.contextReadings,
            compactionSteps: builder.compactionSteps,
            spans: spans
        )

        #expect(line.points.count == 3)
        #expect(line.points.map(\.fill) == [0.2, 0.7, 0.92])
        #expect(line.points.map(\.x) == line.points.map(\.x).sorted())
        #expect(line.points.allSatisfy { $0.x >= 0 && $0.x <= 1 })
        #expect(line.isDerived)
        #expect(abs(line.peak - 0.92) < 0.0001)
        #expect(line.latest?.used == 184_000)
    }

    @Test("the line is laid out under every scale, not only the clock")
    func everyScale() throws {
        let builder = TrajectoryBuilder.build(from: try stored(script()))
        for scale in TrajectoryScale.allCases {
            let spans = TrajectoryLayout.spans(for: builder.steps, scale: scale, now: nil)
            let line = TrajectoryLayout.contextLine(
                readings: builder.contextReadings,
                compactionSteps: builder.compactionSteps,
                spans: spans
            )
            #expect(line.points.count == 3, "\(scale)")
            #expect(line.points.map(\.x) == line.points.map(\.x).sorted(), "\(scale)")
        }
    }

    @Test("a compaction places a marker where its step is")
    func compactionMarker() throws {
        var events = script()
        events.append(Fixtures.event(.compaction, key: key, at: 40))
        let builder = TrajectoryBuilder.build(from: try stored(events))
        let spans = TrajectoryLayout.spans(for: builder.steps, scale: .duration, now: nil)
        let line = TrajectoryLayout.contextLine(
            readings: builder.contextReadings,
            compactionSteps: builder.compactionSteps,
            spans: spans
        )

        #expect(line.compactions.count == 1)
        let cut = try #require(line.compactions.first)
        let step = try #require(builder.compactionSteps.first)
        #expect(cut == spans[step].start)
    }

    @Test("a measured window is not marked as derived")
    func measuredLine() throws {
        let events = [
            Fixtures.event(.turnStarted, key: key, at: 0),
            Fixtures.event(.userPrompt(preview: "Start"), key: key, at: 0),
            Fixtures.event(
                .contextUsage(used: 61_300, window: 500_000, cached: nil, source: .measured),
                key: key, at: 1
            )
        ]
        let builder = TrajectoryBuilder.build(from: try stored(events))
        let spans = TrajectoryLayout.spans(for: builder.steps, scale: .duration, now: nil)
        let line = TrajectoryLayout.contextLine(
            readings: builder.contextReadings,
            compactionSteps: builder.compactionSteps,
            spans: spans
        )
        #expect(!line.isDerived)
        #expect(line.points.count == 1)
    }

    // MARK: - Nothing to draw

    @Test("a reading with no window cannot be placed on a lane and is dropped")
    func noWindowNoPoint() throws {
        let events = [
            Fixtures.event(.turnStarted, key: key, at: 0),
            Fixtures.event(.userPrompt(preview: "Start"), key: key, at: 0),
            Fixtures.event(
                .contextUsage(used: 61_300, window: nil, cached: nil, source: .measured),
                key: key, at: 1
            )
        ]
        let builder = TrajectoryBuilder.build(from: try stored(events))
        #expect(builder.contextReadings.count == 1)
        let spans = TrajectoryLayout.spans(for: builder.steps, scale: .duration, now: nil)
        let line = TrajectoryLayout.contextLine(
            readings: builder.contextReadings,
            compactionSteps: builder.compactionSteps,
            spans: spans
        )
        #expect(line.isEmpty)
    }

    @Test("a harness that records nothing draws no lane")
    func noReadingsNoLane() throws {
        let builder = TrajectoryBuilder.build(from: try stored([
            Fixtures.event(.turnStarted, key: key, at: 0),
            Fixtures.event(.userPrompt(preview: "Start"), key: key, at: 0),
            Fixtures.event(.assistantText(preview: "Done"), key: key, at: 1)
        ]))
        let spans = TrajectoryLayout.spans(for: builder.steps, scale: .duration, now: nil)
        let line = TrajectoryLayout.contextLine(
            readings: builder.contextReadings, compactionSteps: [], spans: spans
        )
        #expect(line.isEmpty)
    }

    @Test("an empty waterfall places nothing rather than dividing by it")
    func emptySpans() {
        let reading = TrajectoryContextReading(
            stepIndex: 0, used: 10, window: 100, at: Fixtures.date(0), isDerived: false
        )
        #expect(
            TrajectoryLayout.contextLine(
                readings: [reading], compactionSteps: [0], spans: []
            ).isEmpty
        )
    }

    @Test("a reading naming a step the waterfall does not have is dropped")
    func outOfRangeReading() throws {
        let builder = TrajectoryBuilder.build(from: try stored(script()))
        let spans = TrajectoryLayout.spans(for: builder.steps, scale: .duration, now: nil)
        let stray = TrajectoryContextReading(
            stepIndex: 9_999, used: 10, window: 100, at: Fixtures.date(0), isDerived: false
        )
        let line = TrajectoryLayout.contextLine(
            readings: [stray], compactionSteps: [9_999], spans: spans
        )
        #expect(line.isEmpty)
        #expect(line.compactions.isEmpty)
    }

    @Test("an overfull window is drawn at the top of the lane, not outside it")
    func overfullIsClamped() {
        let point = TrajectoryContextLine.Point(x: 1.4, fill: 1.3, used: 260_000, window: 200_000)
        #expect(point.x == 1)
        #expect(point.fill == 1)
        // The counts are untouched: the lane clamps, the tooltip tells.
        #expect(point.used == 260_000)
    }
}
