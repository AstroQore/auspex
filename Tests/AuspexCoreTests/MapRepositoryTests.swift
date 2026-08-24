import AgentSessionKit
import Foundation
import Testing

@testable import AuspexCore

@Suite("Map repository")
struct MapRepositoryTests {
    private func repository() throws -> MapRepository {
        try MapRepository(store: AuspexStore(inMemory: true))
    }

    private func descriptor(
        source: String,
        task: Int64? = nil,
        root: String? = nil,
        project: String = "/Users/example/Code/auspex",
        harness: Harness = .codex,
        labels: Set<String> = ["swift"]
    ) -> MapNodeDescriptor {
        MapNodeDescriptor(
            sourceID: source,
            taskID: task,
            rootSessionKey: root,
            projectKey: project,
            harness: harness,
            labels: labels,
            status: .doing,
            attention: .working
        )
    }

    @Test("migration seeds one protected aggregate board")
    func aggregateBoard() throws {
        let repository = try repository()
        let boards = try repository.boards()
        #expect(boards.map(\.id) == [MapBoard.allID])
        #expect(boards[0].isProtected)
        #expect(throws: MapRepositoryError.protectedBoard) {
            try repository.deleteBoard(id: MapBoard.allID)
        }
    }

    @Test("all boards assigns once and never moves an existing node")
    func stablePlacement() throws {
        let repository = try repository()
        let now = Date(timeIntervalSince1970: 100)
        let first = try repository.synchronize(
            boardID: MapBoard.allID,
            descriptors: [descriptor(source: "implicit:a", root: "codex:a")],
            now: now
        )
        let original = try #require(first.nodes.first)
        _ = try repository.move(
            boardID: MapBoard.allID,
            nodeID: original.node.id,
            to: CGPoint(x: 173, y: 91),
            now: now.addingTimeInterval(1)
        )
        let second = try repository.synchronize(
            boardID: MapBoard.allID,
            descriptors: [
                descriptor(source: "implicit:a", root: "codex:a"),
                descriptor(source: "implicit:b", root: "codex:b"),
            ],
            now: now.addingTimeInterval(2)
        )
        let kept = try #require(second.nodes.first { $0.node.id == original.node.id })
        #expect(kept.placement?.point == CGPoint(x: 176, y: 96))
        #expect(Set(second.nodes.compactMap { $0.placement?.point }).count == 2)
    }

    @Test("implicit promotion keeps the same durable node")
    func promotion() throws {
        let repository = try repository()
        let before = try repository.synchronize(
            boardID: MapBoard.allID,
            descriptors: [descriptor(source: "implicit:a", root: "codex:a")]
        )
        let first = try #require(before.nodes.first)
        let after = try repository.synchronize(
            boardID: MapBoard.allID,
            descriptors: [descriptor(source: "task:42", task: 42, root: "codex:a")]
        )
        let promoted = try #require(after.nodes.first)
        #expect(promoted.node.id == first.node.id)
        #expect(promoted.node.taskID == 42)
        #expect(promoted.placement?.point == first.placement?.point)
    }

    @Test("custom boards evaluate nested rules and preserve dormant placement")
    func customRule() throws {
        let repository = try repository()
        let board = try repository.createBoard(
            name: "Swift work",
            rule: .all([
                .predicate(.harness(.codex)),
                .predicate(.label("swift")),
            ])
        )
        let visible = try repository.synchronize(
            boardID: board.id,
            descriptors: [descriptor(source: "a", root: "codex:a")]
        )
        let node = try #require(visible.nodes.first)
        #expect(node.membership.isVisible)

        let hidden = try repository.synchronize(
            boardID: board.id,
            descriptors: [descriptor(source: "a", root: "codex:a", labels: ["rust"])]
        )
        #expect(!hidden.nodes.contains { $0.membership.isVisible })

        let restored = try repository.synchronize(
            boardID: board.id,
            descriptors: [descriptor(source: "a", root: "codex:a")]
        )
        #expect(restored.nodes.first?.placement?.point == node.placement?.point)
    }

    @Test("one task mirrors independently across boards")
    func mirroredPlacement() throws {
        let repository = try repository()
        let custom = try repository.createBoard(name: "Review")
        let descriptor = descriptor(source: "a", task: 7, root: "codex:a")
        let aggregate = try repository.synchronize(
            boardID: MapBoard.allID,
            descriptors: [descriptor]
        )
        _ = try repository.synchronize(boardID: custom.id, descriptors: [descriptor])
        let node = try #require(aggregate.nodes.first)
        _ = try repository.setMembershipOverride(
            boardID: custom.id,
            nodeID: node.node.id,
            override: .include
        )
        let customVisible = try repository.synchronize(boardID: custom.id, descriptors: [descriptor])
        _ = try repository.move(
            boardID: custom.id,
            nodeID: node.node.id,
            to: CGPoint(x: 640, y: 320)
        )
        let aggregateAgain = try repository.synchronize(
            boardID: MapBoard.allID,
            descriptors: [descriptor]
        )
        #expect(customVisible.nodes.count == 1)
        #expect(aggregateAgain.nodes.first?.placement?.point == aggregate.nodes.first?.placement?.point)
    }

    @Test("soft deletion keeps board history and permits restore")
    func softDelete() throws {
        let repository = try repository()
        let board = try repository.createBoard(name: "Temporary")
        _ = try repository.deleteBoard(id: board.id)
        #expect(!(try repository.boards()).contains { $0.id == board.id })
        #expect((try repository.boards(includingDeleted: true)).contains { $0.id == board.id })
        _ = try repository.restoreBoard(id: board.id)
        #expect((try repository.boards()).contains { $0.id == board.id })
        #expect(try repository.history(boardID: board.id).count >= 3)
    }
}
