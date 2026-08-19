import Foundation
import Testing

@testable import AuspexCore

@Suite("TrajectoryLayout")
struct TrajectoryLayoutTests {
    /// A hand-built step, so the layout suite is about geometry and not about
    /// the fold that produced it.
    private func step(
        _ index: Int,
        turn: Int,
        role: TrajectoryRole,
        from start: TimeInterval,
        to end: TimeInterval? = nil,
        isError: Bool = false
    ) -> TrajectoryStep {
        TrajectoryStep(
            id: Int64(index + 1),
            index: index,
            turn: turn,
            request: 1,
            role: role,
            start: Fixtures.date(start),
            end: end.map(Fixtures.date),
            title: "step \(index)",
            isError: isError
        )
    }

    /// Ten seconds, three steps: a prompt at 0, a model answer at 1, and a
    /// tool call that runs from 2 to 10.
    private var simple: [TrajectoryStep] {
        [
            step(0, turn: 1, role: .user, from: 0),
            step(1, turn: 1, role: .assistant, from: 1),
            step(2, turn: 1, role: .tool, from: 2, to: 10)
        ]
    }

    // MARK: - Duration

    @Test("Duration lays every bar out against the wall clock")
    func durationIsProportional() {
        let spans = TrajectoryLayout.spans(for: simple, scale: .duration)

        #expect(spans.count == 3)
        // The prompt is an instant; its bar runs to the next thing observed,
        // which is the only honest width an instant can be drawn at.
        #expect(spans[0].start == 0)
        #expect(spans[0].end == 0.1)
        #expect(spans[1].start == 0.1)
        #expect(spans[1].end == 0.2)
        // The tool call has a recorded close, so it is drawn at its real
        // length: eight of the session's ten seconds.
        #expect(spans[2].start == 0.2)
        #expect(spans[2].end == 1.0)
    }

    @Test("each role is drawn in its own lane")
    func lanesFollowRoles() {
        let spans = TrajectoryLayout.spans(for: simple, scale: .duration)
        #expect(spans.map(\.lane) == [.input, .model, .tools])
        #expect(TrajectoryRole.system.lane == .input)
    }

    @Test("a live session's axis runs to now, not to its last event")
    func liveAxisRunsToNow() {
        // Nothing has happened for the last ten seconds; the tool call must
        // therefore occupy the first half of the axis rather than all of it.
        let spans = TrajectoryLayout.spans(
            for: simple, scale: .duration, now: Fixtures.date(20)
        )
        #expect(spans[2].end == 0.5)
        #expect(TrajectoryLayout.cursor(for: simple, scale: .duration, now: Fixtures.date(20)) == 1)
        // The other two scales have taken time off the axis, so a cursor on
        // them would be pointing at nothing.
        #expect(TrajectoryLayout.cursor(for: simple, scale: .calls, now: Fixtures.date(20)) == nil)
    }

    @Test("a session whose events share one instant falls back to equal columns")
    func zeroLengthSessionsDoNotDivideByZero() {
        let steps = (0..<4).map { step($0, turn: 1, role: .tool, from: 0) }
        let spans = TrajectoryLayout.spans(for: steps, scale: .duration)

        #expect(spans.map(\.start) == [0, 0.25, 0.5, 0.75])
        #expect(spans.map(\.end) == [0.25, 0.5, 0.75, 1.0])
    }

    @Test("an empty trajectory lays out to nothing")
    func emptyIsTotal() {
        for scale in TrajectoryScale.allCases {
            #expect(TrajectoryLayout.spans(for: [], scale: scale).isEmpty)
            #expect(TrajectoryLayout.ticks(for: [], scale: scale).isEmpty)
        }
    }

    // MARK: - Turns

    @Test("Turns gives every turn the same width, however long it took")
    func turnsAreEqualColumns() {
        // Turn 1 takes a second, turn 2 takes ninety-nine. Duration would draw
        // the first as a hairline; Turns is the mode that refuses to.
        let steps = [
            step(0, turn: 1, role: .user, from: 0),
            step(1, turn: 1, role: .assistant, from: 0.5, to: 1),
            step(2, turn: 2, role: .user, from: 1),
            step(3, turn: 2, role: .tool, from: 1, to: 100)
        ]
        let spans = TrajectoryLayout.spans(for: steps, scale: .turns)

        #expect(spans[0].start == 0)
        #expect(spans[1].end == 0.5)
        #expect(spans[2].start == 0.5)
        #expect(spans[3].end == 1.0)
        // Inside a column the bars are still proportional to what happened in
        // that turn: the answer began halfway through the second it took.
        #expect(abs(spans[1].start - 0.25) < 1e-9)
    }

    @Test("a turn whose steps share one instant spreads them evenly")
    func degenerateTurnsSpreadEvenly() {
        let steps = [
            step(0, turn: 1, role: .user, from: 0),
            step(1, turn: 1, role: .assistant, from: 0),
            step(2, turn: 2, role: .tool, from: 5, to: 9)
        ]
        let spans = TrajectoryLayout.spans(for: steps, scale: .turns)

        #expect(spans[0].start == 0)
        #expect(spans[0].end == 0.25)
        #expect(spans[1].start == 0.25)
        #expect(spans[1].end == 0.5)
    }

    // MARK: - Calls

    @Test("Calls gives every step the same width")
    func callsAreEqualColumns() {
        let spans = TrajectoryLayout.spans(for: simple, scale: .calls)
        let widths = spans.map(\.width)

        #expect(widths.allSatisfy { abs($0 - 1.0 / 3) < 1e-9 })
        #expect(spans.first?.start == 0)
        #expect(spans.last?.end == 1)
    }

    // MARK: - Ticks

    @Test("the axis is labelled in the units its scale measures")
    func ticksMatchTheScale() {
        let duration = TrajectoryLayout.ticks(for: simple, scale: .duration, count: 3)
        #expect(duration.map(\.position) == [0, 0.5, 1])
        #expect(duration.first?.label == "0s")
        #expect(duration.last?.label == "10s")
        #expect(duration.allSatisfy { !$0.isDivider })

        let steps = simple + [step(3, turn: 2, role: .user, from: 11)]
        let turns = TrajectoryLayout.ticks(for: steps, scale: .turns, count: 6)
        #expect(turns.map(\.label) == ["T1", "T2"])
        #expect(turns.allSatisfy { $0.isDivider })

        let calls = TrajectoryLayout.ticks(for: simple, scale: .calls, count: 6)
        #expect(calls.map(\.label) == ["#1", "#2", "#3"])
    }

    @Test("a long session's axis keeps its label count bounded")
    func ticksAreThinnedOnLongSessions() {
        let steps = (0..<400).map { step($0, turn: $0 / 4 + 1, role: .tool, from: Double($0)) }
        #expect(TrajectoryLayout.ticks(for: steps, scale: .turns, count: 6).count <= 6 + 1)
        #expect(TrajectoryLayout.ticks(for: steps, scale: .calls, count: 6).count <= 6 + 1)
    }

    // MARK: - Brushing

    @Test("a brush keeps every row whose bar it touches")
    func brushSelectsCrossingBars() {
        let spans = TrajectoryLayout.spans(for: simple, scale: .duration)

        // The first tenth holds only the prompt.
        let head = TrajectoryLayout.steps(simple, in: 0...0.09, spans: spans)
        #expect(head.map(\.index) == [0])

        // The last half holds only the tool call — which starts before the
        // range and must still be kept, because a bar the reader dragged over
        // is a bar they selected.
        let tail = TrajectoryLayout.steps(simple, in: 0.5...1, spans: spans)
        #expect(tail.map(\.index) == [2])

        // A range that touches the boundary between two bars keeps both.
        let middle = TrajectoryLayout.steps(simple, in: 0.1...0.2, spans: spans)
        #expect(middle.map(\.index) == [0, 1, 2])
    }

    @Test("no brush keeps everything, and a brush past the data keeps nothing")
    func brushEdgesAreTotal() {
        let spans = TrajectoryLayout.spans(for: simple, scale: .calls)

        #expect(TrajectoryLayout.steps(simple, in: nil, spans: spans).count == 3)
        #expect(TrajectoryLayout.steps(simple, in: 0.99...1, spans: spans).map(\.index) == [2])
        // A brush and a span array that do not describe the same trajectory is
        // a bug in the caller; filtering on it would hide rows for reasons the
        // reader cannot see, so the whole list is kept instead.
        #expect(TrajectoryLayout.steps(simple, in: 0...0.1, spans: []).count == 3)
    }
}
