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

    /// The long tables, in the order they were opened. `nil` is a table whose
    /// family has stopped meeting.
    private var tables: [TableState?]

    /// Who is on the front row by the path — the waiting bench. `nil` is a
    /// place somebody got up from.
    ///
    /// A table of its own rather than a slice of the lawn's, because the two
    /// have different rules: the lawn is bounded and gives way when a
    /// repository is busy, and the waiting bench never is. A session that said
    /// it wants you is never one of the ones the map decided not to draw.
    private var waitingSeats: [SessionKey?]

    /// Who is on which bench on the back lawn. `nil` is a seat somebody got up
    /// from.
    private var gardenSeats: [SessionKey?]

    /// Who is in the queue for the gate, in the order they joined it.
    private var gateQueue: [SessionKey?]

    /// Creates an empty building.
    public init(metrics: SceneMetrics = .standard) {
        self.metrics = metrics
        self.floors = []
        self.tables = []
        self.waitingSeats = []
        self.gardenSeats = []
        self.gateQueue = []
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

    /// One delegating family, meeting.
    ///
    /// The head is the session that delegated; the seats are its descendants,
    /// alternating sides down the table. Like a bay, the seats are never
    /// shortened while the head is still meeting — a table that shrank every
    /// time a subagent finished would rearrange the room under the reader.
    private struct TableState: Sendable, Equatable {
        var head: SessionKey
        var seats: [SessionKey?]
    }

    /// The width of a bay that has been vacated: one plain workstation.
    private static let vacantBayWidth: CGFloat = 1

    /// The air between a strip's edge and what is drawn inside it.
    private static let stripPadding: CGFloat = 16

    // MARK: - Update

    /// Seats `board` and returns the map to draw.
    ///
    /// - Parameters:
    ///   - board: the frame to lay out. Its own ordering is used only to break
    ///     ties when several new sessions appear at once, so that two layouts
    ///     fed the same boards agree.
    ///   - zones: which annexes are switched on. ``SceneZoneOptions/officeOnly``
    ///     produces exactly the office this layout produced before the annexes
    ///     existed, down to the coordinates.
    ///   - attention: what each session is signalling, if anything. They are
    ///     the ones that sit on the waiting bench by the path, and there is no
    ///     way to derive the map from the board — it is made of things agents
    ///     and harnesses said, which Auspex holds and the transcript does not.
    public mutating func update(
        with board: BoardSnapshot,
        zones: SceneZoneOptions = .all,
        attention: [SessionKey: AttentionState] = [:]
    ) -> SceneFrame {
        let plan = Plan(board: board, zones: zones, attention: attention, metrics: metrics)
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
        /// Which part of the map each session belongs on.
        let placement: [SessionKey: SceneZoning.Placement]
        /// The heads of the tables that want to be open, in board order.
        let tableHeads: [SessionKey]
        /// Each table's children, in board order.
        let tableChildren: [SessionKey: [SessionKey]]
        /// Which annexes are switched on.
        let zones: SceneZoneOptions
        /// The sessions the map does not draw at all — see ``SceneLayout``'s
        /// note on what is bounded and why.
        let offMap: Set<SessionKey>
        /// How many resting sessions the garden counted rather than seated.
        let gardenOverflow: Int

        init(
            board: BoardSnapshot,
            zones: SceneZoneOptions,
            attention: [SessionKey: AttentionState],
            metrics: SceneMetrics
        ) {
            self.board = board
            self.zones = zones
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

            // A table is a family *in one project*, which is the same rule a
            // bay follows and for the same reason: a subagent working in
            // another repository is a root of its own, and dragging it into
            // its parent's meeting would bury the one delegation a person most
            // wants to see. So the meeting room is told about the edges that
            // stay inside a room, and only those.
            var roomParent: [SessionKey: SessionKey] = [:]
            for (child, above) in parent where floorKey[child] == floorKey[above] {
                roomParent[child] = above
            }
            let placement = SceneZoning.placements(
                sessions: board.sessions,
                parent: roomParent,
                attention: attention,
                options: zones
            )
            self.placement = placement

            var heads: [SessionKey] = []
            var children: [SessionKey: [SessionKey]] = [:]
            for key in order {
                guard let seat = placement[key], let table = seat.table else { continue }
                if table == key {
                    heads.append(key)
                } else {
                    children[table, default: []].append(key)
                }
            }
            // A table with no head is a table nobody called: it can only happen
            // if the head left the board between two derivations of the same
            // frame, which it cannot, but seating children around nothing would
            // be silent and wrong rather than loud and wrong.
            let headSet = Set(heads)
            self.tableHeads = heads
            self.tableChildren = children.filter { headSet.contains($0.key) }

            let bounded = Self.bound(
                order: order,
                sessions: board.sessions,
                placement: placement,
                floorKey: floorKey,
                metrics: metrics
            )
            self.offMap = bounded.offMap
            self.gardenOverflow = bounded.gardenOverflow
        }

        /// Decides what the map will not draw.
        ///
        /// ## Why a map has to have a size
        ///
        /// Everything else in this file is about *stability* — a desk that
        /// does not move, a gap that gets reused. This is about *bounds*, and
        /// it is the only rule here that takes something away. A machine that
        /// has been running agents for a week hands the office over a thousand
        /// finished sessions; seating all of them produced a building the
        /// camera had to sit at 6 % zoom to frame, which is a picture of
        /// nothing.
        ///
        /// Two bounds, and each is a statement about what the picture means
        /// rather than a number picked to make it fit:
        ///
        /// - **The gate is a doorway, not a car park.** An ended session walks
        ///   out and is gone. The queue holds the most recently finished
        ///   ``SceneMetrics/gateQueueLimit``; everything that finished before
        ///   them has left, and leaves no desk behind either — it is never
        ///   coming back to sit at one.
        /// - **The back lawn seats a bounded number per project**, dozing
        ///   before resting: a session that may be wrong about working is
        ///   worth more of the picture than one with nothing outstanding. The
        ///   rest are counted on the nameplate. Per project rather than in
        ///   total, so one busy repository cannot push a quiet one's single
        ///   bench off the map.
        ///
        /// Nothing here can remove a session that is working, at a table, or on
        /// the **waiting bench**. The last of those is the point: the front row
        /// is made of things that were said out loud, and a map that quietly
        /// dropped one would be hiding exactly what it exists to show. It is
        /// bounded by the vocabulary instead — nothing lands there without an
        /// agent or a harness having put it there.
        private static func bound(
            order: [SessionKey],
            sessions: [SessionSnapshot],
            placement: [SessionKey: SceneZoning.Placement],
            floorKey: [SessionKey: FloorKey],
            metrics: SceneMetrics
        ) -> (offMap: Set<SessionKey>, gardenOverflow: Int) {
            var byKey: [SessionKey: SessionSnapshot] = [:]
            byKey.reserveCapacity(sessions.count)
            for session in sessions { byKey[session.key] = session }

            /// When a session last did anything, for "most recent first".
            func at(_ key: SessionKey) -> Date {
                guard let session = byKey[key] else { return .distantPast }
                return session.endedAt ?? session.lastEventAt ?? session.startedAt ?? .distantPast
            }

            /// Which of `keys` to keep, `limit` of them, `rank` lowest first
            /// and the most recent first within a rank. Total, so the same
            /// board always drops the same sessions.
            func keep(
                _ keys: [SessionKey], limit: Int, rank: (SessionKey) -> Int = { _ in 0 }
            ) -> Set<SessionKey> {
                guard keys.count > limit else { return Set(keys) }
                let ordered = keys.sorted { lhs, rhs in
                    let lhsRank = rank(lhs)
                    let rhsRank = rank(rhs)
                    if lhsRank != rhsRank { return lhsRank < rhsRank }
                    let lhsAt = at(lhs)
                    let rhsAt = at(rhs)
                    if lhsAt != rhsAt { return lhsAt > rhsAt }
                    return lhs.description < rhs.description
                }
                return Set(ordered.prefix(limit))
            }

            var offMap: Set<SessionKey> = []

            let leaving = order.filter { placement[$0]?.kind == .gate }
            let stillLeaving = keep(leaving, limit: max(0, metrics.gateQueueLimit))
            for key in leaving where !stillLeaving.contains(key) { offMap.insert(key) }

            var resting: [FloorKey: [SessionKey]] = [:]
            for key in order where placement[key]?.kind.isGardenRest == true {
                resting[floorKey[key] ?? .unplaced, default: []].append(key)
            }
            var overflow = 0
            for (_, keys) in resting {
                // A doze is a session that may be wrong about claiming to
                // work. A bench is the one with nothing outstanding, so it is
                // the one that gives way.
                let seated = keep(keys, limit: max(0, metrics.gardenSeatsPerProject)) { key in
                    placement[key]?.kind == .doze ? 0 : 1
                }
                for key in keys where !seated.contains(key) {
                    offMap.insert(key)
                    overflow += 1
                }
            }
            return (offMap, overflow)
        }

        /// Where one session goes. The office desk for anything the annexes
        /// have no opinion about.
        func place(_ key: SessionKey) -> SceneZoning.Placement {
            placement[key] ?? .desk
        }

        /// Whether the map draws `key` anywhere at all.
        func draws(_ key: SessionKey) -> Bool { !offMap.contains(key) }
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
                    && plan.draws(bay.root)
                guard rootIsStillHere else {
                    floor.bays[bayIndex] = nil
                    continue
                }
                for seat in bay.seats.indices {
                    guard let child = bay.seats[seat] else { continue }
                    if plan.bayRoot[child] != bay.root || !plan.draws(child) {
                        bay.seats[seat] = nil
                    }
                }
                floor.bays[bayIndex] = bay
            }

            while let last = floor.bays.last, last == nil { floor.bays.removeLast() }
            floors[index] = floor.bays.isEmpty ? nil : floor
        }
        while let last = floors.last, last == nil { floors.removeLast() }

        sweepAnnexes(plan)
    }

    /// Releases every chair and bench whose occupant has gone back to work,
    /// left the board, or moved to the other annex.
    ///
    /// The same four rules the office follows, for the same reason: a person
    /// who looks away for a minute should come back to the garden they left,
    /// not to one that has been re-sorted around them.
    private mutating func sweepAnnexes(_ plan: Plan) {
        let heads = Set(plan.tableHeads)
        for index in tables.indices {
            guard let table = tables[index] else { continue }
            guard heads.contains(table.head) else {
                tables[index] = nil
                continue
            }
            let children = Set(plan.tableChildren[table.head] ?? [])
            var kept = table
            for seat in kept.seats.indices {
                guard let child = kept.seats[seat] else { continue }
                if !children.contains(child) { kept.seats[seat] = nil }
            }
            tables[index] = kept
        }
        while let last = tables.last, last == nil { tables.removeLast() }

        release(&waitingSeats) { plan.draws($0) && plan.place($0).kind.isWaitingBench }
        release(&gardenSeats) { plan.draws($0) && plan.place($0).kind.isGardenRest }
        release(&gateQueue) { plan.draws($0) && plan.place($0).kind == .gate }
        while let last = waitingSeats.last, last == nil { waitingSeats.removeLast() }
        while let last = gardenSeats.last, last == nil { gardenSeats.removeLast() }
        while let last = gateQueue.last, last == nil { gateQueue.removeLast() }
    }

    /// Empties every place in `slots` whose occupant no longer belongs there.
    private func release(_ slots: inout [SessionKey?], keeping: (SessionKey) -> Bool) {
        for index in slots.indices {
            guard let key = slots[index] else { continue }
            if !keeping(key) { slots[index] = nil }
        }
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

        for key in plan.order
        where plan.bayRoot[key] == key && !seated.contains(key) && plan.draws(key) {
            guard let floorKey = plan.floorKey[key] else { continue }
            let floorIndex = allocateFloor(floorKey)
            let bayIndex = allocateBay(root: key, on: floorIndex)
            bayOf[key] = (floorIndex, bayIndex)
        }

        for key in plan.order
        where plan.bayRoot[key] != key && !seated.contains(key) && plan.draws(key) {
            guard let root = plan.bayRoot[key], let location = bayOf[root] else { continue }
            allocateSeat(child: key, floor: location.floor, bay: location.bay)
        }

        seatAnnexes(plan)
    }

    /// Gives everybody who has left their desk somewhere to be.
    private mutating func seatAnnexes(_ plan: Plan) {
        var tableOf: [SessionKey: Int] = [:]
        var placed: Set<SessionKey> = []
        for (index, table) in tables.enumerated() {
            guard let table else { continue }
            tableOf[table.head] = index
            placed.insert(table.head)
            for child in table.seats { if let child { placed.insert(child) } }
        }

        for head in plan.tableHeads where tableOf[head] == nil {
            tableOf[head] = openTable(head: head)
        }
        for head in plan.tableHeads {
            guard let index = tableOf[head] else { continue }
            for child in plan.tableChildren[head] ?? [] where !placed.contains(child) {
                take(child, at: index)
            }
        }

        var waiting: Set<SessionKey> = []
        for key in waitingSeats { if let key { waiting.insert(key) } }
        var resting: Set<SessionKey> = []
        for key in gardenSeats { if let key { resting.insert(key) } }
        var leaving: Set<SessionKey> = []
        for key in gateQueue { if let key { leaving.insert(key) } }

        for key in plan.order where plan.draws(key) {
            let kind = plan.place(key).kind
            if kind.isWaitingBench, !waiting.contains(key) {
                Self.claim(key, in: &waitingSeats)
            } else if kind.isGardenRest, !resting.contains(key) {
                Self.claim(key, in: &gardenSeats)
            } else if kind == .gate, !leaving.contains(key) {
                Self.claim(key, in: &gateQueue)
            }
        }
    }

    /// Opens a table for `head`, reusing one whose family has broken up.
    private mutating func openTable(head: SessionKey) -> Int {
        let table = TableState(head: head, seats: [])
        if let free = tables.firstIndex(where: { $0 == nil }) {
            tables[free] = table
            return free
        }
        tables.append(table)
        return tables.count - 1
    }

    /// Sits `child` down at the lowest free chair of table `index`.
    private mutating func take(_ child: SessionKey, at index: Int) {
        guard var table = tables[index] else { return }
        if let free = table.seats.firstIndex(where: { $0 == nil }) {
            table.seats[free] = child
        } else {
            table.seats.append(child)
        }
        tables[index] = table
    }

    /// Puts `key` in the lowest free place, growing the list only when there
    /// is none — the office's own rule, so an annex that has churned all day
    /// is no wider than its busiest moment.
    private static func claim(_ key: SessionKey, in places: inout [SessionKey?]) {
        if let free = places.firstIndex(where: { $0 == nil }) {
            places[free] = key
        } else {
            places.append(key)
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

    /// One floor, measured but not yet placed.
    private struct FloorMeasurement {
        let index: Int
        let floor: FloorState
        /// Which row each bay landed on, and how far along it.
        let placed: [(bay: Int, row: Int, x: CGFloat)]
        let rowCount: Int
        /// How wide the room is, in units.
        let units: CGFloat
        let height: CGFloat
    }

    /// Packs one floor's bays into rows. A bay that does not fit in what is
    /// left of a row starts the next one; a bay wider than a whole row gets one
    /// to itself rather than being split, because a subagent on the line below
    /// its parent is not adjacent to anything.
    private func measure(_ floor: FloorState, index: Int) -> FloorMeasurement {
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
        return FloorMeasurement(
            index: index,
            floor: floor,
            placed: placed,
            rowCount: rowCount,
            units: max(metrics.minimumFloorUnits, widest),
            height: metrics.floorHeaderHeight + CGFloat(rowCount) * metrics.rowHeight
        )
    }

    /// Turns the allocation table into coordinates.
    private func geometry(_ plan: Plan) -> SceneFrame {
        var outFloors: [SceneFloor] = []
        var slots: [SceneSlot] = []
        var anchors: [SessionKey: CGPoint] = [:]
        var scales: [SessionKey: CGFloat] = [:]

        // Measuring every room before placing any of them is what lets the
        // campus decide how wide to be: the shelf width is a function of how
        // much building there is, and that is not known until the last room
        // has been packed.
        let measured = floors.enumerated().compactMap { index, floor in
            floor.map { measure($0, index: index) }
        }
        let totalUnits = measured.reduce(0) { $0 + $1.units }
        let averageHeight = measured.isEmpty
            ? 0
            : measured.reduce(0) { $0 + $1.height } / CGFloat(measured.count)
        let shelfWidth = metrics.shelfUnits(
            totalUnits: totalUnits, averageFloorHeight: averageHeight
        )

        // Floors are shelved: they run left to right and wrap when the next one
        // will not fit, so four projects with two agents each read as one wide
        // building rather than a column six screens tall. A floor is never
        // split across a wrap — a room is a room.
        var shelfTop = metrics.margin
        var shelfHeight: CGFloat = 0
        var shelfUnits: CGFloat = 0
        var cursorX = metrics.margin
        var buildingRight = metrics.margin

        for measurement in measured {
            let floorIndex = measurement.index
            let floor = measurement.floor
            let placed = measurement.placed
            let rowCount = measurement.rowCount
            let units = measurement.units
            let height = measurement.height
            var occupancy = 0

            if shelfUnits > 0, shelfUnits + units > shelfWidth + 0.0001 {
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
                        row: placement.row,
                        isAway: bay.map { plan.place($0.root).zone != .office } ?? false
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
                            row: placement.row,
                            isAway: child.map { plan.place($0).zone != .office } ?? false
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

        // The office is finished and has not moved a point. Everything after
        // this hangs below it, which is what makes "switch the annexes off"
        // and "the office as it was" the same picture rather than two pictures
        // that have to be kept in step.
        let officeBottom = outFloors.isEmpty ? metrics.margin : shelfTop + shelfHeight
        let officeRight = outFloors.isEmpty ? metrics.margin : buildingRight
        var annexes = Annexes(
            metrics: metrics,
            left: metrics.margin,
            width: max(officeRight - metrics.margin, metrics.rowUnits * metrics.cellWidth),
            top: officeBottom
        )
        annexes.layOutMeeting(tables: tables, plan: plan)
        annexes.layOutGarden(
            waiting: waitingSeats,
            resting: gardenSeats,
            leaving: gateQueue,
            plan: plan
        )

        // Where somebody is, not where their desk is. A parent who has walked
        // to a table and a child that followed it there are still a delegation,
        // and the line has to go where they went.
        for seat in annexes.seats {
            guard let key = seat.session else { continue }
            anchors[key] = seat.anchor
            scales[key] = seat.scale
        }

        // Tethers are drawn between people rather than between desks, so a
        // delegation whose child landed on another floor still gets a line —
        // that crossing is the informative case, not an error to hide — and a
        // family that got up and walked to a table takes its lines with it.
        //
        // They are drawn around a table too, short as they are. "Every
        // delegation on this board has a line" is a property somebody reads
        // the picture with, and a room where it silently stops holding is a
        // room where a missing line means nothing.
        var tethers: [SceneTether] = []
        for key in plan.order {
            guard let parent = plan.parent[key],
                  let from = anchors[parent],
                  let to = anchors[key]
            else { continue }
            tethers.append(SceneTether(parent: parent, child: key, from: from, to: to))
        }

        let bottom = max(officeBottom, annexes.bottom)
        let right = max(officeRight, annexes.right)
        let isEmpty = outFloors.isEmpty && annexes.areas.isEmpty
        let height = isEmpty ? 0 : bottom + metrics.margin
        let width = isEmpty ? 0 : right + metrics.margin
        return SceneFrame(
            floors: outFloors,
            slots: slots,
            tethers: tethers,
            contentRect: CGRect(x: 0, y: 0, width: width, height: height),
            zones: annexes.areas,
            seats: annexes.seats,
            tables: annexes.tables,
            gate: annexes.gate,
            walkways: SceneWalkways(
                trunk: metrics.margin / 2,
                lanes: annexes.lanes(officeBottom: officeBottom)
            ),
            metrics: metrics
        )
    }

    private static func title(for key: FloorKey) -> String {
        switch key {
        case .project(let path): BoardGrouping.projectName(forPath: path)
        case .unplaced: unplacedFloorTitle
        }
    }

    // MARK: - The annexes

    /// Lays the meeting room and the garden out below the office.
    ///
    /// ## Why the annexes are strips and not a second campus
    ///
    /// The office shelves sideways because it is made of rooms whose count is
    /// the number of repositories somebody has open, which is unbounded. The
    /// annexes are not: there is one meeting room and one garden however busy
    /// the day is, and what grows inside them — tables, benches — is bounded by
    /// the same sessions the office already sized itself for. So they are laid
    /// out as full-width strips under the building, which makes the map read
    /// top to bottom as *working, meeting, resting, gone* and makes "walk from
    /// here to there" a trip down one gutter rather than a search.
    ///
    /// Nothing here can move the office. It is handed the office's bottom edge
    /// and its width and it only ever grows downward, which is what makes the
    /// annexes-off picture identical to the picture before they existed rather
    /// than merely similar to it.
    private struct Annexes {
        let metrics: SceneMetrics
        let left: CGFloat
        /// How wide the office is, which is the width the strips take unless
        /// what is in them needs more.
        let width: CGFloat

        private(set) var areas: [SceneZoneArea] = []
        private(set) var seats: [SceneSeat] = []
        private(set) var tables: [SceneTable] = []
        private(set) var gate: CGPoint?
        /// The lowest point anything in the annexes reaches.
        private(set) var bottom: CGFloat
        /// The rightmost point anything in them reaches.
        private(set) var right: CGFloat

        private var cursor: CGFloat
        private var meetingLane: CGFloat?
        private var gardenLane: CGFloat?

        init(metrics: SceneMetrics, left: CGFloat, width: CGFloat, top: CGFloat) {
            self.metrics = metrics
            self.left = left
            self.width = width
            self.bottom = top
            // Starts at the left edge and not at `left + width`: a strip only
            // widens the map once one has actually been placed, which is what
            // keeps a switched-off annex from quietly padding the office out to
            // a full row.
            self.right = left
            self.cursor = top
        }

        /// The walkways, once both strips have been placed.
        func lanes(officeBottom: CGFloat) -> [SceneZone: CGFloat] {
            var lanes: [SceneZone: CGFloat] = [
                .office: officeBottom + metrics.floorGap / 2
            ]
            if let meetingLane { lanes[.meeting] = meetingLane }
            if let gardenLane { lanes[.garden] = gardenLane }
            return lanes
        }

        // MARK: Meeting room

        mutating func layOutMeeting(tables state: [TableState?], plan: Plan) {
            guard plan.zones.meetingRoom else { return }
            let live = state.enumerated().compactMap { index, table in
                table.map { (index: index, table: $0) }
            }
            guard !live.isEmpty else { return }

            let top = cursor + metrics.floorGap
            let inner = left + Self.padding
            let limit = left + width - Self.padding
            var cursorX = inner
            var row = 0
            var widest = inner
            var occupancy = 0

            for entry in live {
                let children = entry.table.seats.count
                let tableWidth = metrics.tableWidth(children: children)
                if cursorX > inner, cursorX + tableWidth > limit + 0.0001 {
                    row += 1
                    cursorX = inner
                }
                let tableTop = top + metrics.floorHeaderHeight
                    + CGFloat(row) * (metrics.tableHeight + metrics.tableGap)
                let rect = CGRect(
                    x: cursorX, y: tableTop, width: tableWidth, height: metrics.tableHeight
                )
                let id = "z.meeting.t\(entry.index)"
                let floorKey = plan.floorKey[entry.table.head]
                tables.append(
                    SceneTable(
                        id: id,
                        head: entry.table.head,
                        projectKey: floorKey?.projectKey,
                        title: floorKey.map(SceneLayout.title(for:)) ?? "",
                        frame: rect,
                        seatCount: children
                    )
                )
                occupancy += 1
                seats.append(
                    SceneSeat(
                        id: "\(id).head",
                        session: entry.table.head,
                        kind: .tableHead,
                        anchor: CGPoint(x: rect.minX + 30, y: rect.minY + metrics.tableSurfaceBottom),
                        scale: 1,
                        tableID: id
                    )
                )
                for (index, child) in entry.table.seats.enumerated() {
                    if child != nil { occupancy += 1 }
                    let column = index / 2
                    let isFarSide = index.isMultiple(of: 2)
                    let x = rect.minX + metrics.tableHeadWidth + 20
                        + (CGFloat(column) + 0.5) * metrics.tableSeatSpacing
                    let y = isFarSide
                        ? rect.minY + metrics.tableSurfaceTop
                        : rect.minY + metrics.tableNearSeatY
                    seats.append(
                        SceneSeat(
                            id: "\(id).c\(index)",
                            session: child,
                            kind: isFarSide ? .tableNorth : .tableSouth,
                            anchor: CGPoint(x: x, y: y),
                            scale: metrics.childScale,
                            tableID: id
                        )
                    )
                }
                cursorX += tableWidth + metrics.tableGap
                widest = max(widest, cursorX - metrics.tableGap)
            }

            let rows = row + 1
            let height = metrics.floorHeaderHeight
                + CGFloat(rows) * (metrics.tableHeight + metrics.tableGap)
                - metrics.tableGap + Self.padding
            let stripWidth = max(width, widest - left + Self.padding)
            let rect = CGRect(x: left, y: top, width: stripWidth, height: height)
            meetingLane = rect.maxY - Self.laneInset
            areas.append(
                SceneZoneArea(
                    id: "z.meeting",
                    zone: .meeting,
                    title: Self.meetingTitle,
                    frame: rect,
                    rowCount: rows,
                    occupancy: occupancy,
                    laneY: rect.maxY - Self.laneInset
                )
            )
            cursor = rect.maxY
            bottom = max(bottom, rect.maxY)
            right = max(right, rect.maxX)
        }

        // MARK: Garden

        /// Lays the garden out: the back lawn, then the waiting bench along
        /// the path at the front, then the gate.
        ///
        /// ## Why the front row exists
        ///
        /// The garden used to be one grid of benches, and the two things a
        /// person actually comes to this map for — *is anything stuck on me*
        /// and *did anything finish* — were somewhere inside it, next to a
        /// dozen sessions doing nothing. A picture where the urgent thing is
        /// laid out exactly like the unimportant thing is a picture you have to
        /// read rather than glance at.
        ///
        /// So the garden has a front and a back. The front row runs along the
        /// walkway, is the last thing between the reader and the path, and
        /// holds only sessions that said something out loud: a red `!` for
        /// somebody waiting on a person, a green `✓` for a receipt nobody has
        /// read. The back lawn is everything that is merely resting, and it is
        /// the half that gives way when a busy repository fills the map.
        mutating func layOutGarden(
            waiting: [SessionKey?],
            resting: [SessionKey?],
            leaving: [SessionKey?],
            plan: Plan
        ) {
            guard plan.zones.garden else { return }
            let leavingCount = leaving.count
            // The overflow counts too: a garden with twelve benches and forty
            // more people in it has to be drawn to be able to say so.
            guard !waiting.isEmpty || !resting.isEmpty || leavingCount > 0
                || plan.gardenOverflow > 0
            else { return }

            let top = cursor + metrics.floorGap
            // The gate end is kept clear of benches, and it widens with the
            // queue: a session on its way out walking through somebody's picnic
            // is the kind of overlap a fixed reserve produces on exactly the
            // busy afternoon nobody wants to debug.
            let reserve = max(
                metrics.gateReserve, Self.gatePost + CGFloat(leavingCount) * Self.queueSpacing
            )
            let usable = width - Self.padding * 2 - reserve
            let columns = max(1, Int((usable / metrics.gardenSeatSpacing).rounded(.down)))
            let lawnRows = resting.isEmpty
                ? 0 : max(1, (resting.count + columns - 1) / columns)
            // The waiting bench wraps like the lawn does. It is normally one
            // row and it has to survive the afternoon where it is not.
            let waitingRows = waiting.isEmpty
                ? 0 : max(1, (waiting.count + columns - 1) / columns)
            // At least one row of garden even when nobody is in it, because the
            // gate stands in it and the overflow count is written on it.
            let rows = max(1, lawnRows + waitingRows)
            let height = metrics.floorHeaderHeight + CGFloat(rows) * metrics.gardenRowHeight
            let rect = CGRect(x: left, y: top, width: width, height: height)

            /// The floor line of one row, counting from the top of the strip.
            func rowY(_ row: Int) -> CGFloat {
                top + metrics.floorHeaderHeight
                    + CGFloat(row + 1) * metrics.gardenRowHeight - Self.seatLift
            }

            /// Where the `index`th person in a band stands.
            func anchor(index: Int, firstRow: Int) -> CGPoint {
                CGPoint(
                    x: left + Self.padding
                        + (CGFloat(index % columns) + 0.5) * metrics.gardenSeatSpacing,
                    y: rowY(firstRow + index / columns)
                )
            }

            var occupancy = 0
            // The lawn first, at the back, because the strip is drawn top to
            // bottom and the path is along the bottom edge.
            for (index, key) in resting.enumerated() {
                if key != nil { occupancy += 1 }
                seats.append(
                    SceneSeat(
                        id: "z.garden.s\(index)",
                        session: key,
                        kind: key.map { plan.place($0).kind } ?? .bench,
                        anchor: anchor(index: index, firstRow: 0),
                        scale: 1
                    )
                )
            }
            // Then the front row, nearest the walkway. Its own id prefix, so a
            // renderer diffing nodes never mistakes a bench on the lawn for a
            // place on the waiting bench and animates somebody sideways across
            // the garden when a receipt arrives.
            for (index, key) in waiting.enumerated() {
                if key != nil { occupancy += 1 }
                seats.append(
                    SceneSeat(
                        id: "z.garden.w\(index)",
                        session: key,
                        kind: key.map { plan.place($0).kind } ?? .note,
                        anchor: anchor(index: index, firstRow: lawnRows),
                        scale: 1
                    )
                )
            }

            let gateY = rowY(0)
            let gatePoint = CGPoint(x: rect.maxX - reserve / 2, y: gateY)
            gate = gatePoint
            for (index, key) in leaving.enumerated() {
                if key != nil { occupancy += 1 }
                seats.append(
                    SceneSeat(
                        id: "z.garden.g\(index)",
                        session: key,
                        kind: .gate,
                        anchor: CGPoint(
                            x: gatePoint.x - Self.gatePost / 2
                                - CGFloat(index) * Self.queueSpacing,
                            y: gateY
                        ),
                        scale: 1
                    )
                )
            }

            gardenLane = rect.maxY - Self.laneInset
            areas.append(
                SceneZoneArea(
                    id: "z.garden",
                    zone: .garden,
                    title: Self.gardenTitle,
                    frame: rect,
                    rowCount: rows,
                    occupancy: occupancy,
                    laneY: rect.maxY - Self.laneInset,
                    overflow: plan.gardenOverflow
                )
            )
            cursor = rect.maxY
            bottom = max(bottom, rect.maxY)
            right = max(right, rect.maxX)
        }

        /// The air between a strip's edge and what is drawn inside it.
        private static let padding: CGFloat = SceneLayout.stripPadding
        /// How far above a row's bottom line somebody's feet are.
        private static let seatLift: CGFloat = 26
        /// How far above a strip's bottom edge its walkway runs.
        private static let laneInset: CGFloat = 14
        /// How much room the gate itself takes.
        private static let gatePost: CGFloat = 96
        /// The gap between two sessions queueing to leave.
        private static let queueSpacing: CGFloat = 38

        static let meetingTitle = "Meeting room"
        static let gardenTitle = "Garden"
    }
}
