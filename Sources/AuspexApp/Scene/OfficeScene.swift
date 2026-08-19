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

    /// Called when a person clicks a desk. The container turns it into
    /// `model.selectedKey`, which is the same value clicking a card sets — one
    /// selection, two ways in.
    var onSelect: ((SessionKey?) -> Void)?

    /// Whether the system asked for less motion.
    private(set) var reduceMotion = false

    /// How much a scroll wheel notch or a `+` button changes the zoom.
    private static let zoomStep: CGFloat = 1.22

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
    }

    // MARK: - Input from the app

    /// Brings the room up to date with one board frame.
    func update(
        board: BoardSnapshot,
        selected: SessionKey?,
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
        }

        var byKey: [SessionKey: SessionSnapshot] = [:]
        byKey.reserveCapacity(board.sessions.count)
        for session in board.sessions { byKey[session.key] = session }
        sessions = byKey

        let moved = director.apply(board)
        if moved {
            cameraController.setContentRect(director.contentRect)
            rebuildBackdrop()
            if !cameraController.hasFitted { fitAll() }
        }

        if self.selected != selected {
            self.selected = selected
            director.select(selected)
        }
    }

    /// Frames the whole building.
    func fitAll(animated: Bool = false) {
        cameraController.setViewSize(size)
        cameraController.fit(animated: animated)
        director.setCameraScale(cameraController.node.xScale)
    }

    /// Steps the zoom, for the overlay's buttons and the keyboard.
    func step(zoom factor: CGFloat) {
        cameraController.zoom(by: factor)
        director.setCameraScale(cameraController.node.xScale)
    }

    /// Puts the camera on one session, for a double-click or a selection made
    /// on the board.
    func focus(on key: SessionKey, animated: Bool = true) {
        guard let desk = director.desk(for: key) else { return }
        cameraController.center(on: desk.position, animated: animated)
    }

    /// The current zoom, for the overlay's readout.
    var zoom: CGFloat { cameraController.zoom }

    /// The building's bounds in scene coordinates. What an offscreen render
    /// crops to.
    var contentBounds: CGRect { director.contentRect }

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
        cameraController.node.removeAllActions()
        cameraController.node.position = CGPoint(x: rect.midX, y: rect.midY)
        cameraController.node.setScale(1 / scale)
        defer {
            cameraController.node.position = parkedPosition
            cameraController.node.setScale(parkedScale)
            rebuildBackdrop()
        }
        return view.texture(from: self)?.cgImage()
    }

    // MARK: - Gestures

    override func scrollWheel(with event: NSEvent) {
        // The platform convention: a plain wheel or two-finger scroll moves the
        // world, and the same gesture with a modifier zooms. Matching it
        // matters more than any argument about which is more useful here.
        if event.modifierFlags.contains(.command) {
            step(zoom: event.scrollingDeltaY > 0 ? Self.zoomStep : 1 / Self.zoomStep)
            return
        }
        cameraController.pan(by: CGVector(dx: -event.scrollingDeltaX, dy: -event.scrollingDeltaY))
    }

    override func magnify(with event: NSEvent) {
        step(zoom: 1 + event.magnification)
    }

    override func mouseDown(with event: NSEvent) {
        guard let view else { return }
        let point = scenePoint(for: event, in: view)
        guard let desk = desk(at: point), let key = desk.sessionKey else {
            // Clicking the floor clears the selection, the way clicking the
            // board's background does.
            if event.clickCount == 1 { onSelect?(nil) }
            return
        }
        onSelect?(key)
        if event.clickCount >= 2 { focus(on: key) }
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
