import AgentSessionKit
import AgentSessionLive
import Foundation
import Testing

@testable import AuspexCore

@Suite("Map playback")
struct MapPlaybackTests {
    private func json(_ value: some Encodable) throws -> String {
        try StoreJSON.encodeToString(value, using: StoreJSON.makeEncoder())
    }

    private func storedEvents() throws -> [StoredEvent] {
        let store = try AuspexStore(inMemory: true)
        let repository = SessionRepository(store: store)
        let key = Fixtures.key(.codex, "playback")
        try repository.upsert(snapshot: SessionStateReducer.initialSnapshot(
            identity: Fixtures.identity(key: key)
        ))
        try repository.insertEvents([
            Fixtures.event(.sessionStarted(identity: Fixtures.identity(key: key)), key: key, at: 1),
            Fixtures.event(
                .toolCallStarted(id: "tool", name: "Edit", kind: .fileWrite, target: "/Users/example/a"),
                key: key,
                at: 2
            ),
            Fixtures.event(.toolCallFinished(id: "tool", isError: false), key: key, at: 4),
        ])
        return try repository.firstEvents(key: key)
    }

    @Test("a playhead rebuilds the session state at that event")
    func sessionMoment() throws {
        let events = try storedEvents()
        let archive = MapPlaybackArchive(sessionEvents: events, boardEvents: [])
        let key = Fixtures.key(.codex, "playback")
        #expect(archive.count == 3)
        #expect(archive.moment(at: 1)?.state.sessions[key]?.state == .writingFile(path: "/Users/example/a"))
        #expect(archive.moment(at: 2)?.state.sessions[key]?.state == .thinking)
        #expect(archive.moment(at: 1)?.eventsAhead == 1)
    }

    @Test("seeking backward from a checkpoint returns the exact old layout")
    func checkpointSeek() throws {
        let board = MapBoard(
            id: "board", name: "Board", kind: .custom,
            createdAt: Fixtures.date(0), updatedAt: Fixtures.date(0)
        )
        let node = MapNode(
            id: "node", rootSessionKey: "codex:playback",
            createdAt: Fixtures.date(0), updatedAt: Fixtures.date(0)
        )
        var history: [MapHistoryEntry] = [
            .init(id: 1, timestamp: Fixtures.date(0), kind: .boardCreated, boardID: board.id, payloadJSON: try json(board)),
            .init(id: 2, timestamp: Fixtures.date(0), kind: .nodeBound, nodeID: node.id, payloadJSON: try json(node)),
        ]
        for index in 0..<600 {
            let placement = MapPlacement(
                boardID: board.id,
                nodeID: node.id,
                x: Double(index * 16),
                y: 0,
                updatedAt: Fixtures.date(Double(index + 1))
            )
            history.append(.init(
                id: Int64(index + 3),
                timestamp: Fixtures.date(Double(index + 1)),
                kind: .placementChanged,
                boardID: board.id,
                nodeID: node.id,
                payloadJSON: try json(placement)
            ))
        }
        let archive = MapPlaybackArchive(sessionEvents: [], boardEvents: history)
        #expect(archive.moment(at: 512)?.state.placement(boardID: board.id, nodeID: node.id)?.x == 8_160)
        #expect(archive.moment(at: 12)?.state.placement(boardID: board.id, nodeID: node.id)?.x == 160)
        #expect(archive.moment(at: 601)?.state.placement(boardID: board.id, nodeID: node.id)?.x == 9_584)
    }
}

@Suite("Map branch merge")
struct MapMergeTests {
    private func descriptor() -> MapNodeDescriptor {
        MapNodeDescriptor(
            sourceID: "task:9",
            taskID: 9,
            rootSessionKey: "codex:root",
            projectKey: "/Users/example/Code/auspex",
            harness: .codex,
            labels: ["map"],
            status: .doing,
            attention: .working
        )
    }

    @Test("same-field edits conflict and a chosen branch position merges atomically")
    func mergePositionConflict() throws {
        let store = try AuspexStore(inMemory: true)
        let repository = MapRepository(store: store)
        let parent = try repository.createBoard(name: "Parent")
        let current = try repository.synchronize(boardID: parent.id, descriptors: [descriptor()])
        let node = try #require(current.nodes.first)
        _ = try repository.setMembershipOverride(
            boardID: parent.id,
            nodeID: node.node.id,
            override: .include
        )
        let visible = try repository.synchronize(boardID: parent.id, descriptors: [descriptor()])
        let placement = try #require(visible.nodes.first?.placement)
        let baseID = try #require(repository.history(boardID: parent.id).last?.id)
        var state = MapPlaybackState()
        state.boards[parent.id] = parent
        state.nodes[node.node.id] = node.node
        state.memberships[MapPlaybackState.pair(parent.id, node.node.id)] = MapMembership(
            boardID: parent.id,
            nodeID: node.node.id,
            ruleMatches: false,
            override: .include
        )
        state.placements[MapPlaybackState.pair(parent.id, node.node.id)] = placement
        let branch = try repository.forkBoard(
            source: parent,
            state: state,
            through: baseID,
            name: "Branch"
        )

        _ = try repository.move(
            boardID: parent.id,
            nodeID: node.node.id,
            to: CGPoint(x: 320, y: 160)
        )
        _ = try repository.move(
            boardID: branch.id,
            nodeID: node.node.id,
            to: CGPoint(x: 960, y: 480)
        )
        let plan = try repository.prepareMerge(branchID: branch.id)
        let conflict = try #require(plan.conflicts.first { $0.field == .position })
        try repository.applyMerge(
            branchID: branch.id,
            plan: plan,
            choices: [conflict.id: .branch]
        )
        let merged = try repository.synchronize(boardID: parent.id, descriptors: [descriptor()])
        #expect(merged.nodes.first?.placement?.point == CGPoint(x: 960, y: 480))
        #expect(try repository.board(id: branch.id)?.mergeBaseEventID != baseID)
    }

    @Test("non-conflicting branch edits merge without a choice")
    func automaticMerge() {
        let base = MapLayoutSnapshot(
            boardID: "parent",
            rule: MapRuleValue(rule: nil, paused: false),
            memberships: [:],
            placements: ["n": MapPlacementValue(MapPlacement(boardID: "p", nodeID: "n", x: 0, y: 0))]
        )
        var parent = base
        parent.memberships["n"] = MapMembershipValue(MapMembership(
            boardID: "p", nodeID: "n", ruleMatches: true
        ))
        var branch = base
        branch.placements["n"] = MapPlacementValue(MapPlacement(
            boardID: "b", nodeID: "n", x: 64, y: 32
        ))
        let plan = MapMergePlanner.plan(base: base, parent: parent, branch: branch)
        #expect(plan.conflicts.isEmpty)
        #expect(plan.automaticMemberships["n"] != nil)
        #expect(plan.automaticPlacements["n"] != nil)
    }
}
