import Foundation

/// The actionable subset of the board, ordered by how much work one human
/// gesture unlocks rather than by which session happened to speak last.
///
/// Every ranking input is visible on the returned item. This is a work queue,
/// not a score whose reasoning the person has to guess.
public struct HumanWorkQueue: Sendable, Equatable {
    public struct Item: Identifiable, Sendable, Equatable {
        public enum Reason: String, Sendable, Equatable, Codable, CaseIterable {
            case needsYou = "needs_you"
            case takeover
            case review
            case orphanedClaim = "orphaned_claim"

            fileprivate var rank: Int {
                switch self {
                case .needsYou: 0
                case .takeover: 1
                case .review: 2
                case .orphanedClaim: 3
                }
            }
        }

        public let capsule: TaskCapsule
        public let reason: Reason
        /// Open tasks directly waiting on this task.
        public let unlocks: Int
        public let importance: TaskImportance
        public let waitingSince: Date?
        /// One sentence the UI can show beside the order.
        public let orderingReason: String

        public var id: String { capsule.id }
    }

    public let items: [Item]

    public init(units: [TaskUnit]) {
        var dependentCount: [Int64: Int] = [:]
        for unit in units where unit.isOpen {
            for dependency in unit.waitingOn {
                dependentCount[dependency.id, default: 0] += 1
            }
        }

        items = units.compactMap { unit -> Item? in
            let reason: Item.Reason
            if unit.needsPerson {
                reason = .needsYou
            } else if unit.pendingTakeoverCount > 0 {
                reason = .takeover
            } else if unit.isInReview {
                reason = .review
            } else if unit.isClaimOrphaned {
                reason = .orphanedClaim
            } else {
                return nil
            }
            let unlocks = unit.origin.taskID.flatMap { dependentCount[$0] } ?? 0
            return Item(
                capsule: TaskCapsule(unit: unit),
                reason: reason,
                unlocks: unlocks,
                importance: unit.importance,
                waitingSince: Self.waitingSince(unit, reason: reason),
                orderingReason: Self.explanation(reason: reason, unlocks: unlocks, unit: unit)
            )
        }.sorted(by: Self.precedes)
    }

    private static func waitingSince(_ unit: TaskUnit, reason: Item.Reason) -> Date? {
        switch reason {
        case .needsYou:
            return unit.lead.notice?.at ?? unit.lastEventAt
        case .takeover:
            return unit.pendingTakeoverAt ?? unit.updatedAt
        case .review:
            return unit.updatedAt ?? unit.lastEventAt
        case .orphanedClaim:
            return unit.endedAt ?? unit.lastEventAt
        }
    }

    private static func explanation(
        reason: Item.Reason,
        unlocks: Int,
        unit: TaskUnit
    ) -> String {
        let base: String
        switch reason {
        case .needsYou:
            base = unit.attention.message ?? "Waiting for a person"
        case .takeover:
            let noun = unit.pendingTakeoverCount == 1 ? "request" : "requests"
            base = "\(unit.pendingTakeoverCount) takeover \(noun) waiting for approval"
        case .review:
            base = "Finished work is waiting for review"
        case .orphanedClaim:
            base = "The claiming session ended before finishing"
        }
        guard unlocks > 0 else { return base }
        return "\(base) · unlocks \(unlocks) downstream \(unlocks == 1 ? "task" : "tasks")"
    }

    private static func precedes(_ lhs: Item, _ rhs: Item) -> Bool {
        if lhs.reason.rank != rhs.reason.rank { return lhs.reason.rank < rhs.reason.rank }
        if lhs.unlocks != rhs.unlocks { return lhs.unlocks > rhs.unlocks }
        if lhs.importance.rank != rhs.importance.rank {
            return lhs.importance.rank < rhs.importance.rank
        }
        let left = lhs.waitingSince ?? .distantFuture
        let right = rhs.waitingSince ?? .distantFuture
        if left != right { return left < right }
        return lhs.id < rhs.id
    }
}
