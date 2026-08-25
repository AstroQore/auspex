import AgentSessionKit
import AgentSessionLive
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

    @Test("paused board keeps historical members missing from the live frame")
    func pausedBoardKeepsMissingMembers() throws {
        let repository = try repository()
        let board = try repository.createBoard(
            name: "Paused fork",
            rule: .predicate(.harness(.codex))
        )
        let initial = try repository.synchronize(
            boardID: board.id,
            descriptors: [descriptor(source: "implicit:a", root: "codex:a")]
        )
        let node = try #require(initial.nodes.first)
        _ = try repository.setRulesPaused(boardID: board.id, paused: true)

        let paused = try repository.synchronize(boardID: board.id, descriptors: [])
        let kept = try #require(paused.nodes.first { $0.node.id == node.node.id })
        #expect(kept.membership.isVisible)
        #expect(kept.placement?.point == node.placement?.point)
    }

    @Test("custom boards reorder atomically below All boards")
    func reorderBoards() throws {
        let repository = try repository()
        let first = try repository.createBoard(name: "First")
        let second = try repository.createBoard(name: "Second")
        try repository.reorderBoards([second.id, first.id])
        #expect(try repository.boards().map(\.id) == [MapBoard.allID, second.id, first.id])
        #expect(throws: MapRepositoryError.invalidBoardOrder) {
            try repository.reorderBoards([first.id])
        }
    }

    @Test("complete history pagination reads through the tail")
    func completeHistoryPagination() throws {
        let repository = try repository()
        let board = try repository.createBoard(name: "History pages")
        _ = try repository.renameBoard(id: board.id, name: "History pages 2")
        _ = try repository.renameBoard(id: board.id, name: "History pages 3")
        let paged = try repository.allHistory(boardID: board.id, pageSize: 2)
        let direct = try repository.history(boardID: board.id)
        #expect(paged.count == direct.count)
        #expect(paged.map(\.id) == paged.map(\.id).sorted())
    }

    @Test("task and attention writes enter board history in the same store")
    func coordinationHistoryTriggers() throws {
        let store = try AuspexStore(inMemory: true)
        let tasks = TaskRepository(store: store)
        let maps = MapRepository(store: store)
        let key = Fixtures.key(.codex, "history")
        let task = try tasks.createTask(
            title: "Record history",
            projectKey: "/Users/example/Code/auspex",
            createdBy: key
        )
        _ = try tasks.recordNotice(
            session: key,
            kind: .needsReview,
            message: "Check the Map"
        )
        _ = try tasks.recordReport(session: key, focus: "Building history", progress: "1/2")
        try SessionRepository(store: store).acknowledge(key: key, reason: .opened)
        let history = try maps.history()
        #expect(history.contains { $0.kind == .taskSnapshot && $0.taskID == task.id })
        #expect(history.contains { $0.kind == .noticeSnapshot && $0.sessionKey == key.description })
        #expect(history.contains { $0.kind == .reportSnapshot && $0.sessionKey == key.description })
        #expect(history.contains { $0.kind == .acknowledgementSnapshot && $0.sessionKey == key.description })
    }
}
