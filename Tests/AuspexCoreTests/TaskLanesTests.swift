import AgentSessionKit
import AgentSessionLive
import Foundation
import Testing

@testable import AuspexCore

/// The Tasks page's derivation: one lane per project, only the columns with
/// something in them, scope chips over explicit tasks, and rows compared by
/// revision.
@Suite("TaskLanes")
struct TaskLanesTests {
    private let now = Fixtures.date(60 * 86_400)
    private let day: TimeInterval = 86_400
    private let alpha = "/Users/example/Code/alpha"
    private let beta = "/Users/example/Code/beta"
    private let worker = SessionKey(harness: .codex, sessionID: "lanes-worker")

    private func task(
        _ id: Int64,
        _ status: AuspexTaskStatus,
        project: String? = nil,
        claimed: Bool = false,
        plan: Int64? = nil,
        version: Int64 = 1,
        ageDays: Double = 1,
        finishedDaysAgo: Double? = nil,
        stale: Bool = false
    ) -> AuspexTask {
        let created = now.addingTimeInterval(-ageDays * day)
        let finished = finishedDaysAgo.map { now.addingTimeInterval(-$0 * day) }
        return AuspexTask(
            id: id, version: version, planID: plan, title: "Task \(id)", body: nil, status: status,
            priority: 0, projectID: nil, projectKey: project ?? alpha, createdBy: nil,
            claimRole: claimed ? "implementer" : nil, claimScope: nil,
            claimedBy: claimed ? worker : nil, claimedAt: claimed ? created : nil,
            completedAt: finished, result: finished == nil ? nil : "Did it",
            source: "mcp", createdAt: created, updatedAt: finished ?? created,
            staleAt: stale ? now : nil
        )
    }

    private func plan(_ id: Int64, archived: Bool = false) -> AuspexPlan {
        AuspexPlan(
            id: id, slug: "plan-\(id)", title: "Milestone \(id)", summary: nil,
            status: archived ? .archived : .active, projectID: nil, projectKey: alpha,
            createdBy: nil, createdAt: now.addingTimeInterval(-30 * day),
            updatedAt: now.addingTimeInterval(-Double(id) * day), archivedAt: nil
        )
    }

    private func board(
        _ tasks: [AuspexTask],
        plans: [AuspexPlan] = [],
        scope: TaskScopeSelection = .default,
        showsArchived: Bool = false,
        showsStale: Bool = false,
        expansion: TaskLaneExpansion = TaskLaneExpansion()
    ) -> TaskLaneBoard {
        TaskLanes.board(
            tasks: tasks, plans: plans, units: [:], claims: .empty, scope: scope,
            showsArchived: showsArchived, showsStale: showsStale, focusedProjectKey: nil,
            expansion: expansion, text: .english, now: now
        )
    }

    @Test("one lane per project, and only the columns that have something in them")
    func lanesArePerProjectWithNonEmptyColumns() {
        let page = board([
            task(1, .doing, claimed: true),
            task(2, .review, claimed: true, finishedDaysAgo: 1),
            task(3, .doing, project: beta, claimed: true),
            task(4, .todo)
        ])
        #expect(page.lanes.map(\.key).sorted() == [alpha, beta])
        let lane = page.lanes.first { $0.key == alpha }
        #expect(lane?.columns.map(\.status) == [.doing, .review], "no empty To do, Blocked or Done")
        // The header counts the whole lane whatever the chips say.
        #expect(lane?.counts == TaskLane.Counts(doing: 1, review: 1, blocked: 0, unclaimed: 1, done: 0))
        #expect(page.openCount == 4)
        #expect(page.projectCount == 2)
    }

    @Test("the default scope is the work in progress and the work in review; All adds the rest")
    func scopes() {
        let tasks = [
            task(1, .todo), task(2, .todo, claimed: true), task(3, .doing, claimed: true),
            task(4, .blocked, claimed: true), task(5, .review, claimed: true, finishedDaysAgo: 1),
            task(6, .done, claimed: true, finishedDaysAgo: 2)
        ]
        func shown(_ scope: TaskScopeSelection) -> Set<Int64> {
            Set(board(tasks, scope: scope).lanes.flatMap(\.columns).flatMap(\.cards).map(\.id))
        }
        #expect(shown(.default) == [2, 3, 4, 5])
        #expect(shown(TaskScopeSelection([.unclaimed])) == [1])
        #expect(shown(TaskScopeSelection([.blocked])) == [4])
        #expect(shown(.all) == [1, 2, 3, 4, 5, 6])

        let counts = board(tasks).scopeCounts
        #expect(counts == TaskLaneBoard.ScopeCounts(review: 1, blocked: 1, inProgress: 3, unclaimed: 1))

        var selection = TaskScopeSelection.default
        selection.toggle(.inProgress)
        selection.toggle(.review)
        #expect(selection.isAll, "turning the last chip off is All")
    }

    @Test("a column draws eight cards and says how many more; opening it draws them all")
    func columnsAreCapped() {
        let tasks = (1...11).map { task(Int64($0), .doing, claimed: true, ageDays: Double($0)) }
        let closed = board(tasks)
        let column = try? #require(closed.lanes.first?.columns.first)
        #expect(column?.cards.count == TaskLanes.columnLimit)
        #expect(column?.hiddenCount == 3)
        #expect(column?.total == 11)

        var expansion = TaskLaneExpansion()
        expansion.expandedColumns = [column?.id ?? ""]
        let opened = board(tasks, expansion: expansion).lanes.first?.columns.first
        #expect(opened?.cards.count == 11)
        #expect(opened?.hiddenCount == 0)
    }

    @Test("rows are compared by revision, and a change moves only its own lane's revision")
    func revisions() {
        let tasks = [
            task(1, .doing, claimed: true), task(2, .doing, project: beta, claimed: true)
        ]
        let first = board(tasks)
        let again = board(tasks)
        #expect(first == again)
        #expect(first.lanes.map(\.revision) == again.lanes.map(\.revision))

        var edited = tasks
        edited[0] = task(1, .doing, claimed: true, version: 2)
        let next = board(edited)
        let alphaBefore = first.lanes.first { $0.key == alpha }
        let alphaAfter = next.lanes.first { $0.key == alpha }
        let betaBefore = first.lanes.first { $0.key == beta }
        let betaAfter = next.lanes.first { $0.key == beta }
        #expect(alphaBefore != alphaAfter)
        #expect(betaBefore == betaAfter)
        #expect(betaBefore?.revision == betaAfter?.revision)
    }

    @Test("stale tasks are set aside unless asked for, and still counted")
    func staleIsHidden() {
        let tasks = [task(1, .todo, ageDays: 20, stale: true), task(2, .todo)]
        let hidden = board(tasks, scope: .all)
        #expect(hidden.staleCount == 1)
        #expect(hidden.lanes.flatMap(\.columns).flatMap(\.cards).map(\.id) == [2])
        #expect(hidden.openCount == 1, "stale work is not open work")

        let shown = board(tasks, scope: .default, showsStale: true)
        let cards = shown.lanes.flatMap(\.columns).flatMap(\.cards)
        #expect(cards.map(\.id) == [1], "the switch shows stale work whatever the chips say")
        #expect(cards.first?.isStale == true)
    }

    @Test("old reviews fold into their own group and are offered to close in one go")
    func oldReviews() {
        let page = board([
            task(1, .review, claimed: true, finishedDaysAgo: 20),
            task(2, .review, claimed: true, finishedDaysAgo: 2)
        ])
        let review = page.lanes.first?.columns.first { $0.status == .review }
        #expect(review?.cards.map(\.id) == [2])
        #expect(review?.oldReviews.map(\.id) == [1])
        #expect(review?.showsOldReviews == false)
        #expect(review?.closableIDs.sorted() == [1, 2], "Close all closes the whole column")
        #expect(page.oldReviewIDs == [1])
        #expect(page.scopeCounts.review == 2)
    }

    @Test("an archived milestone hides what is finished under it, never what is open")
    func archivedMilestones() {
        let plans = [plan(1, archived: true), plan(2)]
        let tasks = [
            task(1, .done, claimed: true, plan: 1, finishedDaysAgo: 9),
            task(2, .review, claimed: true, plan: 1, finishedDaysAgo: 3),
            task(3, .doing, claimed: true, plan: 2)
        ]
        let page = board(tasks, plans: plans, scope: .all)
        let ids = Set(page.lanes.flatMap(\.columns).flatMap(\.cards).map(\.id))
        #expect(ids == [2, 3])
        let lane = page.lanes.first
        #expect(lane?.milestones.map(\.id) == [2], "only active milestones are chips")
        #expect(lane?.archivedMilestoneCount == 1)

        let everything = board(tasks, plans: plans, scope: .all, showsArchived: true)
        #expect(everything.lanes.flatMap(\.columns).flatMap(\.cards).count == 3)
    }

    @Test("a milestone chip narrows its lane; a card carries its milestone and its age")
    func milestoneFilterAndCardText() {
        let plans = [plan(1), plan(2)]
        let tasks = [
            task(1, .doing, claimed: true, plan: 1),
            task(2, .doing, claimed: true, plan: 2),
            task(3, .todo, ageDays: 12)
        ]
        var expansion = TaskLaneExpansion()
        expansion.milestoneFilter[alpha] = 1
        let narrowed = board(tasks, plans: plans, expansion: expansion)
        #expect(narrowed.lanes.first?.columns.flatMap(\.cards).map(\.id) == [1])
        #expect(narrowed.lanes.first?.milestoneFilter == 1)

        let all = board(tasks, plans: plans, scope: .all)
        let cards = all.lanes.flatMap(\.columns).flatMap(\.cards)
        #expect(cards.first { $0.id == 1 }?.milestone?.title == "Milestone 1")
        let unclaimed = cards.first { $0.id == 3 }
        #expect(unclaimed?.isUnclaimed == true)
        #expect(unclaimed?.age == "unclaimed · filed 12d ago")
    }

    @Test("a collapsed lane keeps its header and its counts")
    func collapsedLane() {
        var expansion = TaskLaneExpansion()
        expansion.collapsedLanes = [alpha]
        let lane = board([task(1, .doing, claimed: true)], expansion: expansion).lanes.first
        #expect(lane?.isCollapsed == true)
        #expect(lane?.counts.doing == 1)
    }
}
