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

    public init(
        cellWidth: CGFloat = 104,
        rowHeight: CGFloat = 104,
        childUnit: CGFloat = 0.62,
        rowUnits: CGFloat = 8,
        margin: CGFloat = 28,
        floorHeaderHeight: CGFloat = 30,
        floorGap: CGFloat = 22,
        childScale: CGFloat = 0.66,
        minimumFloorUnits: CGFloat = 3
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
    }

    /// The dimensions the scene view uses.
    public static let standard = SceneMetrics()

    /// The widest the building can get: a floor filled to the wrap rule, plus
    /// the margins. A building whose busiest floor holds three desks is
    /// narrower than this, because a room is drawn the size of its contents —
    /// a row of empty floor to the right of every project would say there is
    /// space nobody is using, which is not what an idle repository means.
    public var contentWidth: CGFloat {
        margin * 2 + rowUnits * cellWidth
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

    public init(
        id: String,
        session: SessionKey?,
        parent: SessionKey?,
        depth: Int,
        anchor: CGPoint,
        scale: CGFloat,
        floorIndex: Int,
        row: Int
    ) {
        self.id = id
        self.session = session
        self.parent = parent
        self.depth = depth
        self.anchor = anchor
        self.scale = scale
        self.floorIndex = floorIndex
        self.row = row
    }

    /// `true` when the desk is standing empty.
    public var isVacant: Bool { session == nil }
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

    public init(
        floors: [SceneFloor],
        slots: [SceneSlot],
        tethers: [SceneTether],
        contentRect: CGRect
    ) {
        self.floors = floors
        self.slots = slots
        self.tethers = tethers
        self.contentRect = contentRect
    }

    /// An empty building.
    public static let empty = SceneFrame(
        floors: [], slots: [], tethers: [], contentRect: .zero
    )

    /// The desk `key` is sitting at, when it has one.
    public func slot(for key: SessionKey) -> SceneSlot? {
        slots.first { $0.session == key }
    }
}
