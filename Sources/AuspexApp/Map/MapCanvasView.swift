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
    let viewport: MapViewport
    let commands: MapCanvasCommands
    let onSelect: (SessionKey) -> Void
    let onOpenFlight: (SessionKey) -> Void
    let onMove: (String, CGPoint) -> Void
    let onSetDependencies: (Int64, [Int64]) -> Void
    let onViewport: (CGPoint, CGFloat) -> Void

    func makeNSView(context: Context) -> MapCanvasNSView {
        let view = MapCanvasNSView(frame: .zero)
        view.onSelect = onSelect
        view.onOpenFlight = onOpenFlight
        view.onMove = onMove
        view.onSetDependencies = onSetDependencies
        view.onViewport = onViewport
        wire(commands, to: view)
        return view
    }

    func updateNSView(_ view: MapCanvasNSView, context: Context) {
        view.onSelect = onSelect
        view.onOpenFlight = onOpenFlight
        view.onMove = onMove
        view.onSetDependencies = onSetDependencies
        view.onViewport = onViewport
        view.update(
            cards: cards,
            frames: frames,
            dependencies: dependencies,
            selectedNodeID: selectedNodeID,
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
    static let worldInset: CGFloat = 640
    static let minimumWorld = CGSize(width: 6_000, height: 4_000)
    static let prefetch: CGFloat = 420

    let scrollView = MapScrollView()
    let document = MapDocumentView()

    var onSelect: (SessionKey) -> Void = { _ in }
    var onOpenFlight: (SessionKey) -> Void = { _ in }
    var onMove: (String, CGPoint) -> Void = { _, _ in }
    var onSetDependencies: (Int64, [Int64]) -> Void = { _, _ in }
    var onViewport: (CGPoint, CGFloat) -> Void = { _, _ in }

    private var boundsObserver: NSObjectProtocol?
    private var magnifyObserver: NSObjectProtocol?
    private var lastBoardID: String?
    private var lastViewportStamp: Date?
    private var isApplyingViewport = false

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
        viewport: MapViewport
    ) {
        resizeWorld(for: cards)
        document.update(
            cards: cards,
            frames: frames,
            dependencies: dependencies,
            selectedNodeID: selectedNodeID,
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
    private var zoom: CGFloat = 1
    private var hosts: [String: NSHostingView<MapCardSurface>] = [:]
    private var visibleIDs: Set<String> = []

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
        zoom: CGFloat
    ) {
        let changed = self.cards != cards || self.frames != frames
            || self.dependencies != dependencies || self.selectedNodeID != selectedNodeID
        self.cards = cards
        byID = Dictionary(uniqueKeysWithValues: cards.map { ($0.id, $0) })
        self.frames = frames
        self.dependencies = dependencies
        self.selectedNodeID = selectedNodeID
        self.zoom = zoom
        if changed { needsDisplay = true }
        refreshVisibleCards(force: changed)
    }

    func stop() {
        for host in hosts.values { host.removeFromSuperview() }
        hosts.removeAll()
        visibleIDs.removeAll()
    }

    func refreshVisibleCards(force: Bool) {
        guard let canvas else { return }
        zoom = canvas.scrollView.magnification
        let visible = canvas.scrollView.documentVisibleRect.insetBy(
            dx: -MapCanvasNSView.prefetch,
            dy: -MapCanvasNSView.prefetch
        )
        let wanted = Set(cards.lazy.filter { self.cardRect($0).intersects(visible) }.map(\.id))
        guard force || wanted != visibleIDs else { return }

        for id in visibleIDs.subtracting(wanted) {
            hosts.removeValue(forKey: id)?.removeFromSuperview()
        }
        for id in wanted {
            guard let card = byID[id] else { continue }
            let root = surface(card)
            if let host = hosts[id] {
                host.rootView = root
                host.frame = cardRect(card)
            } else {
                let host = NSHostingView(rootView: root)
                host.frame = cardRect(card)
                addSubview(host)
                hosts[id] = host
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
            dependencyTargets: cards.compactMap { target in
                guard let taskID = target.taskID, taskID != card.taskID else { return nil }
                return MapDependencyTarget(id: taskID, title: target.title)
            },
            onSetDependencies: { [weak self] ids in
                guard let taskID = card.taskID else { return }
                self?.canvas?.onSetDependencies(taskID, ids)
            }
        )
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
    let dependencyTargets: [MapDependencyTarget]
    let onSetDependencies: ([Int64]) -> Void

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
                    onMove(CGPoint(
                        x: max(0, card.position.x + value.translation.width),
                        y: max(0, card.position.y + value.translation.height)
                    ))
                }
        )
        .onHover { isHovering = $0 }
        .contextMenu {
            if card.taskID != nil, !dependencyTargets.isEmpty {
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
                if card.memberCount > 1 { Text("↳ \(card.memberCount - 1)") }
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
