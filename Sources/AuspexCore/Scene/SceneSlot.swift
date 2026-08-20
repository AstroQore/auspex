import AgentSessionLive
import CoreGraphics
import Foundation

/// The floor plan of the office, in scene points.
///
/// Every distance the scene view draws with is here, and none of it depends on
/// the size of the window. That is deliberate: the layout is computed once per
/// frame in a fixed coordinate space and the *camera* is what adapts to the
/// viewport. A layout that reflowed when a person dragged the split view would
/// move every desk under their cursor, and a desk that moves is a desk they
/// have to find again.
///
/// Distances are expressed two ways. Horizontal space inside a floor is
/// measured in **units**, where one unit is ``cellWidth`` — one full-size
/// workstation. Everything else is points. Units exist so that the wrap rule
/// ("a floor is ``rowUnits`` wide") stays readable when a bay is 1.62 units
/// because its agent has one subagent.
public struct SceneMetrics: Sendable, Equatable {
    /// The width of one full-size workstation.
    public var cellWidth: CGFloat
    /// The height of one row of desks, floor line to floor line.
    public var rowHeight: CGFloat
    /// How much of a unit a subagent's desk occupies. Smaller than one, which
    /// is what makes a delegated session read as *smaller* rather than as
    /// another peer.
    public var childUnit: CGFloat
    /// How wide a floor is before its desks wrap onto another row.
    public var rowUnits: CGFloat
    /// The margin around the whole building.
    public var margin: CGFloat
    /// The strip at the top of a floor that carries its name.
    public var floorHeaderHeight: CGFloat
    /// The air between two floors.
    public var floorGap: CGFloat
    /// The scale a subagent's whole workstation is drawn at.
    public var childScale: CGFloat
    /// The narrowest a floor is allowed to be, in units. A room with one desk
    /// in it still has to be wide enough to write the project's name across.
    public var minimumFloorUnits: CGFloat

    // MARK: The annexes

    /// How fast somebody walks, in layout points a second.
    ///
    /// Two workstations a second: fast enough that a person who looked away
    /// for a moment does not come back to somebody still crossing the map,
    /// slow enough that the walk is a thing you see happen rather than a jump
    /// with a smear in it.
    public var walkSpeed: CGFloat
    /// The distance between two seats along one side of a long table.
    public var tableSeatSpacing: CGFloat
    /// The end of the table the session that delegated sits at, and the width
    /// its chair needs.
    public var tableHeadWidth: CGFloat
    /// The far end, past the last seat. Wide enough to stand the projector
    /// screen at, which is where a meeting room puts one and — more to the
    /// point — the one place on a table that no chair is ever allocated.
    public var tableTailWidth: CGFloat
    /// A whole table, projector screen and both rows of chairs included.
    public var tableHeight: CGFloat
    /// The air between two tables.
    public var tableGap: CGFloat
    /// The distance between two seats in the garden.
    public var gardenSeatSpacing: CGFloat
    /// The height of one row of garden seats.
    public var gardenRowHeight: CGFloat
    /// How much of the garden's right-hand end is kept clear for the gate and
    /// the queue of sessions walking out through it.
    public var gateReserve: CGFloat

    public init(
        cellWidth: CGFloat = 104,
        rowHeight: CGFloat = 104,
        childUnit: CGFloat = 0.62,
        rowUnits: CGFloat = 8,
        margin: CGFloat = 28,
        floorHeaderHeight: CGFloat = 30,
        floorGap: CGFloat = 22,
        childScale: CGFloat = 0.66,
        minimumFloorUnits: CGFloat = 3,
        walkSpeed: CGFloat = 208,
        tableSeatSpacing: CGFloat = 68,
        tableHeadWidth: CGFloat = 60,
        tableTailWidth: CGFloat = 64,
        tableHeight: CGFloat = 150,
        tableGap: CGFloat = 26,
        gardenSeatSpacing: CGFloat = 92,
        gardenRowHeight: CGFloat = 110,
        gateReserve: CGFloat = 150
    ) {
        self.cellWidth = cellWidth
        self.rowHeight = rowHeight
        self.childUnit = childUnit
        self.rowUnits = rowUnits
        self.margin = margin
        self.floorHeaderHeight = floorHeaderHeight
        self.floorGap = floorGap
        self.childScale = childScale
        self.minimumFloorUnits = minimumFloorUnits
        self.walkSpeed = walkSpeed
        self.tableSeatSpacing = tableSeatSpacing
        self.tableHeadWidth = tableHeadWidth
        self.tableTailWidth = tableTailWidth
        self.tableHeight = tableHeight
        self.tableGap = tableGap
        self.gardenSeatSpacing = gardenSeatSpacing
        self.gardenRowHeight = gardenRowHeight
        self.gateReserve = gateReserve
    }

    /// How wide a table with `children` seats along it is.
    ///
    /// Children sit in pairs facing each other, so the table grows by one
    /// column for every two of them and a family of two is the same table as a
    /// family of one — which is what stops a table breathing every time a
    /// subagent finishes.
    public func tableWidth(children: Int) -> CGFloat {
        let columns = max(1, (children + 1) / 2)
        return tableHeadWidth + tableSeatSpacing * CGFloat(columns) + tableTailWidth + 20
    }

    /// Where the surface of a table sits inside its rectangle, measured from
    /// the top of that rectangle. Above it is the projector screen and the far
    /// row of chairs; below it is the near row.
    public var tableSurfaceTop: CGFloat { 74 }
    /// The bottom edge of the table surface, from the top of its rectangle.
    public var tableSurfaceBottom: CGFloat { 104 }
    /// The floor line the near row of chairs stands on.
    public var tableNearSeatY: CGFloat { 132 }

    /// The dimensions the scene view uses.
    public static let standard = SceneMetrics()

    /// The width of a building one room wide: a floor filled to the wrap rule,
    /// plus the margins. A building whose busiest floor holds three desks is
    /// narrower than this, because a room is drawn the size of its contents —
    /// a row of empty floor to the right of every project would say there is
    /// space nobody is using, which is not what an idle repository means.
    ///
    /// It is the *narrowest* the campus gets, not the widest: past a few
    /// projects the rooms shelve sideways as well as down. See
    /// ``shelfUnits(totalUnits:averageFloorHeight:)``.
    public var contentWidth: CGFloat {
        margin * 2 + rowUnits * cellWidth
    }

    /// How wide the campus is allowed to grow, in units, before a room wraps
    /// onto the shelf below.
    ///
    /// ## Why the map widens instead of only growing down
    ///
    /// A fixed-width strip of rooms is fine for four projects and useless for
    /// forty: the building becomes a column eight screens tall, "fit all"
    /// frames a ribbon two desks wide, and the canvas the camera flies over is
    /// mostly empty air either side. So the shelf width grows with the amount
    /// of building there is to shelve, aiming to keep the whole map roughly as
    /// wide as a window is — a campus rather than a tower.
    ///
    /// The rule is the solution of *width ÷ height = 4/3* for a greedy shelf
    /// packing: with `U` units of room to place and a shelf `W` units wide the
    /// building is `W · cellWidth` across and about `(U / W) · stride` tall, so
    ///
    /// ```
    /// W · cellWidth       4              4 · U · stride
    /// ───────────────  =  ─   ⟹   W  =  √──────────────
    /// (U / W) · stride    3                3 · cellWidth
    /// ```
    ///
    /// It never goes below ``rowUnits``, so a small office keeps exactly the
    /// single-column shape it has always had and only the busy ones spread
    /// out. The result is deliberately *not* the viewport's aspect ratio: the
    /// map is a stable thing that a reader learns the shape of, and a
    /// building that reflowed when somebody widened the window would be a new
    /// building every time.
    public func shelfUnits(totalUnits: CGFloat, averageFloorHeight: CGFloat) -> CGFloat {
        guard totalUnits > 0, cellWidth > 0 else { return rowUnits }
        let stride = averageFloorHeight + floorGap
        let ideal = ((4 * totalUnits * stride) / (3 * cellWidth)).squareRoot()
        return max(rowUnits, ideal)
    }
}

/// One workstation: where it is, how big it is, and who is sitting at it.
///
/// A slot is produced even when nobody is sitting at it. An agent that finishes
/// and leaves the board frees its desk, and until something else takes it the
/// scene draws the desk with the chair pushed in and the monitor dark — which
/// is both what an office looks like and the only honest way to show a gap in
/// the middle of a row. The alternative, closing the gap, would slide every
/// desk after it sideways for no reason a viewer could name.
public struct SceneSlot: Sendable, Equatable, Identifiable {
    /// Stable for as long as the desk exists, whoever is sitting at it.
    /// Formed from the floor, bay, and seat indices, so it survives the person.
    public let id: String
    /// The session at this desk, or `nil` when the desk is vacant.
    public let session: SessionKey?
    /// The session this one was delegated by, when it has one on the board.
    /// Drives the dotted tether and nothing else.
    public let parent: SessionKey?
    /// `0` for an agent that nobody spawned, `1` for its subagents, and so on.
    public let depth: Int
    /// Where the workstation stands, in layout space: the point on the floor
    /// line at the centre of the desk. See ``SceneFrame`` for the axis
    /// convention.
    public let anchor: CGPoint
    /// How large to draw it. `1` for a root, ``SceneMetrics/childScale`` below
    /// that for a delegated session.
    public let scale: CGFloat
    /// Which floor this desk is on.
    public let floorIndex: Int
    /// Which row of that floor.
    public let row: Int
    /// `true` when this desk's session is sitting somewhere else on the map —
    /// at a table in the meeting room, or on a bench in the garden.
    ///
    /// The desk is *held* rather than freed, which is the difference between
    /// somebody being out of the room and somebody having left the company. It
    /// costs an empty desk in the picture and buys three things: the office
    /// keeps the exact geometry it had before the annexes existed, a session
    /// that goes idle and comes back sits down where it was rather than
    /// wherever the allocator had got to, and a walk has somewhere to walk
    /// *from*.
    public let isAway: Bool

    public init(
        id: String,
        session: SessionKey?,
        parent: SessionKey?,
        depth: Int,
        anchor: CGPoint,
        scale: CGFloat,
        floorIndex: Int,
        row: Int,
        isAway: Bool = false
    ) {
        self.id = id
        self.session = session
        self.parent = parent
        self.depth = depth
        self.anchor = anchor
        self.scale = scale
        self.floorIndex = floorIndex
        self.row = row
        self.isAway = isAway
    }

    /// `true` when the desk is standing empty.
    public var isVacant: Bool { session == nil }

    /// `true` when somebody is actually sitting here.
    public var isOccupied: Bool { session != nil && !isAway }
}

/// One seat in an annex: a chair at a long table, or a place in the garden.
///
/// The office's counterpart is ``SceneSlot``, and the two are deliberately not
/// one type. A desk is an *allocation* — it belongs to the layout's table of
/// who took which bay, it survives its occupant, and it is what the office's
/// four stability rules are about. A seat is a *placement*: it exists because
/// somebody is doing something, it is held only while they keep doing it, and
/// nothing about the office moves when one appears.
public struct SceneSeat: Sendable, Equatable, Identifiable {
    /// Stable for as long as the seat exists, whoever is in it.
    public let id: String
    /// Who is sitting here, or `nil` for a seat being kept warm.
    public let session: SessionKey?
    /// What they are doing here, which is also what furniture to draw.
    public let kind: SceneSeatKind
    /// The point on the floor line they stand on, in layout space.
    public let anchor: CGPoint
    /// How large to draw them — the same convention ``SceneSlot/scale`` uses.
    public let scale: CGFloat
    /// The table this seat belongs to, for a meeting seat.
    public let tableID: String?

    public init(
        id: String,
        session: SessionKey?,
        kind: SceneSeatKind,
        anchor: CGPoint,
        scale: CGFloat,
        tableID: String? = nil
    ) {
        self.id = id
        self.session = session
        self.kind = kind
        self.anchor = anchor
        self.scale = scale
        self.tableID = tableID
    }

    public var zone: SceneZone { kind.zone }
    public var isVacant: Bool { session == nil }
}

/// One annex, as a strip of the map.
///
/// The counterpart of ``SceneFloor``, and like a floor it is what the minimap
/// draws and what a double-click frames. Unlike a floor it is not a project:
/// there is one meeting room and one garden however many projects are open,
/// because who you are working *for* stops mattering the moment you get up
/// from the desk.
public struct SceneZoneArea: Sendable, Equatable, Identifiable {
    public let id: String
    public let zone: SceneZone
    /// What the strip's nameplate says.
    public let title: String
    /// The whole strip, header included, in layout space.
    public let frame: CGRect
    /// How many rows of seats it holds.
    public let rowCount: Int
    /// How many of its seats have somebody in them.
    public let occupancy: Int
    /// The `y` of the walkway through it. Everybody in this strip leaves and
    /// arrives on this line, which is what makes a route three straight
    /// segments instead of a pathfinding problem.
    public let laneY: CGFloat

    public init(
        id: String,
        zone: SceneZone,
        title: String,
        frame: CGRect,
        rowCount: Int,
        occupancy: Int,
        laneY: CGFloat
    ) {
        self.id = id
        self.zone = zone
        self.title = title
        self.frame = frame
        self.rowCount = rowCount
        self.occupancy = occupancy
        self.laneY = laneY
    }
}

/// One delegating family's table.
public struct SceneTable: Sendable, Equatable, Identifiable {
    /// Stable while the family is meeting.
    public let id: String
    /// The session that delegated. It sits at the head.
    public let head: SessionKey
    /// The project the family is working in, for the table's nameplate.
    public let projectKey: String?
    /// What the nameplate says.
    public let title: String
    /// The table and both rows of chairs, in layout space.
    public let frame: CGRect
    /// How many children are seated along it.
    public let seatCount: Int

    public init(
        id: String,
        head: SessionKey,
        projectKey: String?,
        title: String,
        frame: CGRect,
        seatCount: Int
    ) {
        self.id = id
        self.head = head
        self.projectKey = projectKey
        self.title = title
        self.frame = frame
        self.seatCount = seatCount
    }
}

/// Where the walking happens.
///
/// One horizontal walkway per strip and one vertical gutter joining them, in
/// layout space. Every route on the map is built out of these two ideas, so
/// they are published with the frame rather than re-derived by whoever is
/// animating: a walker that took a different view of where the walkway was
/// would step through the furniture on its way to agreeing.
public struct SceneWalkways: Sendable, Equatable {
    /// The `x` of the gutter that joins the strips.
    public let trunk: CGFloat
    private let lanes: [SceneZone: CGFloat]

    public init(trunk: CGFloat, lanes: [SceneZone: CGFloat]) {
        self.trunk = trunk
        self.lanes = lanes
    }

    public static let empty = SceneWalkways(trunk: 0, lanes: [:])

    /// The walkway through one strip. Falls back to the gutter's own origin
    /// for a strip that is not drawn, which only a stale route can ask for.
    public func lane(_ zone: SceneZone) -> CGFloat { lanes[zone] ?? 0 }
}

/// One project, as a floor of the building.
///
/// The room a project's agents share. Its title is the project's short name —
/// the git root's basename, or the working directory's — because that is what
/// the board's section headers call it, and two views naming the same thing
/// differently is how a person stops trusting either.
public struct SceneFloor: Sendable, Equatable, Identifiable {
    /// Stable while the floor is occupied.
    public let id: String
    /// The floor's allocation index — the same number ``SceneSlot/floorIndex``
    /// carries, and *not* this floor's position in ``SceneFrame/floors``: a
    /// vacated floor is skipped when drawing but does not renumber the ones
    /// below it.
    public let index: Int
    /// The project this floor is, or `nil` for the floor that holds sessions
    /// no directory could be found for.
    public let projectKey: String?
    /// The nameplate's text.
    public let title: String
    /// The whole floor, header strip included, in layout space.
    public let frame: CGRect
    /// How many rows of desks it has.
    public let rowCount: Int
    /// How many of its desks have somebody at them.
    public let occupancy: Int

    public init(
        id: String,
        index: Int,
        projectKey: String?,
        title: String,
        frame: CGRect,
        rowCount: Int,
        occupancy: Int
    ) {
        self.id = id
        self.index = index
        self.projectKey = projectKey
        self.title = title
        self.frame = frame
        self.rowCount = rowCount
        self.occupancy = occupancy
    }
}

/// A delegation, as a line between two desks.
public struct SceneTether: Sendable, Equatable, Hashable, Identifiable {
    public let parent: SessionKey
    public let child: SessionKey
    /// The parent's desk, in layout space.
    public let from: CGPoint
    /// The child's desk.
    public let to: CGPoint

    public init(parent: SessionKey, child: SessionKey, from: CGPoint, to: CGPoint) {
        self.parent = parent
        self.child = child
        self.from = from
        self.to = to
    }

    public var id: String { "\(parent.description)->\(child.description)" }
}

/// Everything the scene draws for one board frame.
///
/// ## The axis convention
///
/// Layout space has its origin at the **top left** of the building and `y`
/// increases **downward**, the way a floor plan is read and the way every
/// wrapping layout in this file is easiest to reason about. SpriteKit's world
/// is `y`-up, so the scene negates `y` once, at the single point where a slot
/// becomes a node. Doing the flip in the renderer rather than in the layout is
/// what lets the layout tests read like a table of coordinates.
public struct SceneFrame: Sendable, Equatable {
    /// The floors, top to bottom.
    public let floors: [SceneFloor]
    /// Every workstation, occupied or not, in floor then bay then seat order.
    public let slots: [SceneSlot]
    /// The delegation lines.
    public let tethers: [SceneTether]
    /// The building's bounding box in layout space. What "fit all" fits.
    public let contentRect: CGRect
    /// The annexes that are switched on and have anybody in them, in drawing
    /// order. Empty is the office exactly as it was before they existed.
    public let zones: [SceneZoneArea]
    /// Every chair and bench in those annexes.
    public let seats: [SceneSeat]
    /// The long tables, one per delegating family.
    public let tables: [SceneTable]
    /// Where the gate stands, when there is a garden. Sessions that are over
    /// walk to it and off the map.
    public let gate: CGPoint?
    /// The walkways, for whoever is animating a walk.
    public let walkways: SceneWalkways
    /// The floor plan this frame was measured with.
    public let metrics: SceneMetrics

    public init(
        floors: [SceneFloor],
        slots: [SceneSlot],
        tethers: [SceneTether],
        contentRect: CGRect,
        zones: [SceneZoneArea] = [],
        seats: [SceneSeat] = [],
        tables: [SceneTable] = [],
        gate: CGPoint? = nil,
        walkways: SceneWalkways = .empty,
        metrics: SceneMetrics = .standard
    ) {
        self.floors = floors
        self.slots = slots
        self.tethers = tethers
        self.contentRect = contentRect
        self.zones = zones
        self.seats = seats
        self.tables = tables
        self.gate = gate
        self.walkways = walkways
        self.metrics = metrics
    }

    /// An empty building.
    public static let empty = SceneFrame(
        floors: [], slots: [], tethers: [], contentRect: .zero
    )

    /// The desk `key` is sitting at, when it has one.
    public func slot(for key: SessionKey) -> SceneSlot? {
        slots.first { $0.session == key }
    }

    /// The annex seat `key` is in, when it is not at its desk.
    public func seat(for key: SessionKey) -> SceneSeat? {
        seats.first { $0.session == key }
    }

    /// Where one session actually is, whichever part of the map that is.
    ///
    /// The one lookup everything that has to *point at* a session uses — the
    /// delegation lines, the camera, the walkers. Asking for the desk and
    /// forgetting to check whether its occupant is away is the bug this exists
    /// to make impossible.
    public struct Place: Sendable, Equatable {
        public let anchor: CGPoint
        public let scale: CGFloat
        public let kind: SceneSeatKind
        /// The desk or seat's id, which is what the renderer keys nodes on.
        public let id: String

        public var zone: SceneZone { kind.zone }

        public init(anchor: CGPoint, scale: CGFloat, kind: SceneSeatKind, id: String) {
            self.anchor = anchor
            self.scale = scale
            self.kind = kind
            self.id = id
        }
    }

    /// Where `key` is sitting, or `nil` when it is not on this frame.
    public func place(of key: SessionKey) -> Place? {
        if let seat = seats.first(where: { $0.session == key }) {
            return Place(anchor: seat.anchor, scale: seat.scale, kind: seat.kind, id: seat.id)
        }
        guard let slot = slots.first(where: { $0.session == key }) else { return nil }
        return Place(anchor: slot.anchor, scale: slot.scale, kind: .desk, id: slot.id)
    }

    /// The annex under a layout-space point.
    public func zone(at point: CGPoint) -> SceneZoneArea? {
        zones.last { $0.frame.contains(point) }
    }

    /// Every room a project has, in drawing order.
    ///
    /// Plural because a project can hold more than one floor once the office
    /// has churned — a floor is an allocation, and the layout would rather
    /// open a second room than renumber the ones already drawn. `nil` asks for
    /// the room that holds the sessions no directory could be found for.
    public func floors(forProject key: String?) -> [SceneFloor] {
        floors.filter { $0.projectKey == key }
    }

    /// What the camera frames when a project is focused: everything that
    /// project occupies, in layout space, or `nil` when it occupies nothing.
    ///
    /// The union rather than the first room, because framing one of a
    /// project's two rooms and leaving the other off screen answers the
    /// question "where is this project" with half a lie.
    ///
    /// Once a delegating family gets up and walks out, the room it left is a
    /// row of empty desks — a picture of where a project's people are *not*.
    /// So when nobody is at a desk of this project's and it has a table, the
    /// table is what gets framed.
    ///
    /// Framing both would be worse than framing either: the annexes hang under
    /// the whole campus, so the union of a room near the top and a table near
    /// the bottom is most of the map, and "focus this project" would become
    /// "fit everything" for any project that happened to be delegating.
    public func focusRect(forProject key: String?) -> CGRect? {
        let rooms = floors(forProject: key)
        let indices = Set(rooms.map(\.index))
        let anybodyAtADesk = slots.contains { $0.isOccupied && indices.contains($0.floorIndex) }

        if !anybodyAtADesk {
            var meeting: CGRect?
            for table in tables where table.projectKey == key {
                meeting = meeting.map { $0.union(table.frame) } ?? table.frame
            }
            if let meeting { return meeting }
        }

        guard var union = rooms.first?.frame else { return nil }
        for room in rooms.dropFirst() { union = union.union(room.frame) }
        return union
    }

    /// The room under a layout-space point, for a double-click on the floor.
    ///
    /// Last match wins so that the answer agrees with what is drawn on top
    /// when two rooms overlap, which they should not, but a hit test that
    /// silently disagrees with the picture is a bug nobody can see.
    public func floor(at point: CGPoint) -> SceneFloor? {
        floors.last { $0.frame.contains(point) }
    }
}
