import AgentSessionKit
import AgentSessionLive
import Foundation
import Testing

@testable import AuspexCore

@Suite("Flight event scale")
struct FlightEventLayoutTests {
    @Test("event scale gives observed events equal width")
    func equalEventSlots() {
        let key = SessionKey(harness: .codex, sessionID: "events")
        let steps = [
            TrajectoryStep(
                id: 10, index: 0, session: key, turn: 1, request: 1,
                role: .assistant, start: Date(timeIntervalSince1970: 1), title: "Thinking"
            ),
            TrajectoryStep(
                id: 30, index: 1, session: key, turn: 1, request: 1,
                role: .tool, start: Date(timeIntervalSince1970: 3), title: "Edit"
            ),
        ]
        let spans = TrajectoryLayout.spans(
            for: steps,
            scale: .events,
            eventIDs: [10, 20, 30, 40]
        )
        #expect(spans[0].start == 0)
        #expect(spans[0].end == 0.5)
        #expect(spans[1].start == 0.5)
        #expect(spans[1].end == 0.75)
    }

    @Test("event ticks say which observed fact they mark")
    func eventTicks() {
        let step = TrajectoryStep(
            id: 1, index: 0, turn: 0, request: 0,
            role: .system, start: .distantPast, title: "Start"
        )
        let ticks = TrajectoryLayout.ticks(
            for: [step],
            scale: .events,
            count: 4,
            eventCount: 12
        )
        #expect(ticks.map(\.label) == ["#1", "#4", "#7", "#10"])
    }
}
