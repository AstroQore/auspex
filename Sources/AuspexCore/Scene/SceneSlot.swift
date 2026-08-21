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
    /// The distance between two seats in a break room.
    public var gardenSeatSpacing: CGFloat
    /// The height of one row of break-room seats.
    public var gardenRowHeight: CGFloat
    /// How much of a break room's right-hand end is kept clear for the suite's
    /// door and the few sessions walking out through it.
    public var gateReserve: CGFloat
    /// The air between the rooms of one suite.
    ///
    /// Small on purpose: the desks, the meeting rooms and the break room are
    /// one company's premises, and a gap the size of the one between two
    /// companies would read as three buildings.
    public var suiteGap: CGFloat
    /// How many sessions a project needs before its suite is drawn with rooms
    /// nobody is in yet.
    ///
    /// A company of two does its talking across the desk and makes tea in the
    /// kitchen upstairs. A company of three has a meeting room and a break
    /// room, and drawing them empty is what makes them *places* rather than
    /// things that materialise the instant somebody delegates or goes idle.
    public var suiteRoomThreshold: Int

    // MARK: What the map will draw at all

    /// How many sessions queue at one suite's door before the rest are simply
    /// gone.
    ///
    /// A safety net rather than the mechanism. An ended session now walks to
    /// its company's door and is *removed* when it gets there, so the queue
    /// holds whoever is mid-stride and nobody else; this is what stops a board
    /// that reports two hundred exits in one tick from drawing two hundred
    /// people at one door while they file out.
    public var gateQueueLimit: Int
    /// How many sessions rest in one project's break room before the rest are
    /// counted rather than seated.
    ///
    /// Per project rather than in total, so a busy repository cannot push a
    /// quiet one's single bench off the map — the same rule the office follows
    /// by giving every project a room of its own.
    public var gardenSeatsPerProject: Int

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
        gardenSeatSpacing: CGFloat = 72,
        gardenRowHeight: CGFloat = 96,
        gateReserve: CGFloat = 84,
        suiteGap: CGFloat = 8,
        suiteRoomThreshold: Int = 3,
        gateQueueLimit: Int = 3,
        gardenSeatsPerProject: Int = 8
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
        self.suiteGap = suiteGap
        self.suiteRoomThreshold = suiteRoomThreshold
        self.gateQueueLimit = gateQueueLimit
        self.gardenSeatsPerProject = gardenSeatsPerProject
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
    /// keeps the exact geometry it had before the other rooms existed, a
    /// session that goes idle and comes back sits down where it was rather
    /// than wherever the allocator had got to, and a walk has somewhere to
    /// walk *from*.
    public let isAway: Bool
    /// How many sessions this one delegated to, on this board.
    ///
    /// Drawn as a `↳ N` badge rather than as N lines. Once a family has more
    /// than a couple of children the lines stop being a relationship and start
    /// being a mesh, and the number is the part a reader was going to count
    /// anyway. See ``SceneFrame/arcs(focus:limit:)``.
    public let childCount: Int

    public init(
        id: String,
        session: SessionKey?,
        parent: SessionKey?,
        depth: Int,
        anchor: CGPoint,
        scale: CGFloat,
        floorIndex: Int,
        row: Int,
        isAway: Bool = false,
        childCount: Int = 0
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
        self.childCount = childCount
    }

    /// `true` when the desk is standing empty.
    public var isVacant: Bool { session == nil }

    /// `true` when somebody is actually sitting here.
    public var isOccupied: Bool { session != nil && !isAway }
}

/// One seat away from the desks: a chair at a long table, or a place in the
/// break room.
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
    /// Which suite this seat is in. Every room belongs to a project now, and
    /// a walk is routed along *that suite's* corridor.
    public let floorIndex: Int
    /// How many sessions the occupant delegated to — see
    /// ``SceneSlot/childCount``.
    public let childCount: Int

    public init(
        id: String,
        session: SessionKey?,
        kind: SceneSeatKind,
        anchor: CGPoint,
        scale: CGFloat,
        floorIndex: Int,
        tableID: String? = nil,
        childCount: Int = 0
    ) {
        self.id = id
        self.session = session
        self.kind = kind
        self.anchor = anchor
        self.scale = scale
        self.floorIndex = floorIndex
        self.tableID = tableID
        self.childCount = childCount
    }

    public var zone: SceneZone { kind.zone }
    public var isVacant: Bool { session == nil }
}

/// One room of one suite, other than the desks.
///
/// The counterpart of ``SceneFloor``, and like a floor it is what the minimap
/// draws and what a double-click frames. Unlike the old annexes it belongs to
/// a project: a meeting room is *this company's* meeting room and the break
/// room is the one its people walk to, because "whose meeting is this" is the
/// first thing a reader asks of a table.
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
    /// How many more belong here than there are places for.
    ///
    /// A break room seats a bounded number per project and counts the rest;
    /// this is that count, so the nameplate can say `+12 more` instead of the
    /// map quietly losing them. `0` everywhere else.
    public let overflow: Int
    /// The `y` of the corridor this room opens onto. Everybody in the suite
    /// leaves and arrives on this line, which is what makes a route three
    /// straight segments instead of a pathfinding problem.
    public let laneY: CGFloat
    /// The project whose suite this room is in.
    public let projectKey: String?
    /// Which suite, by the same allocation index ``SceneSlot/floorIndex``
    /// carries.
    public let floorIndex: Int
    /// What kind of break room this is. `nil` for a meeting room.
    public let breakKind: SceneBreakKind?
    /// Where the suite's door stands, for the break room that holds it.
    /// Sessions that are over walk to it and off the map.
    public let door: CGPoint?

    public init(
        id: String,
        zone: SceneZone,
        title: String,
        frame: CGRect,
        rowCount: Int,
        occupancy: Int,
        laneY: CGFloat,
        projectKey: String? = nil,
        floorIndex: Int = 0,
        overflow: Int = 0,
        breakKind: SceneBreakKind? = nil,
        door: CGPoint? = nil
    ) {
        self.id = id
        self.zone = zone
        self.title = title
        self.frame = frame
        self.rowCount = rowCount
        self.occupancy = occupancy
        self.overflow = overflow
        self.laneY = laneY
        self.projectKey = projectKey
        self.floorIndex = floorIndex
        self.breakKind = breakKind
        self.door = door
    }

    /// Whether the suite's corridor runs through this room, which is what
    /// decides who draws it.
    public var drawsLane: Bool { laneY > frame.minY && laneY < frame.maxY }
}

/// One of a suite's meeting rooms.
public struct SceneTable: Sendable, Equatable, Identifiable {
    /// Stable while the room is open.
    public let id: String
    /// The session that delegated. It sits at the head. `nil` for a room the
    /// company has but nobody is using — a table is a place, not something
    /// that materialises the instant somebody delegates.
    public let head: SessionKey?
    /// The project the family is working in, for the table's nameplate.
    public let projectKey: String?
    /// What the nameplate says.
    public let title: String
    /// The table and both rows of chairs, in layout space.
    public let frame: CGRect
    /// How many children are seated along it.
    public let seatCount: Int
    /// Which suite this room is in.
    public let floorIndex: Int

    public init(
        id: String,
        head: SessionKey?,
        projectKey: String?,
        title: String,
        frame: CGRect,
        seatCount: Int,
        floorIndex: Int = 0
    ) {
        self.id = id
        self.head = head
        self.projectKey = projectKey
        self.title = title
        self.frame = frame
        self.seatCount = seatCount
        self.floorIndex = floorIndex
    }
}

/// Where the walking happens.
///
/// One horizontal corridor per suite and one vertical gutter down the campus,
/// in layout space. Every route on the map is built out of those two ideas, so
/// they are published with the frame rather than re-derived by whoever is
/// animating: a walker that took a different view of where the corridor was
/// would step through the furniture on its way to agreeing.
///
/// A corridor per *suite* rather than per kind of room is what a company
/// actually is: the desks, the meeting rooms and the break room open onto one
/// hallway, and walking from a desk to a table is a trip down it. A walk
/// between two companies — which only happens when a session's working
/// directory changes under it — goes out to the campus gutter and back.
public struct SceneWalkways: Sendable, Equatable {
    /// The `x` of the gutter that runs down the campus.
    public let trunk: CGFloat
    private let lanes: [Int: CGFloat]

    public init(trunk: CGFloat, lanes: [Int: CGFloat]) {
        self.trunk = trunk
        self.lanes = lanes
    }

    public static let empty = SceneWalkways(trunk: 0, lanes: [:])

    /// The corridor through one suite. Falls back to the gutter's own origin
    /// for a suite that is not drawn, which only a stale route can ask for.
    public func lane(floor: Int) -> CGFloat { lanes[floor] ?? 0 }
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
    /// The desks, header strip included, in layout space. Exactly the
    /// rectangle this floor had before a project's other rooms existed, which
    /// is what makes "switch them off and the office is unchanged" a property
    /// rather than a hope.
    public let frame: CGRect
    /// The whole suite: the desks, the meeting rooms and the break room. What
    /// "focus this project" frames, because a company is all of it.
    public let suite: CGRect
    /// How many rows of desks it has.
    public let rowCount: Int
    /// How many of its desks have somebody at them.
    public let occupancy: Int
    /// The kind of break room this company has.
    public let breakKind: SceneBreakKind

    public init(
        id: String,
        index: Int,
        projectKey: String?,
        title: String,
        frame: CGRect,
        rowCount: Int,
        occupancy: Int,
        suite: CGRect? = nil,
        breakKind: SceneBreakKind = .garden
    ) {
        self.id = id
        self.index = index
        self.projectKey = projectKey
        self.title = title
        self.frame = frame
        self.suite = suite ?? frame
        self.rowCount = rowCount
        self.occupancy = occupancy
        self.breakKind = breakKind
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
    /// The session at the top of this delegation's tree — the one whose family
    /// this arc belongs to.
    ///
    /// Arcs are drawn a family at a time rather than all at once, so every arc
    /// has to know which family it is in. See ``SceneFrame/arcs(focus:limit:)``.
    public let family: SessionKey

    public init(
        parent: SessionKey,
        child: SessionKey,
        from: CGPoint,
        to: CGPoint,
        family: SessionKey? = nil
    ) {
        self.parent = parent
        self.child = child
        self.from = from
        self.to = to
        self.family = family ?? parent
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
    /// The suites' other rooms, in drawing order. Empty is the office exactly
    /// as it was before they existed.
    public let zones: [SceneZoneArea]
    /// Every chair and bench in those rooms.
    public let seats: [SceneSeat]
    /// The meeting rooms, in drawing order.
    public let tables: [SceneTable]
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
        self.walkways = walkways
        self.metrics = metrics
    }

    /// Where one suite's door stands, when its break room is drawn.
    public func door(ofSuite index: Int) -> CGPoint? {
        zones.first { $0.floorIndex == index && $0.door != nil }?.door
    }

    /// Every suite door on the map.
    public var doors: [CGPoint] { zones.compactMap(\.door) }

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
        /// Which suite it is in, which is which corridor a walk to or from it
        /// runs along.
        public let floorIndex: Int

        public var zone: SceneZone { kind.zone }

        public init(
            anchor: CGPoint,
            scale: CGFloat,
            kind: SceneSeatKind,
            id: String,
            floorIndex: Int = 0
        ) {
            self.anchor = anchor
            self.scale = scale
            self.kind = kind
            self.id = id
            self.floorIndex = floorIndex
        }
    }

    /// Where `key` is sitting, or `nil` when it is not on this frame.
    public func place(of key: SessionKey) -> Place? {
        if let seat = seats.first(where: { $0.session == key }) {
            return Place(
                anchor: seat.anchor,
                scale: seat.scale,
                kind: seat.kind,
                id: seat.id,
                floorIndex: seat.floorIndex
            )
        }
        guard let slot = slots.first(where: { $0.session == key }) else { return nil }
        return Place(
            anchor: slot.anchor,
            scale: slot.scale,
            kind: .desk,
            id: slot.id,
            floorIndex: slot.floorIndex
        )
    }

    /// The room under a layout-space point.
    public func zone(at point: CGPoint) -> SceneZoneArea? {
        zones.last { $0.frame.contains(point) }
    }

    /// The suite a layout-space point is in.
    public func suite(at point: CGPoint) -> SceneFloor? {
        floors.last { $0.suite.contains(point) }
    }

    /// The delegation arcs worth drawing, given what the reader is pointing at.
    ///
    /// ## Why a board of forty subagents draws six lines
    ///
    /// A tether is a relationship, and a relationship is only legible against
    /// a background of things it is *not*. Drawing every delegation on a busy
    /// board produces a mesh: forty arcs over one room, none of which can be
    /// followed from one end to the other, and the picture stops saying "this
    /// one handed work to those three" and starts saying "there is a lot going
    /// on here", which the colours already said.
    ///
    /// So the arcs are drawn one family at a time, for the family the reader
    /// is actually looking at, and everything else says the same thing in the
    /// two ways that cost no ink: children of a delegating session sit
    /// *around its table*, and a parent's desk carries a `↳ N` badge. Nothing
    /// is hidden — the relationship is still on the map, drawn as furniture
    /// rather than as a line.
    ///
    /// - Parameters:
    ///   - focus: the session the reader has selected or is hovering. Its
    ///     whole family's arcs are returned, whether it is the parent, a
    ///     child, or a cousin.
    ///   - limit: the most arcs to return. Six is about as many lines as can
    ///     cross one room and still be followed.
    /// - Returns: the arcs to draw, nearest the family's root first. Empty
    ///   when nothing is focused, which is the resting state of the map.
    public func arcs(focus: SessionKey?, limit: Int = 6) -> [SceneTether] {
        guard let focus, limit > 0 else { return [] }
        guard let family = tethers.first(where: {
            $0.family == focus || $0.parent == focus || $0.child == focus
        })?.family else { return [] }
        return Array(tethers.filter { $0.family == family }.prefix(limit))
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

    /// What the camera frames when a project is focused: the whole suite, in
    /// layout space, or `nil` when the project has none.
    ///
    /// The suite rather than the desks, because a company is its desks *and*
    /// its meeting rooms *and* its break room, and a session that walked next
    /// door is exactly the one a reader is looking for when they focus a
    /// project. The union across suites, because a project that has churned
    /// long enough holds two of them — a suite is an allocation, and the
    /// layout would rather open a second than renumber the ones already drawn.
    public func focusRect(forProject key: String?) -> CGRect? {
        let rooms = floors(forProject: key)
        guard var union = rooms.first?.suite else { return nil }
        for room in rooms.dropFirst() { union = union.union(room.suite) }
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
