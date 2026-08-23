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

    // MARK: - Projects

    @Test("a task is filed in a project, and the counts are one query")
    func tasksAreCountedByProject() throws {
        let repository = try makeRepository()
        let auspex = "/Users/example/Code/auspex"
        let storefront = "/Users/example/Code/storefront-web"
        let done = try repository.createTask(title: "Adapter", projectKey: auspex)
        try repository.completeTask(id: done.id, result: "shipped")
        // A finished task is only closed once a person has closed it — see
        // `completeTask`. Counting it as open until then is the point.
        try repository.closeTask(id: done.id)
        _ = try repository.createTask(title: "Tailer", projectKey: auspex)
        _ = try repository.createTask(title: "Cart", projectKey: storefront)

        #expect(try repository.tasks(projectKey: auspex).count == 2)
        #expect(try repository.tasks(projectKey: storefront).map(\.title) == ["Cart"])

        let counts = try repository.taskCounts()
        #expect(counts[auspex] == TaskProjectCounts(total: 2, open: 1))
        #expect(counts[storefront]?.openDescription == "1 task open")
        #expect(counts["/Users/example/Code/nothing"] == nil)
    }

    @Test("a task filed under a milestone is filed in that milestone's project")
    func taskInheritsTheMilestonesProject() throws {
        let repository = try makeRepository()
        let plan = try repository.createPlan(
            title: "Ship the live board", projectKey: "/Users/example/Code/auspex"
        )
        let task = try repository.createTask(title: "Retention", planID: plan.id)
        #expect(task.projectKey == "/Users/example/Code/auspex")
    }

    @Test("a milestone registered before its first task takes that task's project")
    func milestoneLearnsItsProjectFromItsFirstTask() throws {
        let repository = try makeRepository()
        let plan = try repository.createPlan(title: "Atlas pass")
        #expect(plan.projectKey == nil)
        _ = try repository.createTask(
            title: "First", planID: plan.id, projectKey: "/Users/example/Code/auspex"
        )
        #expect(try repository.plan(id: plan.id)?.projectKey == "/Users/example/Code/auspex")

        // And never re-learns it: the board has already drawn the first answer.
        _ = try repository.createTask(
            title: "Second", planID: plan.id, projectKey: "/Users/example/Code/elsewhere"
        )
        #expect(try repository.plan(id: plan.id)?.projectKey == "/Users/example/Code/auspex")
    }

    @Test("re-registering a milestone fills in a project the first attempt did not know")
    func milestoneRegistrationLearnsAProject() throws {
        let repository = try makeRepository()
        let first = try repository.createPlan(title: "Atlas pass")
        let second = try repository.createPlan(
            title: "Atlas pass", projectKey: "/Users/example/Code/auspex"
        )
        #expect(first.id == second.id)
        #expect(second.projectKey == "/Users/example/Code/auspex")
    }

    @Test("moving a task between projects leaves a line in its history")
    func movingATaskIsRecorded() throws {
        let repository = try makeRepository()
        let task = try repository.createTask(
            title: "Filed in the wrong place", projectKey: TaskProject.scratchKey
        )
        let moved = try repository.moveTask(
            id: task.id, toProjectKey: "/Users/example/Code/auspex"
        )
        #expect(moved.projectKey == "/Users/example/Code/auspex")
        let log = try repository.log(taskID: task.id)
        #expect(log.contains {
            $0.kind == "project" && $0.message?.contains("/Users/example/Code/auspex") == true
        })
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

    @Test("a task with no project takes the project of the session that claims it")
    func claimGivesAnUnfiledTaskItsProject() throws {
        let repository = try makeRepository()
        let worker = Fixtures.key(.codex, "worker-1")
        let task = try repository.createTask(title: "Filed by a person, in a hurry")
        #expect(task.projectKey == nil)

        let claimed = try repository.claimTask(
            id: task.id, role: "implementer", scope: nil, by: worker,
            projectKey: "/Users/example/Code/auspex"
        )
        #expect(claimed.projectKey == "/Users/example/Code/auspex")
    }

    @Test("a claim does not move a task that already knows which project it is in")
    func claimDoesNotRefileAKnownTask() throws {
        let repository = try makeRepository()
        let worker = Fixtures.key(.codex, "worker-1")
        let task = try repository.createTask(
            title: "Already filed", projectKey: "/Users/example/Code/auspex"
        )
        let claimed = try repository.claimTask(
            id: task.id, role: "reviewer", scope: nil, by: worker,
            projectKey: "/Users/example/Code/somewhere-else"
        )
        #expect(claimed.projectKey == "/Users/example/Code/auspex")
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

    @Test("concurrent claimers produce one holder and one refusal")
    func concurrentClaimsAreSerialized() async throws {
        let repository = try makeRepository()
        let task = try repository.createTask(title: "One winner")
        let contenders = [
            Fixtures.key(.codex, "worker-1"),
            Fixtures.key(.claudeCode, "worker-2")
        ]
        let outcomes = await withTaskGroup(of: String.self) { group in
            for contender in contenders {
                group.addTask {
                    do {
                        let task = try repository.claimTask(
                            id: task.id, role: "implementer", scope: nil,
                            by: contender, expectedVersion: task.version
                        )
                        return "claimed:\(task.claimedBy?.description ?? "none")"
                    } catch let error as TaskLedgerError {
                        return "refused:\(error.description)"
                    } catch {
                        return "unexpected"
                    }
                }
            }
            var values: [String] = []
            for await outcome in group { values.append(outcome) }
            return values
        }
        #expect(outcomes.count { $0.hasPrefix("claimed:") } == 1)
        #expect(outcomes.count { $0.hasPrefix("refused:") } == 1)
        #expect(try repository.task(id: task.id)?.version == 2)
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

    @Test("a holder-only release is atomic and records why")
    func holderOnlyRelease() throws {
        let repository = try makeRepository()
        let holder = Fixtures.key(.codex, "worker-1")
        let stranger = Fixtures.key(.claudeCode, "worker-2")
        let task = try repository.createTask(title: "One holder")
        try repository.claimTask(id: task.id, role: "implementer", scope: nil, by: holder)

        #expect(throws: TaskLedgerError.notClaimHolder(holder.description)) {
            try repository.releaseTask(
                id: task.id, by: stranger, reason: "not mine", requireHolder: true
            )
        }
        #expect(try repository.task(id: task.id)?.claimedBy == holder)

        let released = try repository.releaseTask(
            id: task.id, by: holder, reason: "handoff to the migration owner",
            requireHolder: true
        )
        #expect(released.claimedBy == nil)
        #expect(try repository.log(taskID: task.id).last?.message == "handoff to the migration owner")
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
        // Finished, not closed. An agent that says it is done has asked to be
        // checked; nobody has checked it yet.
        #expect(done.status == .review)
        #expect(done.status.isOpen)
        #expect(done.completedAt != nil)
        #expect(done.result == "v3 migration and 12 tests")

        let log = try repository.log(taskID: task.id)
        #expect(log.map(\.kind) == ["created", "claimed", "finished"])
        #expect(log.last?.message == "v3 migration and 12 tests")
    }

    @Test("closing is the person's gesture, and it is what ends the task")
    func closingIsWhatCloses() throws {
        let repository = try makeRepository()
        let worker = Fixtures.key(.codex, "worker-1")
        let task = try repository.createTask(title: "Land the migration")
        let finished = try repository.completeTask(id: task.id, result: "shipped", by: worker)
        #expect(finished.status == .review)

        let closed = try repository.closeTask(id: task.id)
        #expect(closed.status == .done)
        #expect(!closed.status.isOpen)
        // The stamp is when the *work* finished, not when somebody got round
        // to reading it.
        #expect(closed.completedAt == finished.completedAt)
        #expect(try repository.log(taskID: task.id).map(\.kind).last == "closed")
    }

    @Test("moving a finished task back out clears the finish stamp")
    func reopeningClearsCompletion() throws {
        let repository = try makeRepository()
        let task = try repository.createTask(title: "Premature")
        try repository.completeTask(id: task.id, result: "done", by: nil)
        let reopened = try repository.updateTask(id: task.id, status: .doing)
        #expect(reopened.status == .doing)
        #expect(reopened.completedAt == nil)
    }

    // MARK: - Dependencies

    @Test("a task whose dependency is open is not ready")
    func dependenciesGateReadiness() throws {
        let repository = try makeRepository()
        let first = try repository.createTask(title: "Land the schema")
        let second = try repository.createTask(title: "Read the schema", dependsOn: [first.id])

        #expect(try repository.task(id: second.id)?.dependsOn == [first.id])
        // The gate is about dependencies alone: `first` waits on nothing and is
        // ready whatever column it is in.
        #expect(try repository.tasks(readyOnly: true).map(\.id) == [first.id])

        // Review is not closed, so a task waiting on one is still waiting.
        try repository.completeTask(id: first.id, result: "landed")
        #expect(try repository.tasks(readyOnly: true).map(\.id) == [first.id])

        try repository.closeTask(id: first.id)
        #expect(Set(try repository.tasks(readyOnly: true).map(\.id)) == [first.id, second.id])
    }

    @Test("invalid dependencies are refused and leave the graph untouched")
    func dependencyEdgesFailClosed() throws {
        let repository = try makeRepository()
        #expect(throws: TaskLedgerError.dependencyNotFound(9_999)) {
            try repository.createTask(title: "Alone", dependsOn: [9_999])
        }
        #expect(try repository.tasks().isEmpty)

        let first = try repository.createTask(title: "First")
        let second = try repository.createTask(title: "Second", dependsOn: [first.id])
        #expect(throws: TaskLedgerError.selfDependency(second.id)) {
            try repository.setDependencies([second.id], of: second.id)
        }
        #expect(try repository.task(id: second.id)?.dependsOn == [first.id])

        #expect(throws: TaskLedgerError.dependencyCycle([first.id, second.id, first.id])) {
            try repository.setDependencies([second.id], of: first.id)
        }
        #expect(try repository.task(id: first.id)?.dependsOn.isEmpty == true)
        #expect(try repository.task(id: second.id)?.dependsOn == [first.id])
    }

    @Test("task versions reject stale writes without partial mutation")
    func versionsFenceStaleWriters() throws {
        let repository = try makeRepository()
        let task = try repository.createTask(title: "One truth")
        #expect(task.version == 1)

        let moved = try repository.updateTask(
            id: task.id, status: .doing, expectedVersion: task.version
        )
        #expect(moved.version == 2)
        #expect(throws: TaskLedgerError.versionConflict(expected: 1, actual: 2)) {
            try repository.updateTask(
                id: task.id, title: "stale title", dependsOn: [9_999], expectedVersion: 1
            )
        }
        let current = try #require(try repository.task(id: task.id))
        #expect(current.title == "One truth")
        #expect(current.status == .doing)
        #expect(current.version == 2)

        // A sparse update that changes nothing is not a mutation.
        #expect(try repository.updateTask(id: task.id).version == 2)
    }

    @Test("claim conflicts become human-approved takeover requests")
    func takeoverRequestsAreExplicit() throws {
        let repository = try makeRepository()
        let holder = Fixtures.key(.codex, "holder")
        let requester = Fixtures.key(.claudeCode, "requester")
        let task = try repository.createTask(title: "One owner")
        let held = try repository.claimTask(
            id: task.id, role: "implementer", scope: "store", by: holder
        )

        let outcome = try repository.claimOrRequestTask(
            id: task.id,
            role: "reviewer",
            scope: "migration",
            reason: "I have the compatibility context",
            by: requester,
            expectedVersion: held.version
        )
        guard case let .pending(pendingTask, request) = outcome else {
            Issue.record("expected a pending takeover")
            return
        }
        #expect(pendingTask.claimedBy == holder)
        #expect(pendingTask.version == held.version + 1)
        #expect(request.taskVersion == pendingTask.version)
        #expect(request.status == .pending)

        let retry = try repository.claimOrRequestTask(
            id: task.id,
            role: "reviewer",
            scope: "migration",
            reason: "I have the compatibility context",
            by: requester
        )
        guard case let .pending(retriedTask, retriedRequest) = retry else {
            Issue.record("expected the existing pending takeover")
            return
        }
        #expect(retriedRequest.id == request.id)
        #expect(retriedTask.version == pendingTask.version)
        #expect(try repository.claimRequests(taskID: task.id).count == 1)

        let otherRequester = Fixtures.key(.cursor, "requester-2")
        let secondOutcome = try repository.claimOrRequestTask(
            id: task.id, role: "tester", scope: "concurrency", reason: nil,
            by: otherRequester, expectedVersion: retriedTask.version
        )
        guard case .pending = secondOutcome else {
            Issue.record("expected a second pending takeover")
            return
        }
        #expect(try repository.claimRequests(taskID: task.id).count == 2)

        // A release makes the request visible on an unclaimed task; it does
        // not grant it in the background.
        let released = try repository.releaseTask(id: task.id, by: holder, requireHolder: true)
        #expect(released.claimedBy == nil)
        #expect(try repository.claimRequests(taskID: task.id).count == 2)
        let afterReleaseRetry = try repository.claimOrRequestTask(
            id: task.id, role: "reviewer", scope: "migration",
            reason: "I have the compatibility context", by: requester,
            expectedVersion: released.version
        )
        guard case let .pending(stillReleased, sameRequest) = afterReleaseRetry else {
            Issue.record("a retry must not self-approve a pending takeover")
            return
        }
        #expect(stillReleased.claimedBy == nil)
        #expect(stillReleased.version == released.version)
        #expect(sameRequest.id == request.id)

        let expired = try repository.resolveClaimRequest(id: request.id, approve: true)
        #expect(expired.request.status == .expired)
        #expect(expired.task.version == released.version + 1)
        #expect(expired.task.claimedBy == nil)
        #expect(try repository.claimRequests(taskID: task.id).count == 1)
        let resolved = try repository.claimRequests(taskID: task.id, status: nil)
        #expect(resolved.count { $0.status == .expired } == 1)
        #expect(try repository.log(taskID: task.id).map(\.kind).contains("takeover_expired"))
    }

    @Test("approving a current takeover atomically transfers the exact reviewed claim")
    func approvingCurrentTakeoverTransfersClaim() throws {
        let repository = try makeRepository()
        let holder = Fixtures.key(.codex, "holder-current")
        let requester = Fixtures.key(.claudeCode, "requester-current")
        let task = try repository.createTask(title: "Transfer this exact claim")
        let held = try repository.claimTask(
            id: task.id, role: "implementer", scope: "old scope", by: holder
        )
        let outcome = try repository.claimOrRequestTask(
            id: task.id, role: "reviewer", scope: "new scope", reason: "handoff",
            by: requester, expectedVersion: held.version
        )
        guard case let .pending(requestedTask, request) = outcome else {
            Issue.record("expected a pending takeover")
            return
        }

        let approved = try repository.resolveClaimRequest(id: request.id, approve: true)
        #expect(approved.request.status == .approved)
        #expect(approved.task.version == requestedTask.version + 1)
        #expect(approved.task.claimedBy == requester)
        #expect(approved.task.claimRole == "reviewer")
        #expect(approved.task.claimScope == "new scope")
        #expect(try repository.claimRequests(taskID: task.id).isEmpty)
        #expect(try repository.log(taskID: task.id).map(\.kind).contains("takeover_approved"))
    }

    @Test("rejecting a takeover leaves the current claim intact")
    func rejectingTakeoverKeepsHolder() throws {
        let repository = try makeRepository()
        let holder = Fixtures.key(.codex, "holder")
        let requester = Fixtures.key(.claudeCode, "requester")
        let task = try repository.createTask(title: "Keep the owner")
        let held = try repository.claimTask(
            id: task.id, role: "implementer", scope: nil, by: holder
        )
        let outcome = try repository.claimOrRequestTask(
            id: task.id, role: "reviewer", scope: nil, reason: nil,
            by: requester, expectedVersion: held.version
        )
        guard case let .pending(requestedTask, request) = outcome else {
            Issue.record("expected a pending takeover")
            return
        }
        let rejected = try repository.resolveClaimRequest(id: request.id, approve: false)
        #expect(rejected.request.status == .rejected)
        #expect(rejected.task.version == requestedTask.version + 1)
        #expect(rejected.task.claimedBy == holder)
    }

    @Test("rejecting one takeover does not expire another for the same holder")
    func takeoverDecisionOrderDoesNotChooseTheWinner() throws {
        let repository = try makeRepository()
        let holder = Fixtures.key(.codex, "holder-many")
        let first = Fixtures.key(.claudeCode, "requester-first")
        let second = Fixtures.key(.cursor, "requester-second")
        let task = try repository.createTask(title: "Choose one reviewer")
        let held = try repository.claimTask(
            id: task.id, role: "implementer", scope: nil, by: holder
        )
        let firstOutcome = try repository.claimOrRequestTask(
            id: task.id, role: "reviewer", scope: "first", reason: nil,
            by: first, expectedVersion: held.version
        )
        guard case let .pending(firstTask, firstRequest) = firstOutcome else {
            Issue.record("expected first pending takeover")
            return
        }
        let secondOutcome = try repository.claimOrRequestTask(
            id: task.id, role: "reviewer", scope: "second", reason: nil,
            by: second, expectedVersion: firstTask.version
        )
        guard case let .pending(secondTask, secondRequest) = secondOutcome else {
            Issue.record("expected second pending takeover")
            return
        }
        let synchronized = try repository.claimRequests(taskID: task.id)
        #expect(synchronized.allSatisfy { $0.taskVersion == secondTask.version })

        let rejected = try repository.resolveClaimRequest(
            id: firstRequest.id, approve: false
        )
        let remaining = try #require(
            try repository.claimRequests(taskID: task.id).first { $0.id == secondRequest.id }
        )
        #expect(remaining.taskVersion == rejected.task.version)

        let approved = try repository.resolveClaimRequest(id: remaining.id, approve: true)
        #expect(approved.request.status == .approved)
        #expect(approved.task.claimedBy == second)
        #expect(approved.task.claimScope == "second")
    }

    // MARK: - Kind, labels, notes

    @Test("a task carries what kind of work it is and whatever labels were put on it")
    func kindAndLabelsRoundTrip() throws {
        let repository = try makeRepository()
        let task = try repository.createTask(
            title: "Tail the rollout format",
            kind: .fix,
            labels: ["Adapter", "codex", "adapter", "  ", "codex"]
        )
        #expect(task.kind == .fix)
        // Trimmed, lowercased, deduplicated, in the order given.
        #expect(task.labels == ["adapter", "codex"])
        #expect(try repository.task(id: task.id)?.labels == ["adapter", "codex"])

        let updated = try repository.updateTask(id: task.id, kind: .research, labels: [])
        #expect(updated.kind == .research)
        #expect(updated.labels.isEmpty)
    }

    @Test("a note says what kind of thing it is, and where to go and check")
    func notesCarryKindAndRef() throws {
        let repository = try makeRepository()
        let worker = Fixtures.key(.codex, "worker-1")
        let task = try repository.createTask(title: "Decide the wire format")
        try repository.appendLog(
            taskID: task.id, actor: worker, kind: TaskNoteKind.decision.rawValue,
            message: "Protobuf, not JSON: the store is already binary.",
            ref: "a1b2c3d"
        )
        let entry = try #require(try repository.log(taskID: task.id).last)
        #expect(entry.noteKind == .decision)
        #expect(entry.ref == "a1b2c3d")
        // The ledger's own lines are not notes.
        #expect(try repository.log(taskID: task.id).first?.noteKind == nil)
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

    @Test("a notice of any kind is answered by the next prompt")
    func autoClearRule() {
        let asked = AgentNotice(
            session: Fixtures.key(), kind: .needsInput, message: "?", createdAt: Fixtures.date(0)
        )
        #expect(asked.isAnswered(byPromptAt: Fixtures.date(10)))
        #expect(!asked.isAnswered(byPromptAt: Fixtures.date(-10)))
        #expect(!asked.isAnswered(byPromptAt: nil))

        // Every kind, and not only a question: typing into the session's own
        // terminal is the clearing gesture that happens where the work is, and
        // it is the one nobody should have to visit Auspex to perform.
        let blocked = AgentNotice(
            session: Fixtures.key(), kind: .blocked, message: "!", createdAt: Fixtures.date(0)
        )
        #expect(blocked.isAnswered(byPromptAt: Fixtures.date(10)))
        #expect(!blocked.isAnswered(byPromptAt: Fixtures.date(-10)))
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
