import AgentSessionKit
import AgentSessionLive
import AppKit
import AuspexCore
import SwiftUI

struct FlightGraphView: View {
    @Bindable var board: LiveBoardModel
    @Bindable var model: TrajectoryModel

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isSnapshotRender) private var isSnapshotRender
    @GestureState private var dragOffset = CGSize.zero
    @GestureState private var magnification: CGFloat = 1

    private var animates: Bool {
        // Playback itself advances the graph at the event cadence. The native
        // paint clock exists only for the short completion afterglow; running
        // it merely to march every active dash made live bursts pay for a
        // second animation loop on top of their real state changes.
        let hasMotionContent = !model.graphAfterglows.isEmpty
        return FlightGraphMotionPolicy.needsClock(
            isVisible: true,
            isPlaying: (model.isHistory ? model.isPlaying : model.graphLiveMotionActive)
                && hasMotionContent,
            reduceMotion: reduceMotion
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            transport
            Group {
                if let frame = model.graphFrame, !frame.nodes.isEmpty {
                    canvas(frame: frame)
                } else {
                    EmptyStateView(
                        symbol: "point.3.connected.trianglepath.dotted",
                        title: "Building the execution graph…",
                        detail: "Flight is folding this session's observed agent and tool events."
                    )
                    .centredInPane()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            timeline
        }
        .background(AuspexPalette.canvas)
        .focusable()
        .onKeyPress("o") {
            model.setGraphCamera(.overview)
            return .handled
        }
        .onKeyPress("f") {
            model.setGraphCamera(.follow)
            return .handled
        }
        .onKeyPress(.upArrow) {
            model.moveGraphSelection(by: -1)
            return .handled
        }
        .onKeyPress(.leftArrow) {
            model.moveGraphSelection(by: -1)
            return .handled
        }
        .onKeyPress(.downArrow) {
            model.moveGraphSelection(by: 1)
            return .handled
        }
        .onKeyPress(.rightArrow) {
            model.moveGraphSelection(by: 1)
            return .handled
        }
    }

    private var transport: some View {
        HStack(spacing: 10) {
            Button {
                model.togglePlayback()
            } label: {
                Image(systemName: model.isHistory && !model.isPlaying ? "play.fill" : "pause.fill")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(AuspexPalette.text2)
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(AuspexPalette.bg1))
            }
            .buttonStyle(.auspex)
            .accessibilityLabel(model.isPlaying ? "Pause graph playback" : "Play graph history")

            Menu {
                ForEach(PlaybackSpeed.allCases, id: \.self) { speed in
                    Button(speed.label) { model.setPlaybackSpeed(speed) }
                }
            } label: {
                Text(model.playbackSpeed.label)
                    .font(AuspexType.monoSmall)
                    .foregroundStyle(AuspexPalette.text2)
                    .frame(width: 30, height: 22)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)

            HStack(spacing: 5) {
                StateDot(
                    color: model.isHistory ? AuspexPalette.stateStale : AuspexPalette.stateWriting,
                    glows: !model.isHistory && !reduceMotion
                )
                Text(model.isHistory ? (model.isPlaying ? "History" : "Paused") : "Live")
                    .font(AuspexType.pill)
                    .foregroundStyle(
                        model.isHistory ? AuspexPalette.stateStale : AuspexPalette.text)
            }
            Text("event \(model.historyIndex + 1) / \(max(1, model.historyCount))")
                .font(AuspexType.monoSmall)
                .foregroundStyle(AuspexPalette.text3)
            if let frame = model.graphFrame {
                Text(frame.timestamp.formatted(date: .omitted, time: .standard))
                    .font(AuspexType.monoSmall)
                    .foregroundStyle(AuspexPalette.text2)
            }
            Spacer()
            Text("o overview · f follow · pan/zoom = manual")
                .font(AuspexType.monoSmall)
                .foregroundStyle(AuspexPalette.text3)
            if model.isHistory {
                Button("Jump to Live") { model.jumpToLive() }
                    .font(AuspexType.pill)
                    .buttonStyle(.auspex(cornerRadius: 7))
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 46)
        .background(AuspexPalette.bg0)
        .overlay(alignment: .bottom) {
            Rectangle().fill(AuspexPalette.line).frame(height: 1)
        }
    }

    private func canvas(frame: FlightGraphFrame) -> some View {
        GeometryReader { geometry in
            let size = geometry.size
            let fit = fitScale(frame: frame, in: size)
            let scale =
                model.graphCamera == .overview
                ? fit
                : min(2.5, max(0.35, model.graphZoom * magnification))
            let camera = cameraOffset(frame: frame, in: size, scale: scale)
            let pan = CGSize(
                width: camera.width + model.graphPan.width + dragOffset.width,
                height: camera.height + model.graphPan.height + dragOffset.height
            )
            ZStack(alignment: .topLeading) {
                FlightGraphMotionLayer(
                    model: model,
                    frame: frame,
                    size: size,
                    scale: scale,
                    pan: pan,
                    animates: animates,
                    expires: !model.isHistory,
                    reduceMotion: reduceMotion,
                    isSnapshotRender: isSnapshotRender
                )

                ForEach(frame.nodes) { node in
                    let point = screenPoint(node.position, in: size, scale: scale, pan: pan)
                    FlightGraphNodeView(
                        node: node,
                        isSelected: model.selectedAgentKey == node.key,
                        onSelect: { model.selectGraphAgent(node.key) }
                    )
                    .scaleEffect(scale)
                    .position(point)
                    .transition(.opacity)
                }

                FlightGraphMinimap(
                    frame: frame,
                    selected: model.selectedAgentKey,
                    viewport: CGRect(
                        x: (-size.width / 2 - pan.width) / scale,
                        y: (-90 - pan.height) / scale,
                        width: size.width / scale,
                        height: size.height / scale
                    )
                )
                .frame(width: 150, height: 96)
                .padding(14)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            }
            .clipped()
            .contentShape(Rectangle())
            .simultaneousGesture(panGesture)
            .simultaneousGesture(zoomGesture)
            .animation(
                animates ? .smooth(duration: 0.5) : nil,
                value: followTarget(frame: frame)?.description
            )
            .animation(
                animates ? .easeOut(duration: 0.2) : nil,
                value: frame.nodes.map(\.key)
            )
        }
    }

    private var panGesture: some Gesture {
        DragGesture(minimumDistance: 3)
            .updating($dragOffset) { value, state, _ in state = value.translation }
            .onEnded { value in
                model.updateGraphViewport(
                    pan: CGSize(
                        width: model.graphPan.width + value.translation.width,
                        height: model.graphPan.height + value.translation.height
                    ),
                    zoom: model.graphZoom
                )
            }
    }

    private var zoomGesture: some Gesture {
        MagnifyGesture()
            .updating($magnification) { value, state, _ in state = value.magnification }
            .onEnded { value in
                model.updateGraphViewport(
                    pan: model.graphPan,
                    zoom: model.graphZoom * value.magnification
                )
            }
    }

    private func fitScale(frame: FlightGraphFrame, in size: CGSize) -> CGFloat {
        guard let bounds = graphBounds(frame.nodes) else { return 1 }
        return min(
            1.25,
            max(
                0.35,
                min(
                    (size.width - 120) / max(1, bounds.width),
                    (size.height - 150) / max(1, bounds.height)))
        )
    }

    private func cameraOffset(
        frame: FlightGraphFrame,
        in size: CGSize,
        scale: CGFloat
    ) -> CGSize {
        guard model.graphCamera == .follow,
            let target = followTarget(frame: frame),
            let node = frame.nodes.first(where: { $0.key == target })
        else { return .zero }
        return CGSize(width: -node.position.x * scale, height: -node.position.y * scale + 20)
    }

    private func followTarget(frame: FlightGraphFrame) -> SessionKey? {
        model.selectedAgentKey ?? frame.latestActiveNodeID
    }

    private func graphBounds(_ nodes: [FlightGraphNode]) -> CGRect? {
        guard let first = nodes.first else { return nil }
        var rect = CGRect(
            x: first.position.x - 120, y: first.position.y - 40, width: 240, height: 100)
        for node in nodes.dropFirst() {
            rect = rect.union(
                CGRect(x: node.position.x - 120, y: node.position.y - 40, width: 240, height: 100))
        }
        return rect
    }

    private func screenPoint(
        _ point: CGPoint,
        in size: CGSize,
        scale: CGFloat,
        pan: CGSize
    ) -> CGPoint {
        CGPoint(
            x: size.width / 2 + point.x * scale + pan.width,
            y: 90 + point.y * scale + pan.height
        )
    }

    private var timeline: some View {
        HStack(spacing: 10) {
            if model.historyCount > 1 {
                FlightEventScrubber(model: model)
            }
            Text(model.graphFrame?.timestamp.formatted(date: .omitted, time: .standard) ?? "—")
                .font(AuspexType.monoSmall)
                .foregroundStyle(AuspexPalette.text2)
                .fixedSize()
        }
        .padding(.horizontal, 16)
        .frame(height: 48)
        .background(AuspexPalette.bg0)
        .overlay(alignment: .top) {
            Rectangle().fill(AuspexPalette.line).frame(height: 1)
        }
    }
}

struct FlightEventScrubber: View {
    @Bindable var model: TrajectoryModel

    var body: some View {
        GeometryReader { geometry in
            Canvas { context, size in
                let y = size.height / 2
                context.stroke(
                    Path { path in
                        path.move(to: CGPoint(x: 0, y: y))
                        path.addLine(to: CGPoint(x: size.width, y: y))
                    },
                    with: .color(AuspexPalette.line2),
                    lineWidth: 1
                )
                let denominator = CGFloat(max(1, model.events.count - 1))
                for (index, event) in model.events.enumerated() {
                    let x = CGFloat(index) / denominator * size.width
                    let color: Color
                    switch event.kind {
                    case .toolCallStarted: color = AuspexPalette.stateTool
                    case .subagentStarted: color = AuspexPalette.stateDelegating
                    case .userPrompt: color = AuspexPalette.stateThinking
                    default: color = AuspexPalette.line2
                    }
                    let height = CGFloat(5 + index % 3 * 3)
                    context.fill(
                        Path(CGRect(x: x, y: y - height / 2, width: 2, height: height)),
                        with: .color(color.opacity(index <= model.historyIndex ? 0.85 : 0.28))
                    )
                }
                let fraction = CGFloat(model.historyIndex) / denominator
                let x = min(size.width - 2, max(0, fraction * size.width))
                context.stroke(
                    Path { path in
                        path.move(to: CGPoint(x: 0, y: y))
                        path.addLine(to: CGPoint(x: x, y: y))
                    },
                    with: .color(AuspexPalette.accent.opacity(0.42)),
                    lineWidth: 2
                )
                context.fill(
                    Path(
                        roundedRect: CGRect(x: x - 1, y: 1, width: 2, height: size.height - 2),
                        cornerRadius: 1),
                    with: .color(AuspexPalette.accent)
                )
                context.fill(
                    Path(ellipseIn: CGRect(x: x - 4, y: y - 4, width: 8, height: 8)),
                    with: .color(AuspexPalette.accent)
                )
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let fraction = min(
                            1, max(0, value.location.x / max(1, geometry.size.width)))
                        model.seek(
                            to: Int(
                                (Double(fraction) * Double(max(0, model.historyCount - 1)))
                                    .rounded()))
                    }
            )
        }
        .frame(height: 28)
        .focusable()
        .onKeyPress(.leftArrow) {
            model.seek(to: max(0, model.historyIndex - 1))
            return .handled
        }
        .onKeyPress(.rightArrow) {
            model.seek(to: min(max(0, model.historyCount - 1), model.historyIndex + 1))
            return .handled
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Flight event playhead")
        .accessibilityValue("Event \(model.historyIndex + 1) of \(model.historyCount)")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment:
                model.seek(to: min(max(0, model.historyCount - 1), model.historyIndex + 1))
            case .decrement: model.seek(to: max(0, model.historyIndex - 1))
            @unknown default: break
            }
        }
    }
}

private struct FlightGraphMotionLayer: View {
    @Bindable var model: TrajectoryModel
    let frame: FlightGraphFrame
    let size: CGSize
    let scale: CGFloat
    let pan: CGSize
    let animates: Bool
    let expires: Bool
    let reduceMotion: Bool
    let isSnapshotRender: Bool

    var body: some View {
        if isSnapshotRender {
            FlightGraphSnapshotBackdrop(frame: frame, scale: scale, pan: pan)
        } else {
            FlightGraphMotionSurface(
                frame: frame,
                scale: scale,
                pan: pan,
                afterglows: reduceMotion ? [] : model.graphAfterglows,
                animates: animates,
                expires: expires
            )
        }
    }
}

private struct FlightGraphSnapshotBackdrop: View {
    let frame: FlightGraphFrame
    let scale: CGFloat
    let pan: CGSize

    var body: some View {
        Canvas { context, size in
            var x: CGFloat = 4
            while x < size.width {
                var y: CGFloat = 4
                while y < size.height {
                    context.fill(
                        Path(ellipseIn: CGRect(x: x, y: y, width: 1.2, height: 1.2)),
                        with: .color(AuspexPalette.grid)
                    )
                    y += 32
                }
                x += 32
            }
            let nodes = Dictionary(uniqueKeysWithValues: frame.nodes.map { ($0.key, $0) })
            func point(_ world: CGPoint) -> CGPoint {
                CGPoint(
                    x: size.width / 2 + world.x * scale + pan.width,
                    y: 90 + world.y * scale + pan.height
                )
            }
            for edge in frame.edges {
                guard let parent = nodes[edge.parent], let child = nodes[edge.child] else { continue }
                let start = point(parent.position)
                let end = point(child.position)
                var path = Path()
                path.move(to: CGPoint(x: start.x, y: start.y + 28 * scale))
                let middle = (start.y + end.y) / 2
                path.addLine(to: CGPoint(x: start.x, y: middle))
                path.addLine(to: CGPoint(x: end.x, y: middle))
                path.addLine(to: CGPoint(x: end.x, y: end.y - 25 * scale))
                let color = edge.isActive
                    ? (nodes[edge.child]?.state.style.color ?? AuspexPalette.stateWriting)
                    : AuspexPalette.line2
                context.stroke(
                    path,
                    with: .color(color.opacity(edge.isActive ? 0.9 : 0.7)),
                    style: StrokeStyle(lineWidth: edge.isActive ? 1.5 : 1, dash: edge.isActive ? [7, 5] : [])
                )
            }
        }
    }
}

private struct FlightGraphMotionSurface: NSViewRepresentable {
    let frame: FlightGraphFrame
    let scale: CGFloat
    let pan: CGSize
    let afterglows: [FlightGraphAfterglow]
    let animates: Bool
    let expires: Bool

    func makeNSView(context: Context) -> FlightGraphMotionNSView {
        FlightGraphMotionNSView()
    }

    func updateNSView(_ view: FlightGraphMotionNSView, context: Context) {
        view.update(
            frame: frame,
            scale: scale,
            pan: pan,
            afterglows: afterglows,
            animates: animates,
            expires: expires
        )
    }

    static func dismantleNSView(_ view: FlightGraphMotionNSView, coordinator: ()) {
        view.stop()
    }
}

@MainActor
private final class FlightGraphMotionNSView: NSView {
    /// Dashed lineage and tool chips are ambient instrumentation, not video.
    /// Ten paint frames per second keep their direction legible while leaving
    /// the main thread room for live board updates during a harness burst.
    private static let framesPerSecond = 5.0

    private var graphFrame: FlightGraphFrame?
    private var graphScale: CGFloat = 1
    private var graphPan = CGSize.zero
    private var graphAfterglows: [FlightGraphAfterglow] = []
    private var wantsAnimation = false
    private var animationDeadline: Date?
    private var timer: Timer?

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }

    func update(
        frame: FlightGraphFrame,
        scale: CGFloat,
        pan: CGSize,
        afterglows: [FlightGraphAfterglow],
        animates: Bool,
        expires: Bool
    ) {
        let frameChanged = graphFrame?.index != frame.index
            || graphFrame?.count != frame.count
            || graphFrame?.timestamp != frame.timestamp
        graphFrame = frame
        graphScale = scale
        graphPan = pan
        graphAfterglows = afterglows
        wantsAnimation = animates
        if !animates {
            animationDeadline = nil
        } else if !expires {
            animationDeadline = nil
        } else if frameChanged || animationDeadline == nil {
            animationDeadline = Date().addingTimeInterval(10)
        }
        updateClock()
        needsDisplay = true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateClock()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func updateClock() {
        guard wantsAnimation, window != nil else {
            stop()
            return
        }
        guard timer == nil else { return }
        let next = Timer(timeInterval: 1.0 / Self.framesPerSecond, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if let deadline = self.animationDeadline, Date() >= deadline {
                    self.wantsAnimation = false
                    self.animationDeadline = nil
                    self.stop()
                    self.needsDisplay = true
                    return
                }
                self.needsDisplay = true
            }
        }
        next.tolerance = 0.02
        RunLoop.main.add(next, forMode: .common)
        timer = next
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let frame = graphFrame else { return }
        let appearance = effectiveAppearance
        drawGrid(appearance: appearance)
        let nodes = Dictionary(uniqueKeysWithValues: frame.nodes.map { ($0.key, $0) })
        let phase = Date().timeIntervalSinceReferenceDate
        for edge in frame.edges {
            guard let parent = nodes[edge.parent], let child = nodes[edge.child] else { continue }
            let start = point(parent.position)
            let end = point(child.position)
            let path = NSBezierPath()
            path.move(to: CGPoint(x: start.x, y: start.y + 28 * graphScale))
            let middle = (start.y + end.y) / 2
            path.line(to: CGPoint(x: start.x, y: middle))
            path.line(to: CGPoint(x: end.x, y: middle))
            path.line(to: CGPoint(x: end.x, y: end.y - 25 * graphScale))
            let swiftColor = edge.isActive
                ? (nodes[edge.child]?.state.style.color ?? AuspexPalette.stateWriting)
                : AuspexPalette.line2
            let color = AuspexPalette.resolve(swiftColor, for: appearance)
            color.withAlphaComponent(edge.isActive ? 0.9 : 0.7).setStroke()
            path.lineWidth = edge.isActive ? 1.5 : 1
            if edge.isActive {
                path.setLineDash([7, 5], count: 2, phase: wantsAnimation ? -phase * 18 : 0)
            }
            path.stroke()
        }
        drawChips(frame: frame, nodes: nodes, phase: phase, appearance: appearance)
    }

    private func point(_ world: CGPoint) -> CGPoint {
        CGPoint(
            x: bounds.width / 2 + world.x * graphScale + graphPan.width,
            y: 90 + world.y * graphScale + graphPan.height
        )
    }

    private func drawGrid(appearance: NSAppearance) {
        let color = AuspexPalette.resolve(AuspexPalette.grid, for: appearance)
        color.setFill()
        var x: CGFloat = 4
        while x < bounds.width {
            var y: CGFloat = 4
            while y < bounds.height {
                NSBezierPath(ovalIn: CGRect(x: x, y: y, width: 1.2, height: 1.2)).fill()
                y += 32
            }
            x += 32
        }
    }

    private func drawChips(
        frame: FlightGraphFrame,
        nodes: [SessionKey: FlightGraphNode],
        phase: TimeInterval,
        appearance: NSAppearance
    ) {
        guard graphScale >= 0.55 else { return }
        var grouped: [SessionKey: [(String, Int, FlightGraphChipState, Double)]] = [:]
        for chip in frame.chips {
            grouped[chip.session, default: []].append((chip.name, chip.count, .pending, 1))
        }
        let now = Date()
        for item in graphAfterglows {
            let age = item.age(at: now)
            guard age < item.ttl else { continue }
            grouped[item.session, default: []].append((
                item.name,
                item.count,
                item.isError ? .failed : .succeeded,
                max(0, 1 - age / item.ttl)
            ))
        }
        for (session, chips) in grouped {
            guard let node = nodes[session] else { continue }
            let center = point(node.position)
            var cursor = center.x - CGFloat(chips.prefix(3).count - 1) * 42
            for chip in chips.prefix(3) {
                let swiftColor: Color = switch chip.2 {
                case .pending: AuspexPalette.stateTool
                case .succeeded: AuspexPalette.stateWriting
                case .failed: AuspexPalette.statePermission
                }
                let pulse = chip.2 == .pending && wantsAnimation
                    ? 0.78 + 0.22 * sin(phase * 7)
                    : 1
                let opacity = chip.3 * pulse
                let color = AuspexPalette.resolve(swiftColor, for: appearance)
                let label = (chip.2 == .pending ? "◉ " : (chip.2 == .failed ? "× " : "✓ "))
                    + chip.0 + (chip.1 > 1 ? " ×\(chip.1)" : "")
                let width = max(54, CGFloat(label.count) * 6.5 + 12)
                let rect = CGRect(x: cursor - width / 2, y: center.y + 36 * graphScale, width: width, height: 19)
                color.withAlphaComponent(0.1 * opacity).setFill()
                NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5).fill()
                (label as NSString).draw(
                    at: CGPoint(x: rect.minX + 6, y: rect.minY + 4),
                    withAttributes: [
                        .font: NSFont.monospacedSystemFont(ofSize: 9, weight: .medium),
                        .foregroundColor: color.withAlphaComponent(opacity),
                    ]
                )
                cursor += width + 5
            }
        }
    }
}

private struct FlightGraphNodeView: View {
    let node: FlightGraphNode
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 7) {
                HarnessBadge(harness: node.key.harness, size: 18, isMuted: node.state.isEnded)
                Text(node.title)
                    .font(AuspexType.cardTitle)
                    .foregroundStyle(AuspexPalette.text)
                    .lineLimit(1)
                Spacer(minLength: 4)
                StatePill(state: node.state, isStale: node.isStale, showsChildCount: false)
            }
            HStack(spacing: 8) {
                Text(node.key.sessionID.prefix(8))
                Text("turn \(node.turnCount)")
                if node.tokensOut > 0 { Text("\(TokenFormat.compact(node.tokensOut)) out") }
            }
            .font(AuspexType.monoSmall)
            .foregroundStyle(AuspexPalette.text3)
        }
        .padding(10)
        .frame(width: node.parent == nil ? 260 : 230, height: 58, alignment: .topLeading)
        .background(isSelected ? AuspexPalette.selection : AuspexPalette.bg1)
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(
                    isSelected ? AuspexPalette.accent : AuspexPalette.line,
                    lineWidth: isSelected ? 1.5 : 1)
        }
        .overlay(alignment: .leading) {
            Capsule().fill(node.key.harness.style.accent).frame(width: 2).padding(.vertical, 1)
        }
        .opacity(node.state.isEnded ? 0.62 : 1)
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(node.title), \(node.state.label), \(node.toolCount) tools")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

private struct FlightGraphMinimap: View {
    let frame: FlightGraphFrame
    let selected: SessionKey?
    let viewport: CGRect

    var body: some View {
        Canvas { context, size in
            guard let minX = frame.nodes.map(\.position.x).min(),
                let maxX = frame.nodes.map(\.position.x).max(),
                let minY = frame.nodes.map(\.position.y).min(),
                let maxY = frame.nodes.map(\.position.y).max()
            else { return }
            let width = max(1, maxX - minX)
            let height = max(1, maxY - minY)
            func point(_ value: CGPoint) -> CGPoint {
                CGPoint(
                    x: 12 + (value.x - minX) / width * (size.width - 24),
                    y: 12 + (value.y - minY) / height * (size.height - 24)
                )
            }
            for edge in frame.edges {
                guard let a = frame.nodes.first(where: { $0.key == edge.parent }),
                    let b = frame.nodes.first(where: { $0.key == edge.child })
                else { continue }
                var path = Path()
                path.move(to: point(a.position))
                path.addLine(to: point(b.position))
                context.stroke(path, with: .color(AuspexPalette.line2), lineWidth: 1)
            }
            for node in frame.nodes {
                let p = point(node.position)
                context.fill(
                    Path(
                        roundedRect: CGRect(x: p.x - 8, y: p.y - 3, width: 16, height: 6),
                        cornerRadius: 2),
                    with: .color(
                        node.key == selected
                            ? AuspexPalette.accent : node.key.harness.style.accent.opacity(0.8)
                    )
                )
            }
            let a = point(viewport.origin)
            let b = point(CGPoint(x: viewport.maxX, y: viewport.maxY))
            context.stroke(
                Path(
                    roundedRect: CGRect(
                        x: min(a.x, b.x),
                        y: min(a.y, b.y),
                        width: max(8, abs(b.x - a.x)),
                        height: max(8, abs(b.y - a.y))
                    ), cornerRadius: 3),
                with: .color(AuspexPalette.accent.opacity(0.7)),
                lineWidth: 1
            )
        }
        .background(AuspexPalette.bg2.opacity(0.94))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(AuspexPalette.line, lineWidth: 1)
        }
        .accessibilityHidden(true)
    }
}
