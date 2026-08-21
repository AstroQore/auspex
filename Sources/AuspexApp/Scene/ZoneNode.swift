import AgentSessionKit
import AgentSessionLive
import AppKit
import AuspexCore
import SpriteKit

/// One annex, as a strip of ground with a name on it.
///
/// ## Why an annex is not a floor
///
/// ``SceneFloor``'s node draws a project: a panel, a nameplate, and a line
/// under each row of desks, all of it in the office's own greys. An annex is
/// somewhere *else* — the point of walking to it is that a glance can tell
/// where somebody is without reading anything — so it is drawn in its own
/// ground tone with its own scenery, and the scenery is the tell. Trees mean
/// nobody down there is working.
///
/// The scenery is placed from the strip's own rectangle rather than at random,
/// which is what makes two renders of one board the same picture. It is also
/// why there is no `SKTileMapNode` here: a hundred grass tiles is a hundred
/// nodes for the scene to walk past every frame, and what they would buy over
/// a filled panel is texture nobody is looking at from the zoom this view is
/// read at.
@MainActor
final class ZoneNode: SKNode {
    private let ground = SKShapeNode()
    private let headerRule = SKShapeNode()
    private let title = SKLabelNode()
    private let counts = SKLabelNode()
    private let path = SKShapeNode()
    private let scenery = SKNode()
    private let gateSprite = SKSpriteNode()

    let zone: SceneZone
    private var lastFrame: CGRect = .null
    private var lastGate: CGPoint?
    private var lastSummary: String?

    init(zone: SceneZone, theme: SceneTheme) {
        self.zone = zone
        super.init()

        ground.fillColor = Self.groundColor(zone, theme: theme).withAlphaComponent(0.5)
        ground.strokeColor = theme.hairline
        ground.lineWidth = 1
        ground.zPosition = 0

        headerRule.strokeColor = theme.hairlineStrong
        headerRule.lineWidth = 1
        headerRule.zPosition = 1

        // The walkway. Drawn because a walk that follows an invisible line
        // looks like a bug and a walk that follows a drawn one looks like a
        // path — the same trick a garden uses on people.
        path.strokeColor = theme.stone.withAlphaComponent(0.55)
        path.lineWidth = 3
        path.lineCap = .round
        path.zPosition = 0.5

        title.horizontalAlignmentMode = .left
        title.verticalAlignmentMode = .center
        title.zPosition = 3
        counts.horizontalAlignmentMode = .right
        counts.verticalAlignmentMode = .center
        counts.zPosition = 3

        scenery.zPosition = 0.6
        gateSprite.anchorPoint = CGPoint(x: 0.5, y: 0)
        gateSprite.size = CGSize(width: 40, height: 44)
        gateSprite.zPosition = 0.7
        gateSprite.isHidden = true

        addChild(ground)
        addChild(path)
        addChild(headerRule)
        addChild(scenery)
        addChild(gateSprite)
        addChild(title)
        addChild(counts)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("ZoneNode is not archived") }

    /// Redraws the strip, and only when its shape actually changed.
    func update(
        area: SceneZoneArea,
        gate: CGPoint?,
        metrics: SceneMetrics,
        theme: SceneTheme
    ) {
        if area.frame != lastFrame || gate != lastGate {
            lastFrame = area.frame
            lastGate = gate
            // Layout space is y-down; the scene is y-up. One flip, here.
            let rect = SceneGeometry.scene(from: area.frame)
            ground.path = CGPath(
                roundedRect: rect, cornerWidth: 4, cornerHeight: 4, transform: nil
            )

            let headerY = rect.maxY - metrics.floorHeaderHeight
            let rule = CGMutablePath()
            rule.move(to: CGPoint(x: rect.minX, y: headerY))
            rule.addLine(to: CGPoint(x: rect.maxX, y: headerY))
            headerRule.path = rule

            let lane = CGMutablePath()
            lane.move(to: CGPoint(x: rect.minX + 10, y: -area.laneY))
            lane.addLine(to: CGPoint(x: rect.maxX - 10, y: -area.laneY))
            path.path = lane

            title.position = CGPoint(
                x: rect.minX + 12, y: rect.maxY - metrics.floorHeaderHeight / 2
            )
            counts.position = CGPoint(
                x: rect.maxX - 12, y: rect.maxY - metrics.floorHeaderHeight / 2
            )

            rebuildScenery(rect: rect, headerY: headerY, theme: theme)

            if let gate, zone == .garden {
                gateSprite.texture = PlaceholderArt.shared.gate()
                gateSprite.position = SceneGeometry.scene(from: gate)
                gateSprite.isHidden = false
            } else {
                gateSprite.isHidden = true
            }
        }

        if lastTitle != area.title {
            lastTitle = area.title
            title.attributedText = SceneText.label(
                area.title, size: 12, weight: .bold, color: theme.textPrimary
            )
            labelsNeedFitting = true
        }
        let summary = Self.summary(
            zone: zone, occupancy: area.occupancy, overflow: area.overflow
        )
        if lastSummary != summary {
            lastSummary = summary
            counts.attributedText = SceneText.label(
                summary, size: 9, color: theme.textTertiary
            )
            labelsNeedFitting = true
        }
    }

    /// Trees and hedges, placed from the strip's own rectangle.
    ///
    /// Along the top edge only, above the header rule's line of seats, so
    /// nothing is ever drawn over somebody. Rebuilt only when the strip
    /// changes shape, which is a handful of times a session.
    private func rebuildScenery(rect: CGRect, headerY: CGFloat, theme: SceneTheme) {
        scenery.removeAllChildren()
        guard zone == .garden, rect.width > 120 else { return }
        let art = PlaceholderArt.shared
        let spacing: CGFloat = 132
        var x = rect.minX + 30
        var index = 0
        while x < rect.maxX - 40 {
            let tall = index.isMultiple(of: 3)
            let tree = SKSpriteNode(texture: art.tree(tall: tall))
            tree.anchorPoint = CGPoint(x: 0.5, y: 0)
            tree.size = tall
                ? CGSize(width: 32, height: 52)
                : CGSize(width: 32, height: 38)
            tree.position = CGPoint(x: x, y: headerY - tree.size.height - 2)
            scenery.addChild(tree)

            if index.isMultiple(of: 2) {
                let hedge = SKSpriteNode(texture: art.bush())
                hedge.anchorPoint = CGPoint(x: 0.5, y: 0)
                hedge.size = CGSize(width: 24, height: 14)
                hedge.position = CGPoint(x: x + 54, y: headerY - 18)
                scenery.addChild(hedge)
            }
            x += spacing
            index += 1
        }
    }

    /// Keeps the nameplate the size it is on the screen rather than the size
    /// it is on the map, and drops what will not fit — the same bargain a
    /// room's nameplate makes.
    func setCameraScale(_ scale: CGFloat, width: CGFloat) {
        let clamped = max(1, min(2, scale))
        guard labelsNeedFitting || clamped != lastLabelScale || width != lastLabelWidth else {
            return
        }
        labelsNeedFitting = false
        lastLabelScale = clamped
        lastLabelWidth = width
        title.setScale(clamped)
        counts.setScale(clamped)
        title.isHidden = false
        counts.isHidden = false
        let insets = 24 * clamped
        let titleWidth = title.frame.width
        title.isHidden = titleWidth + insets > width
        counts.isHidden = title.isHidden
            || titleWidth + counts.frame.width + insets + 12 * clamped > width
    }

    private var lastLabelScale: CGFloat = 1
    private var lastLabelWidth: CGFloat = 0
    private var lastTitle: String?
    private var labelsNeedFitting = true

    private static func groundColor(_ zone: SceneZone, theme: SceneTheme) -> NSColor {
        switch zone {
        case .garden: theme.grass
        case .meeting: theme.carpet
        case .office: theme.panel
        }
    }

    /// What the strip's header says. A count and the word for what they are
    /// doing there, which is the same shape a room's header uses.
    ///
    /// The garden seats a bounded number per project and counts the rest, so
    /// its nameplate carries the remainder: `12 resting · +28 more`. A map
    /// that silently dropped them would be a map that lies about how much is
    /// out there, which is the one thing a picture of a machine must not do.
    private static func summary(zone: SceneZone, occupancy: Int, overflow: Int) -> String {
        switch zone {
        case .meeting: "\(occupancy) meeting"
        case .garden:
            overflow > 0
                ? "\(occupancy) resting · +\(overflow) more"
                : "\(occupancy) resting"
        case .office: "\(occupancy) live"
        }
    }
}

/// One delegating family's long table, with the projector behind it.
///
/// The projector is the table's version of a monitor: it carries the *parent*
/// session's state colour, so a table says what the handover is doing from the
/// distance a room says what a desk is doing. Without it a meeting would be
/// the one part of the map with no light in it, which on a board read by its
/// lighting means a part nobody looks at.
@MainActor
final class TableNode: SKNode {
    private let surface = SKSpriteNode()
    private let projector = SKSpriteNode()
    private let projection = SKSpriteNode()
    private let glow = SKSpriteNode()
    private let plate = SKLabelNode()

    private var lastFrame: CGRect = .null
    private var lastStateKey: String?
    private var lastTitle: String?

    init(theme: SceneTheme) {
        super.init()
        let art = PlaceholderArt.shared

        surface.texture = art.table()
        surface.anchorPoint = CGPoint(x: 0, y: 0)
        // Nine-slice: the ends stay the size they were drawn and the middle
        // repeats, so a table for two and a table for six have the same legs.
        surface.centerRect = PlaceholderArt.tableCenterRect
        surface.zPosition = 1

        projection.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        projection.colorBlendFactor = 1
        projection.color = theme.screenOff
        projection.zPosition = 0.8

        projector.texture = art.projectorScreen()
        projector.anchorPoint = CGPoint(x: 0.5, y: 0)
        projector.zPosition = 0.9

        glow.texture = art.glow()
        glow.blendMode = .add
        glow.colorBlendFactor = 1
        glow.alpha = 0
        glow.zPosition = 0.4

        plate.horizontalAlignmentMode = .left
        plate.verticalAlignmentMode = .center
        plate.zPosition = 2

        addChild(glow)
        addChild(projection)
        addChild(projector)
        addChild(surface)
        addChild(plate)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("TableNode is not archived") }

    func update(
        table: SceneTable,
        state: SessionState?,
        metrics: SceneMetrics,
        theme: SceneTheme,
        reduceMotion: Bool
    ) {
        if table.frame != lastFrame {
            lastFrame = table.frame
            let rect = SceneGeometry.scene(from: table.frame)
            let surfaceTop = rect.maxY - metrics.tableSurfaceTop
            let surfaceHeight = metrics.tableSurfaceBottom - metrics.tableSurfaceTop
            surface.position = CGPoint(
                x: rect.minX + metrics.tableHeadWidth - 16, y: surfaceTop - surfaceHeight
            )
            surface.size = CGSize(
                width: rect.width - metrics.tableHeadWidth - metrics.tableTailWidth + 56,
                height: surfaceHeight
            )
            // The screen stands *on* the far end of the table, which is where
            // a meeting room puts one and, more usefully, the one stretch of a
            // table the layout never allocates a chair on.
            let screenX = rect.maxX - metrics.tableTailWidth / 2 - 2
            projector.position = CGPoint(x: screenX, y: surfaceTop - 6)
            projector.size = CGSize(width: 52, height: 40)
            let screenCentre = CGPoint(x: screenX, y: surfaceTop + 18)
            projection.position = screenCentre
            projection.size = CGSize(width: 42, height: 19)
            glow.position = screenCentre
            glow.size = CGSize(width: 112, height: 112)
        }

        let key = state.map(SceneTheme.stateKey) ?? "vacant"
        if lastStateKey != key {
            lastStateKey = key
            projection.removeAllActions()
            glow.removeAllActions()
            guard let state else {
                projection.color = theme.screenOff
                glow.alpha = 0
                return
            }
            let color = theme.color(for: state)
            projection.color = color
            glow.color = color
            glow.alpha = 0.3
            guard !reduceMotion else { return }
            glow.run(
                .repeatForever(
                    .sequence([
                        .fadeAlpha(to: 0.46, duration: 1.2),
                        .fadeAlpha(to: 0.24, duration: 1.2)
                    ])
                ),
                withKey: "light"
            )
        }

        if lastTitle != table.title {
            lastTitle = table.title
            plate.attributedText = SceneText.label(
                table.title, size: 9, color: theme.textTertiary
            )
            let rect = SceneGeometry.scene(from: table.frame)
            plate.position = CGPoint(x: rect.minX + 10, y: rect.maxY - 12)
        }
    }
}

/// Somebody crossing the map.
///
/// ## Why a walk is not the desk moving
///
/// The obvious implementation — animate the desk node from where it was to
/// where it is going — is wrong twice. A desk does not go to the garden: the
/// *person* does, and the desk stays behind for them to come back to. And a
/// person who walks from a workstation to a bench is between two nodes that
/// both want to draw them, so one of them has to be told to stop, and the one
/// that knows is neither.
///
/// So a walk is a third node in a layer of its own, living exactly as long as
/// the walk: the desk draws itself empty, the bench draws itself empty, and
/// this walks between them. It carries the same ``AgentSprite`` both ends
/// would have drawn, so the person who arrives is the person who left.
///
/// Every leg is one `SKAction.move` with one walk strip playing over it. There
/// is no per-frame Swift in a walk at all — which is the property that lets
/// forty of them happen at once without the scene's budget noticing.
@MainActor
final class WalkerNode: SKNode {
    let session: SessionKey
    private let sprite: AgentSprite
    /// Where this walk is heading, so a retarget can tell whether it still is.
    private(set) var destination: String

    init(session: SessionKey, harness: Harness, destination: String, scale: CGFloat) {
        self.session = session
        self.destination = destination
        self.sprite = AgentSprite(harness: harness, key: session)
        super.init()
        sprite.zPosition = 0
        addChild(sprite)
        setScale(scale)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("WalkerNode is not archived") }

    /// Starts the walk. `onArrival` runs once, on the main actor, when the
    /// last leg finishes.
    func travel(
        legs: [SceneWalkLeg],
        speed: CGFloat,
        scale: CGFloat,
        reduceMotion: Bool,
        onArrival: @escaping @MainActor () -> Void
    ) {
        removeAllActions()
        setScale(scale)
        guard !legs.isEmpty, speed > 0, !reduceMotion else {
            onArrival()
            return
        }
        var steps: [SKAction] = []
        steps.reserveCapacity(legs.count * 2 + 1)
        for leg in legs {
            let direction = leg.direction
            steps.append(
                .run { [weak self] in
                    MainActor.assumeIsolated {
                        self?.sprite.walk(direction, reduceMotion: false)
                    }
                }
            )
            steps.append(
                .move(
                    to: SceneGeometry.scene(from: leg.to),
                    duration: TimeInterval(leg.distance / speed)
                )
            )
        }
        steps.append(
            .run {
                MainActor.assumeIsolated { onArrival() }
            }
        )
        run(.sequence(steps), withKey: "walk")
    }

    /// Where the walker is right now, on the floor plan. A retarget starts
    /// from here rather than from the seat it was aiming at.
    var layoutPosition: CGPoint { SceneGeometry.layout(from: position) }

    func retarget(to destination: String) { self.destination = destination }
}
