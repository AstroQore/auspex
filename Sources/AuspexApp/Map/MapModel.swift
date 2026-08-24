import AgentSessionKit
import AgentSessionLive
import AuspexCore
import Foundation
import Observation

struct MapCardValue: Identifiable, Equatable, Sendable {
    let id: String
    let unitID: String
    let taskID: Int64?
    let dependencyIDs: [Int64]
    let leadKey: SessionKey
    let title: String
    let shortID: String
    let harness: Harness
    let state: SessionState
    let isStale: Bool
    let attention: AttentionState
    let status: AuspexTaskStatus
    let focus: String
    let projectKey: String?
    let projectName: String
    let memberCount: Int
    let turnCount: Int
    let toolCount: Int
    let lastEventAt: Date?
    let position: CGPoint
    let zIndex: Int64
    let isImplicit: Bool
}

struct MapProjectFrame: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let rect: CGRect
    let liveCount: Int
}

struct MapDependencyValue: Identifiable, Equatable, Sendable {
    var id: String { "\(fromNodeID)->\(toNodeID)" }
    let fromNodeID: String
    let toNodeID: String
    let label: String
}

@MainActor
@Observable
final class MapModel {
    private(set) var boards: [MapBoard] = []
    private(set) var cards: [MapCardValue] = []
    private(set) var projectFrames: [MapProjectFrame] = []
    private(set) var dependencies: [MapDependencyValue] = []
    private(set) var viewport = MapViewport(boardID: MapBoard.allID)
    private(set) var isLoading = false
    private(set) var errorDescription: String?

    var selectedBoardID = MapBoard.allID {
        didSet {
            guard oldValue != selectedBoardID else { return }
            viewport = MapViewport(boardID: selectedBoardID)
            scheduleSync()
            loadViewport()
        }
    }

    var selectedBoard: MapBoard? { boards.first { $0.id == selectedBoardID } }

    func contains(unitID: String) -> Bool { cards.contains { $0.unitID == unitID } }

    private var repository: MapRepository?
    private var units: [TaskUnit] = []
    private var synchronizedBySource: [String: MapSynchronizedNode] = [:]
    private var syncTask: Task<Void, Never>?
    private var viewportTask: Task<Void, Never>?
    private var generation: UInt64 = 0

    func start(repository: MapRepository) {
        self.repository = repository
        reloadBoards()
        scheduleSync()
        loadViewport()
    }

    func apply(units: [TaskUnit]) {
        guard units != self.units else { return }
        self.units = units
        scheduleSync()
    }

    func stop() {
        syncTask?.cancel()
        viewportTask?.cancel()
        syncTask = nil
        viewportTask = nil
    }

    func reloadBoards() {
        guard let repository else { return }
        Task { [weak self] in
            let values = await Task.detached(priority: .utility) {
                (try? repository.boards()) ?? []
            }.value
            guard let self else { return }
            boards = values
            if !values.contains(where: { $0.id == selectedBoardID }) {
                selectedBoardID = MapBoard.allID
            }
        }
    }

    func createBoard(name: String, rule: MapRule? = nil) {
        guard let repository else { return }
        Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                Result { try repository.createBoard(name: name, rule: rule) }
            }.value
            guard let self else { return }
            switch result {
            case .success(let board):
                reloadBoards()
                selectedBoardID = board.id
            case .failure(let error):
                errorDescription = error.localizedDescription
            }
        }
    }

    func renameSelectedBoard(_ name: String) {
        guard let repository, let board = selectedBoard, !board.isProtected else { return }
        Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                Result { try repository.renameBoard(id: board.id, name: name) }
            }.value
            guard let self else { return }
            if case .failure(let error) = result { errorDescription = error.localizedDescription }
            reloadBoards()
        }
    }

    func deleteSelectedBoard() {
        guard let repository, let board = selectedBoard, !board.isProtected else { return }
        Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                Result { try repository.deleteBoard(id: board.id) }
            }.value
            guard let self else { return }
            if case .failure(let error) = result { errorDescription = error.localizedDescription }
            selectedBoardID = MapBoard.allID
            reloadBoards()
        }
    }

    func setRule(_ rule: MapRule?) {
        guard let repository, let board = selectedBoard, !board.isProtected else { return }
        Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                Result { try repository.setRule(boardID: board.id, rule: rule) }
            }.value
            guard let self else { return }
            switch result {
            case .success:
                reloadBoards()
                scheduleSync()
            case .failure(let error):
                errorDescription = error.localizedDescription
            }
        }
    }

    func setRulesPaused(_ paused: Bool) {
        guard let repository, let board = selectedBoard, !board.isProtected else { return }
        Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                Result { try repository.setRulesPaused(boardID: board.id, paused: paused) }
            }.value
            guard let self else { return }
            switch result {
            case .success:
                reloadBoards()
                scheduleSync()
            case .failure(let error):
                errorDescription = error.localizedDescription
            }
        }
    }

    func include(unitID: String) {
        guard let repository,
              let item = synchronizedBySource[unitID],
              selectedBoard?.isProtected == false
        else { return }
        let boardID = selectedBoardID
        Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                Result {
                    try repository.setMembershipOverride(
                        boardID: boardID,
                        nodeID: item.node.id,
                        override: .include
                    )
                }
            }.value
            guard let self else { return }
            if case .failure(let error) = result { errorDescription = error.localizedDescription }
            scheduleSync()
        }
    }

    func exclude(nodeID: String) {
        guard let repository, selectedBoard?.isProtected == false else { return }
        let boardID = selectedBoardID
        Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                Result {
                    try repository.setMembershipOverride(
                        boardID: boardID,
                        nodeID: nodeID,
                        override: .exclude
                    )
                }
            }.value
            guard let self else { return }
            if case .failure(let error) = result { errorDescription = error.localizedDescription }
            scheduleSync()
        }
    }

    func move(nodeID: String, to point: CGPoint) {
        guard let repository else { return }
        let boardID = selectedBoardID
        let snapped = MapPlacementPlanner.snapped(point)
        if let index = cards.firstIndex(where: { $0.id == nodeID }) {
            let old = cards[index]
            cards[index] = MapCardValue(
                id: old.id,
                unitID: old.unitID,
                taskID: old.taskID,
                dependencyIDs: old.dependencyIDs,
                leadKey: old.leadKey,
                title: old.title,
                shortID: old.shortID,
                harness: old.harness,
                state: old.state,
                isStale: old.isStale,
                attention: old.attention,
                status: old.status,
                focus: old.focus,
                projectKey: old.projectKey,
                projectName: old.projectName,
                memberCount: old.memberCount,
                turnCount: old.turnCount,
                toolCount: old.toolCount,
                lastEventAt: old.lastEventAt,
                position: snapped,
                zIndex: old.zIndex,
                isImplicit: old.isImplicit
            )
            deriveChrome()
        }
        Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                Result { try repository.move(boardID: boardID, nodeID: nodeID, to: snapped) }
            }.value
            guard let self else { return }
            if case .failure(let error) = result { errorDescription = error.localizedDescription }
        }
    }

    func saveViewport(center: CGPoint, zoom: CGFloat) {
        viewport = MapViewport(
            boardID: selectedBoardID,
            centerX: center.x,
            centerY: center.y,
            zoom: zoom,
            updatedAt: Date()
        )
        guard let repository else { return }
        viewportTask?.cancel()
        let value = viewport
        viewportTask = Task {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            await Task.detached(priority: .utility) { try? repository.save(viewport: value) }.value
        }
    }

    private func loadViewport() {
        guard let repository else { return }
        let boardID = selectedBoardID
        Task { [weak self] in
            let stored = await Task.detached(priority: .utility) {
                try? repository.viewport(boardID: boardID)
            }.value
            guard let self, selectedBoardID == boardID, let stored else { return }
            viewport = stored
        }
    }

    private func scheduleSync() {
        guard let repository else { return }
        generation &+= 1
        let request = generation
        let boardID = selectedBoardID
        let seeds = units.map(Self.seed)
        let descriptors = seeds.map(\.descriptor)
        syncTask?.cancel()
        isLoading = cards.isEmpty
        syncTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(60))
            guard !Task.isCancelled else { return }
            let result = await Task.detached(priority: .userInitiated) {
                Result { try repository.synchronize(boardID: boardID, descriptors: descriptors) }
            }.value
            guard !Task.isCancelled, let self, generation == request else { return }
            isLoading = false
            syncTask = nil
            switch result {
            case .success(let snapshot):
                adopt(snapshot, seeds: seeds)
            case .failure(let error):
                errorDescription = error.localizedDescription
            }
        }
    }

    private func adopt(_ snapshot: MapWorkspaceSnapshot, seeds: [Seed]) {
        let bySource = Dictionary(uniqueKeysWithValues: seeds.map { ($0.descriptor.sourceID, $0) })
        synchronizedBySource = Dictionary(
            uniqueKeysWithValues: snapshot.nodes.map { ($0.sourceID, $0) }
        )
        cards = snapshot.nodes.compactMap { item in
            guard item.membership.isVisible else { return nil }
            guard let placement = item.placement else { return nil }
            guard let seed = bySource[item.sourceID] else { return nil }
            return seed.card(nodeID: item.node.id, placement: placement)
        }
        deriveChrome()
    }

    private func deriveChrome() {
        var grouped: [String: [MapCardValue]] = [:]
        for card in cards { grouped[card.projectKey ?? "scratch", default: []].append(card) }
        projectFrames = grouped.map { key, members in
            let minX = members.map(\.position.x).min() ?? 0
            let minY = members.map(\.position.y).min() ?? 0
            let maxX = members.map { $0.position.x + MapPlacement.cardSize.width }.max() ?? 0
            let maxY = members.map { $0.position.y + MapPlacement.cardSize.height }.max() ?? 0
            return MapProjectFrame(
                id: key,
                title: members.first?.projectName ?? "Scratch",
                rect: CGRect(
                    x: minX - 28,
                    y: minY - 42,
                    width: max(180, maxX - minX + 56),
                    height: max(120, maxY - minY + 70)
                ),
                liveCount: members.count { !$0.state.isEnded }
            )
        }.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }

        let nodeByTask = Dictionary(
            uniqueKeysWithValues: cards.compactMap { card in
                card.taskID.map { ($0, card.id) }
            }
        )
        let unitByID = Dictionary(uniqueKeysWithValues: units.map { ($0.id, $0) })
        dependencies = cards.flatMap { card -> [MapDependencyValue] in
            guard let unit = unitByID[card.unitID] else { return [] }
            return unit.waitingOn.compactMap { dependency in
                guard let target = nodeByTask[dependency.id] else { return nil }
                return MapDependencyValue(
                    fromNodeID: card.id,
                    toNodeID: target,
                    label: "depends"
                )
            }
        }
    }

    private struct Seed: Sendable {
        let descriptor: MapNodeDescriptor
        let unitID: String
        let taskID: Int64?
        let dependencyIDs: [Int64]
        let leadKey: SessionKey
        let title: String
        let shortID: String
        let harness: Harness
        let state: SessionState
        let isStale: Bool
        let attention: AttentionState
        let status: AuspexTaskStatus
        let focus: String
        let projectKey: String?
        let projectName: String
        let memberCount: Int
        let turnCount: Int
        let toolCount: Int
        let lastEventAt: Date?
        let isImplicit: Bool

        func card(nodeID: String, placement: MapPlacement) -> MapCardValue {
            MapCardValue(
                id: nodeID,
                unitID: unitID,
                taskID: taskID,
                dependencyIDs: dependencyIDs,
                leadKey: leadKey,
                title: title,
                shortID: shortID,
                harness: harness,
                state: state,
                isStale: isStale,
                attention: attention,
                status: status,
                focus: focus,
                projectKey: projectKey,
                projectName: projectName,
                memberCount: memberCount,
                turnCount: turnCount,
                toolCount: toolCount,
                lastEventAt: lastEventAt,
                position: placement.point,
                zIndex: placement.zIndex,
                isImplicit: isImplicit
            )
        }
    }

    private static func seed(_ unit: TaskUnit) -> Seed {
        let attention: MapAttentionKind
        if unit.needsPerson {
            attention = .needsYou
        } else if unit.isInReview {
            attention = .review
        } else if unit.counts.working > 0 {
            attention = .working
        } else if unit.counts.live > 0 {
            attention = .idle
        } else {
            attention = .ended
        }
        let root = unit.members.first(where: { $0.depth == 0 })?.key ?? unit.lead.key
        let descriptor = MapNodeDescriptor(
            sourceID: unit.id,
            taskID: unit.origin.taskID,
            rootSessionKey: unit.hasSessions ? root.description : nil,
            projectKey: unit.projectKey,
            harness: unit.lead.harness,
            labels: Set(unit.labels),
            status: unit.status,
            attention: attention
        )
        return Seed(
            descriptor: descriptor,
            unitID: unit.id,
            taskID: unit.origin.taskID,
            dependencyIDs: unit.dependsOn,
            leadKey: unit.lead.key,
            title: unit.title,
            shortID: unit.shortID,
            harness: unit.lead.harness,
            state: unit.lead.state,
            isStale: unit.lead.isStale,
            attention: unit.attention,
            status: unit.status,
            focus: unit.lead.reportedFocus ?? unit.lead.activity,
            projectKey: unit.projectKey,
            projectName: unit.projectKey.map(BoardGrouping.projectName(forPath:)) ?? "Scratch",
            memberCount: unit.memberCount,
            turnCount: unit.lead.turnCount,
            toolCount: unit.lead.toolCallCount,
            lastEventAt: unit.lastEventAt,
            isImplicit: unit.origin.isImplicit
        )
    }
}
