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

    /// Whatever is carrying the office — the scroll view, when there is a
    /// window. `nil` for the offscreen renderer, which has no view to scroll
    /// and frames the building by pointing the camera at it directly.
    weak var host: SceneViewportHost?

    /// `true` once the camera has framed a non-empty building, so a first frame
    /// arriving after the view has been sized still gets fitted.
    private var hasFitted = false

    /// Where the pointer was last seen, in layout space, waiting to be acted on
    /// at the next drawn frame. `.some(nil)` means it left the view.
    private var pendingHover: CGPoint??
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
        viewSizeChanged(to: size)
    }

    /// The window changed size.
    ///
    /// The camera keeps its zoom and re-clamps, so the office is *re-laid out*
    /// at the new size rather than scaled to it — a wider window shows more
    /// office, not a bigger one. Called from the view during a live resize as
    /// well as from SpriteKit, because the two do not always agree about when
    /// a drag has changed the bounds.
    ///
    /// When a scroll view is carrying the office it is the clip view that knows
    /// how big the window is, and this only matters for the first fit and for
    /// the offscreen renderer.
    func viewSizeChanged(to size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        cameraController.setViewSize(size)
        if !hasFitted { fitAll() }
        cameraDidChange()
    }

    // MARK: - Input from the app

    /// Brings the room up to date with one board frame.
    func update(
        board: BoardSnapshot,
        selected: SessionKey?,
        focusedProject: String?,
        reduceMotion: Bool,
        theme: SceneTheme,
        zones: SceneZoneOptions = .all,
        attention: [SessionKey: AttentionState] = [:]
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
        }
        director.apply(zones: zones)

        var byKey: [SessionKey: SessionSnapshot] = [:]
        byKey.reserveCapacity(board.sessions.count)
        for session in board.sessions { byKey[session.key] = session }
        sessions = byKey

        let moved = director.apply(board, attention: attention)
        overviewIsStale = true
        if moved {
            cameraController.setContentRect(director.contentRect)
            host?.setWorld(director.frame.contentRect)
            rebuildBackdrop()
            if !hasFitted { fitAll() }
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

    // MARK: - Pointing the camera

    /// Where the camera is pointed and how close it is.
    ///
    /// The scroll view is the answer when there is one: it is what the reader's
    /// fingers moved, and asking anything else would be asking where the camera
    /// *was told* to go rather than where it is.
    var viewport: SceneViewport { host?.viewport ?? cameraController.viewport }

    /// The current zoom, for the overlay's readout.
    var zoom: CGFloat { viewport.zoom }

    /// The one way the camera moves.
    ///
    /// With a scroll view carrying the office the move is the scroll view's, so
    /// that the scrollers, the elastic edges and the camera cannot disagree;
    /// the camera follows on the next drawn frame. Without one — the offscreen
    /// renderer — the camera is written directly, because there is nothing else
    /// to write.
    private func setViewport(
        _ next: SceneViewport,
        animated: Bool = false,
        framingEverything: Bool = false
    ) {
        if let host {
            host.apply(
                next,
                animated: animated && !reduceMotion,
                framingEverything: framingEverything
            )
        } else {
            cameraController.mirror(next)
            cameraDidChange()
        }
    }

    /// Frames the whole building.
    func fitAll(animated: Bool = false) {
        cameraController.setViewSize(size)
        let current = viewport
        guard current.content.width > 0, current.size.width > 0 else { return }
        hasFitted = true
        setViewport(current.fitted(), animated: animated, framingEverything: true)
    }

    /// Steps the zoom by rungs of the ladder, for the overlay's buttons and
    /// the keyboard.
    func step(zoom steps: Int, around anchor: CGPoint? = nil) {
        setViewport(viewport.stepped(steps, around: anchor))
    }

    /// Goes to one of the named zooms, keeping the middle of the view fixed.
    func setZoom(_ zoom: CGFloat) {
        setViewport(viewport.zoomed(to: zoom), animated: true)
    }

    /// Points the camera at a place on the map, for a click on the minimap.
    /// The point arrives in layout space, which is what the minimap draws in.
    func jump(toLayoutPoint point: CGPoint) {
        setViewport(viewport.centered(on: SceneGeometry.scene(from: point)))
    }

    /// Puts the camera on one session, for a double-click.
    func focus(on key: SessionKey, animated: Bool = true) {
        guard let rect = director.deskRect(for: key) else { return }
        hasFitted = true
        setViewport(viewport.focused(on: rect.insetBy(dx: -110, dy: -80)), animated: animated)
    }

    /// Frames one project's room, or the whole building when there is no
    /// project to frame.
    private func apply(focus project: String?, animated: Bool) {
        guard let project else {
            fitAll(animated: animated)
            return
        }
        guard let rect = director.frame.focusRect(forProject: project) else { return }
        hasFitted = true
        setViewport(
            viewport.focused(on: SceneGeometry.scene(from: rect)), animated: animated
        )
    }

    /// Brings a selected session's desk on screen without changing how close
    /// the camera is — a selection is a request to see one session, not a
    /// request to be moved somewhere else.
    private func revealDesk(of key: SessionKey) {
        guard let rect = director.deskRect(for: key) else { return }
        let current = viewport
        guard !current.showsAll(of: rect) else { return }
        setViewport(
            current.centered(on: CGPoint(x: rect.midX, y: rect.midY)), animated: true
        )
    }

    /// The building's bounds in scene coordinates. What an offscreen render
    /// crops to.
    var contentBounds: CGRect { director.contentRect }

    /// The floor plan this scene is actually drawing.
    ///
    /// Not the same thing as running the board through a fresh ``SceneLayout``:
    /// the scene's copy knows who has already walked out of a door, and a test
    /// that pointed at a bench derived without that would be pointing at a
    /// bench this scene does not have.
    var map: SceneFrame { director.frame }

    /// The desk the pointer is on. For the tests that stand in for a hand.
    var hoveredSlotID: String? { hovered?.slotID }

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
        // The scroll view is where the reader is. It is read — and any flight
        // in progress advanced — immediately before the frame that will show
        // the result, which is what keeps the picture and the scrollers on the
        // same instant.
        if let host {
            host.advance(to: currentTime)
            if !hasFitted { fitAll() }
            cameraController.mirror(host.viewport)
            director.setCameraScale(cameraController.node.xScale)
        }
        // At most one hit test per drawn frame, however many times the pointer
        // moved between them.
        flushHover()

        let live = cameraController.viewport
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
        director.settleWalks()
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
    func render(view: SKView, scale: CGFloat) -> CGImage? {
        let rect = director.contentRect
        rebuildBackdrop(padding: 0)
        let parkedPosition = cameraController.node.position
        let parkedScale = cameraController.node.xScale
        // A render frames the whole building at once, so whatever the live
        // camera had culled has to come back before the shutter opens — and
        // the nameplates, which are sized for wherever the camera happened to
        // be, go back to the one-to-one they are drawn at here. Anybody caught
        // mid-stride is put in their seat: a render is one instant, and half a
        // walk is a picture of neither end of it.
        director.settleWalks()
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

    // MARK: - What the pointer is doing

    /// A two-finger double tap: frame the room under the pointer, or pull back
    /// to the whole map if it is already framed.
    ///
    /// The same toggle every smart zoom on this platform performs — in, then
    /// out again on the second tap — with "in" meaning the thing under the
    /// pointer rather than a fixed magnification.
    func smartZoom(atLayoutPoint point: CGPoint) {
        guard let room = room(atLayoutPoint: point) else {
            fitAll(animated: true)
            claimFocus(nil)
            return
        }
        let rect = SceneGeometry.scene(from: room.frame)
        let current = viewport
        let framed = current.focused(on: rect)
        if abs(framed.zoom - current.zoom) < 0.001, current.showsAll(of: rect) {
            fitAll(animated: true)
            claimFocus(nil)
        } else {
            focus(room: room)
        }
    }

    /// A click on the office, at a point on the floor plan.
    func click(atLayoutPoint point: CGPoint, clickCount: Int) {
        guard let desk = desk(atLayoutPoint: point), let key = desk.sessionKey else {
            // Clicking the floor clears the selection, the way clicking the
            // board's background does. Double-clicking one frames the room,
            // which is the fastest way from "the whole office" to "this
            // project" without going near the sidebar.
            if clickCount >= 2, let room = room(atLayoutPoint: point) {
                focus(room: room)
            } else if clickCount == 1 {
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
            if !viewport.showsAll(of: rect) {
                hasFitted = true
                setViewport(viewport.focused(on: rect), animated: true)
            }
        }
        if clickCount >= 2 { focus(on: key) }
    }

    /// Frames a room and tells the app which project that was, so the sidebar
    /// and the scene agree about what is being looked at.
    private func focus(room: SceneFloor) {
        claimFocus(room.projectKey)
        hasFitted = true
        setViewport(
            viewport.focused(on: SceneGeometry.scene(from: room.frame)), animated: true
        )
    }

    /// Records a focus this scene is about to perform itself, so the value
    /// coming back through the model is recognised as an echo rather than as a
    /// second request to fly somewhere.
    private func claimFocus(_ project: String?) {
        focusedProject = .some(project)
        onFocusProject?(project)
    }

    /// The pointer has moved, at a point on the floor plan — or left the view.
    ///
    /// Recorded rather than acted on. A trackpad delivers mouse-moved events
    /// several times faster than the office is drawn, and every one of them
    /// used to become a hit test whose answer nothing could see until the next
    /// frame; keeping the last one and answering it in ``update(_:)`` is the
    /// same picture for a fraction of the work.
    func hover(atLayoutPoint point: CGPoint?) {
        pendingHover = .some(point)
    }

    /// Acts on wherever the pointer was last seen, at most once per frame.
    private func flushHover() {
        guard let pending = pendingHover else { return }
        pendingHover = nil
        guard let point = pending else {
            hovered?.setHovered(false)
            hovered = nil
            director.hover(nil)
            return
        }
        let desk = desk(atLayoutPoint: point)
        guard desk !== hovered else { return }
        hovered?.setHovered(false)
        hovered = desk
        // Hovering is also what points the delegation arcs at a family — the
        // cheapest question a person can ask of this map, and the one it
        // answers with lines.
        director.hover(desk?.sessionKey)

        guard let desk, let key = desk.sessionKey, let session = sessions[key] else { return }
        desk.setCameraScale(cameraController.node.xScale)
        desk.setHovered(true, title: Self.title(for: session), detail: Self.detail(for: session))
    }

    // MARK: - Hit testing

    /// The desk under a point on the floor plan.
    private func desk(atLayoutPoint point: CGPoint) -> DeskNode? {
        director.desk(atLayoutPoint: point)
    }

    /// The room under a point on the floor plan.
    private func room(atLayoutPoint point: CGPoint) -> SceneFloor? {
        director.floor(atLayoutPoint: point)
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
