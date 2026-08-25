import AppKit
import AgentSessionKit
import AgentSessionLive
import AuspexCore
import SwiftUI

@MainActor
final class MapCanvasCommands {
    var fit: () -> Void = {}
    var zoomIn: () -> Void = {}
    var zoomOut: () -> Void = {}
    var setZoom: (CGFloat) -> Void = { _ in }
    var center: (CGPoint) -> Void = { _ in }
}

struct MapCanvasRepresentable: NSViewRepresentable {
    let cards: [MapCardValue]
    let frames: [MapProjectFrame]
    let dependencies: [MapDependencyValue]
    let selectedNodeID: String?
    let expandedNodeIDs: Set<String>
    let viewport: MapViewport
    let isReadOnly: Bool
    let commands: MapCanvasCommands
    let onSelect: (SessionKey) -> Void
    let onOpenFlight: (SessionKey) -> Void
    let onEscape: () -> Void
    let onMove: (String, CGPoint) -> Void
    let onToggleExpanded: (String) -> Void
    let onSetDependencies: (Int64, [Int64], Int64?) -> Void
    let onViewport: (CGPoint, CGFloat) -> Void

    func makeNSView(context: Context) -> MapCanvasNSView {
        let view = MapCanvasNSView(frame: .zero)
        view.onSelect = onSelect
        view.onOpenFlight = onOpenFlight
        view.onEscape = onEscape
        view.onMove = onMove
        view.onToggleExpanded = onToggleExpanded
        view.onSetDependencies = onSetDependencies
        view.onViewport = onViewport
        wire(commands, to: view)
        return view
    }

    func updateNSView(_ view: MapCanvasNSView, context: Context) {
        view.onSelect = onSelect
        view.onOpenFlight = onOpenFlight
        view.onEscape = onEscape
        view.onMove = onMove
        view.onToggleExpanded = onToggleExpanded
        view.onSetDependencies = onSetDependencies
        view.onViewport = onViewport
        view.update(
            cards: cards,
            frames: frames,
            dependencies: dependencies,
            selectedNodeID: selectedNodeID,
            expandedNodeIDs: expandedNodeIDs,
            isReadOnly: isReadOnly,
            viewport: viewport
        )
        wire(commands, to: view)
    }

    static func dismantleNSView(_ view: MapCanvasNSView, coordinator: ()) {
        view.stop()
    }

    private func wire(_ commands: MapCanvasCommands, to view: MapCanvasNSView) {
        commands.fit = { [weak view] in view?.fitAll() }
        commands.zoomIn = { [weak view] in view?.stepZoom(1) }
        commands.zoomOut = { [weak view] in view?.stepZoom(-1) }
        commands.setZoom = { [weak view] in view?.setZoom($0) }
        commands.center = { [weak view] in view?.center(on: $0) }
    }
}

/// A native scroll surface whose document owns only the card views near the
/// viewport. The backdrop is one AppKit draw pass; cards retain SwiftUI's
/// accessibility and focus semantics without keeping hundreds of hosting
/// views alive offscreen.
@MainActor
final class MapCanvasNSView: NSView {
    /// Enough breathing room to pan past the first card without making a new
    /// board open in the lower-right quadrant of an otherwise empty window.
    static let worldInset: CGFloat = 120
    static let minimumWorld = CGSize(width: 6_000, height: 4_000)
    static let prefetch: CGFloat = 420

    let scrollView = MapScrollView()
    let document = MapDocumentView()

    var onSelect: (SessionKey) -> Void = { _ in }
    var onOpenFlight: (SessionKey) -> Void = { _ in }
    var onEscape: () -> Void = {}
    var onMove: (String, CGPoint) -> Void = { _, _ in }
    var onToggleExpanded: (String) -> Void = { _ in }
    var onSetDependencies: (Int64, [Int64], Int64?) -> Void = { _, _, _ in }
    var onViewport: (CGPoint, CGFloat) -> Void = { _, _ in }

    private var boundsObserver: NSObjectProtocol?
    private var magnifyObserver: NSObjectProtocol?
    private var lastBoardID: String?
    private var lastViewportStamp: Date?
    private var isReadOnly = false
    private var isApplyingViewport = false
    private var keyboardCards: [MapCardValue] = []
    private var keyboardSelectedNodeID: String?
    private(set) var viewportApplyCount = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        autoresizingMask = [.width, .height]
        scrollView.frame = bounds
        scrollView.autoresizingMask = [.width, .height]
        scrollView.documentView = document
        scrollView.drawsBackground = false
        scrollView.contentView.drawsBackground = false
        scrollView.allowsMagnification = true
        scrollView.minMagnification = 0.25
        scrollView.maxMagnification = 4
        scrollView.usesPredominantAxisScrolling = false
        scrollView.horizontalScrollElasticity = .allowed
        scrollView.verticalScrollElasticity = .allowed
        scrollView.hasHorizontalScroller = true
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.focusRingType = .none
        scrollView.contentView.postsBoundsChangedNotifications = true
        scrollView.canvas = self
        document.canvas = self
        addSubview(scrollView)

        boundsObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: scrollView.contentView,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.viewportMoved() }
        }
        magnifyObserver = NotificationCenter.default.addObserver(
            forName: NSScrollView.didEndLiveMagnifyNotification,
            object: scrollView,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.document.refreshVisibleCards(force: true)
                self?.viewportMoved()
            }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("MapCanvasNSView is not archived") }

    func update(
        cards: [MapCardValue],
        frames: [MapProjectFrame],
        dependencies: [MapDependencyValue],
        selectedNodeID: String?,
        expandedNodeIDs: Set<String>,
        isReadOnly: Bool,
        viewport: MapViewport
    ) {
        self.isReadOnly = isReadOnly
        keyboardCards = cards
        keyboardSelectedNodeID = selectedNodeID
        resizeWorld(for: cards)
        document.update(
            cards: cards,
            frames: frames,
            dependencies: dependencies,
            selectedNodeID: selectedNodeID,
            expandedNodeIDs: expandedNodeIDs,
            isReadOnly: isReadOnly,
            zoom: scrollView.magnification
        )
        if lastBoardID != viewport.boardID || lastViewportStamp != viewport.updatedAt {
            lastBoardID = viewport.boardID
            lastViewportStamp = viewport.updatedAt
            apply(viewport)
        }
    }

    func stop() {
        document.stop()
        if let boundsObserver {
            NotificationCenter.default.removeObserver(boundsObserver)
            self.boundsObserver = nil
        }
        if let magnifyObserver {
            NotificationCenter.default.removeObserver(magnifyObserver)
            self.magnifyObserver = nil
        }
    }

    func fitAll() {
        guard let rect = document.cardsBounds else { return }
        let padded = rect.insetBy(dx: -100, dy: -100)
        scrollView.magnify(toFit: padded)
        document.refreshVisibleCards(force: true)
        viewportMoved()
    }

    func stepZoom(_ direction: Int) {
        let next = SceneViewport.rung(direction, from: scrollView.magnification)
        setZoom(next)
    }

    func setZoom(_ zoom: CGFloat) {
        let center = scrollView.documentVisibleRect.center
        scrollView.setMagnification(min(4, max(0.25, zoom)), centeredAt: center)
        document.refreshVisibleCards(force: true)
        viewportMoved()
    }

    func center(on worldPoint: CGPoint) {
        let point = documentPoint(worldPoint)
        let visible = scrollView.documentVisibleRect
        scrollView.contentView.setBoundsOrigin(
            CGPoint(x: point.x - visible.width / 2, y: point.y - visible.height / 2)
        )
        scrollView.reflectScrolledClipView(scrollView.contentView)
        viewportMoved()
    }

    func selectForKeyboard() {
        guard keyboardSelectedNodeID == nil,
            let first = keyboardCards.sorted(by: Self.readingOrder).first
        else { return }
        keyboardSelectedNodeID = first.id
        onSelect(first.leadKey)
    }

    func moveKeyboardSelection(horizontal: Int, vertical: Int) {
        guard !keyboardCards.isEmpty else { return }
        guard let currentID = keyboardSelectedNodeID,
            let current = keyboardCards.first(where: { $0.id == currentID })
        else {
            selectForKeyboard()
            return
        }
        let origin = CGPoint(
            x: current.position.x + MapPlacement.cardSize.width / 2,
            y: current.position.y + MapPlacement.cardSize.height / 2
        )
        let candidates = keyboardCards.filter { card in
            guard card.id != current.id else { return false }
            let dx = card.position.x + MapPlacement.cardSize.width / 2 - origin.x
            let dy = card.position.y + MapPlacement.cardSize.height / 2 - origin.y
            if horizontal < 0 { return dx < 0 }
            if horizontal > 0 { return dx > 0 }
            if vertical < 0 { return dy < 0 }
            return dy > 0
        }
        let next = candidates.min { lhs, rhs in
            Self.navigationScore(lhs, from: origin, horizontal: horizontal)
                < Self.navigationScore(rhs, from: origin, horizontal: horizontal)
        }
        guard let next else { return }
        keyboardSelectedNodeID = next.id
        onSelect(next.leadKey)
        center(on: CGPoint(
            x: next.position.x + MapPlacement.cardSize.width / 2,
            y: next.position.y + MapPlacement.cardSize.height / 2
        ))
    }

    func openKeyboardSelection() {
        guard let id = keyboardSelectedNodeID,
            let card = keyboardCards.first(where: { $0.id == id })
        else { return }
        onOpenFlight(card.leadKey)
    }

    func confirmKeyboardSelection() {
        guard let id = keyboardSelectedNodeID,
            let card = keyboardCards.first(where: { $0.id == id })
        else { return }
        onSelect(card.leadKey)
    }

    private static func readingOrder(_ lhs: MapCardValue, _ rhs: MapCardValue) -> Bool {
        if lhs.position.y != rhs.position.y { return lhs.position.y < rhs.position.y }
        if lhs.position.x != rhs.position.x { return lhs.position.x < rhs.position.x }
        return lhs.id < rhs.id
    }

    private static func navigationScore(
        _ card: MapCardValue,
        from origin: CGPoint,
        horizontal: Int
    ) -> CGFloat {
        let dx = abs(card.position.x + MapPlacement.cardSize.width / 2 - origin.x)
        let dy = abs(card.position.y + MapPlacement.cardSize.height / 2 - origin.y)
        return horizontal == 0 ? dy * 2 + dx : dx * 2 + dy
    }

    func worldPoint(_ documentPoint: CGPoint) -> CGPoint {
        CGPoint(
            x: max(0, documentPoint.x - Self.worldInset),
            y: max(0, documentPoint.y - Self.worldInset)
        )
    }

    func documentPoint(_ worldPoint: CGPoint) -> CGPoint {
        CGPoint(x: worldPoint.x + Self.worldInset, y: worldPoint.y + Self.worldInset)
    }

    private func resizeWorld(for cards: [MapCardValue]) {
        let maxX = cards.map { $0.position.x + MapPlacement.cardSize.width }.max() ?? 0
        let maxY = cards.map { $0.position.y + MapPlacement.cardSize.height }.max() ?? 0
        let size = CGSize(
            width: max(Self.minimumWorld.width, maxX + Self.worldInset * 2),
            height: max(Self.minimumWorld.height, maxY + Self.worldInset * 2)
        )
        guard document.frame.size != size else { return }
        document.frame = CGRect(origin: .zero, size: size)
    }

    private func apply(_ viewport: MapViewport) {
        guard bounds.width > 0, bounds.height > 0 else { return }
        viewportApplyCount += 1
        isApplyingViewport = true
        let zoom = min(4, max(0.25, CGFloat(viewport.zoom)))
        scrollView.magnification = zoom
        let center = documentPoint(CGPoint(x: viewport.centerX, y: viewport.centerY))
        let visible = scrollView.documentVisibleRect
        scrollView.contentView.setBoundsOrigin(
            CGPoint(x: center.x - visible.width / 2, y: center.y - visible.height / 2)
        )
        scrollView.reflectScrolledClipView(scrollView.contentView)
        isApplyingViewport = false
        document.refreshVisibleCards(force: true)
    }

    private func viewportMoved() {
        document.refreshVisibleCards(force: false)
        guard !isApplyingViewport else { return }
        let visible = scrollView.documentVisibleRect
        onViewport(worldPoint(visible.center), scrollView.magnification)
    }
}

final class MapScrollView: NSScrollView {
    weak var canvas: MapCanvasNSView?

    override var acceptsFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool {
        canvas?.selectForKeyboard()
        return true
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        super.mouseDown(with: event)
    }

    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if modifiers.contains(.command), event.charactersIgnoringModifiers?.lowercased() == "t" {
            canvas?.openKeyboardSelection()
            return
        }
        switch event.keyCode {
        case 36, 76:
            canvas?.confirmKeyboardSelection()
        case 53:
            canvas?.onEscape()
        case 123:
            canvas?.moveKeyboardSelection(horizontal: -1, vertical: 0)
        case 124:
            canvas?.moveKeyboardSelection(horizontal: 1, vertical: 0)
        case 125:
            canvas?.moveKeyboardSelection(horizontal: 0, vertical: 1)
        case 126:
            canvas?.moveKeyboardSelection(horizontal: 0, vertical: -1)
        default:
            super.keyDown(with: event)
        }
    }

    override func magnify(with event: NSEvent) {
        super.magnify(with: event)
        if event.phase.contains(.ended) || event.phase.contains(.cancelled) {
            canvas?.document.refreshVisibleCards(force: true)
        }
    }

    override func smartMagnify(with event: NSEvent) {
        canvas?.fitAll()
    }
}

@MainActor
final class MapDocumentView: NSView {
    weak var canvas: MapCanvasNSView?
    private var cards: [MapCardValue] = []
    private var byID: [String: MapCardValue] = [:]
    private var frames: [MapProjectFrame] = []
    private var dependencies: [MapDependencyValue] = []
    private var selectedNodeID: String?
    private var expandedNodeIDs: Set<String> = []
    private var isReadOnly = false
    private var zoom: CGFloat = 1
    private var hosts: [String: NSHostingView<MapCardSurface>] = [:]
    private var visibleIDs: Set<String> = []

    var hostedCardCount: Int { hosts.count }
    private(set) var hostedSurfaceUpdateCount = 0

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    var cardsBounds: CGRect? {
        guard let first = cards.first else { return nil }
        var rect = cardRect(first)
        for card in cards.dropFirst() { rect = rect.union(cardRect(card)) }
        return rect
    }

    func update(
        cards: [MapCardValue],
        frames: [MapProjectFrame],
        dependencies: [MapDependencyValue],
        selectedNodeID: String?,
        expandedNodeIDs: Set<String>,
        isReadOnly: Bool,
        zoom: CGFloat
    ) {
        let previousByID = byID
        let changedIDs = Set(cards.compactMap { card in
            previousByID[card.id] == card ? nil : card.id
        })
        let surfaceContextChanged = self.selectedNodeID != selectedNodeID
            || self.expandedNodeIDs != expandedNodeIDs
            || self.isReadOnly != isReadOnly
        let backdropCardsChanged = self.cards.count != cards.count
            || zip(self.cards, cards).contains { previous, current in
                previous.id != current.id
                    || previous.position != current.position
                    || previous.subagents != current.subagents
            }
        let backdropChanged = backdropCardsChanged || self.frames != frames
            || self.dependencies != dependencies || self.expandedNodeIDs != expandedNodeIDs
        self.cards = cards
        byID = Dictionary(uniqueKeysWithValues: cards.map { ($0.id, $0) })
        self.frames = frames
        self.dependencies = dependencies
        self.selectedNodeID = selectedNodeID
        self.expandedNodeIDs = expandedNodeIDs
        self.isReadOnly = isReadOnly
        self.zoom = zoom
        if backdropChanged { needsDisplay = true }
        refreshVisibleCards(force: surfaceContextChanged, changedIDs: changedIDs)
    }

    func stop() {
        for host in hosts.values { host.removeFromSuperview() }
        hosts.removeAll()
        visibleIDs.removeAll()
    }

    func refreshVisibleCards(force: Bool, changedIDs: Set<String> = []) {
        guard let canvas else { return }
        zoom = canvas.scrollView.magnification
        let visible = canvas.scrollView.documentVisibleRect.insetBy(
            dx: -MapCanvasNSView.prefetch,
            dy: -MapCanvasNSView.prefetch
        )
        let wanted = Set(cards.lazy.filter { self.cardRect($0).intersects(visible) }.map(\.id))
        guard force || wanted != visibleIDs || !wanted.isDisjoint(with: changedIDs) else { return }

        for id in visibleIDs.subtracting(wanted) {
            hosts.removeValue(forKey: id)?.removeFromSuperview()
        }
        for id in wanted {
            guard let card = byID[id] else { continue }
            if let host = hosts[id] {
                if force || changedIDs.contains(id) {
                    host.rootView = surface(card)
                    host.frame = cardRect(card)
                    hostedSurfaceUpdateCount += 1
                }
            } else {
                let host = NSHostingView(rootView: surface(card))
                host.frame = cardRect(card)
                addSubview(host)
                hosts[id] = host
                hostedSurfaceUpdateCount += 1
            }
        }
        visibleIDs = wanted
    }

    override func draw(_ dirtyRect: NSRect) {
        let appearance = effectiveAppearance
        AuspexPalette.resolve(AuspexPalette.bg0, for: appearance).setFill()
        dirtyRect.fill()
        drawGrid(dirtyRect, appearance: appearance)
        drawProjectFrames(appearance: appearance)
        drawDependencies(appearance: appearance)
        drawLineage(appearance: appearance)
    }

    private func drawGrid(_ dirty: CGRect, appearance: NSAppearance) {
        let color = AuspexPalette.resolve(AuspexPalette.grid, for: appearance)
        color.setFill()
        let pitch: CGFloat = 32
        let startX = floor(dirty.minX / pitch) * pitch
        let startY = floor(dirty.minY / pitch) * pitch
        var y = startY
        while y <= dirty.maxY {
            var x = startX
            while x <= dirty.maxX {
                NSBezierPath(ovalIn: CGRect(x: x, y: y, width: 1.5, height: 1.5)).fill()
                x += pitch
            }
            y += pitch
        }
    }

    private func drawProjectFrames(appearance: NSAppearance) {
        let line = AuspexPalette.resolve(AuspexPalette.line2, for: appearance)
        let text = AuspexPalette.resolve(AuspexPalette.text3, for: appearance)
        for frame in frames {
            let rect = frame.rect.offsetBy(
                dx: MapCanvasNSView.worldInset,
                dy: MapCanvasNSView.worldInset
            )
            let path = NSBezierPath(roundedRect: rect, xRadius: 12, yRadius: 12)
            path.setLineDash([4, 4], count: 2, phase: 0)
            path.lineWidth = 1
            line.setStroke()
            path.stroke()
            let label = "\(frame.title.uppercased()) · \(frame.liveCount) LIVE"
            label.draw(
                at: CGPoint(x: rect.minX + 14, y: rect.minY + 12),
                withAttributes: [
                    .font: NSFont.systemFont(ofSize: 10, weight: .semibold),
                    .foregroundColor: text,
                    .kern: 0.8,
                ]
            )
        }
    }

    private func drawDependencies(appearance: NSAppearance) {
        let line = AuspexPalette.resolve(AuspexPalette.text3, for: appearance)
        let labelColor = AuspexPalette.resolve(AuspexPalette.text3, for: appearance)
        for edge in dependencies {
            guard let from = byID[edge.fromNodeID], let to = byID[edge.toNodeID] else { continue }
            let start = CGPoint(
                x: cardRect(from).midX,
                y: cardRect(from).midY
            )
            let end = CGPoint(
                x: cardRect(to).midX,
                y: cardRect(to).midY
            )
            let path = NSBezierPath()
            path.move(to: start)
            path.line(to: end)
            path.lineWidth = 1.2
            line.setStroke()
            path.stroke()
            drawArrow(at: end, from: start, color: line)

            let middle = CGPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2)
            edge.label.draw(
                at: CGPoint(x: middle.x + 5, y: middle.y - 8),
                withAttributes: [
                    .font: NSFont.monospacedSystemFont(ofSize: 9, weight: .medium),
                    .foregroundColor: labelColor,
                ]
            )
        }
    }

    private func drawArrow(at end: CGPoint, from start: CGPoint, color: NSColor) {
        let angle = atan2(end.y - start.y, end.x - start.x)
        let length: CGFloat = 8
        let spread: CGFloat = .pi / 6
        let path = NSBezierPath()
        path.move(to: end)
        path.line(to: CGPoint(
            x: end.x - length * cos(angle - spread),
            y: end.y - length * sin(angle - spread)
        ))
        path.move(to: end)
        path.line(to: CGPoint(
            x: end.x - length * cos(angle + spread),
            y: end.y - length * sin(angle + spread)
        ))
        path.lineWidth = 1.2
        color.setStroke()
        path.stroke()
    }

    private func cardRect(_ card: MapCardValue) -> CGRect {
        CGRect(
            x: card.position.x + MapCanvasNSView.worldInset,
            y: card.position.y + MapCanvasNSView.worldInset,
            width: MapPlacement.cardSize.width,
            height: MapPlacement.cardSize.height
        )
    }

    private func surface(_ card: MapCardValue) -> MapCardSurface {
        MapCardSurface(
            card: card,
            isSelected: selectedNodeID == card.id,
            zoom: zoom,
            onSelect: { [weak self] in self?.canvas?.onSelect(card.leadKey) },
            onOpenFlight: { [weak self] in self?.canvas?.onOpenFlight(card.leadKey) },
            onMove: { [weak self] point in self?.canvas?.onMove(card.id, point) },
            isReadOnly: isReadOnly,
            isExpanded: expandedNodeIDs.contains(card.id),
            onToggleExpanded: { [weak self] in self?.canvas?.onToggleExpanded(card.id) },
            dependencyTargets: cards.compactMap { target in
                guard let taskID = target.taskID, taskID != card.taskID else { return nil }
                return MapDependencyTarget(id: taskID, title: target.title)
            },
            onSetDependencies: { [weak self] ids in
                guard let taskID = card.taskID else { return }
                self?.canvas?.onSetDependencies(taskID, ids, card.taskVersion)
            },
            onAddDependency: { [weak self] sourceTaskID in
                guard let self, let targetTaskID = card.taskID,
                    sourceTaskID != targetTaskID,
                    let source = cards.first(where: { $0.taskID == sourceTaskID })
                else { return false }
                var next = source.dependencyIDs.filter { $0 != targetTaskID }
                next.append(targetTaskID)
                canvas?.onSetDependencies(sourceTaskID, next.sorted(), source.taskVersion)
                return true
            }
        )
    }

    private func drawLineage(appearance: NSAppearance) {
        let text = AuspexPalette.resolve(AuspexPalette.text3, for: appearance)
        for card in cards where expandedNodeIDs.contains(card.id) {
            let root = cardRect(card)
            for (index, child) in card.subagents.enumerated() {
                let childRect = CGRect(
                    x: root.maxX + 76,
                    y: root.minY + CGFloat(index) * 38,
                    width: 220,
                    height: 30
                )
                let path = NSBezierPath()
                path.move(to: CGPoint(x: root.maxX, y: root.midY))
                path.curve(
                    to: CGPoint(x: childRect.minX, y: childRect.midY),
                    controlPoint1: CGPoint(x: root.maxX + 34, y: root.midY),
                    controlPoint2: CGPoint(x: childRect.minX - 28, y: childRect.midY)
                )
                path.setLineDash([4, 4], count: 2, phase: 0)
                path.lineWidth = 1
                text.setStroke()
                path.stroke()
                let box = NSBezierPath(roundedRect: childRect, xRadius: 7, yRadius: 7)
                AuspexPalette.resolve(AuspexPalette.bg1, for: appearance).setFill()
                box.fill()
                text.withAlphaComponent(0.5).setStroke()
                box.stroke()
                let accent = AuspexPalette.resolve(child.harness.style.accent, for: appearance)
                accent.setFill()
                NSBezierPath(ovalIn: CGRect(x: childRect.minX + 9, y: childRect.midY - 3, width: 6, height: 6)).fill()
                child.title.draw(
                    at: CGPoint(x: childRect.minX + 22, y: childRect.minY + 8),
                    withAttributes: [
                        .font: NSFont.systemFont(ofSize: 11, weight: .medium),
                        .foregroundColor: text,
                    ]
                )
            }
        }
    }
}

private struct MapDependencyTarget: Identifiable, Hashable {
    let id: Int64
    let title: String
}

private struct MapCardSurface: View {
    let card: MapCardValue
    let isSelected: Bool
    let zoom: CGFloat
    let onSelect: () -> Void
    let onOpenFlight: () -> Void
    let onMove: (CGPoint) -> Void
    let isReadOnly: Bool
    let isExpanded: Bool
    let onToggleExpanded: () -> Void
    let dependencyTargets: [MapDependencyTarget]
    let onSetDependencies: ([Int64]) -> Void
    let onAddDependency: (Int64) -> Bool

    @State private var isHovering = false

    private enum Density { case full, compact, marker }
    private var density: Density {
        if zoom >= 0.75 { return .full }
        if zoom >= 0.45 { return .compact }
        return .marker
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            switch density {
            case .full: fullCard
            case .compact: compactCard
            case .marker: marker
            }
        }
        .frame(
            width: MapPlacement.cardSize.width,
            height: MapPlacement.cardSize.height,
            alignment: .topLeading
        )
        .contentShape(Rectangle())
        .onTapGesture(count: 2, perform: onOpenFlight)
        .onTapGesture(perform: onSelect)
        .gesture(
            DragGesture(minimumDistance: 3)
                .onEnded { value in
                    guard !isReadOnly else { return }
                    onMove(CGPoint(
                        x: max(0, card.position.x + value.translation.width),
                        y: max(0, card.position.y + value.translation.height)
                    ))
                }
        )
        .onHover { isHovering = $0 }
        .overlay(alignment: .trailing) {
            if !isReadOnly, let taskID = card.taskID {
                Circle()
                    .fill(AuspexPalette.accent)
                    .frame(width: 10, height: 10)
                    .padding(.trailing, 5)
                    .draggable("auspex-task:\(taskID)")
                    .help("Drag to another task to add a dependency")
                    .accessibilityLabel("Dependency handle")
            }
        }
        .dropDestination(for: String.self) { values, _ in
            guard !isReadOnly else { return false }
            return values.contains { value in
                guard value.hasPrefix("auspex-task:"),
                    let sourceID = Int64(value.dropFirst("auspex-task:".count))
                else { return false }
                return onAddDependency(sourceID)
            }
        }
        .contextMenu {
            if isReadOnly {
                Text("History is read-only · Jump to Live to edit")
            } else if card.taskID != nil, !dependencyTargets.isEmpty {
                Text("Depends on")
                ForEach(dependencyTargets) { target in
                    let isOn = card.dependencyIDs.contains(target.id)
                    Button {
                        var next = card.dependencyIDs.filter { $0 != target.id }
                        if !isOn { next.append(target.id) }
                        onSetDependencies(next.sorted())
                    } label: {
                        if isOn {
                            Label(target.title, systemImage: "checkmark")
                        } else {
                            Text(target.title)
                        }
                    }
                }
            } else if card.isImplicit {
                Text("Promote this task before adding dependencies")
            }
        }
        .opacity(card.state.isEnded ? 0.62 : 1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction(named: "Open Flight", onOpenFlight)
    }

    private var fullCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                HarnessBadge(harness: card.harness, size: 20, isMuted: card.state.isEnded)
                Text(card.title)
                    .font(AuspexType.cardTitle)
                    .foregroundStyle(AuspexPalette.text)
                    .lineLimit(1)
                Spacer(minLength: 4)
                StatePill(state: card.state, isStale: card.isStale, showsChildCount: false)
            }
            HStack(spacing: 6) {
                Text(card.shortID)
                if card.isImplicit { Text("AUTO") }
                if card.memberCount > 1 {
                    Button(action: onToggleExpanded) {
                        Text(isExpanded ? "↳ collapse" : "↳ \(card.memberCount - 1)")
                            .font(AuspexType.monoSmall)
                    }
                    .buttonStyle(.auspex)
                    .accessibilityLabel(isExpanded ? "Collapse subagents" : "Expand subagents")
                }
            }
            .font(AuspexType.monoSmall)
            .foregroundStyle(AuspexPalette.text3)
            Text(card.focus)
                .font(AuspexType.body)
                .foregroundStyle(card.attention.wantsPerson ? AuspexPalette.statePermission : AuspexPalette.text2)
                .lineLimit(1)
            HStack(spacing: 8) {
                Text("turns \(card.turnCount)")
                Text("tools \(card.toolCount)")
                Spacer(minLength: 0)
                if card.taskID != nil {
                    Text(card.status.rawValue)
                }
            }
            .font(AuspexType.monoSmall)
            .foregroundStyle(AuspexPalette.text3)
        }
        .padding(12)
        .frame(width: 280, height: 108, alignment: .topLeading)
        .background(cardBackground)
        .overlay(cardBorder)
        .shadow(
            color: card.attention.wantsPerson ? AuspexPalette.statePermission.opacity(0.24) : .clear,
            radius: 10
        )
    }

    private var compactCard: some View {
        HStack(spacing: 8) {
            HarnessBadge(harness: card.harness, size: 18, isMuted: card.state.isEnded)
            Text(card.title)
                .font(AuspexType.cardTitle)
                .foregroundStyle(AuspexPalette.text)
                .lineLimit(1)
            Spacer(minLength: 4)
            StateDot(color: card.state.style.color, glows: !card.state.style.motion.isAnimated)
            if card.memberCount > 1 {
                Text("↳\(card.memberCount - 1)")
                    .font(AuspexType.monoSmall)
                    .foregroundStyle(AuspexPalette.text3)
            }
        }
        .padding(.horizontal, 10)
        .frame(width: 220, height: 48)
        .background(cardBackground)
        .overlay(cardBorder)
    }

    private var marker: some View {
        HStack(spacing: 6) {
            HarnessBadge(harness: card.harness, size: 20, isMuted: card.state.isEnded)
            if isSelected || isHovering {
                Text(card.title)
                    .font(AuspexType.caption)
                    .foregroundStyle(AuspexPalette.text)
                    .lineLimit(1)
                    .padding(.trailing, 8)
            }
        }
        .frame(height: 24)
        .background((isSelected || isHovering) ? cardBackground : AnyShapeStyle(.clear))
        .overlay {
            if isSelected { cardBorder }
        }
    }

    private var cardBackground: AnyShapeStyle {
        AnyShapeStyle(isSelected ? AuspexPalette.selection : AuspexPalette.bg1)
    }

    private var cardBorder: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(borderColor, lineWidth: isSelected ? 1.5 : 1)
            .overlay(alignment: .leading) {
                Capsule()
                    .fill(card.harness.style.accent)
                    .frame(width: 2)
                    .padding(.vertical, 1)
            }
    }

    private var borderColor: Color {
        if isSelected { return AuspexPalette.accent }
        if card.attention.wantsPerson { return AuspexPalette.statePermission }
        return AuspexPalette.line
    }

    private var accessibilityLabel: String {
        var pieces = [card.title, card.state.label]
        if card.memberCount > 1 { pieces.append("\(card.memberCount - 1) subagents") }
        if card.attention.wantsPerson { pieces.append("needs you") }
        return pieces.joined(separator: ", ")
    }
}

private extension CGRect {
    var center: CGPoint { CGPoint(x: midX, y: midY) }
}
