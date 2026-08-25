import AgentSessionKit
import AgentSessionLive
import AuspexCore
import Foundation
import Observation

struct MapCardValue: Identifiable, Equatable, Sendable {
    let id: String
    let unitID: String
    let taskID: Int64?
    let taskVersion: Int64?
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
    let subagents: [MapSubagentValue]
    let turnCount: Int
    let toolCount: Int
    let lastEventAt: Date?
    let position: CGPoint
    let zIndex: Int64
    let isImplicit: Bool

    func placed(nodeID: String, placement: MapPlacement) -> MapCardValue {
        MapCardValue(
            id: nodeID,
            unitID: unitID,
            taskID: taskID,
            taskVersion: taskVersion,
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
            subagents: subagents,
            turnCount: turnCount,
            toolCount: toolCount,
            lastEventAt: lastEventAt,
            position: placement.point,
            zIndex: placement.zIndex,
            isImplicit: isImplicit
        )
    }
}

struct MapSubagentValue: Identifiable, Equatable, Sendable {
    var id: SessionKey { key }
    let key: SessionKey
    let title: String
    let shortID: String
    let harness: Harness
    let state: SessionState
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
    private(set) var deletedBoards: [MapBoard] = []
    private(set) var cards: [MapCardValue] = []
    private(set) var projectFrames: [MapProjectFrame] = []
    private(set) var dependencies: [MapDependencyValue] = []
    private(set) var viewport = MapViewport(boardID: MapBoard.allID)
    private(set) var isLoading = false
    private(set) var errorDescription: String?
    private(set) var mirrorNamesByNode: [String: [String]] = [:]
    private(set) var playbackPosition = PlaybackPosition.live
    private(set) var playbackSpeed = PlaybackSpeed.normal
    private(set) var isPlaying = false
    private(set) var isHistoryLoading = false
    private(set) var playbackMoment: MapPlaybackMoment?
    private(set) var mergePlan: MapMergePlan?
    private(set) var mergeChoices: [String: MapMergeChoice] = [:]
    private(set) var isPreparingMerge = false
    private(set) var expandedNodeIDs: Set<String> = []

    var isHistory: Bool { playbackPosition.historyIndex != nil }
    var historyCount: Int { playbackArchive?.count ?? 0 }
    var historyIndex: Int { playbackPosition.historyIndex ?? max(0, historyCount - 1) }
    var eventsAhead: Int { playbackMoment?.eventsAhead ?? 0 }
    var eventsSincePlayhead: [MapPlaybackEvent] {
        guard let archive = playbackArchive, let index = playbackPosition.historyIndex,
            index + 1 < archive.events.count
        else { return [] }
        return Array(archive.events[(index + 1)...].prefix(6))
    }

    var selectedBoardID = MapBoard.allID {
        didSet {
            guard oldValue != selectedBoardID else { return }
            jumpToLive()
            playbackArchive = nil
            hasStoredViewport = false
            viewport = MapViewport(boardID: selectedBoardID)
            liveAdoptTask?.cancel()
            liveAdoptTask = nil
            pendingLiveSeeds = nil
            scheduleSync()
            loadViewport()
        }
    }

    var selectedBoard: MapBoard? { boards.first { $0.id == selectedBoardID } }
    var canMergeSelectedBoard: Bool { selectedBoard?.parentBoardID != nil && !isHistory }
    var canMoveSelectedBoardUp: Bool {
        guard !isHistory,
            let index = boards.firstIndex(where: { $0.id == selectedBoardID })
        else { return false }
        return index > 1
    }
    var canMoveSelectedBoardDown: Bool {
        guard !isHistory,
            let index = boards.firstIndex(where: { $0.id == selectedBoardID })
        else { return false }
        return index > 0 && index < boards.count - 1
    }

    func contains(unitID: String) -> Bool { cards.contains { $0.unitID == unitID } }

    func toggleExpanded(nodeID: String) {
        if expandedNodeIDs.contains(nodeID) {
            expandedNodeIDs.remove(nodeID)
        } else {
            expandedNodeIDs.insert(nodeID)
        }
    }

    private var repository: MapRepository?
    private var sessionRepository: SessionRepository?
    private var units: [TaskUnit] = []
    private var synchronizedBySource: [String: MapSynchronizedNode] = [:]
    private var synchronizedBoardID: String?
    private var synchronizedDescriptors: [MapNodeDescriptor] = []
    private var liveCards: [MapCardValue] = []
    private var preservedForkCardsByBoard: [String: [String: MapCardValue]] = [:]
    private var syncTask: Task<Void, Never>?
    private var liveAdoptTask: Task<Void, Never>?
    private var pendingLiveSeeds: [Seed]?
    private var viewportTask: Task<Void, Never>?
    private var historyLoadTask: Task<Void, Never>?
    private var seekTask: Task<Void, Never>?
    private var playbackTask: Task<Void, Never>?
    private var playbackArchive: MapPlaybackArchive?
    private var pendingHistoryIndex: Int?
    private var generation: UInt64 = 0
    private var hasStoredViewport = false

    func start(repository: MapRepository, sessions: SessionRepository) {
        self.repository = repository
        self.sessionRepository = sessions
        reloadBoards()
        scheduleSync()
        loadViewport()
    }

    func apply(units: [TaskUnit]) {
        guard units != self.units else { return }
        self.units = units
        let seeds = units.map(Self.seed)
        let descriptors = seeds.map(\.descriptor)
        if requiresWorkspaceSync(descriptors) {
            scheduleSync()
        } else {
            scheduleLiveAdopt(seeds)
        }
        if isHistory { scheduleHistoryLoad() }
    }

    func stop() {
        syncTask?.cancel()
        liveAdoptTask?.cancel()
        viewportTask?.cancel()
        historyLoadTask?.cancel()
        seekTask?.cancel()
        playbackTask?.cancel()
        syncTask = nil
        liveAdoptTask = nil
        pendingLiveSeeds = nil
        viewportTask = nil
        historyLoadTask = nil
        seekTask = nil
        playbackTask = nil
    }

    func reloadBoards() {
        guard let repository else { return }
        Task { [weak self] in
            let values = await Task.detached(priority: .utility) {
                (try? repository.boards(includingDeleted: true)) ?? []
            }.value
            guard let self else { return }
            boards = values.filter { !$0.isDeleted }
            deletedBoards = values.filter(\.isDeleted)
            if !boards.contains(where: { $0.id == selectedBoardID }) {
                selectedBoardID = MapBoard.allID
            }
        }
    }

    func createBoard(name: String, rule: MapRule? = nil) {
        guard !isHistory, let repository else { return }
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
        guard !isHistory, let repository, let board = selectedBoard, !board.isProtected else {
            return
        }
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
        guard !isHistory, let repository, let board = selectedBoard, !board.isProtected else {
            return
        }
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

    func restoreBoard(_ boardID: String) {
        guard !isHistory, let repository else { return }
        Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                Result { try repository.restoreBoard(id: boardID) }
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

    func moveSelectedBoard(by offset: Int) {
        guard !isHistory, offset != 0, let repository,
            let index = boards.firstIndex(where: { $0.id == selectedBoardID }),
            index > 0
        else { return }
        let target = index + offset
        guard boards.indices.contains(target), target > 0 else { return }
        var reordered = boards
        reordered.swapAt(index, target)
        let customIDs = reordered.filter { !$0.isProtected }.map(\.id)
        Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                Result { try repository.reorderBoards(customIDs) }
            }.value
            guard let self else { return }
            if case .failure(let error) = result {
                errorDescription = error.localizedDescription
            }
            reloadBoards()
        }
    }

    func setRule(_ rule: MapRule?) {
        guard !isHistory, let repository, let board = selectedBoard, !board.isProtected else {
            return
        }
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
        guard !isHistory, let repository, let board = selectedBoard, !board.isProtected else {
            return
        }
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
        guard !isHistory,
            let repository,
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
        guard !isHistory, let repository, selectedBoard?.isProtected == false else { return }
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
        guard !isHistory, let repository else { return }
        let boardID = selectedBoardID
        let snapped = MapPlacementPlanner.snapped(point)
        if let index = cards.firstIndex(where: { $0.id == nodeID }) {
            let old = cards[index]
            cards[index] = MapCardValue(
                id: old.id,
                unitID: old.unitID,
                taskID: old.taskID,
                taskVersion: old.taskVersion,
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
                subagents: old.subagents,
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
        // Canvas-origin movement updates the minimap immediately but keeps the
        // last external stamp. `MapCanvasNSView.update` uses that stamp to
        // distinguish a stored/board-switch viewport it must apply from the
        // native scroll position it just reported itself.
        let visible = MapViewport(
            boardID: selectedBoardID,
            centerX: center.x,
            centerY: center.y,
            zoom: zoom,
            updatedAt: viewport.updatedAt
        )
        viewport = visible
        guard let repository else { return }
        viewportTask?.cancel()
        let value = MapViewport(
            boardID: visible.boardID,
            centerX: visible.centerX,
            centerY: visible.centerY,
            zoom: visible.zoom,
            updatedAt: Date()
        )
        viewportTask = Task {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            await Task.detached(priority: .utility) { try? repository.save(viewport: value) }.value
        }
    }

    // MARK: Playback

    func setPlaybackSpeed(_ speed: PlaybackSpeed) {
        playbackSpeed = speed
        if isPlaying { startPlaybackLoop() }
    }

    func enterHistory(at index: Int? = nil) {
        pendingHistoryIndex = index
        if let archive = playbackArchive, !archive.isEmpty {
            seek(to: index ?? archive.count - 1)
        } else {
            scheduleHistoryLoad()
        }
    }

    func togglePlayback() {
        if !isHistory {
            enterHistory()
            isPlaying = false
            return
        }
        isPlaying.toggle()
        if isPlaying { startPlaybackLoop() } else { playbackTask?.cancel() }
    }

    func seek(to index: Int) {
        guard let archive = playbackArchive, !archive.isEmpty else {
            pendingHistoryIndex = index
            scheduleHistoryLoad()
            return
        }
        let target = min(max(0, index), archive.count - 1)
        playbackPosition = .history(index: target)
        seekTask?.cancel()
        seekTask = Task { [weak self] in
            let moment = await Task.detached(priority: .userInitiated) {
                archive.moment(at: target)
            }.value
            guard !Task.isCancelled, let self,
                playbackPosition.historyIndex == target,
                let moment
            else { return }
            playbackMoment = moment
            cards = historicalCards(from: moment)
            deriveChrome()
        }
    }

    func jumpToLive() {
        playbackTask?.cancel()
        seekTask?.cancel()
        playbackTask = nil
        seekTask = nil
        isPlaying = false
        playbackPosition = .live
        playbackMoment = nil
        cards = liveCards
        deriveChrome()
    }

    func pausePlayback() {
        isPlaying = false
        playbackTask?.cancel()
        playbackTask = nil
    }

    func forkAtPlayhead() {
        guard isHistory,
            let repository,
            let source = selectedBoard,
            let moment = playbackMoment,
            let historyID = moment.state.lastBoardHistoryID
        else { return }
        let rawName = "\(source.name) · event \(moment.index + 1)"
        let name = String(rawName.prefix(80))
        var forkState = moment.state
        for item in synchronizedBySource.values {
            if let placement = item.placement { forkState.setPlacement(placement) }
        }
        let spatialState = forkState
        let forkCards = cards
        Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                Result {
                    try repository.forkBoard(
                        source: source,
                        state: spatialState,
                        through: historyID,
                        name: name
                    )
                }
            }.value
            guard let self else { return }
            switch result {
            case .success(let board):
                preservedForkCardsByBoard[board.id] = Dictionary(
                    uniqueKeysWithValues: forkCards.map { ($0.id, $0) }
                )
                jumpToLive()
                reloadBoards()
                selectedBoardID = board.id
            case .failure(let error):
                errorDescription = error.localizedDescription
            }
        }
    }

    func prepareMerge() {
        guard let repository, canMergeSelectedBoard else { return }
        let branchID = selectedBoardID
        isPreparingMerge = true
        Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                Result { try repository.prepareMerge(branchID: branchID) }
            }.value
            guard let self, selectedBoardID == branchID else { return }
            isPreparingMerge = false
            switch result {
            case .success(let plan):
                mergePlan = plan
                mergeChoices = [:]
            case .failure(let error):
                errorDescription = error.localizedDescription
            }
        }
    }

    func choose(_ choice: MapMergeChoice, for conflictID: String) {
        mergeChoices[conflictID] = choice
    }

    func cancelMerge() {
        mergePlan = nil
        mergeChoices = [:]
    }

    func applyMerge() {
        guard !isHistory, let repository, let plan = mergePlan, let branch = selectedBoard else {
            return
        }
        let choices = mergeChoices
        let branchID = branch.id
        let parentID = branch.parentBoardID
        Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                Result {
                    try repository.applyMerge(
                        branchID: branchID,
                        plan: plan,
                        choices: choices
                    )
                }
            }.value
            guard let self else { return }
            switch result {
            case .success:
                mergePlan = nil
                mergeChoices = [:]
                reloadBoards()
                if let parentID { selectedBoardID = parentID }
            case .failure(let error):
                errorDescription = error.localizedDescription
            }
        }
    }

    private func startPlaybackLoop() {
        playbackTask?.cancel()
        guard isPlaying else { return }
        let speed = playbackSpeed
        playbackTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: speed.interval)
                guard !Task.isCancelled, let self else { return }
                guard let index = playbackPosition.historyIndex else { return }
                let next = index + 1
                if next >= historyCount {
                    jumpToLive()
                    return
                }
                seek(to: next)
            }
        }
    }

    private func scheduleHistoryLoad() {
        guard let repository, let sessionRepository else { return }
        historyLoadTask?.cancel()
        let boardID = selectedBoardID
        let keys = Array(Set(units.flatMap { $0.members.map(\.key) }))
        let explicitIndex = pendingHistoryIndex
        let retainedIndex = playbackPosition.historyIndex
        let retainedEvent: MapPlaybackEvent? = retainedIndex.flatMap { index in
            guard let playbackArchive, playbackArchive.events.indices.contains(index) else {
                return nil
            }
            return playbackArchive.events[index]
        }
        isHistoryLoading = true
        historyLoadTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            let archive = await Task.detached(priority: .userInitiated) {
                () -> MapPlaybackArchive in
                let boardEvents = (try? repository.allHistory(boardID: boardID)) ?? []
                let baseline = boardEvents.first { $0.kind == .baseline }?.timestamp ?? .distantPast
                let sessionEvents =
                    (try? sessionRepository.playbackEvents(
                        keys: keys,
                        since: baseline
                    )) ?? []
                return MapPlaybackArchive(
                    sessionEvents: sessionEvents,
                    boardEvents: boardEvents.filter { $0.timestamp >= baseline }
                )
            }.value
            guard !Task.isCancelled, let self, selectedBoardID == boardID else { return }
            playbackArchive = archive
            isHistoryLoading = false
            historyLoadTask = nil
            guard !archive.isEmpty else { return }
            let requested = Self.restoredHistoryIndex(
                explicit: explicitIndex,
                retainedEvent: retainedEvent,
                retainedIndex: retainedIndex,
                events: archive.events
            )
            pendingHistoryIndex = nil
            seek(to: requested)
        }
    }

    static func restoredHistoryIndex(
        explicit: Int?,
        retainedEvent: MapPlaybackEvent?,
        retainedIndex: Int?,
        events: [MapPlaybackEvent]
    ) -> Int {
        guard !events.isEmpty else { return 0 }
        if let explicit { return min(max(0, explicit), events.count - 1) }
        if let retainedEvent, let restored = events.firstIndex(of: retainedEvent) {
            return restored
        }
        if let retainedIndex { return min(max(0, retainedIndex), events.count - 1) }
        return events.count - 1
    }

    private func historicalCards(from moment: MapPlaybackMoment) -> [MapCardValue] {
        let state = moment.state
        let liveByNode = Dictionary(uniqueKeysWithValues: liveCards.map { ($0.id, $0) })
        let currentPlacementByNode = Dictionary(
            uniqueKeysWithValues:
                synchronizedBySource.values.compactMap { item in
                    item.placement.map { (item.node.id, $0) }
                }
        )
        return state.nodes.values.compactMap { node in
            guard let membership = state.membership(boardID: selectedBoardID, nodeID: node.id),
                membership.isVisible,
                let placement = currentPlacementByNode[node.id]
                    ?? state.placement(boardID: selectedBoardID, nodeID: node.id)
            else { return nil }
            let task = node.taskID.flatMap { state.tasks[$0] }
            let rootKey =
                node.rootSessionKey.flatMap(SessionKey.init(string:))
                ?? node.taskID.flatMap { state.taskLinks[$0]?.first }.flatMap(
                    SessionKey.init(string:))
            guard let key = rootKey ?? liveByNode[node.id]?.leadKey else { return nil }
            let snapshot = state.sessions[key]
            let base = liveByNode[node.id]
            let notice = state.notices[key.description].flatMap { record -> AgentNotice? in
                guard let kind = AgentNoticeKind(rawValue: record.kind),
                    let urgency = AgentNoticeUrgency(rawValue: record.urgency)
                else { return nil }
                return AgentNotice(
                    session: key,
                    kind: kind,
                    message: record.message,
                    urgency: urgency,
                    createdAt: record.createdAt,
                    clearedAt: record.clearedAt
                )
            }
            let acknowledged = state.acknowledgements[key.description]?.acknowledgedAt
            let attention = AttentionState.derive(
                state: snapshot?.state ?? base?.state ?? .idle,
                notice: notice,
                acknowledgedAt: acknowledged,
                lastPromptAt: snapshot?.brief.lastPromptAt,
                lastEventAt: snapshot?.lastEventAt,
                now: moment.event.timestamp
            )
            let status = task?.taskStatus ?? base?.status ?? .doing
            let projectKey = task?.projectKey ?? node.projectKey ?? base?.projectKey
            let links = node.taskID.flatMap { state.taskLinks[$0]?.count } ?? base?.memberCount ?? 1
            let subagents = (snapshot?.children ?? []).compactMap { child -> MapSubagentValue? in
                guard let childSnapshot = state.sessions[child] else { return nil }
                return MapSubagentValue(
                    key: child,
                    title: childSnapshot.identity.title ?? child.sessionID,
                    shortID: String(child.sessionID.prefix(8)),
                    harness: child.harness,
                    state: childSnapshot.state
                )
            }
            return MapCardValue(
                id: node.id,
                unitID: node.taskID.map { "task:\($0)" } ?? node.rootSessionKey.map {
                    "implicit:\($0)"
                }
                    ?? node.id,
                taskID: node.taskID,
                taskVersion: task?.version ?? base?.taskVersion,
                dependencyIDs: node.taskID.map { Array(state.taskDependencies[$0] ?? []).sorted() }
                    ?? base?.dependencyIDs ?? [],
                leadKey: key,
                title: task?.title ?? snapshot?.identity.title ?? base?.title ?? key.sessionID,
                shortID: String(key.sessionID.prefix(8)),
                harness: key.harness,
                state: snapshot?.state ?? base?.state ?? .idle,
                isStale: snapshot?.isStale ?? false,
                attention: attention,
                status: status,
                focus: state.reports[key.description]?.focus
                    ?? snapshot?.brief.latestAssistant
                    ?? base?.focus
                    ?? (snapshot?.state.label ?? "No observed activity"),
                projectKey: projectKey,
                projectName: projectKey.map(BoardGrouping.projectName(forPath:)) ?? "Scratch",
                memberCount: max(1, links),
                subagents: subagents,
                turnCount: snapshot?.turnCount ?? base?.turnCount ?? 0,
                toolCount: snapshot?.toolCallCount ?? base?.toolCount ?? 0,
                lastEventAt: snapshot?.lastEventAt ?? base?.lastEventAt,
                position: placement.point,
                zIndex: placement.zIndex,
                isImplicit: node.taskID == nil
            )
        }.sorted { $0.zIndex < $1.zIndex }
    }

    private func loadViewport() {
        guard let repository else { return }
        let boardID = selectedBoardID
        Task { [weak self] in
            let stored = await Task.detached(priority: .utility) {
                try? repository.viewport(boardID: boardID)
            }.value
            guard let self, selectedBoardID == boardID, let stored else { return }
            hasStoredViewport = true
            viewport = stored
        }
    }

    private func scheduleSync() {
        guard let repository else { return }
        liveAdoptTask?.cancel()
        liveAdoptTask = nil
        pendingLiveSeeds = nil
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
                Result {
                    (
                        snapshot: try repository.synchronize(
                            boardID: boardID,
                            descriptors: descriptors
                        ),
                        mirrors: try repository.visibleBoardsByNode()
                    )
                }
            }.value
            guard !Task.isCancelled, let self, generation == request else { return }
            isLoading = false
            syncTask = nil
            switch result {
            case .success(let value):
                let names = Dictionary(uniqueKeysWithValues: boards.map { ($0.id, $0.name) })
                mirrorNamesByNode = value.mirrors.mapValues { ids in ids.compactMap { names[$0] } }
                synchronizedBoardID = boardID
                synchronizedDescriptors = descriptors.sorted { $0.sourceID < $1.sourceID }
                adopt(value.snapshot, seeds: seeds)
            case .failure(let error):
                errorDescription = error.localizedDescription
            }
        }
    }

    /// Coalesce transcript bursts into at most four Map publications per
    /// second. The live board can fold much faster than a person can read;
    /// recreating several NSHostingView roots for every token/tool event is
    /// what turns a burst into visible stalls. 250 ms stays inside the 0.5 s
    /// freshness budget while guaranteeing progress under a continuous stream
    /// (a throttle, not a debounce).
    private func scheduleLiveAdopt(_ seeds: [Seed]) {
        pendingLiveSeeds = seeds
        guard liveAdoptTask == nil else { return }
        liveAdoptTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled, let self else { return }
            let latest = pendingLiveSeeds
            pendingLiveSeeds = nil
            liveAdoptTask = nil
            if let latest { adoptLiveSeeds(latest) }
        }
    }

    private func adopt(_ snapshot: MapWorkspaceSnapshot, seeds: [Seed]) {
        synchronizedBySource = Dictionary(
            uniqueKeysWithValues: snapshot.nodes.map { ($0.sourceID, $0) }
        )
        adoptLiveSeeds(seeds)
    }

    /// Most live events only change the words and state painted on a card.
    /// Re-running the workspace transaction for those events needlessly
    /// upserts every node and membership. Keep the durable bindings and
    /// placements, then derive the flat card values on the main actor.
    private func adoptLiveSeeds(_ seeds: [Seed]) {
        var nextCards: [MapCardValue] = seeds.compactMap { seed -> MapCardValue? in
            guard let item = synchronizedBySource[seed.descriptor.sourceID] else { return nil }
            guard item.membership.isVisible else { return nil }
            guard let placement = item.placement else { return nil }
            return seed.card(nodeID: item.node.id, placement: placement)
        }
        let present = Set(nextCards.map(\.id))
        if let preserved = preservedForkCardsByBoard[selectedBoardID] {
            for item in synchronizedBySource.values
            where item.membership.isVisible && !present.contains(item.node.id) {
                guard let placement = item.placement, let card = preserved[item.node.id] else {
                    continue
                }
                nextCards.append(card.placed(nodeID: item.node.id, placement: placement))
            }
        }
        nextCards.sort { $0.zIndex < $1.zIndex }
        liveCards = nextCards
        if !isHistory {
            if cards != nextCards {
                cards = nextCards
                deriveChrome()
            }
            if !hasStoredViewport, let first = projectFrames.first {
                hasStoredViewport = true
                saveViewport(center: CGPoint(x: first.rect.midX, y: first.rect.midY), zoom: 1)
            }
        }
    }

    private func requiresWorkspaceSync(_ descriptors: [MapNodeDescriptor]) -> Bool {
        guard synchronizedBoardID == selectedBoardID else { return true }
        let current = descriptors.sorted { $0.sourceID < $1.sourceID }
        guard current.count == synchronizedDescriptors.count else { return true }

        // Custom-board membership can depend on every rule-facing field.
        // All boards only need durable identity and project binding; status,
        // attention, labels and activity are painted from the current Seed.
        if selectedBoardID != MapBoard.allID {
            return current != synchronizedDescriptors
        }
        return zip(current, synchronizedDescriptors).contains { current, previous in
            current.sourceID != previous.sourceID
                || current.taskID != previous.taskID
                || current.rootSessionKey != previous.rootSessionKey
                || current.projectKey != previous.projectKey
        }
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
        dependencies = cards.flatMap { card -> [MapDependencyValue] in
            card.dependencyIDs.compactMap { dependencyID in
                guard let target = nodeByTask[dependencyID] else { return nil }
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
        let taskVersion: Int64?
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
        let subagents: [MapSubagentValue]
        let turnCount: Int
        let toolCount: Int
        let lastEventAt: Date?
        let isImplicit: Bool

        func card(nodeID: String, placement: MapPlacement) -> MapCardValue {
            MapCardValue(
                id: nodeID,
                unitID: unitID,
                taskID: taskID,
                taskVersion: taskVersion,
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
                subagents: subagents,
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
            taskVersion: unit.version,
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
            subagents: unit.subagents.map {
                MapSubagentValue(
                    key: $0.key,
                    title: $0.title,
                    shortID: $0.shortID,
                    harness: $0.harness,
                    state: $0.state
                )
            },
            turnCount: unit.lead.turnCount,
            toolCount: unit.lead.toolCallCount,
            lastEventAt: unit.lastEventAt,
            isImplicit: unit.origin.isImplicit
        )
    }
}
