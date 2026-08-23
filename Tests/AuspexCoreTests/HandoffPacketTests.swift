import AgentSessionKit
import AgentSessionLive
import Foundation
import Testing

@testable import AuspexCore

@Suite("Handoff packet and review queue")
struct HandoffPacketTests {
    private func row(_ id: String = "lead", activity: String = "Validating") -> BoardRow {
        BoardRow(
            key: SessionKey(harness: .codex, sessionID: id),
            harness: .codex,
            title: id == "lead" ? "Lead" : "Worker",
            shortID: String(id.prefix(8)),
            pid: nil,
            modelName: "gpt-example",
            state: .thinking,
            isStale: false,
            project: "example",
            branch: "feat/review",
            directory: "/Users/example/Code/example",
            activity: activity,
            turnCount: 2,
            toolCallCount: 3,
            tokensIn: 10,
            tokensOut: 5,
            elapsedSince: Date(timeIntervalSince1970: 10),
            endedAt: nil,
            lastEventAt: Date(timeIntervalSince1970: 20),
            descendantCount: 0,
            parent: nil,
            depth: 0,
            assignedTask: "Ship delivery review",
            reportedFocus: "Checking the release archive"
        )
    }

    private func unit(
        id: Int64,
        status: AuspexTaskStatus = .review,
        title: String? = nil
    ) -> TaskUnit {
        let lead = row()
        let worker = row("worker-\(id)", activity: "Running tests")
        return TaskUnit(
            id: "task:\(id)",
            shortID: TaskShortID.forTask(id),
            origin: .task(id),
            promotionKey: "task:\(id)",
            projectKey: "/Users/example/Code/example",
            title: title ?? "Delivery review \(id)",
            body: "Make review safe and fast.",
            status: status,
            claim: .init(
                session: lead.key,
                harness: .codex,
                role: "implementer",
                scope: "delivery and handoff",
                claimedAt: Date(timeIntervalSince1970: 5),
                freshAt: Date(timeIntervalSince1970: 20)
            ),
            lead: lead,
            members: [lead, worker],
            counts: .init(working: 2),
            lastEventAt: Date(timeIntervalSince1970: 20),
            result: "All tests passed",
            createdAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: 20)
        )
    }

    @Test("self report, observed delivery, and recorded evidence stay visibly separate")
    func provenanceStaysSeparate() {
        let task = unit(id: 7)
        let log = [
            entry(1, kind: .evidence, message: "Ran the focused suite", ref: "swift test --filter Delivery"),
            entry(2, kind: .decision, message: "No fetch in the reader"),
            entry(3, kind: .risk, message: "Untracked files are absent from diffstat")
        ]
        let delivery = DeliverySnapshot(
            repositoryPath: "/Users/example/Code/example",
            branch: "feat/review",
            workingTree: .unknown,
            checkedAt: Date(timeIntervalSince1970: 30),
            diagnostic: "Local Git status timed out."
        )
        let packet = HandoffPacket(
            unit: task,
            log: log,
            delivery: delivery,
            resumeHints: [.init(sessionLabel: "Codex lead", command: "codex resume lead")]
        ).text

        #expect(packet.contains("Recent [self_reported]: All tests passed"))
        #expect(packet.contains("Local Git [observed_local_git"))
        #expect(packet.contains(": unknown"))
        #expect(packet.contains("## Evidence [recorded]"))
        #expect(packet.contains("`swift test --filter Delivery`"))
        #expect(packet.contains("## Decisions [recorded]"))
        #expect(packet.contains("## Risks [recorded]"))
        #expect(packet.contains("role implementer · scope delivery and handoff"))
        #expect(packet.contains("codex resume lead"))
    }

    @Test("a missing checkout is unknown rather than inferred from the agent result")
    func noDelivery() {
        let packet = HandoffPacket(unit: unit(id: 8), log: [], delivery: nil).text
        #expect(packet.contains("All tests passed"))
        #expect(packet.contains("Local Git [observed]: unknown"))
        #expect(!packet.contains("Working tree: clean"))
    }

    @Test("defer moves work to the end without changing task status")
    func deferOnlyReorders() {
        let one = unit(id: 1)
        let two = unit(id: 2)
        let three = unit(id: 3)
        var queue = ReviewQueue()

        queue.deferReview(id: two.id)
        let ordered = queue.ordered(units: [one, two, three])

        #expect(ordered.map(\.id) == [one.id, three.id, two.id])
        #expect(ordered.allSatisfy { $0.status == .review })
        #expect(queue.neighbor(of: one.id, direction: .next, units: [one, two, three])?.id == three.id)
        #expect(queue.neighbor(of: one.id, direction: .previous, units: [one, two, three]) == nil)
    }

    @Test("resolved work leaves the local defer set")
    func reconcile() {
        let review = unit(id: 1)
        let closed = unit(id: 2, status: .done)
        var queue = ReviewQueue(deferredIDs: [review.id, closed.id])

        queue.reconcile(units: [review, closed])

        #expect(queue.deferredIDs == [review.id])
        #expect(queue.first(units: [review, closed])?.id == review.id)
    }

    private func entry(
        _ id: Int64,
        kind: TaskNoteKind,
        message: String,
        ref: String? = nil
    ) -> AuspexTaskLogEntry {
        AuspexTaskLogEntry(
            id: id,
            taskID: 7,
            timestamp: Date(timeIntervalSince1970: TimeInterval(id)),
            actor: SessionKey(harness: .codex, sessionID: "lead"),
            kind: kind.rawValue,
            message: message,
            ref: ref
        )
    }
}
