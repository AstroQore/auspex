import AgentSessionKit
import AgentSessionLive
import Foundation
import Testing

@testable import AuspexCore

/// The derivation that turns a wall of sessions into a wall of tasks.
///
/// Three properties, and each is a way the wall goes wrong without it:
///
/// - **Total.** Every session on the frame belongs to exactly one unit. A
///   session that fell out would be work the board stopped showing; a session
///   in two units would be work it counted twice.
/// - **Folded.** A delegation family is one card. That is the whole change,
///   and it is what "board 里 subagent 和主 agent 一起显示，太乱" was about.
/// - **Continuous.** A unit that gets a task filed for it keeps its card. A
///   key that changed on promotion would tear the card down mid-scroll.
@Suite("Task units")
struct TaskUnitTests {
    // MARK: - Fixtures

    static func session(
        _ id: String,
        harness: Harness = .claudeCode,
        state: SessionState = .thinking,
        cwd: String? = "/Users/example/Code/auspex",
        parent: SessionKey? = nil,
        title: String? = nil,
        prompt: String? = nil,
        at offset: TimeInterval = 0
    ) -> SessionSnapshot {
        var snapshot = SessionStateReducer.initialSnapshot(
            identity: SessionIdentity(
                key: SessionKey(harness: harness, sessionID: id),
                sourcePath: "/Users/example/store/\(id).jsonl",
                parent: parent,
                cwd: cwd,
                gitRoot: cwd,
                title: title
            )
        )
        snapshot.state = state
        snapshot.isAlive = !state.isEnded
        snapshot.lastEventAt = Fixtures.date(offset)
        if let prompt {
            snapshot.brief = SessionBrief(
                firstPrompt: prompt,
                latestPrompt: prompt,
                lastPromptAt: Fixtures.date(offset)
            )
        }
        return snapshot
    }

    static func key(_ id: String, _ harness: Harness = .claudeCode) -> SessionKey {
        SessionKey(harness: harness, sessionID: id)
    }

    static func board(_ sessions: [SessionSnapshot]) -> BoardSnapshot {
        BoardSnapshot(generatedAt: Fixtures.date(1_000), sessions: sessions)
    }

    static func task(
        id: Int64,
        title: String,
        status: AuspexTaskStatus = .doing,
        priority: Int = 0,
        planID: Int64? = nil,
        projectKey: String? = "/Users/example/Code/auspex",
        claimedBy: SessionKey? = nil,
        claimRole: String? = nil,
        claimScope: String? = nil,
        dependsOn: [Int64] = [],
        result: String? = nil
    ) -> AuspexTask {
        AuspexTask(
            id: id, planID: planID, title: title, body: nil, status: status,
            priority: priority, projectID: nil, projectKey: projectKey,
            createdBy: nil, claimRole: claimRole, claimScope: claimScope,
            claimedBy: claimedBy, claimedAt: claimedBy.map { _ in Fixtures.date(0) },
            completedAt: nil, result: result, source: "test",
            dependsOn: dependsOn,
            createdAt: Fixtures.date(0), updatedAt: Fixtures.date(10)
        )
    }

    static func units(
        _ board: BoardSnapshot,
        ledger: TaskLedgerFrame = .empty,
        notices: [SessionKey: AgentNotice] = [:]
    ) -> [TaskUnit] {
        TaskUnitBuilder.units(
            sessions: board.sessions,
            board: board,
            ledger: ledger,
            builder: BoardRowBuilder(board: board, notices: notices, now: board.generatedAt),
            now: board.generatedAt
        )
    }

    /// A supervisor and the two subagents it spawned.
    static var family: BoardSnapshot {
        board([
            session("lead", title: "Rework the tailer", prompt: "Rework the tailer", at: 30),
            session("child-1", cwd: nil, parent: key("lead"), title: "Fixtures", at: 20),
            session("child-2", cwd: nil, parent: key("lead"), title: "Docs", at: 25),
        ])
    }

    // MARK: - Implicit units

    @Test("a delegation family is one card, and the subagents are inside it")
    func aFamilyIsOneUnit() {
        let units = Self.units(Self.family)
        #expect(units.count == 1)
        let unit = try! #require(units.first)
        #expect(unit.origin.isImplicit)
        #expect(unit.memberCount == 3)
        #expect(unit.subagents.count == 2)
        // The lead is the root, and the children follow it in board order.
        #expect(unit.lead.key == Self.key("lead"))
        #expect(unit.members.first?.key == Self.key("lead"))
        #expect(Set(unit.subagents.map(\.key.sessionID)) == ["child-1", "child-2"])
        // Its title is what the root was asked to do, and its handle is a
        // handle — nothing about the card says "we made this up".
        #expect(unit.title == "Rework the tailer")
        #expect(unit.shortID.hasPrefix("AUX-"))
    }

    @Test("every session lands in exactly one unit")
    func derivationIsTotal() {
        let board = Self.board([
            Self.session("lead", title: "One", at: 30),
            Self.session("child", cwd: nil, parent: Self.key("lead"), at: 20),
            Self.session("alone", harness: .codex, title: "Two", at: 10),
            Self.session("orphan", cwd: nil, parent: Self.key("gone"), title: "Three", at: 5),
        ])
        let units = Self.units(board)
        let members = units.flatMap(\.members).map(\.key)
        #expect(Set(members).count == members.count)
        #expect(Set(members) == Set(board.sessions.map(\.key)))
        // A subagent whose parent is not on the frame is a root, not a
        // disappearance.
        #expect(units.contains { $0.members.map(\.key.sessionID) == ["orphan"] })
    }

    @Test("the same frame always derives the same units in the same order")
    func derivationIsDeterministic() {
        let board = Self.family
        let first = Self.units(board).map(\.id)
        let second = Self.units(board).map(\.id)
        #expect(first == second)
    }

    // MARK: - Explicit units

    @Test("a claimed task takes the family, and the claimer leads it")
    func aClaimedTaskOwnsTheFamily() {
        let board = Self.family
        let task = Self.task(
            id: 7, title: "Tail the Codex rollout format",
            claimedBy: Self.key("lead"), claimRole: "implementer", claimScope: "the tailer"
        )
        let ledger = TaskLedgerFrame(
            tasks: [task],
            links: [
                AuspexTaskLink(
                    taskID: 7, session: Self.key("lead"), kind: .claim, createdAt: Fixtures.date(0)
                )
            ]
        )
        let units = Self.units(board, ledger: ledger)
        #expect(units.count == 1)
        let unit = try! #require(units.first)
        #expect(unit.origin == .task(7))
        #expect(unit.title == "Tail the Codex rollout format")
        // The subagents came along: they never claimed anything, and they are
        // steps inside the claimer's job.
        #expect(unit.memberCount == 3)
        #expect(unit.lead.key == Self.key("lead"))
        #expect(unit.claim?.description == "implementer · the tailer")
        #expect(unit.claim?.freshAt == Fixtures.date(30))
    }

    @Test("a task nobody has picked up is still a card")
    func anUnclaimedTaskIsAUnit() {
        let ledger = TaskLedgerFrame(tasks: [Self.task(id: 3, title: "Retention", status: .todo)])
        let units = Self.units(Self.board([]), ledger: ledger)
        #expect(units.count == 1)
        let unit = try! #require(units.first)
        #expect(unit.status == .todo)
        #expect(unit.memberCount == 1)  // the placeholder lead, and nothing live
        #expect(unit.counts.live == 0)
        #expect(unit.bucket == .idle)
    }

    @Test("pending takeovers travel with the ledger into the task unit")
    func pendingTakeoverIsVisibleOnUnit() {
        let holder = Self.key("holder")
        let request = TaskClaimRequest(
            id: 41,
            taskID: 3,
            requester: Self.key("requester", .codex),
            holder: holder,
            role: "reviewer",
            scope: "handoff",
            reason: "current owner is blocked",
            taskVersion: 2,
            status: .pending,
            requestedAt: Fixtures.date(25),
            resolvedAt: nil
        )
        let ledger = TaskLedgerFrame(
            tasks: [Self.task(id: 3, title: "Retention", claimedBy: holder)],
            pendingClaims: [request]
        )
        let unit = try! #require(Self.units(Self.board([]), ledger: ledger).first)
        #expect(unit.pendingTakeoverCount == 1)
        #expect(unit.pendingTakeoverAt == Fixtures.date(25))
    }

    // MARK: - Promotion

    @Test("filing a task for a family keeps the card it already had")
    func promotionKeepsTheCard() {
        let board = Self.family
        let before = try! #require(Self.units(board).first)
        #expect(before.origin.isImplicit)

        let ledger = TaskLedgerFrame(
            tasks: [Self.task(id: 11, title: "Rework the tailer, properly",
                              claimedBy: Self.key("lead"))],
            links: [
                AuspexTaskLink(
                    taskID: 11, session: Self.key("lead"), kind: .claim, createdAt: Fixtures.date(0)
                )
            ]
        )
        let after = try! #require(Self.units(board, ledger: ledger).first)

        // A new identity, a new title — and the same card, because that is
        // what the views key on.
        #expect(after.id != before.id)
        #expect(after.title != before.title)
        #expect(after.promotionKey == before.promotionKey)
        #expect(after.members.map(\.key) == before.members.map(\.key))
    }

    // MARK: - Roll-ups

    @Test("a unit is as loud as its loudest member")
    func attentionRollsUp() {
        let board = Self.board([
            Self.session("lead", title: "Rework the tailer", at: 30),
            Self.session(
                "child-1", state: .waitingPermission(tool: "Bash"),
                cwd: nil, parent: Self.key("lead"), at: 20
            ),
            Self.session("child-2", cwd: nil, parent: Self.key("lead"), at: 25),
        ])
        let unit = try! #require(Self.units(board).first)
        #expect(unit.attention.wantsPerson)
        #expect(unit.attentionKey == Self.key("child-1"))
        #expect(unit.status == .blocked)
        #expect(unit.bucket == .needsYou)
        // The lead is still the lead: attention says which member is shouting,
        // it does not reorder the family.
        #expect(unit.lead.key == Self.key("lead"))
    }

    @Test("needing a person outranks having finished")
    func needsYouBeatsReview() {
        let board = Self.board([
            Self.session("lead", title: "Rework", at: 30),
            Self.session(
                "child-1", state: .waitingPermission(tool: "Bash"),
                cwd: nil, parent: Self.key("lead"), at: 20
            ),
        ])
        let notices: [SessionKey: AgentNotice] = [
            Self.key("lead"): AgentNotice(
                session: Self.key("lead"), kind: .done, message: "landed",
                createdAt: Fixtures.date(30)
            )
        ]
        let unit = try! #require(Self.units(board, notices: notices).first)
        #expect(unit.status == .blocked)
        #expect(unit.bucket == .needsYou)
    }

    @Test("the counts add up to the members, in one bucket each")
    func countsAddUp() {
        let board = Self.board([
            Self.session("lead", title: "Rework", at: 30),
            Self.session("child-1", state: .idle, cwd: nil, parent: Self.key("lead"), at: 20),
            Self.session(
                "child-2", state: .ended(reason: .exited),
                cwd: nil, parent: Self.key("lead"), at: 25
            ),
        ])
        let unit = try! #require(Self.units(board).first)
        #expect(unit.counts == TaskUnit.Counts(working: 1, idle: 1, ended: 1))
        #expect(unit.counts.total == unit.memberCount)
        #expect(unit.counts.live == 2)
        #expect(!unit.isEnded)
    }

    @Test("a unit whose sessions have all stopped leaves the wall")
    func endedUnitsFold() {
        let board = Self.board([
            Self.session("lead", state: .ended(reason: .exited), title: "Over", at: 30),
            Self.session("live", harness: .codex, title: "Running", at: 10),
        ])
        let split = TaskUnitGrouping.split(Self.units(board))
        #expect(split.live.map(\.title) == ["Running"])
        #expect(split.ended.map(\.title) == ["Over"])
    }

    @Test("work waiting to be read is not history, however dead its process")
    func reviewedWorkStaysOnTheWall() {
        let board = Self.board([
            Self.session("lead", state: .ended(reason: .exited), title: "Over", at: 30)
        ])
        let notices: [SessionKey: AgentNotice] = [
            Self.key("lead"): AgentNotice(
                session: Self.key("lead"), kind: .done, message: "landed",
                createdAt: Fixtures.date(30)
            )
        ]
        let split = TaskUnitGrouping.split(Self.units(board, notices: notices))
        #expect(split.ended.isEmpty)
        #expect(split.live.first?.status == .review)
        #expect(split.live.first?.bucket == .doneReported)
    }

    // MARK: - Status, dependencies, orphans

    @Test("a closed task stays closed whatever its sessions do next")
    func closedIsClosed() {
        let ledger = TaskLedgerFrame(
            tasks: [Self.task(id: 4, title: "Adapter", status: .done, claimedBy: Self.key("lead"))],
            links: [
                AuspexTaskLink(
                    taskID: 4, session: Self.key("lead"), kind: .claim, createdAt: Fixtures.date(0)
                )
            ]
        )
        let board = Self.board([Self.session("lead", title: "Adapter", at: 30)])
        let unit = try! #require(Self.units(board, ledger: ledger).first)
        #expect(unit.status == .done)
        #expect(unit.bucket == .ended)
    }

    @Test("a task waiting on unfinished work says what it waits on")
    func dependenciesAreNamed() {
        let first = Self.task(id: 1, title: "Land the schema", status: .doing)
        let second = Self.task(id: 2, title: "Read the schema", status: .todo, dependsOn: [1])
        let unit = try! #require(
            Self.units(Self.board([]), ledger: TaskLedgerFrame(tasks: [first, second]))
                .first { $0.origin == .task(2) }
        )
        #expect(!unit.isReady)
        #expect(unit.waitingOn.map(\.id) == [1])
        #expect(unit.waitingOn.first?.shortID == TaskShortID.forTask(1))

        let closed = Self.task(id: 1, title: "Land the schema", status: .done)
        let ready = try! #require(
            Self.units(Self.board([]), ledger: TaskLedgerFrame(tasks: [closed, second]))
                .first { $0.origin == .task(2) }
        )
        #expect(ready.isReady)
        #expect(ready.waitingOn.isEmpty)
    }

    @Test("a claim whose session died is marked, and is not a block")
    func orphanedClaimsAreMarked() {
        let board = Self.board([
            Self.session("lead", state: .ended(reason: .killed), title: "Adapter", at: 30)
        ])
        let ledger = TaskLedgerFrame(
            tasks: [Self.task(id: 5, title: "Adapter", claimedBy: Self.key("lead"),
                              claimRole: "implementer")],
            links: [
                AuspexTaskLink(
                    taskID: 5, session: Self.key("lead"), kind: .claim, createdAt: Fixtures.date(0)
                )
            ]
        )
        let unit = try! #require(Self.units(board, ledger: ledger).first)
        #expect(unit.isClaimOrphaned)
        // Debris, not an emergency: the red bucket is for work that is stuck.
        #expect(unit.bucket != .needsYou)
    }

    // MARK: - Grouping and counting

    @Test("the wall is sectioned by project, with milestones as sub-headings")
    func groupingIsProjectThenMilestone() {
        let auspex = "/Users/example/Code/auspex"
        let storefront = "/Users/example/Code/storefront-web"
        let plan = AuspexPlan(
            id: 1, slug: "live-board", title: "Ship the live board", summary: nil,
            status: .active, projectID: nil, projectKey: auspex, createdBy: nil,
            createdAt: Fixtures.date(0), updatedAt: Fixtures.date(0), archivedAt: nil
        )
        let ledger = TaskLedgerFrame(
            tasks: [
                Self.task(id: 1, title: "Tailer", planID: 1, projectKey: auspex),
                Self.task(id: 2, title: "Retention", projectKey: auspex),
                Self.task(id: 3, title: "Cart", projectKey: storefront),
            ],
            plans: [plan]
        )
        let units = Self.units(Self.board([]), ledger: ledger)
        let groups = TaskUnitGrouping.groups(
            for: units, board: Self.board([]), groupBy: .project
        )
        #expect(groups.map(\.title) == ["auspex", "storefront-web"])
        let first = try! #require(groups.first)
        #expect(first.milestones.count == 2)
        #expect(first.milestones.compactMap(\.title) == ["Ship the live board"])
        #expect(first.unitCount == 2)
    }

    @Test("the header counts units, so a family of three is one working task")
    func summaryCountsUnits() {
        let summary = BoardSummary(units: Self.units(Self.family))
        #expect(summary.working == 1)
        #expect(summary.live == 1)
    }

    @Test("the tree axis opens the cards rather than making a section each")
    func treeAxisExpandsMembers() {
        #expect(TaskUnitGrouping.expandsMembers(.tree))
        #expect(!TaskUnitGrouping.expandsMembers(.project))
        let groups = TaskUnitGrouping.groups(
            for: Self.units(Self.family), board: Self.family, groupBy: .tree
        )
        #expect(groups.count == 1)
        #expect(groups.first?.title == "auspex")
    }

    // MARK: - Filters

    @Test("the filter bar offers only what the wall can answer")
    func filterOptionsComeFromTheFrame() {
        let ledger = TaskLedgerFrame(tasks: [
            Self.task(id: 1, title: "Tailer", priority: 4),
            Self.task(id: 2, title: "Retention", dependsOn: [1]),
        ])
        let units = Self.units(Self.board([]), ledger: ledger)
        let options = TaskFilters.options(for: units)
        #expect(options.importances == [.urgent])
        #expect(options.hasDependencies)
        #expect(!options.hasOrphans)
    }

    @Test("filters compose by conjunction, and an empty one keeps everything")
    func filtersCompose() {
        let ledger = TaskLedgerFrame(tasks: [
            Self.task(id: 1, title: "Tailer", priority: 4),
            Self.task(id: 2, title: "Retention", dependsOn: [1]),
        ])
        let units = Self.units(Self.board([]), ledger: ledger)
        #expect(TaskFilters.none.apply(to: units).count == 2)
        #expect(TaskFilters(importance: .urgent).apply(to: units).map(\.title) == ["Tailer"])
        // The one that waits is not ready; the one that waits on nothing is.
        #expect(TaskFilters(readyOnly: true).apply(to: units).map(\.title) == ["Tailer"])
        #expect(
            TaskFilters(importance: .normal, readyOnly: true).apply(to: units).isEmpty
        )
    }

    // MARK: - Handles

    @Test("a handle is stable, readable, and never says i, l, o or u")
    func handlesAreStable() {
        #expect(TaskShortID.forTask(7) == TaskShortID.forTask(7))
        #expect(TaskShortID.forTask(7) != TaskShortID.forTask(8))
        #expect(TaskShortID.looksLikeHandle(TaskShortID.forTask(7)))
        #expect(!TaskShortID.looksLikeHandle("AUX-3f9"))
        #expect(!TaskShortID.looksLikeHandle("close it"))
        let suffix = TaskShortID.forTask(7).suffix(4)
        #expect(suffix.allSatisfy { !"ilou".contains($0) })
    }
}
