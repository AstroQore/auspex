import AgentSessionKit
import AgentSessionLive
import AppKit
import AuspexCore
import SpriteKit
import SwiftUI

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
    /// For the window hint's menu, which is the one control here that changes
    /// a stored setting rather than the camera.
    @Environment(AppEnvironment.self) private var environment
    @State private var commands = SceneCommands()
    /// Where the scene leaves its picture of the map.
    ///
    /// An observable box rather than a `@State` value: the scene publishes a
    /// new overview whenever the camera moves, and a value held here would
    /// invalidate *this* body — which would rebuild the representable and push
    /// the whole board back through the layout for every frame of a pan. Only
    /// the two small views that read it are invalidated instead.
    @State private var overview = SceneOverviewBox()

    var body: some View {
        // Read on this side of the representable on purpose: observation is
        // tracked in a `body`, and a value read only inside `updateNSView`
        // would never schedule the update that reads it.
        //
        // `board` rather than `rawBoard`: it is the frame with the person's
        // ignore rules already applied, so a session they told Auspex to stop
        // showing has no desk, and the office cannot disagree with the wall
        // about who is here.
        let board = model.board
        let selected = model.selectedKey
        // One property for every surface: the sidebar sets it, the wall keeps
        // that project's sections, and the camera flies to that room.
        let focused = model.focusedProjectKey
        // Which annexes are drawn, and who is sitting in the garden holding a
        // note. Both are read here rather than inside `updateNSView` for the
        // same reason `board` is: observation is tracked in a `body`.
        let zones = model.sceneZones
        let attention = model.attention

        ZStack(alignment: .topTrailing) {
            OfficeSceneRepresentable(
                board: board,
                selected: selected,
                focusedProject: focused,
                reduceMotion: reduceMotion || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
                zones: zones,
                attention: attention,
                commands: commands,
                onSelect: { model.selectedKey = $0 },
                onFocusProject: { model.focusedProjectKey = $0 },
                onOverview: { [overview] in overview.value = $0 }
            )
            .ignoresSafeArea()

            if board.sessions.isEmpty {
                emptyRoom
            }

            controls
                .padding(12)
        }
        .overlay(alignment: .bottomLeading) {
            VStack(alignment: .leading, spacing: 6) {
                // Above the legend rather than on the garden's nameplate: the
                // sessions the window is holding back have no bench and no
                // gate — they are not on this map at all — so the place to say
                // so is the map's own chrome, next to the garden it would
                // otherwise have filled.
                if let hint = model.olderHiddenHint { windowHint(hint) }
                legend
            }
            .padding(12)
        }
        .overlay(alignment: .bottomTrailing) {
            SceneMinimapView(overview: overview) { commands.jump($0) }
                .padding(12)
        }
        .background(AuspexPalette.canvas)
        // Switching to the board is the common case and SwiftUI takes the
        // representable away with it, but a mode switch that kept the view
        // alive would keep a scene rendering behind the cards — which is a
        // whole core spent on a picture nobody is looking at.
        .onDisappear { commands.pause() }
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

            SceneZoomControl(overview: overview, commands: commands)

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


    private func controlButton(
        _ title: String, systemImage: String, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 22, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.auspex)
        .foregroundStyle(AuspexPalette.textSecondary)
        .help(title)
        .accessibilityLabel(title)
    }

    /// What the recency window is keeping off the map, and the menu that
    /// widens it.
    private func windowHint(_ hint: String) -> some View {
        SessionWindowMenu(
            window: model.sessionWindow,
            hint: nil,
            onSelect: { environment.catalog.setSessionWindow($0) }
        ) {
            HStack(spacing: 5) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 9, weight: .semibold))
                Text(hint).auspexLabel(AuspexType.labelSmall)
            }
            .foregroundStyle(AuspexPalette.textTertiary)
            .fixedSize()
        }
        .padding(.horizontal, 8)
        .frame(height: 22)
        .background(
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(AuspexPalette.panel.opacity(0.85))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .strokeBorder(AuspexPalette.hairline, lineWidth: 1)
        )
        .help("Older sessions are in the store, not on the map. Widen to draw them.")
    }

    /// What the monitors mean, and what the garden's two rows mean.
    ///
    /// The last two entries are the ones that earn their space: `Idle` and
    /// `Ended` are both *unlit* on this map, and the difference between them is
    /// whether the terminal a person is about to type into still exists. The
    /// swatch cannot carry that, so the tooltip does — see ``StateCopy``.
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
                .help(entry.help)
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

    private static let legendEntries: [(label: String, color: Color, help: String)] = [
        ("Thinking", AuspexPalette.stateThinking, "Reasoning, with no tool open."),
        ("Tool", AuspexPalette.stateTool, "A tool call is running."),
        ("Writing", AuspexPalette.stateWriting, "The working tree is being changed."),
        (
            "Delegating", AuspexPalette.stateDelegating,
            "Waiting on the sub-agents it spawned, around a table."
        ),
        (
            "Needs you", AuspexPalette.statePermission,
            StateCopy.explanation(for: .waitingPermission(tool: nil))
                ?? "Blocked on a person."
        ),
        (
            "Idle", AuspexPalette.stateIdle,
            StateCopy.explanation(for: .idle) ?? "Nothing outstanding."
        ),
        (
            "Ended", AuspexPalette.stateEnded,
            StateCopy.explanation(for: .ended(reason: .exited)) ?? "Over."
        )
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

/// The zoom, and the four zooms a person can ask for by name.
///
/// A menu rather than a label because the presets are the only way to an exact
/// zoom, and somebody who has zoomed somewhere odd wants "100 %" more than
/// they want to count clicks back to it. Its own view so that a readout
/// changing during a pinch invalidates a readout rather than a scene.
private struct SceneZoomControl: View {
    let overview: SceneOverviewBox
    let commands: SceneCommands

    var body: some View {
        Menu {
            ForEach(SceneViewport.zoomPresets, id: \.self) { preset in
                Button(Self.percent(preset)) { commands.setZoom(preset) }
            }
        } label: {
            Text(Self.percent(overview.value.zoom))
                .auspexLabel(AuspexType.labelSmall)
                .monospacedDigit()
                .frame(width: 34, height: 16)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .foregroundStyle(AuspexPalette.textSecondary)
        .help("Zoom")
    }

    /// A zoom as a person reads it. Rounded, because `33 %` is what a third is
    /// called and `33.3 %` is what a spreadsheet calls it.
    private static func percent(_ zoom: CGFloat) -> String {
        "\(Int((zoom * 100).rounded()))%"
    }
}

/// The map of the whole office, in the corner.
///
/// One `Canvas`, drawn from a value the scene publishes when it changes and at
/// no other time — a second SpriteKit view here would be a second animated
/// scene to pay for. Dragging on it scrubs the camera around the map, which is
/// the same gesture as clicking and is what people try first.
///
/// It shows up when there is something to navigate and disappears when the
/// window already shows the whole office, because a map of what you are
/// looking at is furniture rather than information.
private struct SceneMinimapView: View {
    let overview: SceneOverviewBox
    /// Called with a point in layout space.
    let onJump: (CGPoint) -> Void

    var body: some View {
        if overview.value.isWorthDrawing {
            map(overview.value)
        }
    }

    /// How much of the window the overview may take. Small enough to be
    /// furniture, large enough that a room is a few points across.
    private static let maximum = CGSize(width: 168, height: 116)

    private func map(_ overview: SceneOverview) -> some View {
        let box = SceneMinimap.frame(for: overview.world, maximum: Self.maximum)
        return Canvas(opaque: false) { context, size in
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
    /// Stops the clock, for the moment SwiftUI takes the view off screen
    /// without taking it away.
    var pause: () -> Void = {}
}

/// The canvas itself: a scroll view over an `SKView`.
private struct OfficeSceneRepresentable: NSViewRepresentable {
    let board: BoardSnapshot
    let selected: SessionKey?
    let focusedProject: String?
    let reduceMotion: Bool
    let zones: SceneZoneOptions
    let attention: [SessionKey: AttentionState]
    let commands: SceneCommands
    let onSelect: (SessionKey?) -> Void
    let onFocusProject: (String?) -> Void
    let onOverview: (SceneOverview) -> Void

    func makeNSView(context: Context) -> SceneCanvasView {
        let theme = SceneTheme.resolved(for: NSApplication.shared.effectiveAppearance)
        let scene = OfficeScene(theme: theme)
        let view = SceneCanvasView(
            scene: scene, frame: CGRect(x: 0, y: 0, width: 900, height: 640)
        )
        scene.onSelect = onSelect
        scene.onFocusProject = onFocusProject
        scene.onOverview = onOverview

        commands.fit = { [weak scene] in scene?.fitAll(animated: true) }
        commands.zoomIn = { [weak scene] in scene?.step(zoom: 1) }
        commands.zoomOut = { [weak scene] in scene?.step(zoom: -1) }
        commands.setZoom = { [weak scene] zoom in scene?.setZoom(zoom) }
        commands.jump = { [weak scene] point in scene?.jump(toLayoutPoint: point) }
        commands.pause = { [weak view] in view?.suspend() }
        return view
    }

    func updateNSView(_ view: SceneCanvasView, context: Context) {
        // Being asked to update is proof the scene is the mode on screen.
        view.refreshPaused()
        let scene = view.scene
        scene.onSelect = onSelect
        scene.onFocusProject = onFocusProject
        scene.onOverview = onOverview
        scene.update(
            board: board,
            selected: selected,
            focusedProject: focusedProject,
            reduceMotion: reduceMotion,
            theme: SceneTheme.resolved(for: view.effectiveAppearance),
            zones: zones,
            attention: attention
        )
    }

    static func dismantleNSView(_ view: SceneCanvasView, coordinator: ()) {
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
    /// Whether a gesture is in flight, which is the one time the office is
    /// worth drawing at the display's rate.
    private var isInteracting = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        preferredFramesPerSecond = Self.framesPerSecond
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
        suspend()
        presentScene(nil)
    }

    /// Stops the clock, whoever asked.
    ///
    /// Three things rather than one, because each covers a different way the
    /// scene could keep costing something: `isPaused` on the view stops the
    /// render loop, `isPaused` on the scene stops every `SKAction` in it, and
    /// the frame rate is dropped so that even a run loop that somehow ticks is
    /// ticking once a second rather than thirty times.
    func suspend() {
        isPaused = true
        scene?.isPaused = true
        preferredFramesPerSecond = 1
    }

    /// Recomputes whether the scene should be running, from the window.
    ///
    /// Called on every SwiftUI update as well as from the notifications,
    /// because "is this view on screen" has more ways of changing than there
    /// are notifications for it — a mode switch that leaves the view alive is
    /// the one that costs a core.
    func refreshPaused() { updatePaused() }

    /// Says whether a gesture is in flight.
    ///
    /// The office rests at thirty frames a second — the fastest thing in it is
    /// a typing hand at ten changes a second — but a *map moving under the
    /// fingers* is judged by a different standard, and thirty frames of a pan
    /// is the one place the difference is visible. So the rate goes up for the
    /// length of a gesture and comes straight back down; the canvas stops
    /// asking a few hundred milliseconds after the last event, so nothing is
    /// left paying for it.
    func setInteracting(_ interacting: Bool) {
        guard isInteracting != interacting else { return }
        isInteracting = interacting
        guard !isPaused else { return }
        preferredFramesPerSecond = interacting ? Self.gestureFramesPerSecond : Self.framesPerSecond
    }

    // MARK: - Live resize

    /// Keeps the office laid out at the window's size while the window is
    /// being dragged, instead of scaling the last frame and catching up when
    /// the drag stops.
    ///
    /// ## What is actually wrong without this
    ///
    /// A Metal layer's drawable is the size it was when it was drawn. As the
    /// window grows, AppKit stretches that drawable to the new bounds until
    /// another frame arrives, so the office appears to zoom and then snap
    /// back — the single most "not native" thing a Metal-backed view does.
    /// `presentsWithTransaction` makes the layer present its drawable inside
    /// the same Core Animation transaction that resizes it, so the frame and
    /// the bounds change together; it costs a synchronisation per frame, so it
    /// is switched on for the drag and off again afterwards.
    ///
    /// The other half is the camera: ``SceneCamera/setViewSize(_:)`` keeps the
    /// zoom and re-clamps, so a wider window shows *more office* rather than a
    /// bigger office. Nothing is deferred to the end of the drag, so there is
    /// nothing to jump when it ends.
    override func viewWillStartLiveResize() {
        super.viewWillStartLiveResize()
        setPresentsWithTransaction(true)
    }

    override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        setPresentsWithTransaction(false)
        // The scene has been following the size all along; this is only the
        // last one, and it lands on a size it has already been given.
        officeScene?.viewSizeChanged(to: bounds.size)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        officeScene?.viewSizeChanged(to: newSize)
    }

    /// Every Metal layer under this view. SpriteKit does not promise where its
    /// layer is, or that there is one, so this walks and tolerates nothing.
    private func setPresentsWithTransaction(_ enabled: Bool) {
        func walk(_ layer: CALayer?) {
            guard let layer else { return }
            if let metal = layer as? CAMetalLayer { metal.presentsWithTransaction = enabled }
            for sublayer in layer.sublayers ?? [] { walk(sublayer) }
        }
        walk(layer)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updatePaused()
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
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
        let visible = window != nil && superview != nil
            && !isHiddenOrHasHiddenAncestor && onScreen
        guard visible else {
            suspend()
            return
        }
        preferredFramesPerSecond = isInteracting
            ? Self.gestureFramesPerSecond : Self.framesPerSecond
        isPaused = false
        scene?.isPaused = false
    }

    /// Thirty rather than sixty for the same reason the board coalesces its
    /// snapshots at twenty: the fastest thing in the scene is a typing hand at
    /// ten changes a second.
    private static let framesPerSecond = 30
    /// What a gesture gets, for as long as it lasts.
    private static let gestureFramesPerSecond = 60
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
        zones: SceneZoneOptions = .all,
        attention: [SessionKey: AttentionState] = [:],
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
            board: board,
            selected: nil,
            focusedProject: nil,
            reduceMotion: true,
            theme: theme,
            zones: zones,
            attention: attention
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
        let now = start.addingTimeInterval(elapsed)
        let script = DemoScript.make(seed: seed, startedAt: start)
        let reducer = SessionStateReducer(staleAfter: DemoScript.staleAfter)
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

        // Staleness is the one derived value that changes because time passed
        // rather than because something happened, and folding events alone can
        // never produce it: every `reduce` recomputes it against the event's
        // own instant, which is by definition not silent. A live board has a
        // tick to do this on; a still has to do it here, or no render can ever
        // show a session that went quiet — a state the scene draws.
        for (key, snapshot) in snapshots {
            snapshots[key] = reducer.refreshStaleness(snapshot, now: now)
        }

        return BoardSnapshot(generatedAt: now, sessions: Array(snapshots.values))
    }

    /// What the demo board's sessions are signalling.
    ///
    /// The waiting bench's whole point is that this is visible, and it is the
    /// one thing about a board no harness store holds — so the demo says it
    /// out loud in ``DemoScript/notices(now:)``, and the same derivation the
    /// live board runs answers from that. A renderer has no store, which is
    /// exactly why the notices are a value rather than only rows in one.
    @MainActor
    static func demoAttention(_ board: BoardSnapshot) -> [SessionKey: AttentionState] {
        let notices = DemoScript.notices(now: board.generatedAt)
        var attention: [SessionKey: AttentionState] = [:]
        for session in board.sessions {
            let state = TaskLedger.attention(
                of: session,
                notice: notices[session.key],
                acknowledgedAt: nil,
                now: board.generatedAt
            )
            guard state.isSignalling else { continue }
            attention[session.key] = state
        }
        return attention
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
