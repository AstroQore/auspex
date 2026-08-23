import AgentSessionKit
import AgentSessionLive
import Foundation
import Testing

@testable import AuspexCore

@Suite("Collaboration watch signals")
struct CollaborationSignalsTests {
    private func row(
        _ id: String,
        directory: String? = "~/Code/auspex",
        branch: String? = nil,
        state: SessionState = .thinking,
        stale: Bool = false,
        elapsed: TimeInterval = 0,
        context: ContextGauge? = nil
    ) -> BoardRow {
        BoardRow(
            key: SessionKey(harness: .codex, sessionID: id),
            harness: .codex,
            title: id,
            shortID: id,
            pid: nil,
            modelName: nil,
            state: state,
            isStale: stale,
            project: "auspex",
            branch: branch,
            directory: directory,
            activity: "working",
            turnCount: 1,
            toolCallCount: 1,
            tokensIn: 1,
            tokensOut: 1,
            elapsedSince: Fixtures.date(elapsed),
            endedAt: nil,
            lastEventAt: Fixtures.date(50),
            descendantCount: 0,
            parent: nil,
            depth: 0,
            context: context
        )
    }

    private func unit(
        _ id: Int64,
        row: BoardRow,
        orphaned: Bool = false,
        projectKey: String = "/Users/example/Code/auspex"
    ) -> TaskUnit {
        TaskUnit(
            id: "task:\(id)",
            shortID: "AUX-\(id)",
            origin: .task(id),
            promotionKey: "task:\(id)",
            projectKey: projectKey,
            title: "Task \(id)",
            status: .doing,
            isClaimOrphaned: orphaned,
            lead: row,
            members: [row],
            counts: .init(working: 1),
            lastEventAt: row.lastEventAt
        )
    }

    @Test("two tasks in one directory produce one high confidence collision")
    func directoryCollision() {
        let signals = CollaborationSignals.derive(
            units: [unit(1, row: row("one")), unit(2, row: row("two"))],
            now: Fixtures.date(1_000)
        )
        let collision = signals.first { $0.kind == .sharedDirectory }
        #expect(collision?.confidence == .high)
        #expect(collision?.unitIDs == ["task:1", "task:2"])
        #expect(collision?.sessionKeys.count == 2)
    }

    @Test("members of the same task are not reported as a collision")
    func oneTaskIsNotACollision() {
        let one = row("one")
        let two = row("two")
        let unit = TaskUnit(
            id: "task:1",
            shortID: "AUX-1",
            origin: .task(1),
            promotionKey: "task:1",
            projectKey: "/Users/example/Code/auspex",
            title: "One task",
            status: .doing,
            lead: one,
            members: [one, two],
            counts: .init(working: 2)
        )
        #expect(CollaborationSignals.derive(units: [unit], now: Fixtures.date(1_000)).isEmpty)
    }

    @Test("stale, long tool, and context signals stay outside attention")
    func localWatchSignals() {
        let context = ContextGauge(
            used: 190, window: 200, cached: nil, isDerived: false,
            compactions: 0, at: Fixtures.date(50)
        )
        let lead = row(
            "lead", directory: nil, state: .toolCalling(name: "swift test"),
            stale: true, elapsed: 0, context: context
        )
        let signals = CollaborationSignals.derive(
            units: [unit(1, row: lead, orphaned: true)],
            now: Fixtures.date(600),
            longToolAfter: 300
        )
        #expect(Set(signals.map(\.kind)) == [.staleSession, .longTool, .contextPressure])
        #expect(lead.attention == .none)
    }

    @Test("an orphaned claim appears only in the human queue")
    func orphanIsNotDuplicatedAsWatchSignal() {
        let orphan = unit(1, row: row("lead", directory: nil), orphaned: true)
        let queue = HumanWorkQueue(units: [orphan])
        let signals = CollaborationSignals.derive(
            units: [orphan], now: Fixtures.date(1_000)
        )
        #expect(queue.items.map(\.reason) == [.orphanedClaim])
        #expect(!signals.contains { $0.kind == .orphanedClaim })
    }

    @Test("same branch in different directories is still visible")
    func branchCollision() {
        let first = row("one", directory: "~/worktrees/one", branch: "feat/shared")
        let second = row("two", directory: "~/worktrees/two", branch: "feat/shared")
        let signals = CollaborationSignals.derive(
            units: [unit(1, row: first), unit(2, row: second)],
            now: Fixtures.date(1_000)
        )
        #expect(signals.contains { $0.kind == .sharedBranch })
        #expect(!signals.contains { $0.kind == .sharedDirectory })
    }

    @Test("the same branch name in different projects is not a collision")
    func branchNamesAreScopedToProject() {
        let first = row("one", directory: "~/first", branch: "main")
        let second = row("two", directory: "~/second", branch: "main")
        let signals = CollaborationSignals.derive(
            units: [
                unit(1, row: first, projectKey: "/Users/example/Code/first"),
                unit(2, row: second, projectKey: "/Users/example/Code/second"),
            ],
            now: Fixtures.date(1_000)
        )
        #expect(!signals.contains { $0.kind == .sharedBranch })
    }
}
