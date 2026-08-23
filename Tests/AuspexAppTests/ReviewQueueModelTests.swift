import AuspexCore
import Foundation
import Testing

@testable import AuspexApp

@MainActor
@Suite("Review queue UI model")
struct ReviewQueueModelTests {
    @Test("Review Next and Defer navigate without rewriting task state")
    func navigationAndDefer() throws {
        let store = try AuspexStore(inMemory: true)
        let repository = TaskRepository(store: store)
        let one = try reviewTask("One", repository: repository)
        let two = try reviewTask("Two", repository: repository)
        let three = try reviewTask("Three", repository: repository)
        let ledger = TaskLedgerFrame(tasks: [one, two, three], links: [], plans: [])
        let frame = BoardFrameAssembler.frame(
            board: .empty,
            inputs: BoardFrameInputs(ledger: ledger),
            sequence: 1
        )
        let model = LiveBoardModel()

        model.adopt(frame)
        #expect(model.reviewCount == 3)

        model.openNextReview()
        let first = try #require(model.openUnit)
        #expect(first.isInReview)

        model.deferReview(first)
        let second = try #require(model.openUnit)
        #expect(second.id != first.id)
        #expect(second.isInReview)

        let statuses = frame.units.map(\.status)
        #expect(statuses == [.review, .review, .review])
    }

    @Test("Close refreshes the live ledger only after the repository accepted it")
    func closeRefreshesLedger() async throws {
        let store = try AuspexStore(inMemory: true)
        let repository = TaskRepository(store: store)
        let task = try reviewTask("Ready", repository: repository)
        let tasks = TasksModel()
        var didRefresh = false
        tasks.start(repository: repository)
        tasks.onLedgerChange = { didRefresh = true }

        tasks.close(taskID: task.id)
        for _ in 0..<20 where !didRefresh {
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(didRefresh)
        #expect(try repository.task(id: task.id)?.status == .done)
    }

    private func reviewTask(
        _ title: String,
        repository: TaskRepository
    ) throws -> AuspexTask {
        let task = try repository.createTask(
            title: title,
            projectKey: "/Users/example/Code/auspex",
            source: "ui-test"
        )
        return try repository.completeTask(id: task.id, result: "Ready")
    }
}
