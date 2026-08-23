import AgentSessionKit
import AgentSessionLive
import Foundation

/// A task reduced to the handful of sentences a person needs to regain context.
///
/// The live board already knows every event. A catch-up surface should not make
/// its reader reconstruct intent from those events again, so this value keeps
/// five deliberately separate answers: the goal, the stable phase, what is
/// happening now, the most recent outcome, and the next action or blocker.
///
/// Every sentence keeps its provenance. Agent-authored text is useful, but it
/// is not the same kind of fact as an observed tool call or a state derived by
/// Auspex, and a summary that erased that difference would be faster to read
/// only by becoming harder to trust.
public struct TaskCapsule: Identifiable, Sendable, Equatable {
    public enum Source: String, Sendable, Equatable, Codable, CaseIterable {
        case observed
        case selfReported = "self_reported"
        case derived
        case recorded
    }

    public struct Line: Sendable, Equatable {
        public let text: String
        public let source: Source

        public init(_ text: String, source: Source) {
            self.text = text
            self.source = source
        }
    }

    /// Stable enough to scan, unlike a tool name that can change every frame.
    public enum Phase: String, Sendable, Equatable, Codable, CaseIterable {
        case notStarted = "not_started"
        case working
        case idle
        case blocked
        case review
        case done
        case ended
    }

    public let id: String
    public let taskID: Int64?
    public let shortID: String
    public let projectKey: String?
    public let title: String
    public let goal: Line
    public let phase: Phase
    public let current: Line?
    public let recentOutcome: Line?
    public let nextAction: Line?
    public let risk: Line?
    public let changedAt: Date?
    public let memberCount: Int

    public init(unit: TaskUnit) {
        id = unit.id
        taskID = unit.origin.taskID
        shortID = unit.shortID
        projectKey = unit.projectKey
        title = unit.title
        goal = Line(Self.goalText(unit), source: unit.origin.isImplicit ? .observed : .recorded)
        phase = Self.phase(unit)
        current = Self.currentLine(unit)
        recentOutcome = Self.outcomeLine(unit)
        nextAction = Self.nextLine(unit)
        risk = Self.riskLine(unit)
        changedAt = Self.changedAt(unit)
        memberCount = unit.counts.total
    }

    private static func goalText(_ unit: TaskUnit) -> String {
        guard let body = clean(unit.body), body != unit.title else { return unit.title }
        return body
    }

    private static func phase(_ unit: TaskUnit) -> Phase {
        if unit.needsPerson || unit.status == .blocked { return .blocked }
        switch unit.status {
        case .todo: return .notStarted
        case .review: return .review
        case .done: return .done
        case .doing:
            if unit.counts.working > 0 { return .working }
            if unit.counts.live > 0 { return .idle }
            return .ended
        case .blocked: return .blocked
        }
    }

    private static func currentLine(_ unit: TaskUnit) -> Line? {
        if let report = clean(unit.lead.reportedFocus) {
            return Line(report, source: .selfReported)
        }
        guard unit.hasSessions, let activity = clean(unit.lead.activity) else { return nil }
        return Line(activity, source: .observed)
    }

    private static func outcomeLine(_ unit: TaskUnit) -> Line? {
        if let result = clean(unit.result) {
            return Line(result, source: .selfReported)
        }
        if let reply = clean(unit.lead.latestAssistant) {
            return Line(reply, source: .observed)
        }
        return nil
    }

    private static func nextLine(_ unit: TaskUnit) -> Line? {
        if unit.isClaimOrphaned {
            return Line("Release or reassign the orphaned claim", source: .derived)
        }
        if !unit.waitingOn.isEmpty {
            let handles = unit.waitingOn.prefix(3).map(\.shortID).joined(separator: ", ")
            let suffix = unit.waitingOn.count > 3 ? " +\(unit.waitingOn.count - 3)" : ""
            return Line("Wait for \(handles)\(suffix)", source: .recorded)
        }
        if unit.needsPerson, let message = clean(unit.attention.message) {
            return Line(message, source: unit.attention.source == .agent ? .selfReported : .observed)
        }
        switch unit.status {
        case .todo:
            return Line("Claim and start", source: .derived)
        case .review:
            return Line("Review, then close or reopen", source: .derived)
        case .done, .doing, .blocked:
            return nil
        }
    }

    private static func riskLine(_ unit: TaskUnit) -> Line? {
        if unit.isClaimOrphaned {
            return Line("The claiming session ended before the task was finished", source: .derived)
        }
        if unit.needsPerson, let message = clean(unit.attention.message) {
            return Line(message, source: unit.attention.source == .agent ? .selfReported : .observed)
        }
        if unit.lead.isStale, !unit.lead.isEnded {
            return Line("The live session has stopped producing fresh activity", source: .derived)
        }
        if let context = unit.lead.context,
           let fraction = context.fraction,
           fraction >= 0.9 {
            return Line("Context window is at least 90% full", source: .observed)
        }
        return nil
    }

    private static func changedAt(_ unit: TaskUnit) -> Date? {
        [unit.lastEventAt, unit.updatedAt, unit.lead.notice?.at]
            .compactMap { $0 }
            .max()
    }

    private static func clean(_ text: String?) -> String? {
        guard let text else { return nil }
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? nil : cleaned
    }
}

/// What materially changed since the person last reviewed the board.
///
/// This is intentionally a deterministic inbox, not an LLM summary. It can
/// miss nuance, but every row has a stable reason for being present and opens
/// the original task as evidence. A later optional summarizer can rewrite the
/// prose; it must not decide which work disappears from the inbox.
public struct CatchUpSnapshot: Sendable, Equatable {
    public struct Item: Identifiable, Sendable, Equatable {
        public enum Kind: String, Sendable, Equatable, Codable, CaseIterable {
            case needsYou = "needs_you"
            case review
            case orphanedClaim = "orphaned_claim"
            case completed
            case started
            case changed

            fileprivate var rank: Int {
                switch self {
                case .needsYou: 0
                case .review: 1
                case .orphanedClaim: 2
                case .completed: 3
                case .started: 4
                case .changed: 5
                }
            }
        }

        public let capsule: TaskCapsule
        public let kind: Kind

        public var id: String { capsule.id }
    }

    public let since: Date
    public let generatedAt: Date
    public let items: [Item]

    public init(units: [TaskUnit], since: Date, generatedAt: Date = Date()) {
        self.since = since
        self.generatedAt = generatedAt
        items = units.compactMap { unit in
            let capsule = TaskCapsule(unit: unit)
            if unit.needsPerson { return Item(capsule: capsule, kind: .needsYou) }
            if unit.isInReview { return Item(capsule: capsule, kind: .review) }
            if unit.isClaimOrphaned { return Item(capsule: capsule, kind: .orphanedClaim) }
            guard let changed = capsule.changedAt, changed > since else { return nil }
            if unit.status == .done { return Item(capsule: capsule, kind: .completed) }
            if let created = unit.createdAt, created > since {
                return Item(capsule: capsule, kind: .started)
            }
            return Item(capsule: capsule, kind: .changed)
        }.sorted { lhs, rhs in
            if lhs.kind.rank != rhs.kind.rank { return lhs.kind.rank < rhs.kind.rank }
            let left = lhs.capsule.changedAt ?? .distantPast
            let right = rhs.capsule.changedAt ?? .distantPast
            if left != right { return left > right }
            return lhs.id < rhs.id
        }
    }

    public var needsYou: Int { items.count { $0.kind == .needsYou } }
    public var review: Int { items.count { $0.kind == .review } }
    public var changed: Int { items.count - needsYou - review }
}
