import AgentSessionKit
import AgentSessionLive
import CoreGraphics
import Foundation

public enum FlightGraphChipState: String, Hashable, Sendable {
    case pending
    case succeeded
    case failed
}

public enum FlightGraphMotionPolicy {
    public static func needsClock(
        isVisible: Bool,
        isPlaying: Bool,
        reduceMotion: Bool
    ) -> Bool {
        isVisible && isPlaying && !reduceMotion
    }
}

public struct FlightGraphChip: Identifiable, Hashable, Sendable {
    public let id: String
    public let session: SessionKey
    public let name: String
    public let kind: ToolKind
    public let count: Int
    public let state: FlightGraphChipState

    public init(
        id: String,
        session: SessionKey,
        name: String,
        kind: ToolKind,
        count: Int,
        state: FlightGraphChipState
    ) {
        self.id = id
        self.session = session
        self.name = name
        self.kind = kind
        self.count = count
        self.state = state
    }
}

public struct FlightGraphNode: Identifiable, Hashable, Sendable {
    public var id: SessionKey { key }
    public let key: SessionKey
    public let parent: SessionKey?
    public let title: String
    public let state: SessionState
    public let isStale: Bool
    public let turnCount: Int
    public let toolCount: Int
    public let tokensIn: Int
    public let tokensOut: Int
    public let lastEventAt: Date?
    public let position: CGPoint

    public init(
        key: SessionKey,
        parent: SessionKey?,
        title: String,
        state: SessionState,
        isStale: Bool,
        turnCount: Int,
        toolCount: Int,
        tokensIn: Int,
        tokensOut: Int,
        lastEventAt: Date?,
        position: CGPoint
    ) {
        self.key = key
        self.parent = parent
        self.title = title
        self.state = state
        self.isStale = isStale
        self.turnCount = turnCount
        self.toolCount = toolCount
        self.tokensIn = tokensIn
        self.tokensOut = tokensOut
        self.lastEventAt = lastEventAt
        self.position = position
    }
}

public struct FlightGraphEdge: Identifiable, Hashable, Sendable {
    public var id: String { "\(parent.description)->\(child.description)" }
    public let parent: SessionKey
    public let child: SessionKey
    public let isActive: Bool

    public init(parent: SessionKey, child: SessionKey, isActive: Bool) {
        self.parent = parent
        self.child = child
        self.isActive = isActive
    }
}

public struct FlightGraphFrame: Sendable {
    public let index: Int
    public let count: Int
    public let timestamp: Date
    public let nodes: [FlightGraphNode]
    public let edges: [FlightGraphEdge]
    public let chips: [FlightGraphChip]
    public let openToolCount: Int

    public init(
        index: Int,
        count: Int,
        timestamp: Date,
        nodes: [FlightGraphNode],
        edges: [FlightGraphEdge],
        chips: [FlightGraphChip],
        openToolCount: Int
    ) {
        self.index = index
        self.count = count
        self.timestamp = timestamp
        self.nodes = nodes
        self.edges = edges
        self.chips = chips
        self.openToolCount = openToolCount
    }

    public var latestActiveNodeID: SessionKey? {
        nodes.filter { $0.state.isActive }.max {
            ($0.lastEventAt ?? .distantPast) < ($1.lastEventAt ?? .distantPast)
        }?.key
    }
}

/// Event-indexed execution graph for Flight.
///
/// Checkpoints bound a seek to at most 255 folds. Layout is derived from the
/// complete node universe, so a node that disappears on a backward seek and
/// is born again later returns to exactly the same coordinate.
public struct FlightGraphArchive: Sendable {
    public static let checkpointStride = 256

    public let events: [StoredEvent]
    private let checkpoints: [Int: State]
    private let universe: [SessionKey: NodeFact]

    public init(events: [StoredEvent]) {
        self.events = StoredEvent.orderedForPlayback(events)
        var state = State()
        var values: [Int: State] = [:]
        for (index, event) in self.events.enumerated() {
            state.apply(event)
            if index.isMultiple(of: Self.checkpointStride) { values[index] = state }
        }
        checkpoints = values
        universe = state.nodes
    }

    public var count: Int { events.count }
    public var isEmpty: Bool { events.isEmpty }

    public func frame(at requested: Int, root: SessionKey?) -> FlightGraphFrame? {
        guard !events.isEmpty else { return nil }
        let target = min(max(0, requested), events.count - 1)
        let checkpoint = (target / Self.checkpointStride) * Self.checkpointStride
        var state = checkpoints[checkpoint] ?? State()
        if checkpoint < target {
            for index in (checkpoint + 1)...target { state.apply(events[index]) }
        }
        return state.frame(
            index: target,
            count: events.count,
            timestamp: events[target].timestamp,
            root: root,
            universe: universe
        )
    }

    private struct NodeFact: Sendable {
        var key: SessionKey
        var parent: SessionKey?
        var title: String
        var placeholderState: SessionState
        var lastEventAt: Date
        var order: Int
    }

    private struct CallFact: Sendable {
        var id: String
        var session: SessionKey
        var name: String
        var kind: ToolKind
        var startedAt: Date
        var endedAt: Date?
        var isError: Bool?
    }

    private struct State: Sendable {
        var sessions: [SessionKey: SessionSnapshot] = [:]
        var nodes: [SessionKey: NodeFact] = [:]
        var calls: [String: CallFact] = [:]
        var nextOrder = 0

        mutating func apply(_ stored: StoredEvent) {
            guard let kind = stored.kind else { return }
            ensureNode(stored.session, at: stored.timestamp)

            let event = AgentEvent(
                session: stored.session,
                timestamp: stored.timestamp,
                observedAt: stored.observedAt,
                sequence: stored.sequence,
                kind: kind,
                raw: stored.rawPath.map { RawRef(path: $0, byteOffset: stored.rawOffset) }
            )
            let reducer = SessionStateReducer()
            var previous = sessions[stored.session]
            if previous == nil {
                let identity: SessionIdentity
                if case .sessionStarted(let recorded) = kind {
                    identity = recorded
                } else {
                    identity = SessionIdentity(
                        key: stored.session,
                        sourcePath: stored.rawPath ?? "",
                        title: stored.session.sessionID
                    )
                }
                previous = SessionStateReducer.initialSnapshot(identity: identity)
            }
            if let previous {
                let snapshot = reducer.reduce(previous, event: event)
                sessions[stored.session] = snapshot
                if var fact = nodes[stored.session] {
                    fact.parent = snapshot.identity.parent ?? fact.parent
                    fact.title = snapshot.identity.title ?? fact.title
                    fact.lastEventAt = stored.timestamp
                    nodes[stored.session] = fact
                }
            }

            switch kind {
            case .sessionStarted(let identity):
                if var fact = nodes[stored.session] {
                    fact.parent = identity.parent
                    fact.title = identity.title ?? fact.title
                    nodes[stored.session] = fact
                }
            case .subagentStarted(let child, let agentType, _):
                ensureNode(
                    child,
                    parent: stored.session,
                    title: agentType ?? child.sessionID,
                    at: stored.timestamp
                )
            case .subagentFinished(let child):
                if var fact = nodes[child] {
                    fact.placeholderState = .ended(reason: .exited)
                    fact.lastEventAt = stored.timestamp
                    nodes[child] = fact
                }
            case .toolCallStarted(let id, let name, let kind, _):
                calls[callKey(stored.session, id)] = CallFact(
                    id: id,
                    session: stored.session,
                    name: name,
                    kind: kind,
                    startedAt: stored.timestamp,
                    endedAt: nil,
                    isError: nil
                )
            case .toolCallFinished(let id, let isError):
                let key = callKey(stored.session, id)
                if var call = calls[key] {
                    call.endedAt = stored.timestamp
                    call.isError = isError
                    calls[key] = call
                }
            default:
                break
            }
        }

        mutating func ensureNode(
            _ key: SessionKey,
            parent: SessionKey? = nil,
            title: String? = nil,
            at: Date
        ) {
            if var existing = nodes[key] {
                if existing.parent == nil { existing.parent = parent }
                if existing.title == key.sessionID, let title { existing.title = title }
                existing.lastEventAt = max(existing.lastEventAt, at)
                nodes[key] = existing
                return
            }
            nodes[key] = NodeFact(
                key: key,
                parent: parent,
                title: title ?? key.sessionID,
                placeholderState: .thinking,
                lastEventAt: at,
                order: nextOrder
            )
            nextOrder += 1
        }

        func frame(
            index: Int,
            count: Int,
            timestamp: Date,
            root requestedRoot: SessionKey?,
            universe: [SessionKey: NodeFact]
        ) -> FlightGraphFrame {
            let root = requestedRoot ?? universe.values.min(by: { $0.order < $1.order })?.key
            let positions = Layout.positions(universe: universe, root: root)
            let values = nodes.values.sorted { $0.order < $1.order }
            let visibleKeys = Set(values.map(\.key))
            let graphNodes = values.map { fact -> FlightGraphNode in
                let snapshot = sessions[fact.key]
                let parent = effectiveParent(for: fact, root: root, universe: universe)
                return FlightGraphNode(
                    key: fact.key,
                    parent: parent,
                    title: snapshot?.identity.title ?? fact.title,
                    state: snapshot?.state ?? fact.placeholderState,
                    isStale: snapshot?.isStale ?? false,
                    turnCount: snapshot?.turnCount ?? 0,
                    toolCount: snapshot?.toolCallCount
                        ?? calls.values.count { $0.session == fact.key },
                    tokensIn: snapshot?.tokensIn ?? 0,
                    tokensOut: snapshot?.tokensOut ?? 0,
                    lastEventAt: snapshot?.lastEventAt ?? fact.lastEventAt,
                    position: positions[fact.key] ?? .zero
                )
            }
            let byKey = Dictionary(uniqueKeysWithValues: graphNodes.map { ($0.key, $0) })
            let edges = graphNodes.compactMap { node -> FlightGraphEdge? in
                guard let parent = node.parent, visibleKeys.contains(parent) else { return nil }
                return FlightGraphEdge(
                    parent: parent, child: node.key, isActive: node.state.isActive)
            }
            var pendingRuns: [(chip: FlightGraphChip, at: Date)] = []
            for (session, sessionCalls) in Dictionary(grouping: calls.values, by: \.session) {
                guard byKey[session] != nil else { continue }
                let ordered = sessionCalls.sorted { $0.startedAt < $1.startedAt }
                var start = 0
                while start < ordered.count {
                    var end = start + 1
                    while end < ordered.count,
                        ordered[end].name.caseInsensitiveCompare(ordered[start].name)
                            == .orderedSame,
                        ordered[end].startedAt.timeIntervalSince(ordered[end - 1].startedAt) <= 2.5
                    {
                        end += 1
                    }
                    let run = ordered[start..<end]
                    if run.contains(where: { $0.endedAt == nil }), let newest = run.last {
                        pendingRuns.append(
                            (
                                FlightGraphChip(
                                    id:
                                        "\(session.description)/pending/\(newest.name.lowercased())/\(start)",
                                    session: session,
                                    name: newest.name,
                                    kind: newest.kind,
                                    count: run.count,
                                    state: .pending
                                ),
                                newest.startedAt
                            ))
                    }
                    start = end
                }
            }
            let chips = Dictionary(grouping: pendingRuns, by: { $0.chip.session }).values
                .flatMap { $0.sorted { $0.at > $1.at }.prefix(3).map(\.chip) }
                .sorted { $0.id < $1.id }
            let openToolCount = calls.values.count {
                $0.endedAt == nil && visibleKeys.contains($0.session)
            }

            return FlightGraphFrame(
                index: index,
                count: count,
                timestamp: timestamp,
                nodes: graphNodes,
                edges: edges,
                chips: chips,
                openToolCount: openToolCount
            )
        }

        private func effectiveParent(
            for fact: NodeFact,
            root: SessionKey?,
            universe: [SessionKey: NodeFact]
        ) -> SessionKey? {
            if let parent = fact.parent, universe[parent] != nil { return parent }
            if let root, fact.key != root { return root }
            return nil
        }

        private func callKey(_ session: SessionKey, _ id: String) -> String {
            session.description + "\u{1f}" + id
        }
    }

    private enum Layout {
        static let horizontalPitch: CGFloat = 260
        static let verticalPitch: CGFloat = 150

        static func positions(
            universe: [SessionKey: NodeFact],
            root: SessionKey?
        ) -> [SessionKey: CGPoint] {
            let ordered = universe.values.sorted { $0.order < $1.order }
            var depths: [SessionKey: Int] = [:]
            func depth(_ key: SessionKey, visiting: Set<SessionKey> = []) -> Int {
                if let known = depths[key] { return known }
                guard !visiting.contains(key), let fact = universe[key] else { return 0 }
                let parent = fact.parent ?? (key == root ? nil : root)
                guard let parent, universe[parent] != nil else {
                    depths[key] = 0
                    return 0
                }
                var next = visiting
                next.insert(key)
                let value = depth(parent, visiting: next) + 1
                depths[key] = value
                return value
            }
            for fact in ordered { _ = depth(fact.key) }
            let levels = Dictionary(grouping: ordered) { depths[$0.key] ?? 0 }
            var result: [SessionKey: CGPoint] = [:]
            for level in levels.keys.sorted() {
                let nodes = levels[level] ?? []
                let offset = CGFloat(max(0, nodes.count - 1)) * horizontalPitch / 2
                for (index, node) in nodes.enumerated() {
                    result[node.key] = CGPoint(
                        x: CGFloat(index) * horizontalPitch - offset,
                        y: CGFloat(level) * verticalPitch
                    )
                }
            }
            return result
        }
    }
}
