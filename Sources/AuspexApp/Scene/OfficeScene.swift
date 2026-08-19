import AgentSessionKit
import AgentSessionLive
import AppKit
import AuspexCore
import SpriteKit

/// The office: one room per project, one desk per session, one camera.
///
/// ## What this type owns and what it does not
///
/// The scene owns the world node, the camera, the backdrop, and every gesture.
/// It owns no layout — ``SceneLayout`` decides where desks go — and no
/// diffing — ``SceneDirector`` decides what to add and remove. What is left is
/// exactly the part that has to be a `SKScene`: input, the camera transform,
/// and the one flip from the layout's y-down plan into SpriteKit's y-up world.
///
/// ## Reading the room
///
/// The scene is meant to be *glanced at*, usually on a second display, usually
/// while its reader is doing something else. So the loudest channel is light: a
/// monitor's colour is its session's state and its rhythm is that state's
/// motion, and the spill lands on the desk and the agent, which makes a room of
/// forty desks legible as a pattern of lighting before any shape is resolved.
/// Exactly one thing is allowed to shout, and it is a session blocked on a
/// person: a hand up, a red bubble, and a strobing desk.
@MainActor
final class OfficeScene: SKScene {
    /// Everything laid out. Kept as one node so the camera has something to
    /// point at and the backdrop has something to sit behind.
    private let world = SKNode()
    private let backdrop = SKShapeNode()

    private let cameraController = SceneCamera()
    /// Built on first use so that `world` is already a stored constant when it
    /// is handed over — the alternative is constructing a throwaway director
    /// before `super.init` just to satisfy definite initialisation.
    private lazy var director = SceneDirector(world: world, theme: theme)

    private var theme: SceneTheme
    private var sessions: [SessionKey: SessionSnapshot] = [:]
    private var hovered: DeskNode?
    private var selected: SessionKey?
    /// The project the camera is bound to. Held so that the echo of a focus
    /// this scene asked for does not fly the camera a second time.
    private var focusedProject: String??

    /// Called when a person clicks a desk. The container turns it into
    /// `model.selectedKey`, which is the same value clicking a card sets — one
    /// selection, two ways in.
    var onSelect: ((SessionKey?) -> Void)?

    /// Called when a person clicks something that says which project they are
    /// looking at. The container turns it into
    /// `LiveBoardModel.focusedProjectKey`, which is the same value the sidebar
    /// sets — one focus, two ways in.
    var onFocusProject: ((String?) -> Void)?

    /// Called with a fresh picture for the minimap, at most once per rendered
    /// frame and only when something in it moved.
    var onOverview: ((SceneOverview) -> Void)?

    /// Whether the system asked for less motion.
    private(set) var reduceMotion = false

    /// How much of the world beyond the window keeps animating, so that a pan
    /// does not reveal a room in the middle of catching up.
    private static let cullMargin: CGFloat = 240

    /// How far a pinch has to travel to be worth a rung of the zoom ladder.
    /// A trackpad reports magnification in fractions of the view's width, and
    /// a quarter of that is about the size of a deliberate pinch.
    private static let pinchPerStep: CGFloat = 0.25

    init(theme: SceneTheme) {
        self.theme = theme
        super.init(size: CGSize(width: 900, height: 640))

        scaleMode = .resizeFill
        backgroundColor = theme.canvas
        PlaceholderArt.shared.use(theme: theme)

        backdrop.zPosition = -10
        backdrop.strokeColor = theme.grid
        backdrop.lineWidth = 1
        backdrop.fillColor = .clear

        world.addChild(backdrop)
        addChild(world)

        camera = cameraController.node
        addChild(cameraController.node)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("OfficeScene is not archived") }

    override func didChangeSize(_ oldSize: CGSize) {
        super.didChangeSize(oldSize)
        cameraController.setViewSize(size)
        if !cameraController.hasFitted { fitAll() }
        cameraDidChange()
    }

    // MARK: - Input from the app

    /// Brings the room up to date with one board frame.
    func update(
        board: BoardSnapshot,
        selected: SessionKey?,
        focusedProject: String?,
        reduceMotion: Bool,
        theme: SceneTheme
    ) {
        if self.theme.id != theme.id {
            self.theme = theme
            backgroundColor = theme.canvas
            backdrop.strokeColor = theme.grid
            director.apply(theme: theme)
        }
        if self.reduceMotion != reduceMotion {
            self.reduceMotion = reduceMotion
            director.reduceMotion = reduceMotion
            cameraController.reduceMotion = reduceMotion
        }

        var byKey: [SessionKey: SessionSnapshot] = [:]
        byKey.reserveCapacity(board.sessions.count)
        for session in board.sessions { byKey[session.key] = session }
        sessions = byKey

        let moved = director.apply(board)
        overviewIsStale = true
        if moved {
            cameraController.setContentRect(director.contentRect)
            rebuildBackdrop()
            if !cameraController.hasFitted { fitAll() }
            cameraDidChange()
        }

        // Focus before selection: a session that has just been picked in the
        // sidebar is usually in the project that was picked with it, and
        // framing the room first means the desk is already on screen by the
        // time the selection asks whether it needs to be.
        if self.focusedProject != .some(focusedProject) {
            self.focusedProject = .some(focusedProject)
            apply(focus: focusedProject, animated: true)
        }

        if self.selected != selected {
            self.selected = selected
            director.select(selected)
            if let selected { revealDesk(of: selected) }
        }
    }

    /// Frames the whole building.
    func fitAll(animated: Bool = false) {
        cameraController.setViewSize(size)
        cameraController.fit(animated: animated)
        cameraDidChange()
    }

    /// Steps the zoom by rungs of the ladder, for the overlay's buttons and
    /// the keyboard.
    func step(zoom steps: Int, around anchor: CGPoint? = nil) {
        cameraController.step(steps, around: anchor)
        cameraDidChange()
    }

    /// Goes to one of the named zooms, keeping the middle of the view fixed.
    func setZoom(_ zoom: CGFloat) {
        cameraController.setZoom(zoom, animated: true)
        cameraDidChange()
    }

    /// Points the camera at a place on the map, for a click on the minimap.
    /// The point arrives in layout space, which is what the minimap draws in.
    func jump(toLayoutPoint point: CGPoint) {
        cameraController.center(on: SceneGeometry.scene(from: point), animated: false)
        cameraDidChange()
    }

    /// Puts the camera on one session, for a double-click.
    func focus(on key: SessionKey, animated: Bool = true) {
        guard let rect = director.deskRect(for: key) else { return }
        cameraController.focus(on: rect.insetBy(dx: -110, dy: -80), animated: animated)
        cameraDidChange()
    }

    /// Frames one project's room, or the whole building when there is no
    /// project to frame.
    private func apply(focus project: String?, animated: Bool) {
        guard let project else {
            cameraController.fit(animated: animated)
            cameraDidChange()
            return
        }
        guard let rect = director.frame.focusRect(forProject: project) else { return }
        cameraController.focus(on: SceneGeometry.scene(from: rect), animated: animated)
        cameraDidChange()
    }

    /// Brings a selected session's desk on screen without changing how close
    /// the camera is — a selection is a request to see one session, not a
    /// request to be moved somewhere else.
    private func revealDesk(of key: SessionKey) {
        guard let rect = director.deskRect(for: key) else { return }
        guard !cameraController.viewport.showsAll(of: rect) else { return }
        cameraController.center(on: CGPoint(x: rect.midX, y: rect.midY), animated: true)
        cameraDidChange()
    }

    /// The current zoom, for the overlay's readout.
    var zoom: CGFloat { cameraController.zoom }

    /// The building's bounds in scene coordinates. What an offscreen render
    /// crops to.
    var contentBounds: CGRect { director.contentRect }

    // MARK: - The clock

    /// Everything that has to happen because the camera moved.
    ///
    /// Not done inside the camera: the camera's job is to know where it is,
    /// and what follows from that — which labels are legible, which desks are
    /// close enough to keep animating, what the minimap should draw — belongs
    /// to the scene that owns both halves.
    private func cameraDidChange() {
        director.setCameraScale(cameraController.node.xScale)
        overviewIsStale = true
    }

    private var overviewIsStale = true
    private var publishedOverview: SceneOverview?
    private var overviewRect: CGRect = .null

    /// Called by SpriteKit once per rendered frame — and, crucially, not at all
    /// while the scene is paused, which is what makes an off-screen office
    /// cost nothing at all rather than merely cost less.
    override func update(_ currentTime: TimeInterval) {
        super.update(currentTime)
        // The camera keeps moving for a third of a second after a flight is
        // started, so both questions are asked of where it actually is rather
        // than of where it was told to go.
        let live = cameraController.live
        director.cull(to: live.visibleRect, margin: Self.cullMargin)

        // A scene nobody is touching publishes nothing: the minimap is a
        // SwiftUI view, and handing it an equal value thirty times a second
        // would be thirty comparisons of every room for no redraw.
        let rect = live.visibleRect
        guard overviewIsStale || !rect.equalTo(overviewRect) else { return }
        overviewIsStale = false
        overviewRect = rect

        let overview = SceneOverview(
            frame: director.frame,
            counts: director.floorCounts,
            camera: live,
            focusedProject: focusedProject ?? nil
        )
        guard overview != publishedOverview else { return }
        publishedOverview = overview
        onOverview?(overview)
    }

    /// Renders the building offscreen, with no window involved.
    ///
    /// `SKView.texture(from:)` renders the scene the way the view would show
    /// it — through the camera, clipped to the view's bounds — so a snapshot is
    /// arranged by pointing the camera rather than by cropping afterwards: the
    /// view is made the size of the building, the camera is centred on it at
    /// exactly `scale`, and the backdrop is pulled in from its usual overhang
    /// so the grid stops where the building does.
    ///
    /// Two is the only scale worth using: nearest-neighbour filtering doubles
    /// an art pixel into four exactly, and anything fractional puts seams
    /// through the grid.
    /// Renders the office as a window `window` points across would show it,
    /// framed on one project.
    ///
    /// The whole-building render above is the picture of the map; this is the
    /// picture of the camera bound to a room, which is the other half of what
    /// the scene does and the half a static crop cannot show. The view is made
    /// `scale` times the window so that the art still doubles exactly, and the
    /// camera is told the window's size rather than the view's so that "fit
    /// this room" means what it means on a real screen.
    func render(
        view: SKView,
        scale: CGFloat,
        window: CGSize,
        focusing project: String?
    ) -> CGImage? {
        director.uncull()
        rebuildBackdrop()
        cameraController.setViewSize(window)
        let target: SceneViewport
        if let project, let rect = director.frame.focusRect(forProject: project) {
            target = cameraController.viewport.focused(on: SceneGeometry.scene(from: rect))
        } else {
            target = cameraController.viewport.fitted()
        }
        // The labels are sized for the window, not for the oversized view the
        // pixels are rendered into.
        director.setCameraScale(1 / target.zoom)
        cameraController.park(at: target.center, scale: 1 / (target.zoom * scale))
        return view.texture(from: self)?.cgImage()
    }

    func render(view: SKView, scale: CGFloat) -> CGImage? {
        let rect = director.contentRect
        rebuildBackdrop(padding: 0)
        let parkedPosition = cameraController.node.position
        let parkedScale = cameraController.node.xScale
        // A render frames the whole building at once, so whatever the live
        // camera had culled has to come back before the shutter opens — and
        // the nameplates, which are sized for wherever the camera happened to
        // be, go back to the one-to-one they are drawn at here.
        director.uncull()
        director.setCameraScale(1)
        cameraController.park(at: CGPoint(x: rect.midX, y: rect.midY), scale: 1 / scale)
        defer {
            cameraController.park(at: parkedPosition, scale: parkedScale)
            director.setCameraScale(parkedScale)
            rebuildBackdrop()
        }
        return view.texture(from: self)?.cgImage()
    }

    // MARK: - Gestures

    override func scrollWheel(with event: NSEvent) {
        // The platform convention: a plain wheel or two-finger scroll moves the
        // world, and the same gesture with a modifier zooms. Matching it
        // matters more than any argument about which is more useful here.
        guard let view else { return }
        if event.modifierFlags.contains(.command) {
            guard event.scrollingDeltaY != 0 else { return }
            step(zoom: event.scrollingDeltaY > 0 ? 1 : -1, around: scenePoint(for: event, in: view))
            return
        }
        cameraController.pan(by: CGVector(dx: -event.scrollingDeltaX, dy: -event.scrollingDeltaY))
        cameraDidChange()
    }

    /// A pinch is continuous and the zoom is a ladder, so the gesture
    /// accumulates until it has earned a rung. Resetting the accumulator on
    /// every step is what stops a slow pinch from crawling up the ladder one
    /// frame at a time.
    private var pinch: CGFloat = 0

    override func magnify(with event: NSEvent) {
        guard let view else { return }
        if event.phase == .began { pinch = 0 }
        pinch += event.magnification
        guard abs(pinch) >= Self.pinchPerStep else { return }
        let steps = Int((pinch / Self.pinchPerStep).rounded(.towardZero))
        pinch -= CGFloat(steps) * Self.pinchPerStep
        step(zoom: steps, around: scenePoint(for: event, in: view))
    }

    override func mouseDown(with event: NSEvent) {
        guard let view else { return }
        let point = scenePoint(for: event, in: view)
        guard let desk = desk(at: point), let key = desk.sessionKey else {
            // Clicking the floor clears the selection, the way clicking the
            // board's background does. Double-clicking one frames the room,
            // which is the fastest way from "the whole office" to "this
            // project" without going near the sidebar.
            if event.clickCount >= 2, let room = room(at: point) {
                focus(room: room)
            } else if event.clickCount == 1 {
                onSelect?(nil)
            }
            return
        }
        onSelect?(key)
        // Clicking somebody says which project is being looked at, the same
        // way clicking it in the sidebar does. The camera only moves if the
        // room is not already on screen — a click on a desk in the room the
        // reader is watching should not fly anywhere.
        if let room = director.room(for: key) {
            claimFocus(room.projectKey)
            let rect = SceneGeometry.scene(from: room.frame)
            if !cameraController.viewport.showsAll(of: rect) {
                cameraController.focus(on: rect, animated: true)
                cameraDidChange()
            }
        }
        if event.clickCount >= 2 { focus(on: key) }
    }

    /// Frames a room and tells the app which project that was, so the sidebar
    /// and the scene agree about what is being looked at.
    private func focus(room: SceneFloor) {
        claimFocus(room.projectKey)
        cameraController.focus(on: SceneGeometry.scene(from: room.frame), animated: true)
        cameraDidChange()
    }

    /// Records a focus this scene is about to perform itself, so the value
    /// coming back through the model is recognised as an echo rather than as a
    /// second request to fly somewhere.
    private func claimFocus(_ project: String?) {
        focusedProject = .some(project)
        onFocusProject?(project)
    }

    /// Called by the view, which owns the tracking area.
    func handleHover(at viewPoint: CGPoint?) {
        guard let viewPoint, let view else {
            hovered?.setHovered(false)
            hovered = nil
            return
        }
        let point = scenePoint(forViewPoint: viewPoint, in: view)
        let desk = desk(at: point)
        guard desk !== hovered else { return }
        hovered?.setHovered(false)
        hovered = desk

        guard let desk, let key = desk.sessionKey, let session = sessions[key] else { return }
        desk.setCameraScale(cameraController.node.xScale)
        desk.setHovered(true, title: Self.title(for: session), detail: Self.detail(for: session))
    }

    // MARK: - Hit testing

    private func desk(at point: CGPoint) -> DeskNode? {
        for node in nodes(at: point) {
            var current: SKNode? = node
            while let candidate = current {
                if let desk = candidate as? DeskNode { return desk }
                current = candidate.parent
            }
        }
        return nil
    }

    /// The room under a scene point. Asked of the layout rather than of the
    /// scene graph, because a room's panel is a shape node with a hit area
    /// that would answer for its whole bounding box either way.
    private func room(at point: CGPoint) -> SceneFloor? {
        director.frame.floor(at: SceneGeometry.layout(from: point))
    }

    /// Where an event happened, in scene coordinates.
    ///
    /// Computed from the camera rather than through `convertPoint(fromView:)`
    /// so that the answer is the same whatever the camera is doing: the scene
    /// is `resizeFill`, so one view point is one scene point before the camera
    /// scales it, and the camera's own transform is the whole conversion.
    private func scenePoint(for event: NSEvent, in view: SKView) -> CGPoint {
        scenePoint(forViewPoint: view.convert(event.locationInWindow, from: nil), in: view)
    }

    private func scenePoint(forViewPoint point: CGPoint, in view: SKView) -> CGPoint {
        cameraController.scenePoint(
            forViewOffset: CGPoint(
                x: point.x - view.bounds.midX,
                y: point.y - view.bounds.midY
            )
        )
    }

    // MARK: - Backdrop

    /// The same measured grid the board draws, over the same ground.
    ///
    /// It is doing the same job it does there: an unlit dark region with
    /// nothing in it cannot be told apart from a view that failed to draw, and
    /// a grid gives the space a scale. Rebuilt only when the building's bounds
    /// change, which is a handful of times a session.
    private func rebuildBackdrop(padding: CGFloat = 320) {
        let bounds = director.contentRect.insetBy(dx: -padding, dy: -padding)
        guard bounds.width > 0 else {
            backdrop.path = nil
            return
        }
        let spacing: CGFloat = 26
        let path = CGMutablePath()
        var x = (bounds.minX / spacing).rounded(.down) * spacing
        while x <= bounds.maxX {
            path.move(to: CGPoint(x: x, y: bounds.minY))
            path.addLine(to: CGPoint(x: x, y: bounds.maxY))
            x += spacing
        }
        var y = (bounds.minY / spacing).rounded(.down) * spacing
        while y <= bounds.maxY {
            path.move(to: CGPoint(x: bounds.minX, y: y))
            path.addLine(to: CGPoint(x: bounds.maxX, y: y))
            y += spacing
        }
        backdrop.path = path
    }

    // MARK: - Nameplate copy

    /// What the harness called this session, or the project it is in, or its
    /// own id — the same fallback chain a card's title uses, so hovering a desk
    /// and reading a card cannot disagree.
    private static func title(for session: SessionSnapshot) -> String {
        if let title = session.identity.title, !title.isEmpty { return title }
        if let project = BoardGrouping.projectName(for: session) { return project }
        return String(session.key.sessionID.prefix(12))
    }

    private static func detail(for session: SessionSnapshot) -> String {
        var parts = [session.key.harness.displayName, session.state.style.label]
        if session.isStale { parts.append("stale") }
        return parts.joined(separator: " · ")
    }
}
