import AgentSessionKit
import AgentSessionLive
import AppKit
import AuspexCore
import SpriteKit
import SwiftUI

/// Which way the live section is being read.
///
/// Three views of one board, and the choice is remembered: a person who prefers
/// the office should not have to pick it again every launch.
enum LiveViewMode: String, CaseIterable, Identifiable {
    /// The wall of session cards.
    case board
    /// The pixel office.
    case scene
    /// One geometric avatar per session.
    case crew

    var id: String { rawValue }

    var title: String {
        switch self {
        case .board: "Board"
        case .scene: "Scene"
        case .crew: "Crew"
        }
    }

    var systemImage: String {
        switch self {
        case .board: "square.grid.2x2"
        case .scene: "building.2"
        case .crew: "person.3"
        }
    }
}

/// The live section: the wall, or the office.
///
/// One switcher above one board frame. Both halves read the same
/// ``LiveBoardModel``, including its selection, so moving between them keeps
/// whatever the trace inspector was showing.
struct LiveSectionView: View {
    let model: LiveBoardModel

    @AppStorage("auspex.liveViewMode") private var storedMode = LiveViewMode.board.rawValue

    var body: some View {
        let mode = LiveViewMode(rawValue: storedMode) ?? .board

        VStack(spacing: 0) {
            switcher(mode: mode)
            Group {
                switch mode {
                case .board: BoardView(model: model)
                case .scene: SceneContainerView(model: model)
                case .crew: CrewView(model: model)
                }
            }
        }
    }

    private func switcher(mode: LiveViewMode) -> some View {
        HStack(spacing: 10) {
            Picker("View", selection: Binding(
                get: { mode },
                set: { storedMode = $0.rawValue }
            )) {
                ForEach(LiveViewMode.allCases) { option in
                    Label(option.title, systemImage: option.systemImage).tag(option)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 210)
            .help("Read the same board as a wall of cards, as a room, or as a crew")

            Spacer(minLength: 8)

            if mode == .scene {
                Text("Scroll to pan · pinch or ⌘-scroll to zoom · click a desk")
                    .auspexLabel(AuspexType.labelSmall)
                    .foregroundStyle(AuspexPalette.textTertiary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(AuspexPalette.canvasDeep)
        .overlay(alignment: .bottom) {
            Rectangle().fill(AuspexPalette.hairlineStrong).frame(height: 1)
        }
    }
}

/// The scene view: a SpriteKit office with SwiftUI chrome over it.
///
/// A first-class way of reading the same board, not a toy. The wall of cards
/// answers "what is this session doing" precisely; the office answers "what is
/// the whole machine doing" pre-attentively — how many rooms are lit, which one
/// is flashing red, who is standing up handing work to somebody. Both render
/// one ``BoardSnapshot`` and share one ``LiveBoardModel/selectedKey``, so
/// clicking a desk here fills the trace inspector exactly as clicking a card
/// does.
struct SceneContainerView: View {
    let model: LiveBoardModel

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var commands = SceneCommands()
    @State private var overview = SceneOverview.empty

    var body: some View {
        // Read on this side of the representable on purpose: observation is
        // tracked in a `body`, and a value read only inside `updateNSView`
        // would never schedule the update that reads it.
        //
        // TODO: read `model.visibleBoard` here once the ignore rules land —
        // the scene must draw what the board draws, and this is the one line
        // that decides it.
        let board = model.board
        let selected = model.selectedKey
        let focused = model.focusedProjectKey

        ZStack(alignment: .topTrailing) {
            OfficeSceneRepresentable(
                board: board,
                selected: selected,
                focusedProject: focused,
                reduceMotion: reduceMotion || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
                commands: commands,
                onSelect: { model.selectedKey = $0 },
                onFocusProject: { model.focusedProjectKey = $0 },
                onOverview: { overview = $0 }
            )
            .ignoresSafeArea()

            if board.sessions.isEmpty {
                emptyRoom
            }

            controls
                .padding(12)
        }
        .overlay(alignment: .bottomLeading) {
            legend.padding(12)
        }
        .overlay(alignment: .bottomTrailing) {
            if overview.isWorthDrawing {
                SceneMinimapView(overview: overview) { commands.jump($0) }
                    .padding(12)
                    .transition(.opacity)
            }
        }
        .background(AuspexPalette.canvas)
    }

    // MARK: Chrome

    /// Fit, the zoom readout, and the two steps either side of it.
    ///
    /// The readout is a menu rather than a label because the presets are the
    /// only way to get to an exact zoom, and a person who has zoomed somewhere
    /// odd wants "100 %" more than they want to count clicks back to it.
    private var controls: some View {
        VStack(spacing: 6) {
            controlButton("Fit all", systemImage: "arrow.up.left.and.arrow.down.right") {
                commands.fit()
            }
            .keyboardShortcut("0", modifiers: .command)

            controlButton("Zoom in", systemImage: "plus.magnifyingglass") { commands.zoomIn() }
                .keyboardShortcut("=", modifiers: .command)

            Menu {
                ForEach(SceneViewport.zoomPresets, id: \.self) { preset in
                    Button(Self.percent(preset)) { commands.setZoom(preset) }
                }
            } label: {
                Text(Self.percent(overview.zoom))
                    .auspexLabel(AuspexType.labelSmall)
                    .monospacedDigit()
                    .frame(width: 34, height: 16)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .foregroundStyle(AuspexPalette.textSecondary)
            .help("Zoom")

            controlButton("Zoom out", systemImage: "minus.magnifyingglass") { commands.zoomOut() }
                .keyboardShortcut("-", modifiers: .command)
        }
        .padding(4)
        .background(
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(AuspexPalette.panel.opacity(0.9))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .strokeBorder(AuspexPalette.hairline, lineWidth: 1)
        )
    }

    /// A zoom as a person reads it. Rounded, because `33 %` is what a third is
    /// called and `33.3 %` is what a spreadsheet calls it.
    private static func percent(_ zoom: CGFloat) -> String {
        "\(Int((zoom * 100).rounded()))%"
    }

    private func controlButton(
        _ title: String, systemImage: String, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 22, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(AuspexPalette.textSecondary)
        .help(title)
        .accessibilityLabel(title)
    }

    /// What the monitors mean. Five swatches, not seven: `idle` and `ended`
    /// are the absence of light and need no entry.
    private var legend: some View {
        HStack(spacing: 10) {
            ForEach(Self.legendEntries, id: \.label) { entry in
                HStack(spacing: 4) {
                    RoundedRectangle(cornerRadius: 1)
                        .fill(entry.color)
                        .frame(width: 7, height: 7)
                    Text(entry.label)
                        .auspexLabel(AuspexType.labelSmall)
                        .foregroundStyle(AuspexPalette.textTertiary)
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(AuspexPalette.panel.opacity(0.85))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .strokeBorder(AuspexPalette.hairline, lineWidth: 1)
        )
        .accessibilityHidden(true)
    }

    private static let legendEntries: [(label: String, color: Color)] = [
        ("Thinking", AuspexPalette.stateThinking),
        ("Tool", AuspexPalette.stateTool),
        ("Writing", AuspexPalette.stateWriting),
        ("Delegating", AuspexPalette.stateDelegating),
        ("Blocked", AuspexPalette.statePermission)
    ]

    private var emptyRoom: some View {
        VStack(spacing: 6) {
            Text("The office is empty")
                .font(AuspexType.display)
                .foregroundStyle(AuspexPalette.textSecondary)
            Text("A desk appears for every session Auspex can see.")
                .font(AuspexType.body)
                .foregroundStyle(AuspexPalette.textTertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(false)
    }
}

/// The map of the whole office, in the corner.
///
/// One `Canvas`, drawn from a value the scene publishes when it changes and at
/// no other time — a second SpriteKit view here would be a second animated
/// scene to pay for. Dragging on it scrubs the camera around the map, which is
/// the same gesture as clicking and is what people try first.
private struct SceneMinimapView: View {
    let overview: SceneOverview
    /// Called with a point in layout space.
    let onJump: (CGPoint) -> Void

    /// How much of the window the overview may take. Small enough to be
    /// furniture, large enough that a room is a few points across.
    private static let maximum = CGSize(width: 168, height: 116)

    var body: some View {
        let box = SceneMinimap.frame(for: overview.world, maximum: Self.maximum)
        Canvas(opaque: false) { context, size in
            let map = SceneMinimap(
                world: overview.world, in: CGRect(origin: .zero, size: size)
            )
            for room in overview.rooms {
                let rect = map.rect(room.rect).insetBy(dx: 0.5, dy: 0.5)
                guard rect.width > 0, rect.height > 0 else { continue }
                let path = Path(roundedRect: rect, cornerRadius: 1.5)
                context.fill(path, with: .color(room.tint.opacity(room.needsYou ? 0.85 : 0.5)))
                if room.isFocused {
                    context.stroke(path, with: .color(AuspexPalette.textPrimary), lineWidth: 1)
                }
            }
            // The window, drawn last so it is never hidden under a room.
            let viewport = map.rect(overview.viewport).intersection(
                CGRect(origin: .zero, size: size)
            )
            if !viewport.isNull, viewport.width > 0 {
                context.stroke(
                    Path(viewport.insetBy(dx: 0.5, dy: 0.5)),
                    with: .color(AuspexPalette.textPrimary.opacity(0.9)),
                    lineWidth: 1
                )
            }
        }
        .frame(width: box.width, height: box.height)
        .padding(4)
        .background(
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(AuspexPalette.panel.opacity(0.9))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .strokeBorder(AuspexPalette.hairline, lineWidth: 1)
        )
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    let map = SceneMinimap(
                        world: overview.world,
                        in: CGRect(x: 4, y: 4, width: box.width, height: box.height)
                    )
                    onJump(map.worldPoint(value.location))
                }
        )
        .help("The whole office. Click to go there.")
        .accessibilityHidden(true)
    }
}

/// The overlay's buttons, wired to the live scene.
///
/// A box of closures rather than a binding to the scene itself: SwiftUI owns
/// the button and AppKit owns the camera, and the only thing that has to cross
/// between them is "do this now".
@MainActor
final class SceneCommands {
    var fit: () -> Void = {}
    var zoomIn: () -> Void = {}
    var zoomOut: () -> Void = {}
    var setZoom: (CGFloat) -> Void = { _ in }
    /// Points the camera at a place on the map, in layout space.
    var jump: (CGPoint) -> Void = { _ in }
}

/// The `SKView` itself.
private struct OfficeSceneRepresentable: NSViewRepresentable {
    let board: BoardSnapshot
    let selected: SessionKey?
    let focusedProject: String?
    let reduceMotion: Bool
    let commands: SceneCommands
    let onSelect: (SessionKey?) -> Void
    let onFocusProject: (String?) -> Void
    let onOverview: (SceneOverview) -> Void

    func makeNSView(context: Context) -> OfficeSKView {
        let theme = SceneTheme.resolved(for: NSApplication.shared.effectiveAppearance)
        let scene = OfficeScene(theme: theme)
        let view = OfficeSKView(frame: CGRect(x: 0, y: 0, width: 900, height: 640))
        view.presentScene(scene)
        scene.onSelect = onSelect
        scene.onFocusProject = onFocusProject
        scene.onOverview = onOverview

        commands.fit = { [weak scene] in scene?.fitAll(animated: true) }
        commands.zoomIn = { [weak scene] in scene?.step(zoom: 1) }
        commands.zoomOut = { [weak scene] in scene?.step(zoom: -1) }
        commands.setZoom = { [weak scene] zoom in scene?.setZoom(zoom) }
        commands.jump = { [weak scene] point in scene?.jump(toLayoutPoint: point) }
        return view
    }

    func updateNSView(_ view: OfficeSKView, context: Context) {
        guard let scene = view.scene as? OfficeScene else { return }
        scene.onSelect = onSelect
        scene.onFocusProject = onFocusProject
        scene.onOverview = onOverview
        scene.update(
            board: board,
            selected: selected,
            focusedProject: focusedProject,
            reduceMotion: reduceMotion,
            theme: SceneTheme.resolved(for: view.effectiveAppearance)
        )
    }

    static func dismantleNSView(_ view: OfficeSKView, coordinator: ()) {
        view.stop()
    }
}

/// An `SKView` that knows when nobody is looking at it.
///
/// ## Why the pausing is here and not in the scene
///
/// SpriteKit keeps running a scene whose window is occluded, minimised, or
/// behind a full-screen app — a wall of animated desks would otherwise burn a
/// core to render into a surface nobody composites. Only the view can answer
/// "is this on screen", so the view owns the answer and pushes it down.
///
/// Thirty frames a second rather than sixty for the same reason the board
/// coalesces its snapshots at twenty: the fastest thing in the scene is a
/// typing hand at ten changes a second, and the difference between 30 and 60 Hz
/// on that is a difference nobody can see and everybody's fan can hear.
final class OfficeSKView: SKView {
    private var tracking: NSTrackingArea?

    override init(frame: CGRect) {
        super.init(frame: frame)
        preferredFramesPerSecond = 30
        ignoresSiblingOrder = true
        allowsTransparency = false
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(occlusionChanged),
            name: NSWindow.didChangeOcclusionStateNotification,
            object: nil
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("OfficeSKView is not archived") }

    deinit { NotificationCenter.default.removeObserver(self) }

    /// Releases the scene when SwiftUI takes the view away.
    func stop() {
        isPaused = true
        scene?.isPaused = true
        presentScene(nil)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow, .inVisibleRect],
            owner: self
        )
        addTrackingArea(area)
        tracking = area
    }

    override func mouseMoved(with event: NSEvent) {
        officeScene?.handleHover(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) {
        officeScene?.handleHover(at: nil)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updatePaused()
    }

    override func viewDidHide() {
        super.viewDidHide()
        updatePaused()
    }

    override func viewDidUnhide() {
        super.viewDidUnhide()
        updatePaused()
    }

    @objc private func occlusionChanged(_ note: Notification) {
        guard (note.object as? NSWindow) === window else { return }
        updatePaused()
    }

    private var officeScene: OfficeScene? { scene as? OfficeScene }

    private func updatePaused() {
        let onScreen = window?.occlusionState.contains(.visible) ?? false
        let visible = window != nil && !isHiddenOrHasHiddenAncestor && onScreen
        isPaused = !visible
        scene?.isPaused = !visible
    }
}

/// Renders the office to a PNG without a window.
///
/// The office is the one part of Auspex a screenshot has to show to explain,
/// and a screenshot taken by pointing a capture tool at a window is neither
/// reproducible nor safe for a public repository — it carries whatever was on
/// the machine that took it. This renders the demo board offscreen instead, so
/// `docs/screenshots/scene.png` is a build artefact with no real session,
/// no real path, and no real name in it.
enum SceneSnapshotRenderer {
    /// Renders `board` and writes a PNG to `url`.
    ///
    /// - Parameter scale: points per pixel. Two doubles every art pixel
    ///   exactly, which is what nearest-neighbour filtering wants; anything
    ///   fractional would put seams in the pixel grid.
    /// The window a focused render pretends to be looking through.
    static let windowSize = CGSize(width: 900, height: 640)

    @MainActor
    static func render(
        board: BoardSnapshot,
        to url: URL,
        scale: CGFloat = 2,
        focusing project: String? = nil,
        appearance: NSAppearance = NSAppearance(named: .darkAqua) ?? NSAppearance()
    ) throws {
        // Touching AppKit at all requires the shared application to exist; the
        // policy keeps it out of the Dock and off the menu bar while it does.
        NSApplication.shared.setActivationPolicy(.prohibited)

        let theme = SceneTheme.resolved(for: appearance)
        let scene = OfficeScene(theme: theme)
        // The board is applied before the view exists, because the view has to
        // be made the size of the building and only the laid-out scene knows
        // what that is.
        scene.update(
            board: board, selected: nil, focusedProject: nil, reduceMotion: true, theme: theme
        )

        let bounds = scene.contentBounds
        guard bounds.width > 1, bounds.height > 1 else {
            throw RenderError.emptyBoard
        }
        // Framed on one room, the picture is a window onto the map rather than
        // a picture of the whole map, so it is drawn at a window's size.
        let size = project == nil ? bounds.size : windowSize
        let view = SKView(
            frame: CGRect(x: 0, y: 0, width: size.width * scale, height: size.height * scale)
        )
        view.appearance = appearance
        view.presentScene(scene)
        let image = project == nil
            ? scene.render(view: view, scale: scale)
            : scene.render(view: view, scale: scale, window: size, focusing: project)
        guard let image else { throw RenderError.renderFailed }
        guard let data = pngData(from: image, background: theme.canvas) else {
            throw RenderError.encodingFailed
        }
        try data.write(to: url, options: .atomic)
    }

    /// The project key a name from the command line means.
    ///
    /// Matched on the last path component as well as in full, so a screenshot
    /// can be asked for by the name the sidebar shows rather than by a path
    /// nobody wants to type.
    @MainActor
    static func projectKey(named name: String, in board: BoardSnapshot) -> String? {
        var keys: [String] = []
        for session in board.sessions {
            guard let key = board.projectKey(for: session), !keys.contains(key) else { continue }
            keys.append(key)
        }
        if let exact = keys.first(where: { $0 == name }) { return exact }
        return keys.first { ($0 as NSString).lastPathComponent == name }
    }

    /// The demo board, folded to one instant.
    ///
    /// The same fabricated script the app replays with `--demo`, run forward
    /// through the reducer rather than in real time, so a screenshot is a pure
    /// function of a seed and an offset. Nothing here reads a harness store and
    /// every path in it is under `/Users/example`.
    @MainActor
    static func demoBoard(
        elapsed: TimeInterval,
        seed: UInt64 = DemoScript.defaultSeed
    ) -> BoardSnapshot {
        // A fixed instant, so two renders of the same offset are identical.
        let start = Date(timeIntervalSince1970: 1_767_225_600)
        let script = DemoScript.make(seed: seed, startedAt: start)
        let reducer = SessionStateReducer()
        var snapshots: [SessionKey: SessionSnapshot] = [:]

        for step in script.steps where step.offset <= elapsed {
            let key = step.event.session
            var current = snapshots[key]
            if current == nil, case .sessionStarted(let identity) = step.event.kind {
                current = SessionStateReducer.initialSnapshot(identity: identity)
            }
            guard let current else { continue }
            snapshots[key] = reducer.reduce(current, event: step.event)
        }

        return BoardSnapshot(
            generatedAt: start.addingTimeInterval(elapsed),
            sessions: Array(snapshots.values)
        )
    }

    enum RenderError: Error, CustomStringConvertible {
        case emptyBoard
        case renderFailed
        case encodingFailed

        var description: String {
            switch self {
            case .emptyBoard: "the board produced no desks to draw"
            case .renderFailed: "SpriteKit could not render the scene offscreen"
            case .encodingFailed: "the rendered image could not be encoded as PNG"
            }
        }
    }

    /// Flattens the rendered image onto the scene's own ground, which
    /// `texture(from:)` does not include.
    private static func pngData(from image: CGImage, background: NSColor) -> Data? {
        let width = image.width
        let height = image.height
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil,
                  width: width,
                  height: height,
                  bitsPerComponent: 8,
                  bytesPerRow: 0,
                  space: space,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else { return nil }
        context.setFillColor(background.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let flattened = context.makeImage() else { return nil }
        let rep = NSBitmapImageRep(cgImage: flattened)
        return rep.representation(using: .png, properties: [.compressionFactor: 1.0])
    }
}
