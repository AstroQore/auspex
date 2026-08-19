import AgentSessionLive
import CoreGraphics
import Foundation

/// Seats every session on the board at a desk, and remembers where it put them.
///
/// ## Why this is stateful, and why it is still pure
///
/// A board frame arrives up to twenty times a second and its session order is
/// *not* stable: the board sorts by urgency, so a session that hits a
/// permission prompt jumps to the front. Laying the office out directly from
/// that order would rearrange the furniture every time somebody started
/// thinking. So the layout keeps an allocation table — which floor a project
/// took, which bay an agent took, which seat a subagent took — and the table,
/// not the frame, decides where things go.
///
/// It is still a pure function of (previous table, board): no clock, no
/// randomness, no I/O. Feeding the same sequence of boards through a fresh
/// layout always produces the same sequence of frames, which is what makes the
/// stability properties testable rather than merely intended.
///
/// ## The four rules
///
/// - **A desk is held for as long as its session is on the board.** Not for as
///   long as it is *running* — an ended session keeps its desk until the
///   registry drops it, because a card that vanishes the instant a build
///   finishes is a card nobody got to read.
/// - **A new session takes the lowest free slot.** Interior gaps are reused
///   before the building grows, so an office that has churned for eight hours
///   is no wider than its busiest moment.
/// - **Nothing already seated moves when somebody arrives or leaves.** The one
///   exception is deliberate: the first time an agent delegates, its bay widens
///   to make room for the subagent and the bays after it slide over. The bay
///   keeps that width until its agent leaves, so it happens once per agent and
///   it happens for a reason a viewer can see.
/// - **Trailing gaps close.** A freed slot at the end of a floor, or an empty
///   floor at the bottom of the building, is removed rather than left as a
///   stub, so the building shrinks back when the day quiets down.
///
/// ## Bays and seats
///
/// One *bay* is one agent nobody delegated to plus everything it delegated,
/// transitively, that is working in the same project. The root sits at the left
/// of the bay and its descendants sit to its right in tree order at
/// ``SceneMetrics/childScale``, so "adjacent to its parent" is a property of
/// the allocation rather than something the renderer has to arrange.
///
/// A subagent whose own working directory is a *different* project does not
/// follow its parent onto that floor — it is a root of its own bay on the floor
/// it is actually working in, and only the tether says where it came from.
/// A delegation that crosses repositories is exactly the thing a person wants
/// to see, and burying it in the parent's room would hide it.
public struct SceneLayout: Sendable, Equatable {
    /// The floor plan this layout measures with.
    public let metrics: SceneMetrics

    /// The building, bottom-growing. `nil` is a floor that has been vacated and
    /// is waiting for the next project to take it.
    private var floors: [FloorState?]

    /// Creates an empty building.
    public init(metrics: SceneMetrics = .standard) {
        self.metrics = metrics
        self.floors = []
    }

    /// The title the floor with no project shows.
    public static let unplacedFloorTitle = "No project"

    // MARK: - Allocation state

    /// Which project a floor belongs to. A separate type from `String?` so the
    /// "no directory anywhere in the chain" floor cannot be confused with a
    /// project literally named the empty string.
    private enum FloorKey: Hashable, Sendable {
        case project(String)
        case unplaced

        var projectKey: String? {
            if case .project(let path) = self { return path }
            return nil
        }
    }

    private struct FloorState: Sendable, Equatable {
        var key: FloorKey
        /// `nil` is a vacated bay, held so the desks after it do not slide.
        var bays: [BayState?]
    }

    private struct BayState: Sendable, Equatable {
        var root: SessionKey
        /// Seats for the root's descendants. Never shortened while the root is
        /// on the board — that is the hysteresis that keeps a bay from
        /// breathing in and out as subagents come and go.
        var seats: [SessionKey?]

        /// How much of a row this bay takes.
        func width(_ metrics: SceneMetrics) -> CGFloat {
            1 + CGFloat(seats.count) * metrics.childUnit
        }
    }

    /// The width of a bay that has been vacated: one plain workstation.
    private static let vacantBayWidth: CGFloat = 1

    // MARK: - Update

    /// Seats `board` and returns the office to draw.
    ///
    /// - Parameter board: the frame to lay out. Its own ordering is used only
    ///   to break ties when several new sessions appear at once, so that two
    ///   layouts fed the same boards agree.
    public mutating func update(with board: BoardSnapshot) -> SceneFrame {
        let plan = Plan(board: board)
        sweep(plan)
        seat(plan)
        return geometry(plan)
    }

    // MARK: Plan

    /// Everything derived from one board that both the sweep and the seating
    /// pass need, computed once.
    private struct Plan {
        let board: BoardSnapshot
        /// Which floor each session belongs on.
        let floorKey: [SessionKey: FloorKey]
        /// The bay root each session sits with — itself, when it is a root.
        let bayRoot: [SessionKey: SessionKey]
        /// The parent each session is tethered to, when the board has one.
        let parent: [SessionKey: SessionKey]
        /// How far below its bay root a session sits.
        let depth: [SessionKey: Int]
        /// Sessions in the order the board reported them.
        let order: [SessionKey]

        init(board: BoardSnapshot) {
            self.board = board
            self.order = board.sessions.map(\.key)
            let present = Set(order)

            var floorKey: [SessionKey: FloorKey] = [:]
            floorKey.reserveCapacity(board.sessions.count)
            for session in board.sessions {
                floorKey[session.key] = board.projectKey(for: session).map(FloorKey.project)
                    ?? .unplaced
            }
            self.floorKey = floorKey

            // The same parent rule the delegation forest uses: a parent counts
            // only if it is on this board and is not the session itself.
            var parent: [SessionKey: SessionKey] = [:]
            for session in board.sessions {
                guard let claimed = session.identity.parent,
                      claimed != session.key,
                      present.contains(claimed)
                else { continue }
                parent[session.key] = claimed
            }
            self.parent = parent

            // Walk to the top of the delegation chain, stopping at a floor
            // boundary. The seen set is what makes a stored cycle finite; the
            // tree builder refuses to create one, but a board can still hold
            // two identities that disagree.
            var bayRoot: [SessionKey: SessionKey] = [:]
            var depth: [SessionKey: Int] = [:]
            for key in order {
                var seen: Set<SessionKey> = [key]
                var current = key
                var steps = 0
                while let above = parent[current],
                      floorKey[above] == floorKey[key],
                      seen.insert(above).inserted {
                    current = above
                    steps += 1
                }
                bayRoot[key] = current
                depth[key] = steps
            }
            self.bayRoot = bayRoot
            self.depth = depth
        }
    }

    // MARK: Sweep

    /// Releases every desk whose occupant has left the board, changed project,
    /// or stopped being the session it was seated as.
    private mutating func sweep(_ plan: Plan) {
        for index in floors.indices {
            guard var floor = floors[index] else { continue }

            for bayIndex in floor.bays.indices {
                guard var bay = floor.bays[bayIndex] else { continue }
                let rootIsStillHere = plan.floorKey[bay.root] == floor.key
                    && plan.bayRoot[bay.root] == bay.root
                guard rootIsStillHere else {
                    floor.bays[bayIndex] = nil
                    continue
                }
                for seat in bay.seats.indices {
                    guard let child = bay.seats[seat] else { continue }
                    if plan.bayRoot[child] != bay.root { bay.seats[seat] = nil }
                }
                floor.bays[bayIndex] = bay
            }

            while let last = floor.bays.last, last == nil { floor.bays.removeLast() }
            floors[index] = floor.bays.isEmpty ? nil : floor
        }
        while let last = floors.last, last == nil { floors.removeLast() }
    }

    // MARK: Seat

    /// Gives every session on the board a desk, reusing the one it already had.
    ///
    /// Roots first, in board order, so that a subagent always finds its bay
    /// already allocated. Within each pass the lowest free index wins, which is
    /// what keeps the building compact without renumbering anybody.
    private mutating func seat(_ plan: Plan) {
        var bayOf: [SessionKey: (floor: Int, bay: Int)] = [:]
        var seated: Set<SessionKey> = []
        for (floorIndex, floor) in floors.enumerated() {
            guard let floor else { continue }
            for (bayIndex, bay) in floor.bays.enumerated() {
                guard let bay else { continue }
                bayOf[bay.root] = (floorIndex, bayIndex)
                seated.insert(bay.root)
                for child in bay.seats { if let child { seated.insert(child) } }
            }
        }

        for key in plan.order where plan.bayRoot[key] == key && !seated.contains(key) {
            guard let floorKey = plan.floorKey[key] else { continue }
            let floorIndex = allocateFloor(floorKey)
            let bayIndex = allocateBay(root: key, on: floorIndex)
            bayOf[key] = (floorIndex, bayIndex)
        }

        for key in plan.order where plan.bayRoot[key] != key && !seated.contains(key) {
            guard let root = plan.bayRoot[key], let location = bayOf[root] else { continue }
            allocateSeat(child: key, floor: location.floor, bay: location.bay)
        }
    }

    /// The index of `key`'s floor, taking the lowest vacant one if it has none.
    private mutating func allocateFloor(_ key: FloorKey) -> Int {
        for (index, floor) in floors.enumerated() where floor?.key == key { return index }
        if let free = floors.firstIndex(where: { $0 == nil }) {
            floors[free] = FloorState(key: key, bays: [])
            return free
        }
        floors.append(FloorState(key: key, bays: []))
        return floors.count - 1
    }

    private mutating func allocateBay(root: SessionKey, on floorIndex: Int) -> Int {
        guard var floor = floors[floorIndex] else { return 0 }
        defer { floors[floorIndex] = floor }
        let bay = BayState(root: root, seats: [])
        if let free = floor.bays.firstIndex(where: { $0 == nil }) {
            floor.bays[free] = bay
            return free
        }
        floor.bays.append(bay)
        return floor.bays.count - 1
    }

    private mutating func allocateSeat(child: SessionKey, floor floorIndex: Int, bay bayIndex: Int) {
        guard var floor = floors[floorIndex], var bay = floor.bays[bayIndex] else { return }
        if let free = bay.seats.firstIndex(where: { $0 == nil }) {
            bay.seats[free] = child
        } else {
            bay.seats.append(child)
        }
        floor.bays[bayIndex] = bay
        floors[floorIndex] = floor
    }

    // MARK: Geometry

    /// Turns the allocation table into coordinates.
    private func geometry(_ plan: Plan) -> SceneFrame {
        var outFloors: [SceneFloor] = []
        var slots: [SceneSlot] = []
        var anchors: [SessionKey: CGPoint] = [:]
        var scales: [SessionKey: CGFloat] = [:]

        // Floors are shelved: they run left to right and wrap when the next one
        // will not fit, so four projects with two agents each read as one wide
        // building rather than a column six screens tall. A floor is never
        // split across a wrap — a room is a room.
        var shelfTop = metrics.margin
        var shelfHeight: CGFloat = 0
        var shelfUnits: CGFloat = 0
        var cursorX = metrics.margin
        var buildingRight = metrics.margin

        for (floorIndex, floor) in floors.enumerated() {
            guard let floor else { continue }

            // Pack the bays into rows. A bay that does not fit in what is left
            // of a row starts the next one; a bay wider than a whole row gets
            // one to itself rather than being split, because a subagent on the
            // line below its parent is not adjacent to anything.
            var row = 0
            var cursor: CGFloat = 0
            var widest: CGFloat = 0
            var placed: [(bay: Int, row: Int, x: CGFloat)] = []
            placed.reserveCapacity(floor.bays.count)
            for (bayIndex, bay) in floor.bays.enumerated() {
                let width = bay?.width(metrics) ?? Self.vacantBayWidth
                if cursor > 0, cursor + width > metrics.rowUnits + 0.0001 {
                    row += 1
                    cursor = 0
                }
                placed.append((bayIndex, row, cursor))
                cursor += width
                widest = max(widest, cursor)
            }

            let rowCount = placed.isEmpty ? 1 : row + 1
            let units = max(metrics.minimumFloorUnits, widest)
            let height = metrics.floorHeaderHeight + CGFloat(rowCount) * metrics.rowHeight
            var occupancy = 0

            if shelfUnits > 0, shelfUnits + units > metrics.rowUnits + 0.0001 {
                shelfTop += shelfHeight + metrics.floorGap
                shelfHeight = 0
                shelfUnits = 0
                cursorX = metrics.margin
            }
            let left = cursorX
            let top = shelfTop

            for placement in placed {
                let baseline = top + metrics.floorHeaderHeight
                    + CGFloat(placement.row + 1) * metrics.rowHeight
                let bay = floor.bays[placement.bay]
                let identifier = "f\(floorIndex).b\(placement.bay)"

                let rootAnchor = CGPoint(
                    x: left + (placement.x + 0.5) * metrics.cellWidth,
                    y: baseline
                )
                if let bay {
                    occupancy += 1
                    anchors[bay.root] = rootAnchor
                    scales[bay.root] = 1
                }
                slots.append(
                    SceneSlot(
                        id: identifier,
                        session: bay?.root,
                        parent: bay.flatMap { plan.parent[$0.root] },
                        depth: 0,
                        anchor: rootAnchor,
                        scale: 1,
                        floorIndex: floorIndex,
                        row: placement.row
                    )
                )

                for (seat, child) in (bay?.seats ?? []).enumerated() {
                    let offset = placement.x + 1 + (CGFloat(seat) + 0.5) * metrics.childUnit
                    let anchor = CGPoint(x: left + offset * metrics.cellWidth, y: baseline)
                    if let child {
                        occupancy += 1
                        anchors[child] = anchor
                        scales[child] = metrics.childScale
                    }
                    slots.append(
                        SceneSlot(
                            id: "\(identifier).s\(seat)",
                            session: child,
                            parent: child.flatMap { plan.parent[$0] },
                            depth: child.flatMap { plan.depth[$0] } ?? 1,
                            anchor: anchor,
                            scale: metrics.childScale,
                            floorIndex: floorIndex,
                            row: placement.row
                        )
                    )
                }
            }

            outFloors.append(
                SceneFloor(
                    id: "f\(floorIndex)",
                    index: floorIndex,
                    projectKey: floor.key.projectKey,
                    title: Self.title(for: floor.key),
                    frame: CGRect(
                        x: left,
                        y: top,
                        width: units * metrics.cellWidth,
                        height: height
                    ),
                    rowCount: rowCount,
                    occupancy: occupancy
                )
            )

            cursorX += units * metrics.cellWidth + metrics.floorGap
            shelfUnits += units
            shelfHeight = max(shelfHeight, height)
            buildingRight = max(buildingRight, left + units * metrics.cellWidth)
        }

        // Tethers are drawn between desks, so a delegation whose child landed on
        // another floor still gets a line — that crossing is the informative
        // case, not an error to hide.
        var tethers: [SceneTether] = []
        for key in plan.order {
            guard let parent = plan.parent[key],
                  let from = anchors[parent],
                  let to = anchors[key]
            else { continue }
            tethers.append(SceneTether(parent: parent, child: key, from: from, to: to))
        }

        let height = outFloors.isEmpty ? 0 : shelfTop + shelfHeight + metrics.margin
        let width = outFloors.isEmpty ? 0 : buildingRight + metrics.margin
        return SceneFrame(
            floors: outFloors,
            slots: slots,
            tethers: tethers,
            contentRect: CGRect(x: 0, y: 0, width: width, height: height)
        )
    }

    private static func title(for key: FloorKey) -> String {
        switch key {
        case .project(let path): BoardGrouping.projectName(forPath: path)
        case .unplaced: unplacedFloorTitle
        }
    }
}
