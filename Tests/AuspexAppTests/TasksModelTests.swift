import AgentSessionKit
import AgentSessionLive
import AuspexCore
import Foundation
import Testing

@testable import AuspexApp

/// The Tasks page's model: it costs nothing while the page is hidden, its
/// sidebar number counts only explicit work, and its lanes compare by
/// revision.
@MainActor
@Suite("Tasks page model")
struct TasksModelTests {
    private let worker = SessionKey(harness: .codex, sessionID: "tasks-model-worker")

    private func started(with seed: (TaskRepository) throws -> Void) async throws -> (TasksModel, TaskRepository) {
        let store = try AuspexStore(inMemory: true)
        let repository = TaskRepository(store: store)
        try seed(repository)
        let model = TasksModel()
        model.start(repository: repository)
        for _ in 0..<100 where model.isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(!model.isEmpty, "the first ledger read arrived")
        return (model, repository)
    }

    private func units(for repository: TaskRepository) throws -> [TaskUnit] {
        let ledger = TaskLedgerFrame(
            tasks: try repository.tasks(), links: try repository.allLinks(),
            plans: try repository.plans(includingArchived: true)
        )
        return BoardFrameAssembler.frame(board: .empty, inputs: BoardFrameInputs(ledger: ledger)).units
    }

    @Test("a hidden page is not rebuilt, however many frames arrive")
    func hiddenPageCostsNothing() async throws {
        let (model, repository) = try await started { repository in
            let task = try repository.createTask(title: "In flight", projectKey: "/Users/example/Code/a")
            try repository.claimTask(id: task.id, role: "implementer", scope: nil, by: self.worker)
        }
        let units = try units(for: repository)
        #expect(model.rebuildCount == 0)
        #expect(model.page == .empty)

        for revision in 1...50 {
            model.apply(units: units, revision: UInt64(revision), board: .empty)
        }
        try await Task.sleep(for: .milliseconds(400))
        #expect(model.rebuildCount == 0, "fifty frames for a page nobody is looking at")
        #expect(model.needsRebuild)

        model.setVisible(true)
        #expect(model.rebuildCount == 1, "one rebuild, on arrival, with what is new")
        #expect(model.page.lanes.count == 1)

        model.setVisible(false)
        model.apply(units: units, revision: 99, board: .empty)
        try await Task.sleep(for: .milliseconds(400))
        #expect(model.rebuildCount == 1)
    }

    @Test("a visible page skips the units it has already seen and coalesces a burst")
    func visiblePageCoalesces() async throws {
        let (model, repository) = try await started { repository in
            _ = try repository.createTask(title: "Waiting", projectKey: "/Users/example/Code/a")
        }
        let units = try units(for: repository)
        model.setVisible(true)
        let afterOpen = model.rebuildCount
        model.apply(units: units, revision: 7, board: .empty)
        try await Task.sleep(for: .milliseconds(450))
        let afterFirst = model.rebuildCount
        #expect(afterFirst == afterOpen + 1)

        // The same revision again is the same units: nothing to do.
        model.apply(units: units, revision: 7, board: .empty)
        try await Task.sleep(for: .milliseconds(450))
        #expect(model.rebuildCount == afterFirst)

        // A burst is one rebuild, not twenty.
        for revision in 8...27 {
            model.apply(units: units, revision: UInt64(revision), board: .empty)
        }
        try await Task.sleep(for: .milliseconds(450))
        #expect(model.rebuildCount == afterFirst + 1)
    }

    @Test("the sidebar number counts explicit open work, not stale and not finished, without the page")
    func openCountIsExplicitOnly() async throws {
        let (model, _) = try await started { repository in
            let long = Date().addingTimeInterval(-30 * 86_400)
            _ = try repository.createTask(title: "Forgotten", now: long)
            _ = try repository.createTask(title: "Fresh")
            let done = try repository.createTask(title: "Closed")
            try repository.closeTask(id: done.id)
            try LedgerHygiene(dbWriter: repository.dbWriter).runPass()
        }
        #expect(model.openCount == 1)
        #expect(model.rebuildCount == 0, "the number needs no page")
        #expect(model.linkTargets.flatMap(\.tasks).map(\.title) == ["Fresh"])
    }

    @Test("a chip or a fold rebuilds at once, and only the lane it touched changes revision")
    func personalChangesLandImmediately() async throws {
        let (model, repository) = try await started { repository in
            for project in ["/Users/example/Code/a", "/Users/example/Code/b"] {
                let task = try repository.createTask(title: "Work in \(project)", projectKey: project)
                try repository.claimTask(id: task.id, role: "implementer", scope: nil, by: self.worker)
            }
        }
        model.apply(units: try units(for: repository), revision: 1, board: .empty)
        model.setVisible(true)
        let before = model.page.lanes
        #expect(before.count == 2)

        let count = model.rebuildCount
        model.toggleLane("/Users/example/Code/a")
        #expect(model.rebuildCount == count + 1)
        let after = model.page.lanes
        let a = (before.first { $0.key.hasSuffix("/a") }, after.first { $0.key.hasSuffix("/a") })
        let b = (before.first { $0.key.hasSuffix("/b") }, after.first { $0.key.hasSuffix("/b") })
        #expect(a.0 != a.1)
        #expect(a.1?.isCollapsed == true)
        #expect(b.0 == b.1)

        model.toggle(.unclaimed)
        #expect(model.scope.contains(.unclaimed))
        model.showEverything()
        #expect(model.scope.isAll)
    }
}
