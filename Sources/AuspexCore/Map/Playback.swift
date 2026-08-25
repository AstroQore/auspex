import AgentSessionKit
import AgentSessionLive
import Foundation

public enum PlaybackPosition: Hashable, Codable, Sendable {
    case live
    case history(index: Int)

    public var historyIndex: Int? {
        if case .history(let index) = self { return index }
        return nil
    }
}

public enum PlaybackSpeed: Double, CaseIterable, Codable, Sendable {
    case half = 0.5
    case normal = 1
    case double = 2
    case quadruple = 4

    public var label: String {
        rawValue == rawValue.rounded()
            ? "\(Int(rawValue))×"
            : "\(rawValue)×"
    }

    /// Four events per second at 1×.
    public var interval: Duration {
        .milliseconds(Int((250 / rawValue).rounded()))
    }
}

public struct MapTaskHistoryRecord: Hashable, Codable, Sendable {
    public let id: Int64
    public let title: String
    public let body: String?
    public let status: String
    public let priority: Int
    public let projectKey: String?
    public let planID: Int64?
    public let kind: String?
    public let labels: String?
    public let claimedByKey: String?
    public let claimRole: String?
    public let claimScope: String?
    public let createdAt: Date
    public let updatedAt: Date
    public let completedAt: Date?
    public let result: String?
    public let version: Int64

    public var taskStatus: AuspexTaskStatus? { AuspexTaskStatus(rawValue: status) }
}

public struct MapNoticeHistoryRecord: Hashable, Codable, Sendable {
    public let kind: String
    public let message: String
    public let urgency: String
    public let createdAt: Date
    public let clearedAt: Date?
}

public struct MapReportHistoryRecord: Hashable, Codable, Sendable {
    public let focus: String
    public let progress: String?
    public let createdAt: Date
}

public struct MapAcknowledgementHistoryRecord: Hashable, Codable, Sendable {
    public let lastSeenAt: Date
    public let acknowledgedAt: Date?
    public let reason: String?
}

public struct MapPlaybackState: Sendable {
    public var lastBoardHistoryID: Int64?
    public var boards: [String: MapBoard] = [:]
    public var nodes: [String: MapNode] = [:]
    public var memberships: [String: MapMembership] = [:]
    public var placements: [String: MapPlacement] = [:]
    public var sessions: [SessionKey: SessionSnapshot] = [:]
    public var tasks: [Int64: MapTaskHistoryRecord] = [:]
    public var taskLinks: [Int64: Set<String>] = [:]
    public var taskDependencies: [Int64: Set<Int64>] = [:]
    public var notices: [String: MapNoticeHistoryRecord] = [:]
    public var reports: [String: MapReportHistoryRecord] = [:]
    public var acknowledgements: [String: MapAcknowledgementHistoryRecord] = [:]

    public init() {}

    public func membership(boardID: String, nodeID: String) -> MapMembership? {
        memberships[Self.pair(boardID, nodeID)]
    }

    public func placement(boardID: String, nodeID: String) -> MapPlacement? {
        placements[Self.pair(boardID, nodeID)]
    }

    public mutating func setPlacement(_ placement: MapPlacement) {
        placements[Self.pair(placement.boardID, placement.nodeID)] = placement
    }

    static func pair(_ boardID: String, _ nodeID: String) -> String {
        boardID + "\u{1f}" + nodeID
    }
}

public enum MapPlaybackEvent: Hashable, Sendable {
    case session(StoredEvent)
    case board(MapHistoryEntry)

    public var timestamp: Date {
        switch self {
        case .session(let event): event.timestamp
        case .board(let event): event.timestamp
        }
    }

    public var label: String {
        switch self {
        case .session(let event): event.kindLabel
        case .board(let event): event.kind.rawValue
        }
    }

    fileprivate var sortKey: (Date, Int64, Int, Int64) {
        switch self {
        case .session(let event): (event.timestamp, event.sequence, 0, event.id)
        case .board(let event): (event.timestamp, 0, 1, event.id)
        }
    }
}

public struct MapPlaybackMoment: Sendable {
    public let index: Int
    public let count: Int
    public let event: MapPlaybackEvent
    public let state: MapPlaybackState

    public var eventsAhead: Int { max(0, count - index - 1) }
}

/// Immutable event-indexed history with bounded replay from checkpoints.
///
/// Checkpoints are in-memory only and every 256 relevant events. Seeking never
/// performs I/O and applies at most 255 events after copying the nearest value
/// snapshot.
public struct MapPlaybackArchive: Sendable {
    public static let checkpointStride = 256

    public let events: [MapPlaybackEvent]
    private let checkpoints: [Int: MapPlaybackState]

    public init(sessionEvents: [StoredEvent], boardEvents: [MapHistoryEntry]) {
        events =
            (sessionEvents.map(MapPlaybackEvent.session) + boardEvents.map(MapPlaybackEvent.board))
            .sorted { lhs, rhs in
                let left = lhs.sortKey
                let right = rhs.sortKey
                if left.0 != right.0 { return left.0 < right.0 }
                if left.1 != right.1 { return left.1 < right.1 }
                if left.2 != right.2 { return left.2 < right.2 }
                return left.3 < right.3
            }
        var state = MapPlaybackState()
        var values: [Int: MapPlaybackState] = [:]
        for (index, event) in events.enumerated() {
            Self.apply(event, to: &state)
            if index.isMultiple(of: Self.checkpointStride) { values[index] = state }
        }
        checkpoints = values
    }

    public var isEmpty: Bool { events.isEmpty }
    public var count: Int { events.count }

    public func moment(at requested: Int) -> MapPlaybackMoment? {
        guard !events.isEmpty else { return nil }
        let target = min(max(0, requested), events.count - 1)
        let checkpointIndex = (target / Self.checkpointStride) * Self.checkpointStride
        var state = checkpoints[checkpointIndex] ?? MapPlaybackState()
        if checkpointIndex < target {
            for index in (checkpointIndex + 1)...target {
                Self.apply(events[index], to: &state)
            }
        }
        return MapPlaybackMoment(
            index: target,
            count: events.count,
            event: events[target],
            state: state
        )
    }

    private static func apply(_ event: MapPlaybackEvent, to state: inout MapPlaybackState) {
        switch event {
        case .session(let stored): apply(stored, to: &state)
        case .board(let history): apply(history, to: &state)
        }
    }

    private static func apply(_ stored: StoredEvent, to state: inout MapPlaybackState) {
        guard let kind = stored.kind else { return }
        let event = AgentEvent(
            session: stored.session,
            timestamp: stored.timestamp,
            observedAt: stored.observedAt,
            sequence: stored.sequence,
            kind: kind,
            raw: stored.rawPath.map {
                RawRef(path: $0, byteOffset: stored.rawOffset)
            }
        )
        let reducer = SessionStateReducer()
        var previous = state.sessions[stored.session]
        if previous == nil, case .sessionStarted(let identity) = kind {
            previous = SessionStateReducer.initialSnapshot(identity: identity)
        }
        guard let previous else { return }
        state.sessions[stored.session] = reducer.reduce(previous, event: event)
    }

    private static func apply(_ entry: MapHistoryEntry, to state: inout MapPlaybackState) {
        state.lastBoardHistoryID = entry.id
        let decoder = StoreJSON.makeDecoder()
        switch entry.kind {
        case .baseline:
            break
        case .boardCreated, .boardUpdated, .boardDeleted, .boardRestored,
            .rulesChanged, .rulesResumed, .rulesPaused:
            if let board = try? StoreJSON.decode(
                MapBoard.self,
                from: entry.payloadJSON,
                using: decoder
            ) {
                state.boards[board.id] = board
            }
        case .nodeBound:
            if let node = try? StoreJSON.decode(
                MapNode.self,
                from: entry.payloadJSON,
                using: decoder
            ) {
                state.nodes[node.id] = node
            }
        case .nodeMerged:
            if let payload = try? StoreJSON.decode(
                [String: String].self,
                from: entry.payloadJSON,
                using: decoder
            ), let primary = payload["primary"], let duplicate = payload["duplicate"] {
                for (key, var membership) in state.memberships where membership.nodeID == duplicate
                {
                    state.memberships.removeValue(forKey: key)
                    membership = MapMembership(
                        boardID: membership.boardID,
                        nodeID: primary,
                        ruleMatches: membership.ruleMatches,
                        override: membership.override,
                        updatedAt: membership.updatedAt
                    )
                    state.memberships[MapPlaybackState.pair(membership.boardID, primary)] =
                        membership
                }
                for (key, var placement) in state.placements where placement.nodeID == duplicate {
                    state.placements.removeValue(forKey: key)
                    placement = MapPlacement(
                        boardID: placement.boardID,
                        nodeID: primary,
                        x: placement.x,
                        y: placement.y,
                        zIndex: placement.zIndex,
                        isDormant: placement.isDormant,
                        createdAt: placement.createdAt,
                        updatedAt: placement.updatedAt
                    )
                    state.placements[MapPlaybackState.pair(placement.boardID, primary)] = placement
                }
                state.nodes.removeValue(forKey: duplicate)
            }
        case .membershipChanged:
            if let membership = try? StoreJSON.decode(
                MapMembership.self,
                from: entry.payloadJSON,
                using: decoder
            ) {
                state.memberships[MapPlaybackState.pair(membership.boardID, membership.nodeID)] =
                    membership
            }
        case .placementChanged:
            if let placement = try? StoreJSON.decode(
                MapPlacement.self,
                from: entry.payloadJSON,
                using: decoder
            ) {
                state.placements[MapPlaybackState.pair(placement.boardID, placement.nodeID)] =
                    placement
            }
        case .placementRemoved:
            if let boardID = entry.boardID, let nodeID = entry.nodeID {
                state.placements.removeValue(forKey: MapPlaybackState.pair(boardID, nodeID))
            }
        case .taskSnapshot:
            if let task = try? StoreJSON.decode(
                MapTaskHistoryRecord.self,
                from: entry.payloadJSON,
                using: decoder
            ) {
                state.tasks[task.id] = task
            }
        case .taskLinkChanged:
            guard let taskID = entry.taskID, let session = entry.sessionKey,
                let payload = try? StoreJSON.decode(
                    PresencePayload.self,
                    from: entry.payloadJSON,
                    using: decoder
                )
            else { return }
            if payload.isPresent {
                state.taskLinks[taskID, default: []].insert(session)
            } else {
                state.taskLinks[taskID]?.remove(session)
            }
        case .taskDependencyChanged:
            guard let taskID = entry.taskID,
                let payload = try? StoreJSON.decode(
                    DependencyPayload.self,
                    from: entry.payloadJSON,
                    using: decoder
                )
            else { return }
            if payload.isPresent {
                state.taskDependencies[taskID, default: []].insert(payload.dependsOnID)
            } else {
                state.taskDependencies[taskID]?.remove(payload.dependsOnID)
            }
        case .noticeSnapshot:
            if let key = entry.sessionKey,
                let notice = try? StoreJSON.decode(
                    MapNoticeHistoryRecord.self,
                    from: entry.payloadJSON,
                    using: decoder
                )
            {
                state.notices[key] = notice
            }
        case .noticeCleared:
            if let key = entry.sessionKey { state.notices.removeValue(forKey: key) }
        case .reportSnapshot:
            if let key = entry.sessionKey,
                let report = try? StoreJSON.decode(
                    MapReportHistoryRecord.self,
                    from: entry.payloadJSON,
                    using: decoder
                )
            {
                state.reports[key] = report
            }
        case .acknowledgementSnapshot:
            if let key = entry.sessionKey,
                let acknowledgement = try? StoreJSON.decode(
                    MapAcknowledgementHistoryRecord.self,
                    from: entry.payloadJSON,
                    using: decoder
                )
            {
                state.acknowledgements[key] = acknowledgement
            }
        case .mergeApplied:
            break
        }
    }

    private struct PresencePayload: Decodable {
        let present: Int
        var isPresent: Bool { present != 0 }
    }

    private struct DependencyPayload: Decodable {
        let present: Int
        let dependsOnID: Int64
        var isPresent: Bool { present != 0 }
    }
}
