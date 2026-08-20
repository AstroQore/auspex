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
    /// Above the furniture, because somebody walking past a bench walks in
    /// front of it.
    private let walkerLayer = SKNode()

    private var layout = SceneLayout()
    private(set) var frame: SceneFrame = .empty

    /// Every place somebody can be, office desks and annex seats alike, keyed
    /// by the layout's own id. One table because everything a place does —
    /// hover, selection, culling, the state light — it does the same way
    /// wherever it is.
    private var desks: [String: DeskNode] = [:]
    private var floors: [String: FloorNode] = [:]
    private var zones: [String: ZoneNode] = [:]
    private var tables: [String: TableNode] = [:]
    private var tethers: [String: TetherNode] = [:]
    private var deskBySession: [SessionKey: DeskNode] = [:]
    /// Where each desk stands, in scene coordinates, so culling does not have
    /// to ask a node for its position while it is animating toward one.
    private var deskRects: [String: CGRect] = [:]
    /// Where everything is on the floor plan, for the pointer. Rebuilt only
    /// when the layout moves, which on a busy board is almost never.
    private var hitIndex = SceneHitIndex.empty
    /// What each room tallied on the last frame. The minimap's colours.
    private(set) var floorCounts: [Int: BoardSnapshot.Counts] = [:]

    private var theme: SceneTheme
    private var selected: SessionKey?

    /// The rect the last cull was computed for, so a camera that has not moved
    /// costs nothing.
    private var culledTo: CGRect?

    /// Set from `NSWorkspace.shared.accessibilityDisplayShouldReduceMotion`.
    /// Pushed down rather than read per node, so one system setting cannot be
    /// answered two ways in one scene.
    var reduceMotion = false

    /// How long a desk takes to slide when the layout does move one. Long
    /// enough to follow with the eye, short enough not to feel like a
    /// transition.
    private static let moveDuration: TimeInterval = 0.34

    /// Who is between two places, and the node carrying them there.
    private var walkers: [SessionKey: WalkerNode] = [:]
    /// Where everybody was on the last frame, so a place that changed can be
    /// told apart from a place that moved.
    private var lastPlace: [SessionKey: SceneFrame.Place] = [:]
    /// The last board, kept so a walk that finishes between frames can put the
    /// person it delivered into their seat without waiting for the next one.
    private var sessions: [SessionKey: SessionSnapshot] = [:]
    /// Which annexes are switched on.
    private var options = SceneZoneOptions.all

    init(world: SKNode, theme: SceneTheme) {
        self.world = world
        self.theme = theme
        floorLayer.zPosition = 0
        tetherLayer.zPosition = 1
        deskLayer.zPosition = 2
        walkerLayer.zPosition = 3
        world.addChild(floorLayer)
        world.addChild(tetherLayer)
        world.addChild(deskLayer)
        world.addChild(walkerLayer)
    }

    /// The building's bounds in scene coordinates, for the camera.
    var contentRect: CGRect {
        let rect = frame.contentRect
        guard rect.height > 0 else { return .zero }
        return SceneGeometry.scene(from: rect)
    }

    /// Adopts a new appearance, rebuilding everything that baked a colour in.
    func apply(theme: SceneTheme) {
        guard self.theme.id != theme.id else { return }
        self.theme = theme
        PlaceholderArt.shared.use(theme: theme)
        for node in desks.values { node.removeFromParent() }
        for node in floors.values { node.removeFromParent() }
        for node in zones.values { node.removeFromParent() }
        for node in tables.values { node.removeFromParent() }
        for node in walkers.values { node.removeFromParent() }
        desks.removeAll()
        floors.removeAll()
        zones.removeAll()
        tables.removeAll()
        walkers.removeAll()
        lastPlace.removeAll()
        deskBySession.removeAll()
        deskRects.removeAll()
        culledTo = nil
        frame = .empty
    }

    /// Adopts a new set of annexes.
    ///
    /// Switching one off has to take its walkers with it: a walk in flight is
    /// heading for a bench that is about to stop existing, and letting it
    /// arrive would leave somebody standing on the map with nothing under
    /// them.
    func apply(zones options: SceneZoneOptions) {
        guard self.options != options else { return }
        self.options = options
        cancelEveryWalk()
    }

    /// Brings the scene up to date with one board frame.
    ///
    /// - Returns: `true` when the layout changed, so the camera knows whether
    ///   its bounds are still valid.
    @discardableResult
    func apply(_ board: BoardSnapshot, unseenDone: Set<SessionKey> = []) -> Bool {
        let next = layout.update(with: board, zones: options, unseenDone: unseenDone)
        let moved = next != frame
        frame = next

        var byKey: [SessionKey: SessionSnapshot] = [:]
        byKey.reserveCapacity(board.sessions.count)
        for session in board.sessions { byKey[session.key] = session }
        sessions = byKey

        if moved {
            syncDesks()
            syncTethers()
            hitIndex = SceneHitIndex(
                frame: frame,
                deskSize: DeskNode.hitSize,
                deskBaseline: DeskNode.hitBaseline
            )
            // Everything the cull decided is about rectangles that just moved.
            culledTo = nil
        }
        // Walks are started from the *difference* between two frames, and an
        // equal frame has no difference in it: a session cannot have changed
        // which seat it is in without the layout changing, because the seat is
        // part of the layout. So this is gated on `moved` — otherwise a board
        // ticking twenty times a second would rebuild a table of every
        // person's position twenty times a second to conclude, twenty times a
        // second, that nobody had moved.
        if moved { syncWalks(sessions: byKey) }
        // Floors are synced every pass, not only when the geometry moved: a
        // header's tallies change when a session changes state, which does not
        // move a single desk. The node compares them itself and returns.
        syncFloors(sessions: byKey)
        syncZones()
        syncContent(sessions: byKey)
        return moved
    }

    // MARK: The annexes

    private func syncZones() {
        var live: Set<String> = []
        for area in frame.zones {
            live.insert(area.id)
            let node = zones[area.id] ?? {
                let created = ZoneNode(zone: area.zone, theme: theme)
                zones[area.id] = created
                floorLayer.addChild(created)
                return created
            }()
            node.update(
                area: area,
                gate: frame.gate,
                metrics: frame.metrics,
                theme: theme
            )
            node.setCameraScale(lastCameraScale, width: area.frame.width)
        }
        for (id, node) in zones where !live.contains(id) {
            node.removeFromParent()
            zones.removeValue(forKey: id)
        }

        var liveTables: Set<String> = []
        for table in frame.tables {
            liveTables.insert(table.id)
            let node = tables[table.id] ?? {
                let created = TableNode(theme: theme)
                tables[table.id] = created
                floorLayer.addChild(created)
                return created
            }()
            node.update(
                table: table,
                state: sessions[table.head]?.state,
                metrics: frame.metrics,
                theme: theme,
                reduceMotion: reduceMotion
            )
        }
        for (id, node) in tables where !liveTables.contains(id) {
            node.removeFromParent()
            tables.removeValue(forKey: id)
        }
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

        var tallies: [Int: BoardSnapshot.Counts] = [:]
        for floor in frame.floors {
            live.insert(floor.id)
            let node = floors[floor.id] ?? {
                let created = FloorNode(theme: theme)
                floors[floor.id] = created
                floorLayer.addChild(created)
                return created
            }()
            let counts = BoardSnapshot.Counts(sessions: byFloor[floor.index] ?? [])
            tallies[floor.index] = counts
            node.update(
                floor: floor,
                counts: counts,
                metrics: layout.metrics,
                theme: theme
            )
            node.setCameraScale(lastCameraScale, width: floor.frame.width)
        }
        floorCounts = tallies

        for (id, node) in floors where !live.contains(id) {
            node.removeFromParent()
            floors.removeValue(forKey: id)
        }
    }

    // MARK: Desks

    private func syncDesks() {
        var live: Set<String> = []
        var bySession: [SessionKey: DeskNode] = [:]
        var rects: [String: CGRect] = [:]

        for slot in frame.slots {
            place(
                id: slot.id,
                kind: .desk,
                session: slot.session,
                anchor: slot.anchor,
                scale: slot.scale,
                live: &live,
                bySession: &bySession,
                rects: &rects
            )
        }
        // Seats after desks so that the node a session is *drawn* at wins the
        // `bySession` entry: while somebody is in the garden, "reveal their
        // desk" has to mean the bench they are actually on.
        for seat in frame.seats {
            place(
                id: seat.id,
                kind: seat.kind,
                session: seat.session,
                anchor: seat.anchor,
                scale: seat.scale,
                live: &live,
                bySession: &bySession,
                rects: &rects
            )
        }

        for (id, node) in desks where !live.contains(id) {
            desks.removeValue(forKey: id)
            // A desk that has left the plan fades rather than blinking out —
            // the difference between an office closing for the night and a view
            // that dropped a frame.
            if reduceMotion {
                node.removeFromParent()
            } else {
                node.isPaused = false
                node.isHidden = false
                node.run(.sequence([.fadeOut(withDuration: 0.3), .removeFromParent()]))
            }
        }
        deskBySession = bySession
        deskRects = rects
    }

    /// Adds, moves or keeps the node for one place on the map.
    ///
    /// Desks and seats go through the same function because a place is a
    /// place: it is drawn by a ``DeskNode``, it is culled by its rectangle,
    /// and it is hit-tested by the layout. What differs is the furniture, and
    /// that is decided once, when the node is built.
    private func place(
        id: String,
        kind: SceneSeatKind,
        session: SessionKey?,
        anchor: CGPoint,
        scale: CGFloat,
        live: inout Set<String>,
        bySession: inout [SessionKey: DeskNode],
        rects: inout [String: CGRect]
    ) {
        live.insert(id)
        let scenePoint = SceneGeometry.scene(from: anchor)
        rects[id] = Self.deskRect(at: scenePoint, scale: scale)
        let node: DeskNode
        if let existing = desks[id] {
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
            node = DeskNode(slotID: id, kind: kind, theme: theme)
            node.position = scenePoint
            node.setCameraScale(lastCameraScale)
            desks[id] = node
            deskLayer.addChild(node)
        }
        if let session { bySession[session] = node }
    }

    /// The area one workstation occupies, in scene coordinates.
    ///
    /// Generous on purpose: what it is for is deciding whether a desk is close
    /// enough to the window to keep animating, and a bubble over an agent's
    /// head reaching into view a frame before its desk does is exactly the
    /// kind of pop a cull is supposed to avoid.
    private static func deskRect(at point: CGPoint, scale: CGFloat) -> CGRect {
        let width = DeskNode.hitSize.width * scale
        let height = DeskNode.hitSize.height * scale + 40
        return CGRect(x: point.x - width / 2, y: point.y - 12, width: width, height: height)
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
            let inTransit = slot.session.map { walkers[$0] != nil } ?? false
            node.apply(
                session: slot.session.flatMap { sessions[$0] },
                seat: .desk,
                isAway: slot.isAway || inTransit,
                scale: slot.scale,
                theme: theme,
                reduceMotion: reduceMotion
            )
            node.setSelected(slot.session != nil && slot.session == selected)
        }
        for seat in frame.seats {
            guard let node = desks[seat.id] else { continue }
            let inTransit = seat.session.map { walkers[$0] != nil } ?? false
            node.apply(
                session: seat.session.flatMap { sessions[$0] },
                seat: seat.kind,
                isAway: inTransit,
                scale: seat.scale,
                theme: theme,
                reduceMotion: reduceMotion
            )
            node.setSelected(seat.session != nil && seat.session == selected)
        }
    }

    // MARK: Walking

    /// Starts, retargets and cancels walks from the difference between two
    /// frames.
    ///
    /// ## Why this compares places and not positions
    ///
    /// A desk slides when the office reflows, and that is not a walk — it is
    /// the furniture being rearranged, and it already has an animation. What
    /// is a walk is somebody being in a *different place*: at a table when
    /// they were at a desk, on a bench when they were at a table. The layout
    /// gives every place a stable id, so the two cases are told apart by
    /// comparing ids rather than by guessing from a distance.
    private func syncWalks(sessions: [SessionKey: SessionSnapshot]) {
        // A session that has left the board takes its walk with it: the seat
        // it was heading for is gone, and a walker delivering somebody to a
        // place that no longer exists would leave them standing on the map.
        for (key, walker) in walkers where sessions[key] == nil {
            walker.removeFromParent()
            walkers.removeValue(forKey: key)
        }

        guard !reduceMotion else {
            // Reduce Motion has no walking in it at all: a session appears in
            // its seat, which is the same information without the journey.
            cancelEveryWalk()
            lastPlace = Self.places(of: frame)
            return
        }

        let now = Self.places(of: frame)
        defer { lastPlace = now }
        for (key, place) in now {
            guard let was = lastPlace[key], was.id != place.id else { continue }
            guard let session = sessions[key] else { continue }
            // Where the walk actually starts: wherever a walk already in
            // flight had got to, so a session that changes its mind halfway
            // turns round rather than snapping back to its desk.
            let start = walkers[key]?.layoutPosition ?? was.anchor
            begin(
                walk: key,
                harness: session.key.harness,
                from: start,
                fromZone: walkers[key] == nil ? was.zone : zone(containing: start),
                to: place
            )
        }
    }

    /// Every session's place on one frame.
    private static func places(of frame: SceneFrame) -> [SessionKey: SceneFrame.Place] {
        var result: [SessionKey: SceneFrame.Place] = [:]
        result.reserveCapacity(frame.slots.count)
        for slot in frame.slots where slot.session != nil && !slot.isAway {
            guard let key = slot.session else { continue }
            result[key] = SceneFrame.Place(
                anchor: slot.anchor, scale: slot.scale, kind: .desk, id: slot.id
            )
        }
        for seat in frame.seats {
            guard let key = seat.session else { continue }
            result[key] = SceneFrame.Place(
                anchor: seat.anchor, scale: seat.scale, kind: seat.kind, id: seat.id
            )
        }
        return result
    }

    /// Which strip a layout point is in, for a walk that starts mid-journey.
    private func zone(containing point: CGPoint) -> SceneZone {
        frame.zones.last { $0.frame.contains(point) }?.zone ?? .office
    }

    private func begin(
        walk key: SessionKey,
        harness: Harness,
        from: CGPoint,
        fromZone: SceneZone,
        to place: SceneFrame.Place
    ) {
        let waypoints = SceneRoute.waypoints(
            from: from,
            to: place.anchor,
            lanes: (
                departure: frame.walkways.lane(fromZone),
                arrival: frame.walkways.lane(place.zone)
            ),
            trunk: frame.walkways.trunk
        )
        let legs = SceneRoute.legs(waypoints)
        guard !legs.isEmpty else {
            walkers.removeValue(forKey: key)?.removeFromParent()
            return
        }

        // A walk nobody can see is not worth animating. The office already
        // pays only for what is on screen; a walker that crossed a culled
        // corner of the map at thirty frames a second would be the one thing
        // in the scene whose cost did not depend on the camera.
        let travelled = SceneGeometry.scene(from: SceneRoute.bounds(of: waypoints))
        if let culledTo, !culledTo.intersects(travelled.insetBy(dx: -40, dy: -40)) {
            walkers.removeValue(forKey: key)?.removeFromParent()
            return
        }

        let walker: WalkerNode
        if let existing = walkers[key] {
            walker = existing
            walker.retarget(to: place.id)
        } else {
            walker = WalkerNode(
                session: key, harness: harness, destination: place.id, scale: place.scale
            )
            walker.position = SceneGeometry.scene(from: from)
            walkers[key] = walker
            walkerLayer.addChild(walker)
        }
        walker.travel(
            legs: legs,
            speed: frame.metrics.walkSpeed,
            scale: place.scale,
            reduceMotion: reduceMotion
        ) { [weak self, weak walker] in
            guard let self, let walker, walkers[key] === walker else { return }
            walker.removeFromParent()
            walkers.removeValue(forKey: key)
            // The person has arrived; the seat can draw them now.
            syncContent(sessions: sessions)
        }
    }

    /// Stops every walk and puts everybody where the layout says they are.
    private func cancelEveryWalk() {
        guard !walkers.isEmpty else { return }
        for walker in walkers.values { walker.removeFromParent() }
        walkers.removeAll()
        syncContent(sessions: sessions)
    }

    // MARK: Lookups

    /// The desk under a point on the floor plan.
    ///
    /// Asked of the layout rather than of the scene graph. `SKScene.nodes(at:)`
    /// walks every node in the office and allocates an array of what it finds,
    /// and the pointer asks this question faster than the office is drawn; the
    /// index answers it with a handful of rectangle tests and no allocation.
    func desk(atLayoutPoint point: CGPoint) -> DeskNode? {
        guard let hit = hitIndex.desk(at: point) else { return nil }
        return desks[hit.slotID]
    }

    /// The room under a point on the floor plan.
    func floor(atLayoutPoint point: CGPoint) -> SceneFloor? { hitIndex.floor(at: point) }

    /// The desk `key` is sitting at.
    func desk(for key: SessionKey) -> DeskNode? { deskBySession[key] }

    /// The room `key` is working in, when the board has put it in one.
    func room(for key: SessionKey) -> SceneFloor? {
        guard let slot = frame.slot(for: key) else { return nil }
        return frame.floors.first { $0.index == slot.floorIndex }
    }

    /// Where `key`'s desk is, in scene coordinates.
    func deskRect(for key: SessionKey) -> CGRect? {
        frame.slot(for: key).flatMap { deskRects[$0.id] }
    }

    // MARK: Culling

    /// Stops everything outside the window, and starts it again when it comes
    /// back.
    ///
    /// ## Why this exists
    ///
    /// Every desk carries two or three `repeatForever` actions — a screen
    /// pulsing, a hand typing, a bubble bobbing. SpriteKit does not render a
    /// node that is off screen, but it does keep *stepping its actions*, so an
    /// office of six hundred desks costs the same whether the camera is
    /// looking at four of them or at all of them. Pausing the subtree is what
    /// makes the cost of the scene a function of what is on screen, which is
    /// the performance property the whole view is judged on.
    ///
    /// Hiding as well as pausing is not redundant: a hidden subtree is skipped
    /// during the scene's traversal, not merely during its draw.
    ///
    /// - Parameters:
    ///   - visible: the camera's rectangle, in scene coordinates.
    ///   - margin: how much further than the window to keep things running, so
    ///     a slow pan does not reveal a room that has to catch up.
    func cull(to visible: CGRect, margin: CGFloat) {
        let rect = visible.insetBy(dx: -margin, dy: -margin)
        // A pan of a few points does not change anybody's answer, and this runs
        // once per rendered frame.
        if let culledTo, abs(culledTo.minX - rect.minX) < 8, abs(culledTo.minY - rect.minY) < 8,
           abs(culledTo.width - rect.width) < 8, abs(culledTo.height - rect.height) < 8 {
            return
        }
        culledTo = rect

        for (id, node) in desks {
            let onScreen = deskRects[id].map(rect.intersects) ?? true
            if node.isHidden == onScreen {
                node.isHidden = !onScreen
                node.isPaused = !onScreen
            }
        }
        for floor in frame.floors {
            guard let node = floors[floor.id] else { continue }
            let onScreen = rect.intersects(SceneGeometry.scene(from: floor.frame))
            if node.isHidden == onScreen {
                node.isHidden = !onScreen
                node.isPaused = !onScreen
            }
        }
        // The annexes are culled by the same rule as the rooms: an off-screen
        // garden is a strip of scenery and a pulsing projector, and a scene
        // that kept stepping them would be a scene whose cost was the size of
        // the map rather than the size of the window.
        for area in frame.zones {
            guard let node = zones[area.id] else { continue }
            let onScreen = rect.intersects(SceneGeometry.scene(from: area.frame))
            if node.isHidden == onScreen {
                node.isHidden = !onScreen
                node.isPaused = !onScreen
            }
        }
        for table in frame.tables {
            guard let node = tables[table.id] else { continue }
            let onScreen = rect.intersects(SceneGeometry.scene(from: table.frame))
            if node.isHidden == onScreen {
                node.isHidden = !onScreen
                node.isPaused = !onScreen
            }
        }
        for tether in frame.tethers {
            guard let node = tethers[tether.id] else { continue }
            let span = CGRect(
                x: min(tether.from.x, tether.to.x),
                y: min(tether.from.y, tether.to.y),
                width: abs(tether.to.x - tether.from.x),
                height: abs(tether.to.y - tether.from.y)
            ).insetBy(dx: -60, dy: -60)
            let onScreen = rect.intersects(SceneGeometry.scene(from: span))
            if node.isHidden == onScreen {
                node.isHidden = !onScreen
                node.isPaused = !onScreen
            }
        }
    }

    /// Puts everything back on screen, for the offscreen renderer — which
    /// frames the whole building at once and would otherwise photograph
    /// whatever the last live camera happened to be looking at.
    func uncull() {
        culledTo = nil
        for node in desks.values {
            node.isHidden = false
            node.isPaused = false
        }
        for node in floors.values {
            node.isHidden = false
            node.isPaused = false
        }
        for node in zones.values {
            node.isHidden = false
            node.isPaused = false
        }
        for node in tables.values {
            node.isHidden = false
            node.isPaused = false
        }
        for node in tethers.values {
            node.isHidden = false
            node.isPaused = false
        }
    }

    /// Puts everybody in their seat and takes the walkers off the map.
    ///
    /// A render is one instant of a board, and half a dozen people caught
    /// mid-stride between two places is a picture of neither. So a snapshot
    /// lands them first, which is also what Reduce Motion does.
    func settleWalks() {
        cancelEveryWalk()
        lastPlace = Self.places(of: frame)
    }

    /// Rings one desk and unrings the rest.
    func select(_ key: SessionKey?) {
        guard selected != key else { return }
        selected = key
        for (session, node) in deskBySession { node.setSelected(session == key) }
    }

    /// Passes the camera's zoom to everything that writes words, so that a
    /// label is measured in points on the screen rather than in points on the
    /// map.
    ///
    /// A room's nameplate drawn in world units is unreadable the moment the
    /// camera pulls back far enough to show why anybody wanted a map — which
    /// is the one time the name matters most.
    func setCameraScale(_ scale: CGFloat) {
        guard abs(scale - lastCameraScale) > 0.0001 else { return }
        lastCameraScale = scale
        for node in desks.values { node.setCameraScale(scale) }
        for floor in frame.floors {
            floors[floor.id]?.setCameraScale(scale, width: floor.frame.width)
        }
        for area in frame.zones {
            zones[area.id]?.setCameraScale(scale, width: area.frame.width)
        }
    }

    /// The room or annex `key` is in, when the map has put it in one.
    func area(for key: SessionKey) -> SceneZoneArea? {
        guard let seat = frame.seat(for: key) else { return nil }
        return frame.zones.last { $0.zone == seat.zone }
    }

    private var lastCameraScale: CGFloat = 1
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

        // Laying out attributed text is not free and a nameplate changes about
        // once a day, so both labels are written only when their words do.
        if lastTitle != floor.title {
            lastTitle = floor.title
            title.attributedText = SceneText.label(
                floor.title, size: 12, weight: .bold, color: theme.textPrimary
            )
            labelsNeedFitting = true
        }
        if lastCounts != tally {
            lastCounts = tally
            self.counts.attributedText = SceneText.label(
                Self.summary(tally), size: 9, color: theme.textTertiary
            )
            labelsNeedFitting = true
        }
    }

    /// Keeps the nameplate the size it is on the screen rather than the size
    /// it is on the map, and drops what will not fit.
    ///
    /// A room's name drawn in world units is a smudge at the zoom that makes a
    /// map worth having, which is exactly when knowing which room this is
    /// matters most. So the words are scaled against the camera — and because
    /// a room is only so wide, the tallies go first and then the name, until
    /// the room is what it is at that distance: a coloured rectangle, which is
    /// what the minimap in the corner is for.
    ///
    /// - Parameters:
    ///   - scale: the camera node's scale, which is world points per view
    ///     point.
    ///   - width: how wide the room is, in world points.
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
        // The 12-point insets the labels are positioned at, at this scale.
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
