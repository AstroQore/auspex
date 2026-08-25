import Foundation

public struct MapMembershipValue: Hashable, Sendable {
    public let ruleMatches: Bool
    public let override: MapMembershipOverride?

    public init(_ membership: MapMembership) {
        self.ruleMatches = membership.ruleMatches
        self.override = membership.override
    }
}

public struct MapPlacementValue: Hashable, Sendable {
    public let x: Double
    public let y: Double
    public let zIndex: Int64
    public let isDormant: Bool

    public init(_ placement: MapPlacement) {
        self.x = placement.x
        self.y = placement.y
        self.zIndex = placement.zIndex
        self.isDormant = placement.isDormant
    }
}

public struct MapRuleValue: Hashable, Sendable {
    public let rule: MapRule?
    public let paused: Bool

    public init(rule: MapRule?, paused: Bool) {
        self.rule = rule
        self.paused = paused
    }
}

public struct MapLayoutSnapshot: Sendable {
    public let boardID: String
    public var rule: MapRuleValue
    public var memberships: [String: MapMembershipValue]
    public var placements: [String: MapPlacementValue]

    public init(
        boardID: String,
        rule: MapRuleValue,
        memberships: [String: MapMembershipValue],
        placements: [String: MapPlacementValue]
    ) {
        self.boardID = boardID
        self.rule = rule
        self.memberships = memberships
        self.placements = placements
    }
}

public enum MapMergeChoice: String, Codable, Sendable {
    case parent
    case branch
}

public enum MapMergeValue<Value: Sendable>: Sendable {
    case set(Value)
    case remove
}

public struct MapMergeConflict: Identifiable, Hashable, Sendable {
    public enum Field: String, Sendable {
        case membership
        case position
        case rules
    }

    public let id: String
    public let nodeID: String?
    public let field: Field
    public let parentSummary: String
    public let branchSummary: String

    public init(
        id: String,
        nodeID: String?,
        field: Field,
        parentSummary: String,
        branchSummary: String
    ) {
        self.id = id
        self.nodeID = nodeID
        self.field = field
        self.parentSummary = parentSummary
        self.branchSummary = branchSummary
    }
}

public struct MapMergePlan: Sendable {
    public let base: MapLayoutSnapshot
    public let parent: MapLayoutSnapshot
    public let branch: MapLayoutSnapshot
    public let automaticMemberships: [String: MapMergeValue<MapMembershipValue>]
    public let automaticPlacements: [String: MapMergeValue<MapPlacementValue>]
    public let automaticRule: MapRuleValue?
    public let conflicts: [MapMergeConflict]

    public init(
        base: MapLayoutSnapshot,
        parent: MapLayoutSnapshot,
        branch: MapLayoutSnapshot,
        automaticMemberships: [String: MapMergeValue<MapMembershipValue>],
        automaticPlacements: [String: MapMergeValue<MapPlacementValue>],
        automaticRule: MapRuleValue?,
        conflicts: [MapMergeConflict]
    ) {
        self.base = base
        self.parent = parent
        self.branch = branch
        self.automaticMemberships = automaticMemberships
        self.automaticPlacements = automaticPlacements
        self.automaticRule = automaticRule
        self.conflicts = conflicts
    }
}

public enum MapMergePlanner {
    public static func plan(
        base: MapLayoutSnapshot,
        parent: MapLayoutSnapshot,
        branch: MapLayoutSnapshot
    ) -> MapMergePlan {
        var memberships: [String: MapMergeValue<MapMembershipValue>] = [:]
        var placements: [String: MapMergeValue<MapPlacementValue>] = [:]
        var conflicts: [MapMergeConflict] = []

        let memberIDs = Set(base.memberships.keys)
            .union(parent.memberships.keys)
            .union(branch.memberships.keys)
        for id in memberIDs {
            let resolution = merge(
                base: base.memberships[id],
                parent: parent.memberships[id],
                branch: branch.memberships[id]
            )
            switch resolution {
            case .automatic(let value):
                memberships[id] = value.map(MapMergeValue.set) ?? .remove
            case .conflict:
                conflicts.append(MapMergeConflict(
                    id: "membership:\(id)",
                    nodeID: id,
                    field: .membership,
                    parentSummary: membershipSummary(parent.memberships[id]),
                    branchSummary: membershipSummary(branch.memberships[id])
                ))
            }
        }

        let placementIDs = Set(base.placements.keys)
            .union(parent.placements.keys)
            .union(branch.placements.keys)
        for id in placementIDs {
            let resolution = merge(
                base: base.placements[id],
                parent: parent.placements[id],
                branch: branch.placements[id]
            )
            switch resolution {
            case .automatic(let value):
                placements[id] = value.map(MapMergeValue.set) ?? .remove
            case .conflict:
                conflicts.append(MapMergeConflict(
                    id: "position:\(id)",
                    nodeID: id,
                    field: .position,
                    parentSummary: placementSummary(parent.placements[id]),
                    branchSummary: placementSummary(branch.placements[id])
                ))
            }
        }

        let ruleResolution = merge(base: base.rule, parent: parent.rule, branch: branch.rule)
        let automaticRule: MapRuleValue?
        switch ruleResolution {
        case .automatic(let value): automaticRule = value
        case .conflict:
            automaticRule = nil
            conflicts.append(MapMergeConflict(
                id: "rules",
                nodeID: nil,
                field: .rules,
                parentSummary: "Parent rules changed",
                branchSummary: "Branch rules changed"
            ))
        }

        return MapMergePlan(
            base: base,
            parent: parent,
            branch: branch,
            automaticMemberships: memberships,
            automaticPlacements: placements,
            automaticRule: automaticRule,
            conflicts: conflicts.sorted { $0.id < $1.id }
        )
    }

    private enum Resolution<Value> { case automatic(Value); case conflict }

    private static func merge<Value: Equatable>(
        base: Value,
        parent: Value,
        branch: Value
    ) -> Resolution<Value> {
        if parent == branch { return .automatic(parent) }
        if parent == base { return .automatic(branch) }
        if branch == base { return .automatic(parent) }
        return .conflict
    }

    private static func membershipSummary(_ value: MapMembershipValue?) -> String {
        guard let value else { return "Not present" }
        if value.override == .exclude { return "Excluded" }
        if value.override == .include { return "Included manually" }
        return value.ruleMatches ? "Included by rule" : "Dormant"
    }

    private static func placementSummary(_ value: MapPlacementValue?) -> String {
        guard let value else { return "No position" }
        return "\(Int(value.x)), \(Int(value.y))"
    }
}
