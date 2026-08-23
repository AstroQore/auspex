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
        reply: String? = nil,
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
            attention: attention,
            reportedFocus: reported
        )
    }

    private func unit(
        status: AuspexTaskStatus = .doing,
        lead: BoardRow? = nil,
        result: String? = nil,
        waitingOn: [TaskUnit.Dependency] = [],
        orphaned: Bool = false,
        created: TimeInterval = 10,
        updated: TimeInterval = 50
    ) -> TaskUnit {
        let lead = lead ?? row()
        let live = lead.isEnded ? 0 : 1
        return TaskUnit(
            id: "task:7",
            shortID: "AUX-demo",
            origin: .task(7),
            promotionKey: "task:7",
            projectKey: Self.project,
            title: "Build catch-up",
            body: "Show only material changes since the board was reviewed.",
            status: status,
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

    @Test("dependency and orphan messages do not invent progress")
    func recordedNextActions() {
        let dependency = TaskUnit.Dependency(id: 2, shortID: "AUX-dep", title: "Ship the parser")
        let waiting = TaskCapsule(unit: unit(waitingOn: [dependency]))
        #expect(waiting.nextAction == .init("Wait for AUX-dep", source: .recorded))

        let orphan = TaskCapsule(unit: unit(orphaned: true))
        #expect(orphan.risk?.source == .derived)
        #expect(orphan.nextAction?.text == "Release or reassign the orphaned claim")
    }
}
