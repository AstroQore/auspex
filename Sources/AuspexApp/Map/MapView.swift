import AgentSessionLive
import AuspexCore
import SwiftUI

struct MapView: View {
    @Bindable var board: LiveBoardModel
    @Bindable var map: MapModel

    @State private var commands = MapCanvasCommands()
    @State private var createsBoard = false
    @State private var editsBoard = false
    @State private var showsMerge = false
    @Environment(AppEnvironment.self) private var environment

    var body: some View {
        VStack(spacing: 0) {
            if let name = board.focusedProjectName {
                ProjectFilterBar(name: name, path: board.focusedProjectKey ?? "") {
                    board.focusedProjectKey = nil
                }
            }
            MapToolbar(
                map: map,
                selectedUnitID: board.selectedUnit?.id,
                onCreate: { createsBoard = true },
                onEdit: { editsBoard = true },
                onFork: { map.forkAtPlayhead() },
                onMerge: {
                    showsMerge = true
                    map.prepareMerge()
                },
                taskError: environment.tasks.writeErrorDescription
            )
            ZStack {
                MapCanvasRepresentable(
                    cards: visibleCards,
                    frames: visibleFrames,
                    dependencies: visibleDependencies,
                    selectedNodeID: selectedNodeID,
                    expandedNodeIDs: map.expandedNodeIDs,
                    viewport: map.viewport,
                    isReadOnly: map.isHistory,
                    commands: commands,
                    onSelect: { board.selectedKey = $0 },
                    onOpenFlight: { key in
                        board.selectedKey = key
                        board.openTrajectory()
                    },
                    onEscape: { board.viewMode = .board },
                    onMove: { if !map.isHistory { map.move(nodeID: $0, to: $1) } },
                    onToggleExpanded: { map.toggleExpanded(nodeID: $0) },
                    onSetDependencies: { taskID, ids, version in
                        if !map.isHistory {
                            environment.tasks.setDependencies(
                                ids,
                                of: taskID,
                                expectedVersion: version
                            )
                        }
                    },
                    onViewport: { map.saveViewport(center: $0, zoom: $1) }
                )
                if map.cards.isEmpty { emptyState }
                controls
                minimap
            }
            MapPlaybackStrip(map: map, cards: visibleCards)
        }
        .background(AuspexPalette.canvas)
        .sheet(isPresented: $createsBoard) {
            MapBoardCreateSheet(map: map, isPresented: $createsBoard)
                .auspexNoInitialFocus()
        }
        .sheet(isPresented: $editsBoard) {
            if let selected = map.selectedBoard, !selected.isProtected {
                MapBoardEditorSheet(map: map, board: selected, isPresented: $editsBoard)
                    .auspexNoInitialFocus()
            }
        }
        .sheet(isPresented: $showsMerge, onDismiss: { map.cancelMerge() }) {
            MapMergeSheet(map: map, isPresented: $showsMerge)
                .auspexNoInitialFocus()
        }
        .onDisappear { map.pausePlayback() }
    }

    private var visibleCards: [MapCardValue] {
        guard let key = board.focusedProjectKey else { return map.cards }
        return map.cards.filter { $0.projectKey == key }
    }

    private var visibleIDs: Set<String> { Set(visibleCards.map(\.id)) }

    private var visibleFrames: [MapProjectFrame] {
        map.projectFrames.filter { frame in
            board.focusedProjectKey == nil || frame.id == board.focusedProjectKey
        }
    }

    private var visibleDependencies: [MapDependencyValue] {
        let ids = visibleIDs
        return map.dependencies.filter { ids.contains($0.fromNodeID) && ids.contains($0.toNodeID) }
    }

    private var selectedNodeID: String? {
        guard let key = board.selectedKey else { return nil }
        return map.cards.first { $0.leadKey == key }?.id
    }

    private var controls: some View {
        VStack(spacing: 6) {
            mapControl("Fit all", symbol: "arrow.up.left.and.arrow.down.right") { commands.fit() }
                .keyboardShortcut("0", modifiers: .command)
            mapControl("Zoom in", symbol: "plus") { commands.zoomIn() }
                .keyboardShortcut("=", modifiers: .command)
            Menu {
                ForEach([0.25, 0.5, 0.75, 1, 1.5, 2, 4], id: \.self) { zoom in
                    Button("\(Int(zoom * 100))%") { commands.setZoom(zoom) }
                }
            } label: {
                Text("\(Int((map.viewport.zoom * 100).rounded()))%")
                    .font(AuspexType.monoSmall)
                    .frame(width: 38, height: 20)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            mapControl("Zoom out", symbol: "minus") { commands.zoomOut() }
                .keyboardShortcut("-", modifiers: .command)
        }
        .padding(4)
        .panelChrome(cornerRadius: 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        .padding(12)
    }

    private func mapControl(
        _ label: String,
        symbol: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .semibold))
                .frame(width: 24, height: 20)
        }
        .buttonStyle(.auspex)
        .help(label)
        .accessibilityLabel(label)
    }

    private var minimap: some View {
        MapMinimap(cards: visibleCards, frames: visibleFrames, viewport: map.viewport) {
            commands.center($0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        .padding(12)
    }

    private var emptyState: some View {
        EmptyStateView(
            symbol: BoardViewMode.perch.systemImage,
            title: map.isLoading ? "Placing the map…" : "This board is empty",
            detail: map.selectedBoard?.isProtected == true
                ? "A card appears for every piece of work Auspex can see."
                : "Pin a task here, or add a rule that matches one."
        )
        .centredInPane()
        .allowsHitTesting(false)
    }
}

private struct MapToolbar: View {
    @Bindable var map: MapModel
    let selectedUnitID: String?
    let onCreate: () -> Void
    let onEdit: () -> Void
    let onFork: () -> Void
    let onMerge: () -> Void
    let taskError: String?

    var body: some View {
        HStack(spacing: 10) {
            Menu {
                ForEach(map.boards) { board in
                    Button {
                        map.selectedBoardID = board.id
                    } label: {
                        if board.id == map.selectedBoardID {
                            Label(board.name, systemImage: "checkmark")
                        } else {
                            Text(board.name)
                        }
                    }
                }
                if !map.isHistory, !map.deletedBoards.isEmpty {
                    Divider()
                    Menu("Recently deleted") {
                        ForEach(map.deletedBoards) { board in
                            Button("Restore \(board.name)") { map.restoreBoard(board.id) }
                        }
                    }
                }
                if !map.isHistory {
                    Divider()
                    Button("New board…", systemImage: "plus", action: onCreate)
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "square.on.square")
                        .font(.system(size: 10, weight: .semibold))
                    Text(map.selectedBoard?.name ?? "All boards")
                        .font(AuspexType.pill)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .bold))
                }
                .foregroundStyle(AuspexPalette.text2)
                .padding(.horizontal, 9)
                .frame(height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(AuspexPalette.bg1)
                        .overlay(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .strokeBorder(AuspexPalette.line, lineWidth: 1)
                        )
                )
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)

            if map.isHistory {
                Button(action: onFork) {
                    Label("Fork board here", systemImage: "arrow.triangle.branch")
                        .font(AuspexType.caption)
                }
                .buttonStyle(.auspex)
            } else if let board = map.selectedBoard, !board.isProtected {
                if map.canMergeSelectedBoard {
                    Button(action: onMerge) {
                        Label("Merge to parent", systemImage: "arrow.triangle.merge")
                            .font(AuspexType.caption)
                    }
                    .buttonStyle(.auspex)
                }
                if let selectedUnitID {
                    Button {
                        if let node = map.cards.first(where: { $0.unitID == selectedUnitID }) {
                            map.exclude(nodeID: node.id)
                        } else {
                            map.include(unitID: selectedUnitID)
                        }
                    } label: {
                        Label(
                            map.contains(unitID: selectedUnitID) ? "Remove" : "Pin selected",
                            systemImage: map.contains(unitID: selectedUnitID) ? "minus" : "pin"
                        )
                        .font(AuspexType.caption)
                    }
                    .buttonStyle(.auspex)
                }
                Button(action: onEdit) {
                    Label("Board rules", systemImage: "line.3.horizontal.decrease.circle")
                        .font(AuspexType.caption)
                }
                .buttonStyle(.auspex)
                if board.rule != nil {
                    Button {
                        map.setRulesPaused(!board.rulesPaused)
                    } label: {
                        Label(
                            board.rulesPaused ? "Resume rules" : "Pause rules",
                            systemImage: board.rulesPaused ? "play.fill" : "pause.fill"
                        )
                        .font(AuspexType.caption)
                        .foregroundStyle(
                            board.rulesPaused ? AuspexPalette.stateStale : AuspexPalette.text2
                        )
                    }
                    .buttonStyle(.auspex)
                }
            }

            Spacer(minLength: 0)
            Text("\(map.cards.count) cards")
                .font(AuspexType.monoSmall)
                .foregroundStyle(AuspexPalette.text3)
            if let error = map.errorDescription {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(AuspexPalette.statePermission)
                    .help(error)
                    .accessibilityLabel(error)
            } else if let taskError {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(AuspexPalette.statePermission)
                    .help(taskError)
                    .accessibilityLabel(taskError)
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 36)
        .background(AuspexPalette.bg0)
        .overlay(alignment: .bottom) {
            Rectangle().fill(AuspexPalette.line).frame(height: 1)
        }
    }
}

private struct MapMergeSheet: View {
    @Bindable var map: MapModel
    @Binding var isPresented: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Merge Perch branch").font(AuspexType.paneTitle)
            Text(
                "Only positions, membership overrides, and the rule tree are merged. Tasks, dependencies, agents, board names, and cameras are untouched."
            )
            .font(AuspexType.body)
            .foregroundStyle(AuspexPalette.text2)
            .fixedSize(horizontal: false, vertical: true)

            if map.isPreparingMerge {
                ProgressView("Comparing the fork base, parent, and branch…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let plan = map.mergePlan {
                HStack(spacing: 14) {
                    MetaField(
                        key: "automatic memberships", value: "\(plan.automaticMemberships.count)")
                    MetaField(
                        key: "automatic positions", value: "\(plan.automaticPlacements.count)")
                    MetaField(key: "conflicts", value: "\(plan.conflicts.count)")
                }
                if plan.conflicts.isEmpty {
                    EmptyStateView(
                        symbol: "arrow.triangle.merge",
                        title: "No conflicts",
                        detail: "The branch can be merged without replacing later parent edits."
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 8) {
                            ForEach(plan.conflicts) { conflict in
                                conflictRow(conflict)
                            }
                        }
                    }
                    .frame(minHeight: 240, maxHeight: 420)
                }
            } else {
                EmptyStateView(title: "The merge comparison could not be prepared.")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            HStack {
                Button("Cancel", role: .cancel) { isPresented = false }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Merge") {
                    map.applyMerge()
                    isPresented = false
                }
                .disabled(!canApply)
            }
        }
        .padding(20)
        .frame(width: 620)
        .frame(minHeight: 440)
    }

    private var canApply: Bool {
        guard let plan = map.mergePlan else { return false }
        return plan.conflicts.allSatisfy { map.mergeChoices[$0.id] != nil }
    }

    private func conflictRow(_ conflict: MapMergeConflict) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(conflict.field.rawValue.uppercased())
                    .auspexLabel(AuspexType.labelSmall)
                    .foregroundStyle(AuspexPalette.stateStale)
                if let nodeID = conflict.nodeID {
                    Text(String(nodeID.prefix(8)))
                        .font(AuspexType.monoSmall)
                        .foregroundStyle(AuspexPalette.text3)
                }
                Spacer()
                Picker(
                    "Resolution",
                    selection: Binding(
                        get: { map.mergeChoices[conflict.id] },
                        set: { if let value = $0 { map.choose(value, for: conflict.id) } }
                    )
                ) {
                    Text("Choose…").tag(MapMergeChoice?.none)
                    Text("Keep parent").tag(MapMergeChoice?.some(.parent))
                    Text("Take branch").tag(MapMergeChoice?.some(.branch))
                }
                .labelsHidden()
                .frame(width: 130)
                .auspexSystemControlFocus()
            }
            HStack(spacing: 8) {
                comparison("Parent", conflict.parentSummary)
                comparison("Branch", conflict.branchSummary)
            }
        }
        .padding(10)
        .background(AuspexPalette.bg2)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func comparison(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label.uppercased()).auspexLabel(AuspexType.labelSmall)
            Text(value).font(AuspexType.caption).foregroundStyle(AuspexPalette.text2)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AuspexPalette.bg1)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

private struct MapPlaybackStrip: View {
    @Bindable var map: MapModel
    let cards: [MapCardValue]

    var body: some View {
        HStack(spacing: 10) {
            Button {
                map.togglePlayback()
            } label: {
                Image(systemName: map.isHistory && !map.isPlaying ? "play.fill" : "pause.fill")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(AuspexPalette.text2)
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(AuspexPalette.bg1))
            }
            .buttonStyle(.auspex)
            .accessibilityLabel(map.isPlaying ? "Pause playback" : "Play history")
            Menu {
                ForEach(PlaybackSpeed.allCases, id: \.self) { speed in
                    Button(speed.label) { map.setPlaybackSpeed(speed) }
                }
            } label: {
                Text(map.playbackSpeed.label)
                    .font(AuspexType.monoSmall)
                    .foregroundStyle(AuspexPalette.text2)
                    .frame(width: 28, height: 22)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            HStack(spacing: 5) {
                StateDot(
                    color: map.isHistory ? AuspexPalette.stateStale : AuspexPalette.stateWriting,
                    glows: !map.isHistory
                )
                Text(map.isHistory ? "History" : "Live")
                    .font(AuspexType.pill)
                    .foregroundStyle(map.isHistory ? AuspexPalette.stateStale : AuspexPalette.text)
                if map.isHistoryLoading {
                    Text("indexing…").font(AuspexType.caption).foregroundStyle(AuspexPalette.text3)
                } else if map.isHistory {
                    Text("event \(map.historyIndex + 1) / \(map.historyCount)")
                        .font(AuspexType.monoSmall)
                        .foregroundStyle(AuspexPalette.text3)
                } else {
                    Text("following").font(AuspexType.caption).foregroundStyle(AuspexPalette.text3)
                }
            }
            if map.historyCount > 1 {
                Slider(
                    value: Binding(
                        get: { Double(map.historyIndex) },
                        set: { map.seek(to: Int($0.rounded())) }
                    ),
                    in: 0...Double(map.historyCount - 1),
                    step: 1
                )
                .tint(AuspexPalette.accent)
                .auspexSystemControlFocus()
                .accessibilityLabel("Perch history playhead")
                .accessibilityValue("Event \(map.historyIndex + 1) of \(map.historyCount)")
            } else {
                GeometryReader { geometry in
                    Canvas { context, size in
                        let sorted = cards.compactMap(\.lastEventAt).sorted()
                        guard let first = sorted.first, let last = sorted.last else { return }
                        let span = max(1, last.timeIntervalSince(first))
                        for (index, date) in sorted.enumerated() {
                            let fraction =
                                sorted.count == 1
                                ? 1
                                : date.timeIntervalSince(first) / span
                            let height = CGFloat(5 + (index % 4) * 3)
                            let rect = CGRect(
                                x: fraction * max(0, size.width - 2),
                                y: size.height - height,
                                width: 2,
                                height: height
                            )
                            context.fill(
                                Path(rect),
                                with: .color(AuspexPalette.stateTool.opacity(0.65))
                            )
                        }
                    }
                    .frame(width: geometry.size.width, height: 28)
                }
                .frame(height: 28)
            }
            Text(
                map.playbackMoment.map { Self.time($0.event.timestamp) }
                    ?? cards.compactMap(\.lastEventAt).max().map(Self.time) ?? "—"
            )
            .font(AuspexType.monoSmall)
            .foregroundStyle(AuspexPalette.text2)
            if map.isHistory {
                Text("\(map.eventsAhead) ahead")
                    .font(AuspexType.monoSmall)
                    .foregroundStyle(AuspexPalette.text3)
                Button("Jump to Live") { map.jumpToLive() }
                    .font(AuspexType.pill)
                    .buttonStyle(.auspex(cornerRadius: 7))
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 48)
        .background(AuspexPalette.bg0)
        .overlay(alignment: .top) {
            Rectangle().fill(AuspexPalette.line).frame(height: 1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Live activity overview")
    }

    private static func time(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .standard)
    }
}

private struct MapMinimap: View {
    let cards: [MapCardValue]
    let frames: [MapProjectFrame]
    let viewport: MapViewport
    let onCenter: (CGPoint) -> Void

    private let size = CGSize(width: 156, height: 104)

    var body: some View {
        if let world = worldBounds {
            Canvas { context, canvas in
                let scale = min(canvas.width / world.width, canvas.height / world.height)
                func point(_ worldPoint: CGPoint) -> CGPoint {
                    CGPoint(
                        x: (worldPoint.x - world.minX) * scale,
                        y: (worldPoint.y - world.minY) * scale
                    )
                }
                for frame in frames {
                    let origin = point(frame.rect.origin)
                    let rect = CGRect(
                        origin: origin,
                        size: CGSize(
                            width: frame.rect.width * scale, height: frame.rect.height * scale)
                    )
                    context.stroke(
                        Path(roundedRect: rect, cornerRadius: 2),
                        with: .color(AuspexPalette.line2),
                        style: StrokeStyle(lineWidth: 1, dash: [2, 2])
                    )
                }
                for card in cards {
                    let origin = point(card.position)
                    context.fill(
                        Path(CGRect(x: origin.x, y: origin.y, width: 5, height: 3)),
                        with: .color(card.harness.style.accent.opacity(0.8))
                    )
                }
                let center = point(CGPoint(x: viewport.centerX, y: viewport.centerY))
                context.stroke(
                    Path(CGRect(x: center.x - 8, y: center.y - 5, width: 16, height: 10)),
                    with: .color(AuspexPalette.text),
                    lineWidth: 1
                )
            }
            .frame(width: size.width, height: size.height)
            .padding(4)
            .panelChrome(cornerRadius: 7)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0).onChanged { value in
                    let scale = min(size.width / world.width, size.height / world.height)
                    onCenter(
                        CGPoint(
                            x: world.minX + value.location.x / scale,
                            y: world.minY + value.location.y / scale
                        ))
                }
            )
            .help("The whole board. Click or drag to move the camera.")
            .accessibilityHidden(true)
        }
    }

    private var worldBounds: CGRect? {
        guard let first = cards.first else { return nil }
        var rect = CGRect(origin: first.position, size: MapPlacement.cardSize)
        for card in cards.dropFirst() {
            rect = rect.union(CGRect(origin: card.position, size: MapPlacement.cardSize))
        }
        return rect.insetBy(dx: -120, dy: -120)
    }
}

private struct MapBoardCreateSheet: View {
    @Bindable var map: MapModel
    @Binding var isPresented: Bool
    @State private var name = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New Perch board").font(AuspexType.paneTitle)
            TextField("Board name", text: $name)
                .textFieldStyle(.roundedBorder)
                .auspexSystemControlFocus()
            Text("This board starts manual. Add nested rules from Board rules after it is created.")
                .font(AuspexType.body)
                .foregroundStyle(AuspexPalette.text2)
            HStack {
                Spacer()
                Button("Cancel") { isPresented = false }
                Button("Create") {
                    map.createBoard(name: name)
                    isPresented = false
                }
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}

private struct MapBoardEditorSheet: View {
    @Bindable var map: MapModel
    let board: MapBoard
    @Binding var isPresented: Bool
    @State private var name: String
    @State private var confirmsDelete = false

    init(map: MapModel, board: MapBoard, isPresented: Binding<Bool>) {
        self.map = map
        self.board = board
        self._isPresented = isPresented
        self._name = State(initialValue: board.name)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Board rules").font(AuspexType.paneTitle)
            TextField("Board name", text: $name)
                .textFieldStyle(.roundedBorder)
                .auspexSystemControlFocus()
            MapRuleEditor(
                rule: Binding(
                    get: { map.selectedBoard?.rule },
                    set: { map.setRule($0) }
                ))
            Divider()
            HStack {
                Button {
                    map.moveSelectedBoard(by: -1)
                } label: {
                    Label("Move earlier", systemImage: "arrow.up")
                }
                .disabled(!map.canMoveSelectedBoardUp)
                Button {
                    map.moveSelectedBoard(by: 1)
                } label: {
                    Label("Move later", systemImage: "arrow.down")
                }
                .disabled(!map.canMoveSelectedBoardDown)
                Divider().frame(height: 18)
                if confirmsDelete {
                    Text("Delete this board?")
                        .font(AuspexType.caption)
                        .foregroundStyle(AuspexPalette.statePermission)
                    Button("Cancel", role: .cancel) { confirmsDelete = false }
                        .keyboardShortcut(.cancelAction)
                    Button("Delete", role: .destructive) {
                        map.deleteSelectedBoard()
                        isPresented = false
                    }
                } else {
                    Button("Delete board", role: .destructive) { confirmsDelete = true }
                }
                Spacer()
                Button("Done") {
                    if name != board.name { map.renameSelectedBoard(name) }
                    isPresented = false
                }
            }
        }
        .padding(20)
        .frame(width: 560)
        .frame(minHeight: 440)
    }
}
