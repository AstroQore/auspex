import AgentSessionKit
import AgentSessionLive
import Foundation
import GRDB
import Testing

@testable import AuspexCore

/// The three rules that keep the ledger legible without anybody tending it,
/// and the first pass over a store that has never had them.
@Suite("LedgerHygiene")
struct LedgerHygieneTests {
    private let day: TimeInterval = 86_400
    private var now: Date { Fixtures.date(60 * 86_400) }
    private let worker = SessionKey(harness: .codex, sessionID: "hygiene-worker")

    private func ledger() throws -> (AuspexStore, TaskRepository) {
        let store = try AuspexStore(inMemory: true)
        return (store, TaskRepository(store: store))
    }

    // MARK: Rule 1 — stale

    @Test("an unclaimed todo filed over a week ago is set aside; its status does not change")
    func staleTodoIsMarked() throws {
        let (store, repository) = try ledger()
        let old = try repository.createTask(title: "Old and untouched", now: now.addingTimeInterval(-10 * day))
        let young = try repository.createTask(title: "Filed yesterday", now: now.addingTimeInterval(-1 * day))

        let report = try LedgerHygiene(store: store).runPass(now: now)

        #expect(report.markedStale == 1)
        let reread = try #require(try repository.task(id: old.id))
        #expect(reread.status == .todo)
        #expect(reread.isStale)
        #expect(reread.version == old.version, "a stale mark is bookkeeping, not an edit")
        #expect(try repository.task(id: young.id)?.isStale == false)
        // Left out where work is listed for somebody to pick up, kept everywhere else.
        #expect(try repository.tasks(includeStale: false).map(\.id) == [young.id])
        #expect(Set(try repository.tasks().map(\.id)) == [old.id, young.id])
        #expect(try repository.staleTaskCount() == 1)
    }

    @Test("a task that was ever claimed, or is claimed now, is never stale")
    func claimedWorkIsNotStale() throws {
        let (store, repository) = try ledger()
        let released = try repository.createTask(title: "Taken and handed back", now: now.addingTimeInterval(-20 * day))
        try repository.claimTask(id: released.id, role: "implementer", scope: nil, by: worker, now: now.addingTimeInterval(-19 * day))
        try repository.releaseTask(id: released.id, by: worker, reason: "not mine", now: now.addingTimeInterval(-18 * day))
        _ = try repository.updateTask(id: released.id, status: .todo, now: now.addingTimeInterval(-18 * day))
        #expect(try repository.task(id: released.id)?.isClaimed == false)

        let report = try LedgerHygiene(store: store).runPass(now: now)
        #expect(report.markedStale == 0)
        #expect(try repository.task(id: released.id)?.isStale == false)
    }

    @Test("claiming or keeping a stale task brings it back, and the next pass clears the mark")
    func markIsRevocable() throws {
        let (store, repository) = try ledger()
        let claimed = try repository.createTask(title: "Somebody finally took it", now: now.addingTimeInterval(-9 * day))
        let kept = try repository.createTask(title: "A person said keep it", now: now.addingTimeInterval(-9 * day))
        let hygiene = LedgerHygiene(store: store)
        #expect(try hygiene.runPass(now: now).markedStale == 2)

        try repository.claimTask(id: claimed.id, role: "implementer", scope: nil, by: worker, now: now.addingTimeInterval(60))
        #expect(try repository.task(id: claimed.id)?.isStale == false, "a claim ends it on the same write")
        try repository.keepTask(id: kept.id, now: now.addingTimeInterval(60))
        #expect(try repository.task(id: kept.id)?.isStale == false)
        #expect(try repository.log(taskID: kept.id).contains { $0.kind == "kept" })

        let next = try hygiene.runPass(now: now.addingTimeInterval(120))
        #expect(next.cleared == 1, "the claimed task's row is cleared; the kept one was deleted by keep")
        #expect(next.markedStale == 0, "kept measures its week from the keep")
        let rows = try store.dbWriter.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM task_hygiene") }
        #expect(rows == 0)
    }

    // MARK: Rule 2 — settled milestones

    @Test("a quiet milestone whose tasks are all done, stale, or long in review is archived")
    func settledMilestoneIsArchived() throws {
        let (store, repository) = try ledger()
        let long = now.addingTimeInterval(-30 * day)
        let settled = try repository.createPlan(title: "Settled", projectKey: "/Users/example/Code/a", now: long)
        let done = try repository.createTask(title: "Shipped", planID: settled.id, now: long)
        try repository.closeTask(id: done.id, now: long.addingTimeInterval(day))
        let review = try repository.createTask(title: "Waiting to be read", planID: settled.id, now: long)
        try repository.claimTask(id: review.id, role: "implementer", scope: nil, by: worker, now: long)
        try repository.completeTask(id: review.id, result: "Did it", by: worker, now: long.addingTimeInterval(2 * day))
        _ = try repository.createTask(title: "Never picked up", planID: settled.id, now: long)

        let busy = try repository.createPlan(title: "Still moving", projectKey: "/Users/example/Code/a", now: long)
        let doing = try repository.createTask(title: "In flight", planID: busy.id, now: long)
        try repository.claimTask(id: doing.id, role: "implementer", scope: nil, by: worker, now: long)

        let recent = try repository.createPlan(title: "Closed yesterday", projectKey: "/Users/example/Code/a", now: long)
        let yesterday = try repository.createTask(title: "Closed yesterday", planID: recent.id, now: long)
        try repository.closeTask(id: yesterday.id, now: now.addingTimeInterval(-day))

        let report = try LedgerHygiene(store: store).runPass(now: now)

        #expect(report.archivedMilestones == 1)
        #expect(try repository.plan(id: settled.id)?.status == .archived)
        #expect(try repository.plan(id: busy.id)?.status == .active)
        #expect(try repository.plan(id: recent.id)?.status == .active, "quiet for a week, not a day")
        // Archiving a heading never closes the work under it.
        #expect(try repository.task(id: review.id)?.status == .review)
    }

    // MARK: Rule 3 — old reviews

    @Test("a review is old after two weeks with nobody live to answer for it, and is never closed")
    func oldReviewIsAPredicate() throws {
        let finished = now.addingTimeInterval(-15 * day)
        let task = AuspexTask(
            id: 1, planID: nil, title: "Read me", body: nil, status: .review, priority: 0,
            projectID: nil, createdBy: nil, claimRole: "implementer", claimScope: nil,
            claimedBy: worker, claimedAt: finished, completedAt: finished, result: "Done",
            source: "mcp", createdAt: finished, updatedAt: finished
        )
        #expect(LedgerHygiene.isOldReview(task, claimerIsLive: false, now: now))
        #expect(!LedgerHygiene.isOldReview(task, claimerIsLive: true, now: now))
        #expect(!LedgerHygiene.isOldReview(task, claimerIsLive: false, now: finished.addingTimeInterval(13 * day)))
        #expect(!LedgerHygiene.isOldReview(task.moved(to: .doing, at: finished), claimerIsLive: false, now: now))

        let (store, repository) = try ledger()
        let stored = try repository.createTask(title: "Waiting a fortnight", now: finished)
        try repository.claimTask(id: stored.id, role: "implementer", scope: nil, by: worker, now: finished)
        try repository.completeTask(id: stored.id, result: "Did it", by: worker, now: finished)
        let report = try LedgerHygiene(store: store).runPass(now: now)
        #expect(report.oldReviews == 1, "the claimer has no live session in the store")
        #expect(try repository.task(id: stored.id)?.status == .review, "done is a person's word")
    }

    // MARK: The backlog

    @Test("the first pass over an old store marks its whole backlog in batches, once")
    func backlogIsMarkedInBatches() throws {
        let (store, repository) = try ledger()
        let long = now.addingTimeInterval(-40 * day)
        let plan = try repository.createPlan(title: "Six weeks old", projectKey: "/Users/example/Code/b", now: long)
        for index in 0..<23 {
            _ = try repository.createTask(
                title: "Backlog \(index)", planID: index < 5 ? plan.id : nil, now: long
            )
        }
        // A batch smaller than the backlog, so the pass has to loop.
        let hygiene = LedgerHygiene(store: store, batchSize: 4)
        let first = try hygiene.runPass(now: now)
        #expect(first.markedStale == 23)
        #expect(first.archivedMilestones == 1, "the milestone settles once its tasks are marked")
        #expect(try repository.tasks(includeStale: false).isEmpty)

        let second = try hygiene.runPass(now: now.addingTimeInterval(3_600))
        #expect(second == LedgerHygiene.Report(), "idempotent: nothing left to do")
        #expect(!second.didChange)
    }

    @Test("maintenance runs the hygiene pass and reports what it did")
    func maintenanceRunsHygiene() async throws {
        let (store, repository) = try ledger()
        _ = try repository.createTask(title: "Forgotten", now: Date().addingTimeInterval(-30 * day))
        let pass = try await StoreMaintenance(store: store).runPass()
        #expect(pass.hygiene.markedStale == 1)
        #expect(pass.hygiene.didChange)
        #expect(pass.totalDeleted == pass.retention.totalDeleted + (pass.livenessEventsPurged ?? 0))
    }

    @Test("the migration adds the table on an existing store without touching its tasks")
    func migrationIsAdditive() throws {
        let queue = try DatabaseQueue()
        var migrator = AuspexStore.migrator
        migrator.eraseDatabaseOnSchemaChange = false
        try migrator.migrate(queue, upTo: "v10_events_observed_at")
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO tasks (title, status, priority, created_at, updated_at)
                VALUES ('Filed before hygiene existed', 'todo', 0, 0, 0)
                """)
        }
        try migrator.migrate(queue)
        let repository = TaskRepository(dbWriter: queue)
        let tasks = try repository.tasks()
        #expect(tasks.count == 1)
        #expect(tasks[0].isStale == false, "nothing is marked until a pass runs")
        let marked = try LedgerHygiene(dbWriter: queue).runPass(now: Fixtures.date(30 * 86_400))
        #expect(marked.markedStale == 1)
    }
}
