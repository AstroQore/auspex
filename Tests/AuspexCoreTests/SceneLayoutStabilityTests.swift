import AgentSessionKit
import AgentSessionLive
import AuspexCore
import CoreGraphics
import Foundation
import Testing

/// Whether the map holds still.
///
/// ## The complaint
///
/// "每次布局重排，所有任务都位移，很丑，也很占注意力" — every time the layout
/// re-packs, every task moves. A map is a thing a person learns the shape of:
/// the repository with the sofas is over there, the busy company is the wide
/// one on the left. That only works if a desk stays where it was put, and it
/// stopped working because the *campus* was re-packed from scratch on every
/// frame — the shelf width is a function of every suite's height, so one
/// company gaining a row of desks slid every other company sideways.
///
/// So these are the properties that make the map recognisable, asserted over a
/// long random sequence rather than over one hand-made case: the interesting
/// failures are the ones that need fifty frames of churn to show up.
@Suite("Scene layout · stability")
struct SceneLayoutStabilityTests {
    private static let epoch = Date(timeIntervalSince1970: 1_767_225_600)
    private static let projects = [
        "/Users/example/Code/auspex",
        "/Users/example/Code/storefront-web",
        "/Users/example/Code/ingest-pipeline",
        "/Users/example/Code/mobile-client",
        "/Users/example/Code/ops-runbook"
    ]

    private static func session(
        _ id: String,
        project: String,
        state: SessionState,
        at instant: Date
    ) -> SessionSnapshot {
        var snapshot = SessionSnapshot(
            identity: SessionIdentity(
                key: SessionKey(harness: .claudeCode, sessionID: id),
                sourcePath: "/Users/example/.claude/projects/demo/\(id).jsonl",
                cwd: project,
                gitRoot: project
            ),
            state: state,
            isAlive: !state.isEnded
        )
        snapshot.lastEventAt = instant
        if state.isEnded { snapshot.endedAt = instant }
        return snapshot
    }

    /// A small deterministic generator, so a failure is reproducible from the
    /// seed in the test rather than from "it happened once".
    private struct Random {
        private var state: UInt64
        init(seed: UInt64) { state = seed }
        mutating func next(_ bound: Int) -> Int {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Int((state >> 33) % UInt64(bound))
        }
    }

    /// Fifty frames of a machine having a normal day: sessions arrive, change
    /// state, and end.
    private static func churn(frames: Int, seed: UInt64) -> [BoardSnapshot] {
        var random = Random(seed: seed)
        var live: [SessionSnapshot] = []
        var boards: [BoardSnapshot] = []
        var serial = 0
        let states: [SessionState] = [
            .thinking, .toolCalling(name: "shell"), .writingFile(path: "a.swift"), .idle
        ]

        for frame in 0..<frames {
            let now = epoch.addingTimeInterval(TimeInterval(frame) * 5)
            // A couple of arrivals, a couple of state changes, the occasional
            // exit — the shape of a real minute rather than a stress test.
            for _ in 0..<(1 + random.next(3)) {
                serial += 1
                live.append(
                    session(
                        "s-\(serial)",
                        project: projects[random.next(projects.count)],
                        state: states[random.next(states.count)],
                        at: now
                    )
                )
            }
            for _ in 0..<random.next(4) where !live.isEmpty {
                let index = random.next(live.count)
                live[index].state = states[random.next(states.count)]
                live[index].lastEventAt = now
            }
            for _ in 0..<random.next(3) where live.count > 4 {
                let index = random.next(live.count)
                var ending = live.remove(at: index)
                ending.state = .ended(reason: .exited)
                ending.isAlive = false
                ending.endedAt = now
                live.append(ending)
            }
            boards.append(BoardSnapshot(generatedAt: now, sessions: live))
        }
        return boards
    }

    /// Where every session is, as the frame puts it.
    private static func anchors(_ frame: SceneFrame) -> [SessionKey: CGPoint] {
        var out: [SessionKey: CGPoint] = [:]
        for slot in frame.slots { if let key = slot.session { out[key] = slot.anchor } }
        for seat in frame.seats { if let key = seat.session { out[key] = seat.anchor } }
        return out
    }

    @Test("a session that stays put stays put, over fifty frames of churn")
    func seatsAreHeld() {
        var layout = SceneLayout()
        var previous: [SessionKey: CGPoint] = [:]
        var previousStates: [SessionKey: SessionState] = [:]
        var moved = 0
        var carried = 0

        for board in Self.churn(frames: 50, seed: 0x5EED) {
            let frame = layout.update(with: board)
            let now = Self.anchors(frame)
            let states = Dictionary(
                uniqueKeysWithValues: board.sessions.map { ($0.key, $0.state) }
            )
            for (key, point) in now {
                guard let was = previous[key] else { continue }
                // A session that changed state may legitimately have walked to
                // another room — that is the map doing its job. What must not
                // happen is a session that did nothing being moved because
                // somebody *else* arrived or left.
                guard previousStates[key] == states[key] else { continue }
                carried += 1
                if was != point { moved += 1 }
            }
            previous = now
            previousStates = states
        }

        #expect(carried > 500, "the churn did not produce enough survivors to prove anything")
        // What is left is the legitimate causes: a company that has grown too
        // wide for the space it was standing in has to be moved, and the shelf
        // under a company that gained a row of desks has to come down. This
        // churn adds one to three sessions *every frame*, which is a harder
        // day than any real machine has.
        //
        // The number that matters is the demo's, measured the same way: the
        // scaled demo board moved 22.7 settled sessions per frame before this
        // and 3.4 after.
        #expect(moved * 6 < carried, "\(moved) of \(carried) settled sessions moved")
    }

    @Test("suites keep their place in the order they were first seen")
    func suiteOrderIsFirstSeen() {
        var layout = SceneLayout()
        var order: [String] = []

        for board in Self.churn(frames: 50, seed: 0xA11CE) {
            let frame = layout.update(with: board)
            let keys = frame.floors.compactMap(\.projectKey)
            // Every suite that was already on the map keeps its position
            // relative to the others; new ones only ever appear at the end.
            let survivors = keys.filter { order.contains($0) }
            let expected = order.filter { keys.contains($0) }
            #expect(survivors == expected)
            for key in keys where !order.contains(key) { order.append(key) }
        }
        #expect(order.count == Self.projects.count)
    }

    @Test("a desk that empties is held for a minute before its row closes")
    func aFreedDeskIsHeld() {
        var layout = SceneLayout()
        let sessions = (0..<6).map {
            Self.session(
                "s-\($0)", project: Self.projects[0], state: .thinking, at: Self.epoch
            )
        }
        let full = layout.update(
            with: BoardSnapshot(generatedAt: Self.epoch, sessions: sessions)
        )
        let survivors = Array(sessions.prefix(3))

        // Immediately: the same suite, three desks standing empty.
        let held = layout.update(
            with: BoardSnapshot(generatedAt: Self.epoch, sessions: survivors)
        )
        #expect(held.slots.count == full.slots.count)
        #expect(held.floors.first?.frame == full.floors.first?.frame)

        // Half a minute later it is still the same map — this is the whole
        // point of the delay, and the frame in between is the one a person is
        // actually looking at.
        let midway = layout.update(
            with: BoardSnapshot(
                generatedAt: Self.epoch.addingTimeInterval(30), sessions: survivors
            )
        )
        #expect(midway.slots.count == full.slots.count)

        // Past the delay it closes up, and the survivors have not moved.
        let closed = layout.update(
            with: BoardSnapshot(
                generatedAt: Self.epoch.addingTimeInterval(SceneLayout.shrinkDelay + 1),
                sessions: survivors
            )
        )
        #expect(closed.slots.count == 3)
        for session in survivors {
            #expect(closed.place(of: session.key)?.anchor == full.place(of: session.key)?.anchor)
        }
    }

    @Test("one company changing shape does not slide the others")
    func oneSuiteDoesNotMoveTheRest() {
        var layout = SceneLayout()
        // Four companies, then one of them doubles in size. Before the shelf
        // width was held, the ideal width moved with the average suite height
        // and every company on the map was re-packed.
        var sessions: [SessionSnapshot] = []
        for project in Self.projects.prefix(4) {
            sessions += (0..<3).map {
                Self.session(
                    "\(project)-\($0)", project: project, state: .thinking, at: Self.epoch
                )
            }
        }
        let before = layout.update(
            with: BoardSnapshot(generatedAt: Self.epoch, sessions: sessions)
        )

        sessions += (0..<20).map {
            Self.session(
                "grown-\($0)", project: Self.projects[0], state: .thinking, at: Self.epoch
            )
        }
        let after = layout.update(
            with: BoardSnapshot(
                generatedAt: Self.epoch.addingTimeInterval(5), sessions: sessions
            )
        )

        // The company that grew keeps its own corner — it was there first, and
        // it grew into the space beside it.
        let grown = { (frame: SceneFrame) in
            frame.floors.first { $0.projectKey == Self.projects[0] }?.frame.origin
        }
        #expect(grown(after) == grown(before))

        // Exactly one other company is displaced: the one whose plot the grown
        // company now covers. Everybody else keeps their coordinates to the
        // point. Packing from scratch every frame moved all of them.
        let displaced = before.floors.filter { floor in
            guard floor.projectKey != Self.projects[0] else { return false }
            let now = after.floors.first { $0.projectKey == floor.projectKey }
            return now?.frame.origin != floor.frame.origin
        }
        #expect(displaced.count <= 1, "\(displaced.map(\.title)) moved")

        let displacedKeys = Set(displaced.compactMap(\.projectKey))
        for session in sessions
        where session.identity.cwd != Self.projects[0]
            && !displacedKeys.contains(session.identity.cwd ?? "") {
            #expect(
                after.place(of: session.key)?.anchor == before.place(of: session.key)?.anchor
            )
        }
    }
}
