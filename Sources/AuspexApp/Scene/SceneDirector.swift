import AgentSessionKit
import AgentSessionLive
import AppKit
import AuspexCore
import SpriteKit

/// Keeps the scene graph equal to the board, without rebuilding it.
///
/// ## Why this is a diff and not a render
///
/// The obvious shape — throw the world away and build it again from each
/// ``BoardSnapshot`` — is wrong here for a reason that has nothing to do with
/// allocation cost. Every animation in this scene is a `repeatForever` action
/// attached to a node, and a node that is recreated twenty times a second is a
/// node whose animation restarts twenty times a second: the whole room would
/// pulse in lockstep with the ingest pipeline and no rhythm would ever
/// complete. Persisting the nodes is what lets SpriteKit's own loop own the
/// motion.
///
/// So the director keeps three tables — desks by slot, floors by id, tethers by
/// parent-and-child — and each pass adds what is new, removes what is gone, and
/// leaves the rest alone. Geometry is compared as one value first: a
/// ``SceneFrame`` that is equal to the last one means no desk moved, no floor
/// resized, and no delegation appeared, which on a busy board is almost every
/// frame.
///
/// The one thing that does change constantly — what each agent is *doing* — is
/// pushed into ``DeskNode/apply(session:scale:theme:reduceMotion:)``, which
/// compares its own small value and returns without touching anything when the
/// session's look is unchanged.
@MainActor
final class SceneDirector {
    /// Everything laid out, in scene coordinates.
    private let world: SKNode
    private let floorLayer = SKNode()
    private let tetherLayer = SKNode()
    private let deskLayer = SKNode()

    private var layout = SceneLayout()
    private(set) var frame: SceneFrame = .empty

    private var desks: [String: DeskNode] = [:]
    private var floors: [String: FloorNode] = [:]
    private var tethers: [String: TetherNode] = [:]
    private var deskBySession: [SessionKey: DeskNode] = [:]

    private var theme: SceneTheme
    private var selected: SessionKey?

    /// Set from `NSWorkspace.shared.accessibilityDisplayShouldReduceMotion`.
    /// Pushed down rather than read per node, so one system setting cannot be
    /// answered two ways in one scene.
    var reduceMotion = false

    /// How long a desk takes to slide when the layout does move one. Long
    /// enough to follow with the eye, short enough not to feel like a
    /// transition.
    private static let moveDuration: TimeInterval = 0.34

    init(world: SKNode, theme: SceneTheme) {
        self.world = world
        self.theme = theme
        floorLayer.zPosition = 0
        tetherLayer.zPosition = 1
        deskLayer.zPosition = 2
        world.addChild(floorLayer)
        world.addChild(tetherLayer)
        world.addChild(deskLayer)
    }

    /// The building's bounds in scene coordinates, for the camera.
    var contentRect: CGRect {
        let rect = frame.contentRect
        guard rect.height > 0 else { return .zero }
        return CGRect(x: rect.minX, y: -rect.maxY, width: rect.width, height: rect.height)
    }

    /// Adopts a new appearance, rebuilding everything that baked a colour in.
    func apply(theme: SceneTheme) {
        guard self.theme.id != theme.id else { return }
        self.theme = theme
        PlaceholderArt.shared.use(theme: theme)
        for node in desks.values { node.removeFromParent() }
        for node in floors.values { node.removeFromParent() }
        desks.removeAll()
        floors.removeAll()
        deskBySession.removeAll()
        frame = .empty
    }

    /// Brings the scene up to date with one board frame.
    ///
    /// - Returns: `true` when the layout changed, so the camera knows whether
    ///   its bounds are still valid.
    @discardableResult
    func apply(_ board: BoardSnapshot) -> Bool {
        let next = layout.update(with: board)
        let moved = next != frame
        frame = next

        var byKey: [SessionKey: SessionSnapshot] = [:]
        byKey.reserveCapacity(board.sessions.count)
        for session in board.sessions { byKey[session.key] = session }

        if moved {
            syncDesks()
            syncTethers()
        }
        // Floors are synced every pass, not only when the geometry moved: a
        // header's tallies change when a session changes state, which does not
        // move a single desk. The node compares them itself and returns.
        syncFloors(sessions: byKey)
        syncContent(sessions: byKey)
        return moved
    }

    // MARK: Floors

    private func syncFloors(sessions: [SessionKey: SessionSnapshot]) {
        var live: Set<String> = []
        // Which sessions are on which floor, so a header can carry the same
        // tallies the board's section headers do.
        var byFloor: [Int: [SessionSnapshot]] = [:]
        for slot in frame.slots {
            guard let key = slot.session, let session = sessions[key] else { continue }
            byFloor[slot.floorIndex, default: []].append(session)
        }

        for floor in frame.floors {
            live.insert(floor.id)
            let node = floors[floor.id] ?? {
                let created = FloorNode(theme: theme)
                floors[floor.id] = created
                floorLayer.addChild(created)
                return created
            }()
            node.update(
                floor: floor,
                counts: BoardSnapshot.Counts(sessions: byFloor[floor.index] ?? []),
                metrics: layout.metrics,
                theme: theme
            )
        }

        for (id, node) in floors where !live.contains(id) {
            node.removeFromParent()
            floors.removeValue(forKey: id)
        }
    }

    // MARK: Desks

    private func syncDesks() {
        var live: Set<String> = []
        var bySession: [SessionKey: DeskNode] = [:]

        for slot in frame.slots {
            live.insert(slot.id)
            let scenePoint = CGPoint(x: slot.anchor.x, y: -slot.anchor.y)
            let node: DeskNode
            if let existing = desks[slot.id] {
                node = existing
                if existing.position != scenePoint {
                    existing.removeAction(forKey: "move")
                    if reduceMotion {
                        existing.position = scenePoint
                    } else {
                        let move = SKAction.move(to: scenePoint, duration: Self.moveDuration)
                        move.timingMode = .easeInEaseOut
                        existing.run(move, withKey: "move")
                    }
                }
            } else {
                node = DeskNode(slotID: slot.id, theme: theme)
                node.position = scenePoint
                desks[slot.id] = node
                deskLayer.addChild(node)
            }
            if let key = slot.session { bySession[key] = node }
        }

        for (id, node) in desks where !live.contains(id) {
            desks.removeValue(forKey: id)
            // A desk that has left the plan fades rather than blinking out —
            // the difference between an office closing for the night and a view
            // that dropped a frame.
            if reduceMotion {
                node.removeFromParent()
            } else {
                node.run(.sequence([.fadeOut(withDuration: 0.3), .removeFromParent()]))
            }
        }
        deskBySession = bySession
    }

    // MARK: Tethers

    private func syncTethers() {
        var live: Set<String> = []
        for tether in frame.tethers {
            live.insert(tether.id)
            let node = tethers[tether.id] ?? {
                let created = TetherNode(theme: theme)
                tethers[tether.id] = created
                tetherLayer.addChild(created)
                return created
            }()
            node.update(tether, reduceMotion: reduceMotion)
        }
        for (id, node) in tethers where !live.contains(id) {
            node.removeFromParent()
            tethers.removeValue(forKey: id)
        }
    }

    // MARK: Content

    private func syncContent(sessions: [SessionKey: SessionSnapshot]) {
        for slot in frame.slots {
            guard let node = desks[slot.id] else { continue }
            node.apply(
                session: slot.session.flatMap { sessions[$0] },
                scale: slot.scale,
                theme: theme,
                reduceMotion: reduceMotion
            )
            node.setSelected(slot.session != nil && slot.session == selected)
        }
    }

    // MARK: Lookups

    /// The desk `key` is sitting at.
    func desk(for key: SessionKey) -> DeskNode? { deskBySession[key] }

    /// Rings one desk and unrings the rest.
    func select(_ key: SessionKey?) {
        guard selected != key else { return }
        selected = key
        for (session, node) in deskBySession { node.setSelected(session == key) }
    }

    /// Passes the camera's zoom to every desk, so nameplates stay legible.
    func setCameraScale(_ scale: CGFloat) {
        for node in desks.values { node.setCameraScale(scale) }
    }
}

/// One project's room: a panel, a nameplate, and a floor line under each row.
///
/// The floor lines are what make a wrapped row read as another row of desks
/// rather than as desks floating at two heights. They are also the only thing
/// in the scene drawn per row rather than per desk, which is why a floor
/// rebuilds its shape only when the layout says its frame changed.
@MainActor
private final class FloorNode: SKNode {
    private let panel = SKShapeNode()
    private let headerRule = SKShapeNode()
    private let title = SKLabelNode()
    private let counts = SKLabelNode()
    private var lines: [SKShapeNode] = []
    private var lastFrame: CGRect = .null
    private var lastCounts: BoardSnapshot.Counts?

    init(theme: SceneTheme) {
        super.init()
        panel.fillColor = theme.panel.withAlphaComponent(0.45)
        panel.strokeColor = theme.hairline
        panel.lineWidth = 1
        panel.zPosition = 0

        headerRule.strokeColor = theme.hairlineStrong
        headerRule.lineWidth = 1
        headerRule.zPosition = 1

        title.horizontalAlignmentMode = .left
        title.verticalAlignmentMode = .center
        title.zPosition = 2
        counts.horizontalAlignmentMode = .right
        counts.verticalAlignmentMode = .center
        counts.zPosition = 2

        addChild(panel)
        addChild(headerRule)
        addChild(title)
        addChild(counts)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("FloorNode is not archived") }

    func update(
        floor: SceneFloor,
        counts tally: BoardSnapshot.Counts,
        metrics: SceneMetrics,
        theme: SceneTheme
    ) {
        if floor.frame != lastFrame {
            lastFrame = floor.frame
            // Layout space is y-down; the scene is y-up. This is the only place
            // in the renderer that flips a rectangle.
            let rect = CGRect(
                x: floor.frame.minX,
                y: -floor.frame.maxY,
                width: floor.frame.width,
                height: floor.frame.height
            )
            panel.path = CGPath(
                roundedRect: rect, cornerWidth: 4, cornerHeight: 4, transform: nil
            )

            let headerY = rect.maxY - metrics.floorHeaderHeight
            let rule = CGMutablePath()
            rule.move(to: CGPoint(x: rect.minX, y: headerY))
            rule.addLine(to: CGPoint(x: rect.maxX, y: headerY))
            headerRule.path = rule

            title.position = CGPoint(x: rect.minX + 12, y: rect.maxY - metrics.floorHeaderHeight / 2)
            self.counts.position = CGPoint(
                x: rect.maxX - 12, y: rect.maxY - metrics.floorHeaderHeight / 2
            )

            for line in lines { line.removeFromParent() }
            lines = (0..<floor.rowCount).map { row in
                let y = headerY - CGFloat(row + 1) * metrics.rowHeight
                let path = CGMutablePath()
                path.move(to: CGPoint(x: rect.minX + 8, y: y))
                path.addLine(to: CGPoint(x: rect.maxX - 8, y: y))
                let line = SKShapeNode(path: path)
                line.strokeColor = theme.hairlineStrong
                line.lineWidth = 1.5
                line.zPosition = 1
                addChild(line)
                return line
            }
        }

        title.attributedText = SceneText.label(
            floor.title, size: 12, weight: .bold, color: theme.textPrimary
        )
        if lastCounts != tally {
            lastCounts = tally
            self.counts.attributedText = SceneText.label(
                Self.summary(tally), size: 9, color: theme.textTertiary
            )
        }
    }

    /// Only the tallies worth acting on, and only when they are non-zero — the
    /// same rule the board's section headers follow, so the two views do not
    /// teach different habits.
    private static func summary(_ counts: BoardSnapshot.Counts) -> String {
        var parts: [String] = []
        if counts.waitingPermission > 0 { parts.append("\(counts.waitingPermission) blocked") }
        if counts.delegating > 0 { parts.append("\(counts.delegating) delegating") }
        parts.append("\(counts.live) live")
        return parts.joined(separator: " · ")
    }
}

/// A delegation: a dotted line from the agent that handed work over to the one
/// doing it.
///
/// Dotted rather than solid, and thin, because it is a relationship and not a
/// flow. It pulses only while the handover is what the parent is doing; a
/// finished delegation leaves a quiet line, which is what makes the pulsing one
/// worth looking at.
@MainActor
private final class TetherNode: SKShapeNode {
    private var lastFrom: CGPoint = .zero
    private var lastTo: CGPoint = .zero

    init(theme: SceneTheme) {
        super.init()
        strokeColor = theme.color(for: .delegating(children: 1)).withAlphaComponent(0.75)
        lineWidth = 1.5
        lineCap = .round
        zPosition = 1
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("TetherNode is not archived") }

    func update(_ tether: SceneTether, reduceMotion: Bool) {
        let from = CGPoint(x: tether.from.x + 26, y: -tether.from.y + 30)
        let to = CGPoint(x: tether.to.x - 20, y: -tether.to.y + 26)
        guard from != lastFrom || to != lastTo else { return }
        lastFrom = from
        lastTo = to

        let line = CGMutablePath()
        line.move(to: from)
        // A shallow arc rather than a straight line: two desks in the same row
        // would otherwise draw a horizontal rule through the monitors between
        // them.
        let lift = max(18, abs(to.x - from.x) * 0.28)
        line.addQuadCurve(
            to: to,
            control: CGPoint(x: (from.x + to.x) / 2, y: max(from.y, to.y) + lift)
        )
        path = line.copy(dashingWithPhase: 0, lengths: [3, 4])

        removeAllActions()
        guard !reduceMotion else {
            alpha = 0.8
            return
        }
        alpha = 0.45
        run(
            .repeatForever(
                .sequence([
                    .fadeAlpha(to: 0.95, duration: 0.55),
                    .fadeAlpha(to: 0.4, duration: 0.55)
                ])
            )
        )
    }
}
