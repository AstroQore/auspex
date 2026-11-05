import Foundation
import Testing

@testable import AuspexCore

@Suite("DemoBulkLedger")
struct DemoBulkLedgerTests {
    @Test("seeds the asked-for size, under a tenth as many milestones, once")
    func seedsOnce() throws {
        let store = try AuspexStore(inMemory: true)
        let ledger = TaskRepository(store: store)
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        try DemoBulkLedger.seed(into: ledger, count: 120, now: now)
        try DemoBulkLedger.seed(into: ledger, count: 120, now: now)

        let tasks = try ledger.tasks(limit: 10_000)
        #expect(tasks.count == 120)
        #expect(try ledger.plans(includingArchived: true).count == 12)
        // Every column a real backlog has, and every project under the demo home.
        let statuses = Set(tasks.map(\.status))
        #expect(statuses.isSuperset(of: [.todo, .doing, .review, .done]))
        #expect(tasks.allSatisfy { $0.projectKey?.hasPrefix("/Users/example/") == true })
        #expect(tasks.allSatisfy { $0.createdAt < now })
    }

    @Test("only a number in range is a request")
    func requestedCount() {
        #expect(DemoBulkLedger.requestedCount(in: [:]) == 0)
        #expect(DemoBulkLedger.requestedCount(in: ["AUSPEX_DEMO_TASKS": "400"]) == 400)
        #expect(DemoBulkLedger.requestedCount(in: ["AUSPEX_DEMO_TASKS": "lots"]) == 0)
        #expect(DemoBulkLedger.requestedCount(in: ["AUSPEX_DEMO_TASKS": "999999"]) == DemoBulkLedger.limit)
    }
}
