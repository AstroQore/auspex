import AgentSessionKit
import AgentSessionLive
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

    @Test("Takeover resolution refreshes the live ledger after the decision commits")
    func takeoverRefreshesLedger() async throws {
        let store = try AuspexStore(inMemory: true)
        let repository = TaskRepository(store: store)
        let holder = SessionKey(harness: .codex, sessionID: "holder")
        let requester = SessionKey(harness: .claudeCode, sessionID: "requester")
        let task = try repository.createTask(title: "Approve handoff")
        let held = try repository.claimTask(
            id: task.id, role: "implementer", scope: nil, by: holder
        )
        let outcome = try repository.claimOrRequestTask(
            id: task.id, role: "reviewer", scope: "handoff", reason: nil,
            by: requester, expectedVersion: held.version
        )
        guard case let .pending(_, request) = outcome else {
            Issue.record("expected pending takeover")
            return
        }

        let tasks = TasksModel()
        tasks.start(repository: repository)
        var didRefresh = false
        tasks.onLedgerChange = {
            didRefresh = (try? repository.task(id: task.id)?.claimedBy) == requester
        }
        tasks.resolveTakeover(requestID: request.id, approve: true)
        for _ in 0..<40 where !didRefresh {
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(didRefresh)
        #expect(try repository.claimRequests(taskID: task.id).isEmpty)
    }

    @Test("Release, notes, and dependencies refresh only after their writes")
    func queueMutationsRefreshLedger() async throws {
        let store = try AuspexStore(inMemory: true)
        let repository = TaskRepository(store: store)
        let holder = SessionKey(harness: .codex, sessionID: "queue-holder")
        let claimed = try repository.createTask(title: "Release me")
        _ = try repository.claimTask(
            id: claimed.id, role: "implementer", scope: nil, by: holder
        )
        let dependency = try repository.createTask(title: "Dependency")
        let main = try repository.createTask(title: "Main")

        let tasks = TasksModel()
        tasks.start(repository: repository)
        var refreshes = 0
        tasks.onLedgerChange = { refreshes += 1 }

        tasks.releaseClaim(taskID: claimed.id)
        for _ in 0..<40 where refreshes < 1 {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(refreshes >= 1)
        #expect(try repository.task(id: claimed.id)?.claimedBy == nil)

        tasks.log(taskID: main.id, kind: .evidence, message: "verified", ref: "abc123")
        for _ in 0..<40 where refreshes < 2 {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(refreshes >= 2)
        #expect(try repository.log(taskID: main.id).last?.message == "verified")

        tasks.setDependencies([dependency.id], of: main.id)
        for _ in 0..<40 where refreshes < 3 {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(refreshes >= 3)
        #expect(try repository.task(id: main.id)?.dependsOn == [dependency.id])
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
