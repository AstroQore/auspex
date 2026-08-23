import AgentSessionKit
import AgentSessionLive
import AuspexCore
import Foundation
import Testing

@testable import AuspexApp

@MainActor
@Suite("Task delivery UI model")
struct TaskDeliveryModelTests {
    private final class FakeRunner: GitCommandRunning, @unchecked Sendable {
        private let lock = NSLock()
        let root: String
        private(set) var callCount = 0

        init(root: String) { self.root = root }

        func run(
            in directory: URL,
            arguments: [String],
            timeout: TimeInterval,
            maxOutputBytes: Int
        ) -> GitCommandResult {
            lock.lock()
            callCount += 1
            lock.unlock()
            if arguments.contains("--show-toplevel") { return .init(stdout: root + "\n") }
            switch arguments.first {
            case "status": return .init(stdout: "")
            case "symbolic-ref": return .init(stdout: "feat/review\n")
            case "diff": return .init(stdout: "")
            case "log": return .init(stdout: "abc123\tInitial\t1700000000\n")
            default: return .init(stdout: "", exitCode: 1)
            }
        }
    }

    @Test("Git stays idle until a detail explicitly asks, then refresh asks again")
    func onDemandAndRefresh() async throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("auspex-delivery-model-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let runner = FakeRunner(root: directory.path)
        let reader = GitDeliveryReader(runner: runner)
        let model = TaskDeliveryModel(reader: reader)
        let unit = task(project: directory.path)
        let board = LiveBoardModel()

        #expect(model.state == .idle)
        #expect(runner.callCount == 0)

        await model.load(unit: unit, board: board)
        let firstCount = runner.callCount
        #expect(model.snapshot?.workingTree == .clean)
        #expect(firstCount > 0)

        await model.load(unit: unit, board: board)
        #expect(runner.callCount == firstCount)

        await model.load(unit: unit, board: board, force: true)
        #expect(runner.callCount > firstCount)
    }

    @Test("a task without a local checkout presents observed state as unknown")
    func noCheckout() async {
        let model = TaskDeliveryModel()
        let board = LiveBoardModel()
        await model.load(unit: task(project: "auspex:pseudo:grok-bot"), board: board)

        #expect(model.snapshot?.workingTree == .unknown)
        #expect(model.snapshot?.diagnostic?.contains("No local checkout") == true)
    }

    private func task(project: String) -> TaskUnit {
        let lead = BoardRow(
            key: SessionKey(harness: .codex, sessionID: "placeholder-task"),
            harness: .codex,
            title: "Review delivery",
            shortID: "task",
            pid: nil,
            modelName: nil,
            state: .idle,
            isStale: false,
            project: "example",
            branch: nil,
            directory: nil,
            activity: "not started",
            turnCount: 0,
            toolCallCount: 0,
            tokensIn: 0,
            tokensOut: 0,
            elapsedSince: nil,
            endedAt: nil,
            lastEventAt: nil,
            descendantCount: 0,
            parent: nil,
            depth: 0
        )
        return TaskUnit(
            id: "task:1",
            shortID: "AUX-test",
            origin: .task(1),
            promotionKey: "task:1",
            projectKey: project,
            title: "Review delivery",
            status: .review,
            lead: lead,
            members: [lead],
            counts: .init()
        )
    }
}
