import AgentSessionKit
import AgentSessionLive
import Foundation
import GRDB
import Testing

@testable import AuspexCore

@Suite("TaskRepository")
struct TaskRepositoryTests {
    private func makeRepository() throws -> TaskRepository {
        TaskRepository(store: try AuspexStore(inMemory: true))
    }

    // MARK: - Plans

    @Test("a plan registered twice under the same slug is one plan")
    func planCreationIsIdempotent() throws {
        let repository = try makeRepository()
        let first = try repository.createPlan(title: "Ship the MCP surface")
        let second = try repository.createPlan(title: "Ship the MCP surface")
        #expect(first.id == second.id)
        #expect(first.slug == "ship-the-mcp-surface")
        #expect(try repository.plans().count == 1)
    }

    @Test("a plan is found by either spelling of its reference")
    func planLookupTakesIDOrSlug() throws {
        let repository = try makeRepository()
        let plan = try repository.createPlan(title: "Atlas pass", slug: "atlas")
        #expect(try repository.plan(reference: "atlas")?.id == plan.id)
        #expect(try repository.plan(reference: String(plan.id))?.id == plan.id)
        #expect(try repository.plan(reference: "nothing-like-it") == nil)
    }

    @Test("archiving a plan leaves its tasks where they are")
    func archivingKeepsTasks() throws {
        let repository = try makeRepository()
        let plan = try repository.createPlan(title: "Old work")
        let task = try repository.createTask(title: "Still open", planID: plan.id)
        let archived = try #require(try repository.archivePlan(id: plan.id))

        #expect(archived.status == .archived)
        #expect(archived.archivedAt != nil)
        #expect(try repository.plans().isEmpty)
        #expect(try repository.plans(includingArchived: true).count == 1)
        #expect(try repository.task(id: task.id)?.status == .todo)
    }

    // MARK: - Claims

    @Test("a claim records the role and the scope and starts the task moving")
    func claimMovesTaskToDoing() throws {
        let repository = try makeRepository()
        let worker = Fixtures.key(.codex, "worker-1")
        let task = try repository.createTask(title: "Write the installer")

        let claimed = try repository.claimTask(
            id: task.id, role: "implementer", scope: "TOML half", by: worker
        )
        #expect(claimed.status == .doing)
        #expect(claimed.claimRole == "implementer")
        #expect(claimed.claimScope == "TOML half")
        #expect(claimed.claimedBy == worker)
        #expect(claimed.claimDescription == "implementer · TOML half")

        // The claim also attaches the session, so the board can hang it under
        // the task without a second call.
        let links = try repository.links(taskID: task.id)
        #expect(links.map(\.session) == [worker])
        #expect(links.first?.kind == .claim)
    }

    @Test("a second session cannot take a claimed task, and the holder can refine it")
    func claimIsExclusiveButReentrant() throws {
        let repository = try makeRepository()
        let first = Fixtures.key(.codex, "worker-1")
        let second = Fixtures.key(.claudeCode, "worker-2")
        let task = try repository.createTask(title: "One job")
        try repository.claimTask(id: task.id, role: "implementer", scope: nil, by: first)

        #expect(throws: TaskLedgerError.alreadyClaimed(first.description)) {
            try repository.claimTask(id: task.id, role: "implementer", scope: nil, by: second)
        }

        let refined = try repository.claimTask(
            id: task.id, role: "implementer", scope: "the socket only", by: first
        )
        #expect(refined.claimScope == "the socket only")
    }

    @Test("releasing a claim reopens the task without closing it")
    func releaseReopens() throws {
        let repository = try makeRepository()
        let worker = Fixtures.key(.codex, "worker-1")
        let task = try repository.createTask(title: "Give up on this")
        try repository.claimTask(id: task.id, role: "implementer", scope: nil, by: worker)

        let released = try repository.releaseTask(id: task.id, by: worker)
        #expect(released.status == .todo)
        #expect(released.claimedBy == nil)
        #expect(released.claimRole == nil)
    }

    @Test("completing a task records what was finished")
    func completeRecordsResult() throws {
        let repository = try makeRepository()
        let worker = Fixtures.key(.codex, "worker-1")
        let task = try repository.createTask(title: "Land the migration")
        try repository.claimTask(id: task.id, role: "implementer", scope: nil, by: worker)

        let done = try repository.completeTask(
            id: task.id, result: "v3 migration and 12 tests", by: worker
        )
        #expect(done.status == .done)
        #expect(done.completedAt != nil)
        #expect(done.result == "v3 migration and 12 tests")

        let log = try repository.log(taskID: task.id)
        #expect(log.map(\.kind) == ["created", "claimed", "completed"])
        #expect(log.last?.message == "v3 migration and 12 tests")
    }

    @Test("moving a done task back out clears the finish stamp")
    func reopeningClearsCompletion() throws {
        let repository = try makeRepository()
        let task = try repository.createTask(title: "Premature")
        try repository.completeTask(id: task.id, result: "done", by: nil)
        let reopened = try repository.updateTask(id: task.id, status: .doing)
        #expect(reopened.status == .doing)
        #expect(reopened.completedAt == nil)
    }

    @Test("an update leaves untouched what it was not given")
    func updateIsSparse() throws {
        let repository = try makeRepository()
        let task = try repository.createTask(title: "Keep my body", body: "the details")
        let updated = try repository.updateTask(id: task.id, status: .blocked)
        #expect(updated.body == "the details")
        #expect(updated.title == "Keep my body")

        let cleared = try repository.updateTask(id: task.id, body: .some(nil))
        #expect(cleared.body == nil)
    }

    @Test("a missing task is named rather than silently ignored")
    func missingTaskThrows() throws {
        let repository = try makeRepository()
        #expect(throws: TaskLedgerError.notFound("task 99")) {
            try repository.claimTask(id: 99, role: "implementer", scope: nil, by: nil)
        }
    }

    // MARK: - Board order and links

    @Test("the board lists columns in reading order and priority within them")
    func boardOrder() throws {
        let repository = try makeRepository()
        let plan = try repository.createPlan(title: "Ordering")
        let low = try repository.createTask(title: "low", planID: plan.id, priority: 0)
        let high = try repository.createTask(title: "high", planID: plan.id, priority: 5)
        let blocked = try repository.createTask(
            title: "blocked", planID: plan.id, status: .blocked
        )

        let ordered = try repository.tasks(planID: plan.id)
        #expect(ordered.map(\.id) == [high.id, low.id, blocked.id])
        #expect(try repository.tasks(planID: plan.id, statuses: [.blocked]).map(\.id) == [blocked.id])
    }

    @Test("a manual link attaches and detaches; a claim link does not detach")
    func linksAreManualOnlyToRemove() throws {
        let repository = try makeRepository()
        let claimer = Fixtures.key(.codex, "worker-1")
        let bystander = Fixtures.key(.cursor, "worker-3")
        let task = try repository.createTask(title: "Shared")
        try repository.claimTask(id: task.id, role: "implementer", scope: nil, by: claimer)
        try repository.link(taskID: task.id, session: bystander, kind: .manual)

        #expect(try repository.links(taskID: task.id).count == 2)
        try repository.unlink(taskID: task.id, session: bystander)
        #expect(try repository.links(taskID: task.id).map(\.session) == [claimer])

        // Unlinking the claimer is refused quietly: the way off a claim is to
        // release it, which also clears the columns the row draws from.
        try repository.unlink(taskID: task.id, session: claimer)
        #expect(try repository.links(taskID: task.id).map(\.session) == [claimer])
        #expect(try repository.tasks(linkedTo: claimer).map(\.id) == [task.id])
    }

    @Test("a plan floats to the top when its tasks move")
    func planUpdatedAtFollowsItsTasks() throws {
        let repository = try makeRepository()
        let quiet = try repository.createPlan(title: "Quiet", now: Fixtures.date(0))
        let busy = try repository.createPlan(title: "Busy", now: Fixtures.date(1))
        let task = try repository.createTask(title: "Work", planID: quiet.id, now: Fixtures.date(2))
        try repository.updateTask(id: task.id, status: .doing, now: Fixtures.date(100))

        #expect(try repository.plans().map(\.id) == [quiet.id, busy.id])
    }

    // MARK: - Notices

    @Test("a notice replaces the last one rather than stacking")
    func noticesAreLiveStateNotALog() throws {
        let repository = try makeRepository()
        let key = Fixtures.key()
        try repository.recordNotice(
            session: key, kind: .needsInput, message: "Which branch?", now: Fixtures.date(0)
        )
        try repository.recordNotice(
            session: key, kind: .blocked, message: "No network", urgency: .high,
            now: Fixtures.date(10)
        )

        let live = try repository.liveNotices()
        #expect(live.count == 1)
        let notice = try #require(live[key])
        #expect(notice.kind == .blocked)
        #expect(notice.message == "No network")
        #expect(notice.urgency == .high)
    }

    @Test("clearing a notice takes it off the live list and keeps the first stamp")
    func clearingIsIdempotent() throws {
        let repository = try makeRepository()
        let key = Fixtures.key()
        try repository.recordNotice(session: key, kind: .needsInput, message: "?", now: Fixtures.date(0))
        try repository.clearNotice(session: key, now: Fixtures.date(5))
        try repository.clearNotice(session: key, now: Fixtures.date(9))

        #expect(try repository.liveNotices().isEmpty)
        let stored = try #require(try repository.notice(session: key))
        #expect(stored.clearedAt == Fixtures.date(5))
        #expect(!stored.isLive)
    }

    @Test("a new notice on a cleared session goes live again")
    func recordingRevives() throws {
        let repository = try makeRepository()
        let key = Fixtures.key()
        try repository.recordNotice(session: key, kind: .needsInput, message: "?", now: Fixtures.date(0))
        try repository.clearNotice(session: key, now: Fixtures.date(5))
        try repository.recordNotice(session: key, kind: .done, message: "finished", now: Fixtures.date(6))
        #expect(try repository.liveNotices()[key]?.kind == .done)
    }

    @Test("only a needs_input notice is answered by the next prompt")
    func autoClearRule() {
        let asked = AgentNotice(
            session: Fixtures.key(), kind: .needsInput, message: "?", createdAt: Fixtures.date(0)
        )
        #expect(asked.isAnswered(byPromptAt: Fixtures.date(10)))
        #expect(!asked.isAnswered(byPromptAt: Fixtures.date(-10)))
        #expect(!asked.isAnswered(byPromptAt: nil))

        let blocked = AgentNotice(
            session: Fixtures.key(), kind: .blocked, message: "!", createdAt: Fixtures.date(0)
        )
        #expect(!blocked.isAnswered(byPromptAt: Fixtures.date(10)))
    }

    // MARK: - Reports

    @Test("a report replaces the previous one and folds progress into one line")
    func reports() throws {
        let repository = try makeRepository()
        let key = Fixtures.key()
        try repository.recordReport(session: key, focus: "reading the adapter", progress: nil)
        let report = try repository.recordReport(
            session: key, focus: "rewriting the tailer", progress: "step 2 of 5",
            now: Fixtures.date(30)
        )
        #expect(report.line == "rewriting the tailer · step 2 of 5")
        #expect(try repository.allReports().count == 1)
        #expect(try repository.allReports()[key]?.focus == "rewriting the tailer")
        #expect(report.isSuperseded(byAssistantAt: Fixtures.date(40)))
        #expect(!report.isSuperseded(byAssistantAt: Fixtures.date(20)))
    }

    // MARK: - Slugs

    @Test("slugs stay legible and never become a path or a shell word")
    func slugging() {
        #expect(TaskSlug.make("Ship the MCP surface") == "ship-the-mcp-surface")
        #expect(TaskSlug.make("  ../../etc/passwd  ") == "etc-passwd")
        #expect(TaskSlug.make("rm -rf /; echo") == "rm-rf-echo")
        #expect(TaskSlug.make("!!!") == "plan")
        #expect(TaskSlug.make("任务板") == "任务板")
        #expect(TaskSlug.make(String(repeating: "a", count: 200)).count <= 64)
    }
}
