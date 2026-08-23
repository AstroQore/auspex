import AgentSessionKit
import AgentSessionLive
import Foundation
import Testing

@testable import AuspexCore

@Suite("Task capsules and catch-up")
struct TaskCapsuleTests {
    private static let project = "/Users/example/Code/auspex"

    private func row(
        id: String = "lead",
        state: SessionState = .thinking,
        activity: String = "Thinking",
        reported: String? = nil,
        reportedAt: TimeInterval? = nil,
        reply: String? = nil,
        turnEndedAt: TimeInterval? = nil,
        notice: BoardRow.RowNotice? = nil,
        stale: Bool = false,
        attention: AttentionState = .none,
        at: TimeInterval = 50
    ) -> BoardRow {
        BoardRow(
            key: SessionKey(harness: .claudeCode, sessionID: id),
            harness: .claudeCode,
            title: "Lead",
            shortID: id,
            pid: nil,
            modelName: nil,
            state: state,
            isStale: stale,
            project: "auspex",
            branch: "feat/catch-up",
            directory: "~/Code/auspex",
            activity: activity,
            turnCount: 1,
            toolCallCount: 1,
            tokensIn: 10,
            tokensOut: 5,
            elapsedSince: Fixtures.date(at - 5),
            endedAt: state.isEnded ? Fixtures.date(at) : nil,
            lastEventAt: Fixtures.date(at),
            descendantCount: 0,
            parent: nil,
            depth: 0,
            assignedTask: "Build catch-up",
            latestAssistant: reply,
            lastTurnEndedAt: turnEndedAt.map(Fixtures.date),
            attention: attention,
            notice: notice,
            reportedFocus: reported,
            reportedFocusAt: reportedAt.map(Fixtures.date)
        )
    }

    private func unit(
        id: Int64 = 7,
        status: AuspexTaskStatus = .doing,
        lead: BoardRow? = nil,
        result: String? = nil,
        waitingOn: [TaskUnit.Dependency] = [],
        orphaned: Bool = false,
        importance: TaskImportance = .normal,
        created: TimeInterval = 10,
        updated: TimeInterval = 50
    ) -> TaskUnit {
        let lead = lead ?? row()
        let live = lead.isEnded ? 0 : 1
        return TaskUnit(
            id: "task:\(id)",
            shortID: "AUX-\(id)",
            origin: .task(id),
            promotionKey: "task:\(id)",
            projectKey: Self.project,
            title: "Build catch-up",
            body: "Show only material changes since the board was reviewed.",
            status: status,
            importance: importance,
            waitingOn: waitingOn,
            isClaimOrphaned: orphaned,
            lead: lead,
            members: [lead],
            attention: lead.attention,
            attentionKey: lead.needsPerson ? lead.key : nil,
            counts: .init(working: lead.state.isActive && !lead.isEnded ? 1 : 0,
                          idle: live == 1 && !lead.state.isActive ? 1 : 0,
                          ended: lead.isEnded ? 1 : 0),
            lastEventAt: lead.lastEventAt,
            result: result,
            createdAt: Fixtures.date(created),
            updatedAt: Fixtures.date(updated)
        )
    }

    @Test("self report wins for current focus and keeps provenance")
    func selfReportWins() {
        let capsule = TaskCapsule(unit: unit(lead: row(
            activity: "Bash", reported: "Validating the archive", reply: "Implementation is done"
        )))
        #expect(capsule.goal.text == "Show only material changes since the board was reviewed.")
        #expect(capsule.current == .init("Validating the archive", source: .selfReported))
        #expect(capsule.recentOutcome == .init("Implementation is done", source: .observed))
        #expect(capsule.phase == .working)
    }

    @Test("blocked work says why and outranks ordinary changes")
    func blockedOutranksChanges() {
        let blocked = unit(lead: row(
            id: "blocked",
            state: .waitingPermission(tool: "Bash"),
            activity: "Waiting for Bash",
            attention: .needsYou(reason: "Approve the release check", source: .harness),
            at: 20
        ))
        let changed = unit(lead: row(id: "changed", at: 80), updated: 80)
        let snapshot = CatchUpSnapshot(
            units: [changed, blocked], since: Fixtures.date(30), generatedAt: Fixtures.date(100)
        )
        #expect(snapshot.items.map(\.kind) == [.needsYou, .changed])
        #expect(snapshot.items.first?.capsule.risk?.text == "Approve the release check")
    }

    @Test("review stays in catch-up even when it predates the cursor")
    func reviewAlwaysStaysActionable() {
        let review = unit(status: .review, result: "Archive loads its bundled icons", updated: 5)
        let snapshot = CatchUpSnapshot(
            units: [review], since: Fixtures.date(30), generatedAt: Fixtures.date(100)
        )
        #expect(snapshot.review == 1)
        #expect(snapshot.items.first?.capsule.nextAction?.text == "Review, then close or reopen")
        #expect(snapshot.items.first?.capsule.recentOutcome?.source == .selfReported)
    }

    @Test("quiet old work is omitted")
    func quietOldWorkIsOmitted() {
        let old = unit(lead: row(at: 10), updated: 10)
        let snapshot = CatchUpSnapshot(
            units: [old], since: Fixtures.date(30), generatedAt: Fixtures.date(100)
        )
        #expect(snapshot.items.isEmpty)
    }

    @Test("tool and token churn alone is not a material catch-up change")
    func noisyEventIsNotMaterial() {
        let noisy = unit(
            lead: row(
                state: .toolCalling(name: "swift test"),
                activity: "swift test --filter CatchUp",
                at: 80
            ),
            created: 5,
            updated: 10
        )
        let snapshot = CatchUpSnapshot(
            units: [noisy], since: Fixtures.date(30), generatedAt: Fixtures.date(100)
        )
        #expect(snapshot.items.isEmpty)
    }

    @Test("reports and turn outcomes are material catch-up changes")
    func semanticSessionChangesAreMaterial() {
        let report = unit(
            id: 1,
            lead: row(reported: "Checking the archive", reportedAt: 70, at: 90),
            created: 5,
            updated: 10
        )
        let outcome = unit(
            id: 2,
            lead: row(reply: "The archive passed", turnEndedAt: 75, at: 90),
            created: 5,
            updated: 10
        )
        let snapshot = CatchUpSnapshot(
            units: [report, outcome], since: Fixtures.date(30), generatedAt: Fixtures.date(100)
        )
        #expect(snapshot.items.map(\.id) == ["task:2", "task:1"])
        #expect(snapshot.items.map(\.capsule.changedAt) == [Fixtures.date(75), Fixtures.date(70)])
    }

    @Test("activity text does not invalidate an unchanged catch-up snapshot")
    func activityTextDoesNotInvalidateSnapshot() {
        let first = CatchUpSnapshot(
            units: [unit(
                status: .review,
                lead: row(activity: "Reading", at: 20),
                created: 5,
                updated: 10
            )],
            since: Fixtures.date(30),
            generatedAt: Fixtures.date(100)
        )
        let second = CatchUpSnapshot(
            units: [unit(
                status: .review,
                lead: row(
                    state: .toolCalling(name: "Bash"),
                    activity: "Bash",
                    at: 90
                ),
                created: 5,
                updated: 10
            )],
            since: Fixtures.date(30),
            generatedAt: Fixtures.date(110)
        )
        #expect(first == second)
        #expect(first.items.first?.capsule.current != second.items.first?.capsule.current)
    }

    @Test("dependency and orphan messages do not invent progress")
    func recordedNextActions() {
        let dependency = TaskUnit.Dependency(id: 2, shortID: "AUX-dep", title: "Ship the parser")
        let waiting = TaskCapsule(unit: unit(waitingOn: [dependency]))
        #expect(waiting.nextAction == .init("Wait for AUX-dep", source: .recorded))

        let orphan = TaskCapsule(unit: unit(orphaned: true))
        #expect(orphan.risk?.source == .derived)
        #expect(orphan.nextAction?.text == "Release or reassign the orphaned claim")
    }

    @Test("the human queue explains urgency and downstream impact")
    func humanQueue() {
        let needs = unit(
            id: 1,
            lead: row(
                id: "needs", state: .waitingPermission(tool: "Bash"),
                attention: .needsYou(reason: "Approve Bash", source: .harness), at: 20
            ),
            importance: .important
        )
        let review = unit(id: 2, status: .review, updated: 30)
        let orphan = unit(id: 3, orphaned: true, updated: 10)
        let dependency = TaskUnit.Dependency(id: 1, shortID: "AUX-1", title: "Needs")
        let downstreamA = unit(id: 4, status: .todo, waitingOn: [dependency])
        let downstreamB = unit(id: 5, status: .todo, waitingOn: [dependency])

        let queue = HumanWorkQueue(
            units: [review, downstreamA, orphan, needs, downstreamB]
        )
        #expect(queue.items.map(\.reason) == [.needsYou, .review, .orphanedClaim])
        #expect(queue.items.first?.unlocks == 2)
        #expect(queue.items.first?.orderingReason.contains("unlocks 2 downstream tasks") == true)
    }
}
