import AgentSessionKit
import Foundation

/// One user-owned spatial board.
///
/// `all` is the protected aggregate board. Custom boards may mirror the same
/// task independently: membership and placement are both scoped by board id.
public struct MapBoard: Identifiable, Hashable, Codable, Sendable {
    public static let allID = "all"

    public enum Kind: String, Codable, Sendable {
        case all
        case custom
    }

    public let id: String
    public var name: String
    public let kind: Kind
    public var rule: MapRule?
    public var rulesPaused: Bool
    public var sortOrder: Int
    public let createdAt: Date
    public var updatedAt: Date
    public var deletedAt: Date?
    public var parentBoardID: String?
    public var forkEventID: Int64?
    public var mergeBaseEventID: Int64?

    public init(
        id: String,
        name: String,
        kind: Kind,
        rule: MapRule? = nil,
        rulesPaused: Bool = false,
        sortOrder: Int = 0,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        deletedAt: Date? = nil,
        parentBoardID: String? = nil,
        forkEventID: Int64? = nil,
        mergeBaseEventID: Int64? = nil
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.rule = rule
        self.rulesPaused = rulesPaused
        self.sortOrder = sortOrder
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
        self.parentBoardID = parentBoardID
        self.forkEventID = forkEventID
        self.mergeBaseEventID = mergeBaseEventID
    }

    public var isProtected: Bool { kind == .all }
    public var isDeleted: Bool { deletedAt != nil }
}

/// A stable identity for one task-shaped card on the Map.
///
/// The UUID does not change when an implicit root is promoted to a filed task,
/// or when an unclaimed task later acquires a root session. The two optional
/// bindings are aliases that the repository reconciles transactionally.
public struct MapNode: Identifiable, Hashable, Codable, Sendable {
    public let id: String
    public var taskID: Int64?
    public var rootSessionKey: String?
    public var projectKey: String?
    public let createdAt: Date
    public var updatedAt: Date

    public init(
        id: String,
        taskID: Int64? = nil,
        rootSessionKey: String? = nil,
        projectKey: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.taskID = taskID
        self.rootSessionKey = rootSessionKey
        self.projectKey = projectKey
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public enum MapMembershipOverride: String, Codable, CaseIterable, Sendable {
    case include
    case exclude
}

/// Why a node is, or is not, present on one board.
public struct MapMembership: Hashable, Codable, Sendable {
    public let boardID: String
    public let nodeID: String
    public var ruleMatches: Bool
    public var override: MapMembershipOverride?
    public var updatedAt: Date

    public init(
        boardID: String,
        nodeID: String,
        ruleMatches: Bool,
        override: MapMembershipOverride? = nil,
        updatedAt: Date = Date()
    ) {
        self.boardID = boardID
        self.nodeID = nodeID
        self.ruleMatches = ruleMatches
        self.override = override
        self.updatedAt = updatedAt
    }

    public var isVisible: Bool {
        switch override {
        case .include: true
        case .exclude: false
        case nil: ruleMatches
        }
    }
}

/// A node's user-owned position on one board.
public struct MapPlacement: Hashable, Codable, Sendable {
    public static let cardSize = CGSize(width: 280, height: 108)
    public static let grid: CGFloat = 16

    public let boardID: String
    public let nodeID: String
    public var x: Double
    public var y: Double
    public var zIndex: Int64
    public var isDormant: Bool
    public let createdAt: Date
    public var updatedAt: Date

    public init(
        boardID: String,
        nodeID: String,
        x: Double,
        y: Double,
        zIndex: Int64 = 0,
        isDormant: Bool = false,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.boardID = boardID
        self.nodeID = nodeID
        self.x = x
        self.y = y
        self.zIndex = zIndex
        self.isDormant = isDormant
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public var point: CGPoint { CGPoint(x: x, y: y) }
}

/// The current reading position for one board. Viewports are intentionally
/// current-only: history rewinds the board, never the reader's camera.
public struct MapViewport: Hashable, Codable, Sendable {
    public let boardID: String
    public var centerX: Double
    public var centerY: Double
    public var zoom: Double
    public var updatedAt: Date

    public init(
        boardID: String,
        centerX: Double = 0,
        centerY: Double = 0,
        zoom: Double = 1,
        updatedAt: Date = Date()
    ) {
        self.boardID = boardID
        self.centerX = centerX
        self.centerY = centerY
        self.zoom = zoom
        self.updatedAt = updatedAt
    }
}

/// The small, flat value the rule engine evaluates. It deliberately contains
/// no transcript text and no `SessionSnapshot`.
public struct MapRuleCandidate: Hashable, Codable, Sendable {
    public let nodeID: String
    public let projectKey: String?
    public let harness: Harness
    public let labels: Set<String>
    public let status: AuspexTaskStatus
    public let attention: MapAttentionKind

    public init(
        nodeID: String,
        projectKey: String?,
        harness: Harness,
        labels: Set<String>,
        status: AuspexTaskStatus,
        attention: MapAttentionKind
    ) {
        self.nodeID = nodeID
        self.projectKey = projectKey
        self.harness = harness
        self.labels = Set(labels.map { $0.lowercased() })
        self.status = status
        self.attention = attention
    }
}

/// The durable identity and rule-facing fields of one current TaskUnit.
public struct MapNodeDescriptor: Hashable, Codable, Sendable {
    /// The current frame's TaskUnit id. It is not persisted and may change on
    /// promotion; `taskID` and `rootSessionKey` resolve the durable node.
    public let sourceID: String
    public let taskID: Int64?
    public let rootSessionKey: String?
    public let projectKey: String?
    public let harness: Harness
    public let labels: Set<String>
    public let status: AuspexTaskStatus
    public let attention: MapAttentionKind

    public init(
        sourceID: String,
        taskID: Int64?,
        rootSessionKey: String?,
        projectKey: String?,
        harness: Harness,
        labels: Set<String>,
        status: AuspexTaskStatus,
        attention: MapAttentionKind
    ) {
        self.sourceID = sourceID
        self.taskID = taskID
        self.rootSessionKey = rootSessionKey
        self.projectKey = projectKey
        self.harness = harness
        self.labels = Set(labels.map { $0.lowercased() })
        self.status = status
        self.attention = attention
    }

    public func candidate(nodeID: String) -> MapRuleCandidate {
        MapRuleCandidate(
            nodeID: nodeID,
            projectKey: projectKey,
            harness: harness,
            labels: labels,
            status: status,
            attention: attention
        )
    }
}

public struct MapSynchronizedNode: Hashable, Sendable {
    public let sourceID: String
    public let node: MapNode
    public let membership: MapMembership
    public let placement: MapPlacement?

    public init(
        sourceID: String,
        node: MapNode,
        membership: MapMembership,
        placement: MapPlacement?
    ) {
        self.sourceID = sourceID
        self.node = node
        self.membership = membership
        self.placement = placement
    }
}

public struct MapWorkspaceSnapshot: Hashable, Sendable {
    public let board: MapBoard
    public let nodes: [MapSynchronizedNode]

    public init(board: MapBoard, nodes: [MapSynchronizedNode]) {
        self.board = board
        self.nodes = nodes
    }
}

public enum MapAttentionKind: String, Codable, CaseIterable, Sendable {
    case needsYou
    case review
    case working
    case idle
    case ended
}

public enum MapPredicate: Hashable, Codable, Sendable {
    case project(String)
    case harness(Harness)
    case label(String)
    case status(AuspexTaskStatus)
    case attention(MapAttentionKind)

    public func matches(_ candidate: MapRuleCandidate) -> Bool {
        switch self {
        case .project(let key): candidate.projectKey == key
        case .harness(let harness): candidate.harness == harness
        case .label(let label): candidate.labels.contains(label.lowercased())
        case .status(let status): candidate.status == status
        case .attention(let attention): candidate.attention == attention
        }
    }
}

/// A bounded boolean expression for automatic board membership.
public indirect enum MapRule: Hashable, Codable, Sendable {
    case all([MapRule])
    case any([MapRule])
    case not(MapRule)
    case predicate(MapPredicate)

    public static let maximumDepth = 4
    public static let maximumPredicates = 50

    public func matches(_ candidate: MapRuleCandidate) -> Bool {
        switch self {
        case .all(let children): children.allSatisfy { $0.matches(candidate) }
        case .any(let children): children.contains { $0.matches(candidate) }
        case .not(let child): !child.matches(candidate)
        case .predicate(let predicate): predicate.matches(candidate)
        }
    }

    public func validate() throws {
        let shape = shape()
        guard shape.depth <= Self.maximumDepth else {
            throw MapRuleError.tooDeep(maximum: Self.maximumDepth)
        }
        guard shape.predicates <= Self.maximumPredicates else {
            throw MapRuleError.tooManyPredicates(maximum: Self.maximumPredicates)
        }
    }

    private func shape() -> (depth: Int, predicates: Int) {
        switch self {
        case .predicate:
            return (1, 1)
        case .not(let child):
            let value = child.shape()
            return (value.depth + 1, value.predicates)
        case .all(let children), .any(let children):
            let values = children.map { $0.shape() }
            return (
                (values.map(\.depth).max() ?? 0) + 1,
                values.reduce(0) { $0 + $1.predicates }
            )
        }
    }
}

public enum MapRuleError: Error, Equatable, LocalizedError, Sendable {
    case tooDeep(maximum: Int)
    case tooManyPredicates(maximum: Int)

    public var errorDescription: String? {
        switch self {
        case .tooDeep(let maximum):
            "A Map rule may be at most \(maximum) groups deep."
        case .tooManyPredicates(let maximum):
            "A Map rule may contain at most \(maximum) conditions."
        }
    }
}

public enum MapHistoryKind: String, Codable, Sendable {
    case baseline
    case boardCreated
    case boardUpdated
    case boardDeleted
    case boardRestored
    case rulesChanged
    case rulesResumed
    case rulesPaused
    case nodeBound
    case nodeMerged
    case membershipChanged
    case placementChanged
    case placementRemoved
    case taskSnapshot
    case taskLinkChanged
    case taskDependencyChanged
    case noticeSnapshot
    case noticeCleared
    case reportSnapshot
    case acknowledgementSnapshot
    case mergeApplied
}

/// One durable mutation in the user-owned board or coordination overlay.
public struct MapHistoryEntry: Identifiable, Hashable, Sendable {
    public let id: Int64
    public let timestamp: Date
    public let kind: MapHistoryKind
    public let boardID: String?
    public let nodeID: String?
    public let taskID: Int64?
    public let sessionKey: String?
    public let payloadJSON: String

    public init(
        id: Int64,
        timestamp: Date,
        kind: MapHistoryKind,
        boardID: String? = nil,
        nodeID: String? = nil,
        taskID: Int64? = nil,
        sessionKey: String? = nil,
        payloadJSON: String
    ) {
        self.id = id
        self.timestamp = timestamp
        self.kind = kind
        self.boardID = boardID
        self.nodeID = nodeID
        self.taskID = taskID
        self.sessionKey = sessionKey
        self.payloadJSON = payloadJSON
    }
}

/// Pure, one-shot placement for a node that has never been placed before.
/// Existing positions are inputs only and are never rewritten.
public enum MapPlacementPlanner {
    private static let horizontalPitch: CGFloat = 320
    private static let verticalPitch: CGFloat = 148
    // Four full cards occupy 1,240 pt. Leave one card gutter between project
    // origins so the derived frames do not overlap at their default density.
    private static let projectPitch = CGSize(width: 1_440, height: 720)

    public struct Existing: Hashable, Sendable {
        public let point: CGPoint
        public let projectKey: String?

        public init(point: CGPoint, projectKey: String?) {
            self.point = point
            self.projectKey = projectKey
        }
    }

    public static func next(projectKey: String?, existing: [Existing]) -> CGPoint {
        let occupied = Set(existing.map { gridPoint($0.point) })
        let project = existing.filter { $0.projectKey == projectKey }
        let origin: CGPoint
        if let minX = project.map(\.point.x).min(), let minY = project.map(\.point.y).min() {
            origin = CGPoint(x: minX, y: minY)
        } else if !existing.isEmpty {
            var projects: [String] = []
            for item in existing {
                let key = item.projectKey ?? "scratch"
                if !projects.contains(key) { projects.append(key) }
            }
            let slot = projects.count
            origin = CGPoint(
                x: CGFloat(slot % 3) * projectPitch.width,
                y: CGFloat(slot / 3) * projectPitch.height
            )
        } else {
            origin = .zero
        }

        for slot in 0..<10_000 {
            let column = slot % 4
            let row = slot / 4
            let candidate = CGPoint(
                x: snap(origin.x + CGFloat(column) * horizontalPitch),
                y: snap(origin.y + CGFloat(row) * verticalPitch)
            )
            if !occupied.contains(gridPoint(candidate)) { return candidate }
        }
        return CGPoint(x: origin.x, y: origin.y + CGFloat(existing.count) * verticalPitch)
    }

    public static func snapped(_ point: CGPoint) -> CGPoint {
        CGPoint(x: snap(point.x), y: snap(point.y))
    }

    private static func snap(_ value: CGFloat) -> CGFloat {
        (value / MapPlacement.grid).rounded() * MapPlacement.grid
    }

    private static func gridPoint(_ point: CGPoint) -> String {
        "\(Int((point.x / MapPlacement.grid).rounded())):\(Int((point.y / MapPlacement.grid).rounded()))"
    }
}
