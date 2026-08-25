import AgentSessionKit
import AgentSessionLive
import Foundation
import Testing

@testable import AuspexCore

@Suite("Flight execution graph")
struct FlightGraphTests {
    private func events() throws -> ([StoredEvent], SessionKey, SessionKey) {
        let store = try AuspexStore(inMemory: true)
        let repository = SessionRepository(store: store)
        let root = Fixtures.key(.claudeCode, "graph-root")
        let child = Fixtures.key(.claudeCode, "graph-child")
        let identity = Fixtures.identity(key: root)
        try repository.upsert(snapshot: SessionStateReducer.initialSnapshot(identity: identity))
        try repository.insertEvents([
            Fixtures.event(.sessionStarted(identity: identity), key: root, at: 1),
            Fixtures.event(
                .subagentStarted(child: child, agentType: "explore", toolUseID: "spawn"),
                key: root,
                at: 2
            ),
            Fixtures.event(
                .toolCallStarted(id: "g1", name: "Grep", kind: .search, target: "one"),
                key: root,
                at: 3
            ),
            Fixtures.event(
                .toolCallStarted(id: "g2", name: "Grep", kind: .search, target: "two"),
                key: root,
                at: 4
            ),
            Fixtures.event(.toolCallFinished(id: "g1", isError: false), key: root, at: 5),
            Fixtures.event(.subagentFinished(child: child), key: root, at: 6),
            Fixtures.event(.toolCallFinished(id: "g2", isError: true), key: root, at: 7),
        ])
        return (try repository.firstEvents(key: root), root, child)
    }

    @Test("backward seeks remove unborn nodes and preserve their coordinates")
    func birthAndStableLayout() throws {
        let (events, root, child) = try events()
        let archive = FlightGraphArchive(events: events)
        let before = try #require(archive.frame(at: 0, root: root))
        #expect(before.nodes.map(\.key) == [root])

        let born = try #require(archive.frame(at: 1, root: root))
        let position = try #require(born.nodes.first { $0.key == child }?.position)
        #expect(born.edges == [FlightGraphEdge(parent: root, child: child, isActive: true)])

        let settled = try #require(archive.frame(at: 5, root: root))
        #expect(settled.nodes.first { $0.key == child }?.position == position)
        #expect(settled.nodes.first { $0.key == child }?.state.isEnded == true)
        #expect(settled.edges.first?.isActive == false)
    }

    @Test("same-name pending tools aggregate and completed history is silent")
    func pendingToolRuns() throws {
        let (events, root, _) = try events()
        let archive = FlightGraphArchive(events: events)
        let twoOpen = try #require(archive.frame(at: 3, root: root))
        #expect(twoOpen.chips.count == 1)
        #expect(twoOpen.chips.first?.name == "Grep")
        #expect(twoOpen.chips.first?.count == 2)
        #expect(twoOpen.chips.first?.state == .pending)
        #expect(twoOpen.openToolCount == 2)

        let oneOpen = try #require(archive.frame(at: 4, root: root))
        #expect(oneOpen.chips.first?.count == 2)
        #expect(oneOpen.openToolCount == 1)

        let allSettled = try #require(archive.frame(at: 6, root: root))
        #expect(allSettled.chips.isEmpty)
        #expect(allSettled.openToolCount == 0)
    }

    @Test("a checkpoint frame equals a direct prefix fold")
    func checkpoints() throws {
        let (base, root, _) = try events()
        var events = base
        let store = try AuspexStore(inMemory: true)
        let repository = SessionRepository(store: store)
        try repository.upsert(
            snapshot: SessionStateReducer.initialSnapshot(
                identity: Fixtures.identity(key: root)
            ))
        try repository.insertEvents(
            (0..<520).map { index in
                Fixtures.event(.thinking, key: root, at: Double(20 + index))
            })
        events.append(contentsOf: try repository.firstEvents(key: root))
        let archive = FlightGraphArchive(events: events)
        let late = try #require(archive.frame(at: 512, root: root))
        let early = try #require(archive.frame(at: 12, root: root))
        #expect(late.nodes.first?.key == root)
        #expect(early.nodes.first?.key == root)
        #expect(late.count == events.count)
    }

    @Test("the animation clock exists only for a visible playing graph")
    func clockPolicy() {
        #expect(
            FlightGraphMotionPolicy.needsClock(
                isVisible: true, isPlaying: true, reduceMotion: false))
        #expect(
            !FlightGraphMotionPolicy.needsClock(
                isVisible: false, isPlaying: true, reduceMotion: false))
        #expect(
            !FlightGraphMotionPolicy.needsClock(
                isVisible: true, isPlaying: false, reduceMotion: false))
        #expect(
            !FlightGraphMotionPolicy.needsClock(
                isVisible: true, isPlaying: true, reduceMotion: true))
    }
}
