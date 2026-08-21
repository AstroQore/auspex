import AgentSessionLive
import CoreGraphics
import Foundation

/// Seats every session on the board, and remembers where it put them.
///
/// ## Why this is stateful, and why it is still pure
///
/// A board frame arrives up to twenty times a second and its session order is
/// *not* stable: the board sorts by urgency, so a session that hits a
/// permission prompt jumps to the front. Laying the office out directly from
/// that order would rearrange the furniture every time somebody started
/// thinking. So the layout keeps an allocation table — which suite a project
/// took, which bay an agent took, which seat a subagent took — and the table,
/// not the frame, decides where things go.
///
/// It is still a pure function of (previous table, board): no clock, no
/// randomness, no I/O. Feeding the same sequence of boards through a fresh
/// layout always produces the same sequence of frames, which is what makes the
/// stability properties testable rather than merely intended.
///
/// ## One project is one company
///
/// A project's sessions do not share a room and then wander off to a
/// building-wide meeting room and a building-wide garden. They share a
/// **suite**: a block of desks, the meeting rooms that company has, and one
/// break room whose kind — garden, tea room or lounge — is decided by the
/// project itself and stays decided. Everything a project's people do happens
/// inside its own outline, which is what makes "whose meeting is this" and
/// "who is waiting on me, and on what" answerable by looking at one rectangle
/// instead of by reading nameplates in a strip shared by forty repositories.
///
/// Suites tile the campus exactly as rooms did (see
/// ``SceneMetrics/shelfUnits(totalUnits:averageFloorHeight:)``); what changed
/// is how tall one of them is.
///
/// ## The four rules
///
/// - **A desk is held for as long as its session is on the board.** Not for as
///   long as it is *running* — an ended session keeps its desk until it walks
///   out of the door, because a card that vanishes the instant a build
///   finishes is a card nobody got to read.
/// - **A new session takes the lowest free slot.** Interior gaps are reused
///   before the building grows, so an office that has churned for eight hours
///   is no wider than its busiest moment.
/// - **Nothing already seated moves when somebody arrives or leaves.** The one
///   exception is deliberate: the first time an agent delegates, its bay widens
///   to make room for the subagent and the bays after it slide over. The bay
///   keeps that width until its agent leaves, so it happens once per agent and
///   it happens for a reason a viewer can see.
/// - **Trailing gaps close.** A freed slot at the end of a row, or an empty
///   suite at the end of the campus, is removed rather than left as a stub, so
///   the campus shrinks back when the day quiets down.
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
/// follow its parent into that suite — it is a root of its own bay in the
/// suite it is actually working in, and only the tether says where it came
/// from. A delegation that crosses repositories is exactly the thing a person
/// wants to see, and burying it in the parent's company would hide it.
public struct SceneLayout: Sendable, Equatable {
    /// The floor plan this layout measures with.
    public let metrics: SceneMetrics

    /// The campus, suite by suite. `nil` is a suite that has been vacated and
    /// is waiting for the next project to take it.
    private var floors: [FloorState?]

    /// Creates an empty campus.
    public init(metrics: SceneMetrics = .standard) {
        self.metrics = metrics
        self.floors = []
    }

    /// The title the suite with no project shows.
    public static let unplacedFloorTitle = "No project"

    // MARK: - Allocation state

    /// Which project a suite belongs to. A separate type from `String?` so the
    /// "no directory anywhere in the chain" suite cannot be confused with a
    /// project literally named the empty string.
    private enum FloorKey: Hashable, Sendable {
        case project(String)
        case unplaced

        var projectKey: String? {
            if case .project(let path) = self { return path }
            return nil
        }
    }

    /// One company's premises: its desks, its meeting rooms, its break room.
    ///
    /// All five tables live together because they are all allocations *of one
    /// project*, and keeping them together is what makes "this suite is empty,
    /// give it to somebody else" a single question rather than five that have
    /// to agree.
    private struct FloorState: Sendable, Equatable {
        var key: FloorKey
        /// `nil` is a vacated bay, held so the desks after it do not slide.
        var bays: [BayState?]
        /// The meeting rooms, in the order they were opened. `nil` is a room
        /// whose family has stopped meeting.
        var tables: [TableState?]
        /// Who is on the bench by the door — the waiting bench. `nil` is a
        /// place somebody got up from.
        ///
        /// A table of its own rather than a slice of the break room's, because
        /// the two have different rules: the rest of the room is bounded and
        /// gives way when a repository is busy, and the waiting bench never
        /// is. A session that said it wants you is never one of the ones the
        /// map decided not to draw.
        var waiting: [SessionKey?]
        /// Who is on which bench or in which corner. `nil` is a seat somebody
        /// got up from.
        var resting: [SessionKey?]
        /// Who is on their way to the door, in the order they set off.
        var leaving: [SessionKey?]

        init(key: FloorKey) {
            self.key = key
            self.bays = []
            self.tables = []
            self.waiting = []
            self.resting = []
            self.leaving = []
        }

        /// Whether anybody at all is allocated anywhere in this suite.
        var isVacant: Bool {
            bays.allSatisfy { $0 == nil }
                && tables.allSatisfy { $0 == nil }
                && waiting.allSatisfy { $0 == nil }
                && resting.allSatisfy { $0 == nil }
                && leaving.allSatisfy { $0 == nil }
        }
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

    /// One meeting room, in use.
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

    /// The air between a room's edge and what is drawn inside it.
    private static let stripPadding: CGFloat = 16
    /// How far above a row's bottom line somebody's feet are.
    private static let seatLift: CGFloat = 26
    /// How far above a suite's bottom edge its corridor runs.
    private static let laneInset: CGFloat = 14
    /// The gap between two sessions on their way to the door.
    private static let queueSpacing: CGFloat = 32

    static let meetingTitle = "Meeting room"
    static let meetingRoomsTitle = "Meeting rooms"

    // MARK: - Update

    /// Seats `board` and returns the map to draw.
    ///
    /// - Parameters:
    ///   - board: the frame to lay out. Its own ordering is used only to break
    ///     ties when several new sessions appear at once, so that two layouts
    ///     fed the same boards agree.
    ///   - zones: which of a suite's rooms are switched on.
    ///     ``SceneZoneOptions/officeOnly`` produces exactly the office this
    ///     layout produced before the other rooms existed, down to the
    ///     coordinates.
    ///   - attention: what each session is signalling, if anything. They are
    ///     the ones that sit on the waiting bench by the door, and there is no
    ///     way to derive the map from the board — it is made of things agents
    ///     and harnesses said, which Auspex holds and the transcript does not.
    ///   - departed: sessions that have finished walking out of their
    ///     company's door. They are drawn nowhere and hold nothing: their desk
    ///     is released, their place in the queue is released, and the suite
    ///     shrinks back. The renderer owns this set because *when* somebody has
    ///     left is a fact about an animation finishing, not about a board.
    public mutating func update(
        with board: BoardSnapshot,
        zones: SceneZoneOptions = .all,
        attention: [SessionKey: AttentionState] = [:],
        departed: Set<SessionKey> = []
    ) -> SceneFrame {
        let plan = Plan(
            board: board,
            zones: zones,
            attention: attention,
            departed: departed,
            metrics: metrics
        )
        sweep(plan)
        seat(plan)
        return geometry(plan)
    }

    // MARK: Plan

    /// Everything derived from one board that both the sweep and the seating
    /// pass need, computed once.
    private struct Plan {
        let board: BoardSnapshot
        /// Which suite each session belongs in.
        let floorKey: [SessionKey: FloorKey]
        /// The bay root each session sits with — itself, when it is a root.
        let bayRoot: [SessionKey: SessionKey]
        /// The parent each session is tethered to, when the board has one.
        let parent: [SessionKey: SessionKey]
        /// How far below its bay root a session sits.
        let depth: [SessionKey: Int]
        /// How many children each session has on this board.
        let childCount: [SessionKey: Int]
        /// Sessions in the order the board reported them.
        let order: [SessionKey]
        /// Which part of its suite each session belongs in.
        let placement: [SessionKey: SceneZoning.Placement]
        /// The heads of the meeting rooms that want to be open, in board order.
        let tableHeads: [SessionKey]
        /// Each meeting room's children, in board order.
        let tableChildren: [SessionKey: [SessionKey]]
        /// How many sessions each suite holds, for the rule that a company of
        /// three has a meeting room whether or not it is using it.
        let population: [FloorKey: Int]
        /// Which rooms are switched on.
        let zones: SceneZoneOptions
        /// The sessions the map does not draw at all — see ``SceneLayout``'s
        /// note on what is bounded and why.
        let offMap: Set<SessionKey>
        /// How many resting sessions each break room counted rather than
        /// seated.
        let overflow: [FloorKey: Int]

        init(
            board: BoardSnapshot,
            zones: SceneZoneOptions,
            attention: [SessionKey: AttentionState],
            departed: Set<SessionKey>,
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
            var childCount: [SessionKey: Int] = [:]
            for session in board.sessions {
                guard let claimed = session.identity.parent,
                      claimed != session.key,
                      present.contains(claimed)
                else { continue }
                parent[session.key] = claimed
                childCount[claimed, default: 0] += 1
            }
            self.parent = parent
            self.childCount = childCount

            // Walk to the top of the delegation chain, stopping at a suite
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
            // stay inside a suite, and only those.
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
            for key in order where !departed.contains(key) {
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
                departed: departed,
                metrics: metrics
            )
            self.offMap = bounded.offMap
            self.overflow = bounded.overflow

            // How big a company is, counted in the people the map actually
            // draws. Counting everything on the board instead would give a
            // repository with two hundred finished sessions a meeting room and
            // a break room for a staff of one, because the two hundred are
            // bounded away a few lines above this.
            var population: [FloorKey: Int] = [:]
            for key in order where !bounded.offMap.contains(key) {
                population[floorKey[key] ?? .unplaced, default: 0] += 1
            }
            self.population = population
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
        /// Three bounds, and each is a statement about what the picture means
        /// rather than a number picked to make it fit:
        ///
        /// - **Somebody who has left has left.** A session the renderer says
        ///   walked out of its company's door is drawn nowhere and holds
        ///   nothing. This is the one that keeps the map from filling with
        ///   people who finished hours ago.
        /// - **A door is a doorway, not a car park.** The queue at one holds
        ///   the most recently finished ``SceneMetrics/gateQueueLimit``, which
        ///   with people actually leaving is only ever whoever is mid-stride.
        /// - **A break room seats a bounded number per project**, dozing
        ///   before resting: a session that may be wrong about working is
        ///   worth more of the picture than one with nothing outstanding. The
        ///   rest are counted on the nameplate.
        ///
        /// Nothing here can remove a session that is working, at a table, or on
        /// the **waiting bench**. The last of those is the point: that bench is
        /// made of things that were said out loud, and a map that quietly
        /// dropped one would be hiding exactly what it exists to show. It is
        /// bounded by the vocabulary instead — nothing lands there without an
        /// agent or a harness having put it there.
        private static func bound(
            order: [SessionKey],
            sessions: [SessionSnapshot],
            placement: [SessionKey: SceneZoning.Placement],
            floorKey: [SessionKey: FloorKey],
            departed: Set<SessionKey>,
            metrics: SceneMetrics
        ) -> (offMap: Set<SessionKey>, overflow: [FloorKey: Int]) {
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

            var offMap = departed
            let drawn = order.filter { !departed.contains($0) }

            var leavingByFloor: [FloorKey: [SessionKey]] = [:]
            for key in drawn where placement[key]?.kind == .gate {
                leavingByFloor[floorKey[key] ?? .unplaced, default: []].append(key)
            }
            for (_, keys) in leavingByFloor {
                let staying = keep(keys, limit: max(0, metrics.gateQueueLimit))
                for key in keys where !staying.contains(key) { offMap.insert(key) }
            }

            var resting: [FloorKey: [SessionKey]] = [:]
            for key in drawn where placement[key]?.kind.isBreakRest == true {
                resting[floorKey[key] ?? .unplaced, default: []].append(key)
            }
            var overflow: [FloorKey: Int] = [:]
            for (floor, keys) in resting {
                // A doze is a session that may be wrong about claiming to
                // work. A bench is the one with nothing outstanding, so it is
                // the one that gives way.
                let seated = keep(keys, limit: max(0, metrics.gardenSeatsPerProject)) { key in
                    placement[key]?.kind == .doze ? 0 : 1
                }
                for key in keys where !seated.contains(key) {
                    offMap.insert(key)
                    overflow[floor, default: 0] += 1
                }
            }
            return (offMap, overflow)
        }

        /// Where one session goes. The office desk for anything the other
        /// rooms have no opinion about.
        func place(_ key: SessionKey) -> SceneZoning.Placement {
            placement[key] ?? .desk
        }

        /// Whether the map draws `key` anywhere at all.
        func draws(_ key: SessionKey) -> Bool { !offMap.contains(key) }
    }

    // MARK: Sweep

    /// Releases every desk, chair and bench whose occupant has left the board,
    /// changed project, or stopped being the session it was seated as.
    ///
    /// The same four rules everywhere in the suite, for the same reason: a
    /// person who looks away for a minute should come back to the company they
    /// left, not to one that has been re-sorted around them.
    private mutating func sweep(_ plan: Plan) {
        let heads = Set(plan.tableHeads)
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

            for tableIndex in floor.tables.indices {
                guard let table = floor.tables[tableIndex] else { continue }
                guard heads.contains(table.head), plan.floorKey[table.head] == floor.key else {
                    floor.tables[tableIndex] = nil
                    continue
                }
                let children = Set(plan.tableChildren[table.head] ?? [])
                var kept = table
                for seat in kept.seats.indices {
                    guard let child = kept.seats[seat] else { continue }
                    if !children.contains(child) { kept.seats[seat] = nil }
                }
                floor.tables[tableIndex] = kept
            }
            while let last = floor.tables.last, last == nil { floor.tables.removeLast() }

            release(&floor.waiting, on: floor.key, plan: plan) { $0.isWaitingBench }
            release(&floor.resting, on: floor.key, plan: plan) { $0.isBreakRest }
            release(&floor.leaving, on: floor.key, plan: plan) { $0 == .gate }
            while let last = floor.waiting.last, last == nil { floor.waiting.removeLast() }
            while let last = floor.resting.last, last == nil { floor.resting.removeLast() }
            while let last = floor.leaving.last, last == nil { floor.leaving.removeLast() }

            floors[index] = floor.isVacant ? nil : floor
        }
        while let last = floors.last, last == nil { floors.removeLast() }
    }

    /// Empties every place in `slots` whose occupant no longer belongs there.
    private func release(
        _ slots: inout [SessionKey?],
        on floor: FloorKey,
        plan: Plan,
        keeping: (SceneSeatKind) -> Bool
    ) {
        for index in slots.indices {
            guard let key = slots[index] else { continue }
            let belongs = plan.draws(key)
                && plan.floorKey[key] == floor
                && keeping(plan.place(key).kind)
            if !belongs { slots[index] = nil }
        }
    }

    // MARK: Seat

    /// Gives every session on the board a place, reusing the one it already had.
    ///
    /// Roots first, in board order, so that a subagent always finds its bay
    /// already allocated. Within each pass the lowest free index wins, which is
    /// what keeps the campus compact without renumbering anybody.
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

        seatTheOtherRooms(plan)
    }

    /// Gives everybody who has left their desk somewhere to be, in their own
    /// company's rooms.
    private mutating func seatTheOtherRooms(_ plan: Plan) {
        var tableOf: [SessionKey: (floor: Int, table: Int)] = [:]
        var placed: Set<SessionKey> = []
        for (floorIndex, floor) in floors.enumerated() {
            guard let floor else { continue }
            for (index, table) in floor.tables.enumerated() {
                guard let table else { continue }
                tableOf[table.head] = (floorIndex, index)
                placed.insert(table.head)
                for child in table.seats { if let child { placed.insert(child) } }
            }
        }

        for head in plan.tableHeads where tableOf[head] == nil {
            guard let key = plan.floorKey[head] else { continue }
            let floorIndex = allocateFloor(key)
            tableOf[head] = (floorIndex, openTable(head: head, on: floorIndex))
        }
        for head in plan.tableHeads {
            guard let location = tableOf[head] else { continue }
            for child in plan.tableChildren[head] ?? [] where !placed.contains(child) {
                take(child, at: location.table, on: location.floor)
            }
        }

        var already: Set<SessionKey> = []
        for floor in floors {
            guard let floor else { continue }
            for key in floor.waiting { if let key { already.insert(key) } }
            for key in floor.resting { if let key { already.insert(key) } }
            for key in floor.leaving { if let key { already.insert(key) } }
        }

        for key in plan.order where plan.draws(key) && !already.contains(key) {
            let kind = plan.place(key).kind
            guard kind.isWaitingBench || kind.isBreakRest || kind == .gate,
                  let floorKey = plan.floorKey[key]
            else { continue }
            let index = allocateFloor(floorKey)
            guard var floor = floors[index] else { continue }
            if kind.isWaitingBench {
                Self.claim(key, in: &floor.waiting)
            } else if kind.isBreakRest {
                Self.claim(key, in: &floor.resting)
            } else {
                Self.claim(key, in: &floor.leaving)
            }
            floors[index] = floor
        }
    }

    /// Opens a meeting room for `head`, reusing one whose family has broken up.
    private mutating func openTable(head: SessionKey, on floorIndex: Int) -> Int {
        guard var floor = floors[floorIndex] else { return 0 }
        defer { floors[floorIndex] = floor }
        let table = TableState(head: head, seats: [])
        if let free = floor.tables.firstIndex(where: { $0 == nil }) {
            floor.tables[free] = table
            return free
        }
        floor.tables.append(table)
        return floor.tables.count - 1
    }

    /// Sits `child` down at the lowest free chair of one meeting room.
    private mutating func take(_ child: SessionKey, at index: Int, on floorIndex: Int) {
        guard var floor = floors[floorIndex], var table = floor.tables[index] else { return }
        if let free = table.seats.firstIndex(where: { $0 == nil }) {
            table.seats[free] = child
        } else {
            table.seats.append(child)
        }
        floor.tables[index] = table
        floors[floorIndex] = floor
    }

    /// Puts `key` in the lowest free place, growing the list only when there
    /// is none — the office's own rule, so a room that has churned all day
    /// is no wider than its busiest moment.
    private static func claim(_ key: SessionKey, in places: inout [SessionKey?]) {
        if let free = places.firstIndex(where: { $0 == nil }) {
            places[free] = key
        } else {
            places.append(key)
        }
    }

    /// The index of `key`'s suite, taking the lowest vacant one if it has none.
    private mutating func allocateFloor(_ key: FloorKey) -> Int {
        for (index, floor) in floors.enumerated() where floor?.key == key { return index }
        if let free = floors.firstIndex(where: { $0 == nil }) {
            floors[free] = FloorState(key: key)
            return free
        }
        floors.append(FloorState(key: key))
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

    /// One suite, measured but not yet placed.
    ///
    /// Measuring every suite before placing any of them is what lets the campus
    /// decide how wide to be: the shelf width is a function of how much
    /// building there is, and that is not known until the last suite has been
    /// packed.
    private struct SuiteMeasurement {
        let index: Int
        let floor: FloorState
        /// Which row each bay landed on, and how far along it.
        let placed: [(bay: Int, row: Int, x: CGFloat)]
        let rowCount: Int
        /// The desks, in points.
        let deskHeight: CGFloat
        /// The meeting rooms, in the order they are drawn, with the row and
        /// offset each landed at. `table` is `nil` for a room the company has
        /// but nobody is in.
        let rooms: [(id: Int, table: TableState?, row: Int, x: CGFloat, width: CGFloat)]
        let meetingRows: Int
        /// `0` when the suite has no meeting rooms drawn.
        let meetingHeight: CGFloat
        /// How many break-room seats fit across the suite.
        let breakColumns: Int
        let restRows: Int
        let waitingRows: Int
        /// `0` when the suite has no break room drawn.
        let breakHeight: CGFloat
        /// How wide the suite is, in units.
        let units: CGFloat
        /// How tall the whole suite is, gaps included.
        let height: CGFloat
    }

    /// Packs one suite: bays into rows, meeting rooms into rows, and the break
    /// room's seats into columns.
    ///
    /// A bay that does not fit in what is left of a row starts the next one; a
    /// bay wider than a whole row gets one to itself rather than being split,
    /// because a subagent on the line below its parent is not adjacent to
    /// anything.
    private func measure(_ floor: FloorState, index: Int, plan: Plan) -> SuiteMeasurement {
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
        let deskUnits = max(metrics.minimumFloorUnits, widest)
        let deskHeight = metrics.floorHeaderHeight + CGFloat(rowCount) * metrics.rowHeight

        // How many meeting rooms this company has: one per delegating family,
        // and at least one once it is big enough to need somewhere to talk.
        let live = floor.tables.enumerated().compactMap { index, table in
            table.map { (id: index, table: $0) }
        }
        let spare = plan.population[floor.key, default: 0] >= metrics.suiteRoomThreshold ? 1 : 0
        let roomCount = plan.zones.meetingRooms ? max(live.count, spare) : 0
        var roomWidths: [CGFloat] = live.map { metrics.tableWidth(children: $0.table.seats.count) }
        while roomWidths.count < roomCount { roomWidths.append(metrics.tableWidth(children: 0)) }

        // Wide enough for the two widest side by side, so a company with two
        // meetings reads as two rooms rather than as a column.
        let sortedWidths = roomWidths.sorted(by: >)
        let meetingNeed: CGFloat
        switch sortedWidths.count {
        case 0: meetingNeed = 0
        case 1: meetingNeed = sortedWidths[0] + Self.stripPadding * 2
        default:
            meetingNeed = sortedWidths[0] + metrics.tableGap + sortedWidths[1]
                + Self.stripPadding * 2
        }

        // A break room is drawn when somebody is in it, when it has people it
        // could not seat, or when the company is big enough to have one
        // standing empty. A repository with one session in it and nobody
        // resting gets desks and nothing else — the room would be a third of
        // its suite spent on furniture nobody is using, which is exactly what
        // makes a campus of forty projects unreadable.
        let usingBreakRoom = floor.waiting.contains { $0 != nil }
            || floor.resting.contains { $0 != nil }
            || floor.leaving.contains { $0 != nil }
            || (plan.overflow[floor.key] ?? 0) > 0
        let drawsBreak = plan.zones.breakAreas
            && (usingBreakRoom || plan.population[floor.key, default: 0] >= metrics.suiteRoomThreshold)
        // Two seats and a door is the least a break room can be and still be
        // one.
        let breakNeed = drawsBreak
            ? Self.stripPadding * 2 + metrics.gateReserve + metrics.gardenSeatSpacing * 2
            : 0

        let units = max(deskUnits, max(meetingNeed, breakNeed) / metrics.cellWidth)
        let width = units * metrics.cellWidth

        var rooms: [(id: Int, table: TableState?, row: Int, x: CGFloat, width: CGFloat)] = []
        var meetingRows = 0
        if roomCount > 0 {
            let inner = Self.stripPadding
            let limit = width - Self.stripPadding
            var cursorX = inner
            var meetingRow = 0
            for slot in 0..<roomCount {
                let roomWidth = roomWidths[slot]
                if cursorX > inner, cursorX + roomWidth > limit + 0.0001 {
                    meetingRow += 1
                    cursorX = inner
                }
                let id = slot < live.count ? live[slot].id : floor.tables.count + slot
                rooms.append(
                    (
                        id: id,
                        table: slot < live.count ? live[slot].table : nil,
                        row: meetingRow,
                        x: cursorX,
                        width: roomWidth
                    )
                )
                cursorX += roomWidth + metrics.tableGap
            }
            meetingRows = meetingRow + 1
        }
        let meetingHeight = meetingRows == 0
            ? 0
            : metrics.floorHeaderHeight
                + CGFloat(meetingRows) * (metrics.tableHeight + metrics.tableGap)
                - metrics.tableGap + Self.stripPadding

        var breakColumns = 0
        var restRows = 0
        var waitingRows = 0
        var breakHeight: CGFloat = 0
        if drawsBreak {
            let usable = width - Self.stripPadding * 2 - metrics.gateReserve
            breakColumns = max(1, Int((usable / metrics.gardenSeatSpacing).rounded(.down)))
            restRows = floor.resting.isEmpty
                ? 0 : max(1, (floor.resting.count + breakColumns - 1) / breakColumns)
            // The waiting bench wraps like the rest of the room does. It is
            // normally one row and it has to survive the afternoon where it
            // is not.
            waitingRows = floor.waiting.isEmpty
                ? 0 : max(1, (floor.waiting.count + breakColumns - 1) / breakColumns)
            // At least one row of break room even when nobody is in it,
            // because the door stands in it and the overflow count is written
            // on it.
            let rows = max(1, restRows + waitingRows)
            breakHeight = metrics.floorHeaderHeight + CGFloat(rows) * metrics.gardenRowHeight
        }

        var height = deskHeight
        if meetingHeight > 0 { height += metrics.suiteGap + meetingHeight }
        if breakHeight > 0 { height += metrics.suiteGap + breakHeight }

        return SuiteMeasurement(
            index: index,
            floor: floor,
            placed: placed,
            rowCount: rowCount,
            deskHeight: deskHeight,
            rooms: rooms,
            meetingRows: meetingRows,
            meetingHeight: meetingHeight,
            breakColumns: breakColumns,
            restRows: restRows,
            waitingRows: waitingRows,
            breakHeight: breakHeight,
            units: units,
            height: height
        )
    }

    /// Turns the allocation table into coordinates.
    private func geometry(_ plan: Plan) -> SceneFrame {
        var outFloors: [SceneFloor] = []
        var slots: [SceneSlot] = []
        var areas: [SceneZoneArea] = []
        var seats: [SceneSeat] = []
        var tables: [SceneTable] = []
        var lanes: [Int: CGFloat] = [:]
        var anchors: [SessionKey: CGPoint] = [:]
        var scales: [SessionKey: CGFloat] = [:]

        let measured = floors.enumerated().compactMap { index, floor in
            floor.map { measure($0, index: index, plan: plan) }
        }
        let totalUnits = measured.reduce(0) { $0 + $1.units }
        let averageHeight = measured.isEmpty
            ? 0
            : measured.reduce(0) { $0 + $1.height } / CGFloat(measured.count)
        let shelfWidth = metrics.shelfUnits(
            totalUnits: totalUnits, averageFloorHeight: averageHeight
        )

        // Suites are shelved: they run left to right and wrap when the next one
        // will not fit, so four projects with two agents each read as one wide
        // campus rather than a column six screens tall. A suite is never split
        // across a wrap — a company is a company.
        var shelfTop = metrics.margin
        var shelfHeight: CGFloat = 0
        var shelfUnits: CGFloat = 0
        var cursorX = metrics.margin
        var buildingRight = metrics.margin
        var buildingBottom = metrics.margin

        for measurement in measured {
            let floorIndex = measurement.index
            let floor = measurement.floor
            let width = measurement.units * metrics.cellWidth

            if shelfUnits > 0, shelfUnits + measurement.units > shelfWidth + 0.0001 {
                shelfTop += shelfHeight + metrics.floorGap
                shelfHeight = 0
                shelfUnits = 0
                cursorX = metrics.margin
            }
            let left = cursorX
            let top = shelfTop
            let deskRect = CGRect(x: left, y: top, width: width, height: measurement.deskHeight)
            let suiteRect = CGRect(x: left, y: top, width: width, height: measurement.height)
            let projectKey = floor.key.projectKey
            let breakKind = plan.zones.breakKind(forProject: projectKey)

            // The corridor: one per suite, along the bottom of it. Every room
            // in the company opens onto it, so a walk from a desk to a table
            // is out, along, and in — the same three legs as any other walk on
            // the map, with no pathfinding anywhere.
            let hasOtherRooms = measurement.meetingHeight > 0 || measurement.breakHeight > 0
            let lane = hasOtherRooms
                ? suiteRect.maxY - Self.laneInset
                : suiteRect.maxY + metrics.floorGap / 2
            lanes[floorIndex] = lane

            var occupancy = 0
            for placement in measurement.placed {
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
                        isAway: bay.map { plan.place($0.root).zone != .office } ?? false,
                        childCount: bay.map { plan.childCount[$0.root] ?? 0 } ?? 0
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
                            isAway: child.map { plan.place($0).zone != .office } ?? false,
                            childCount: child.map { plan.childCount[$0] ?? 0 } ?? 0
                        )
                    )
                }
            }

            outFloors.append(
                SceneFloor(
                    id: "f\(floorIndex)",
                    index: floorIndex,
                    projectKey: projectKey,
                    title: Self.title(for: floor.key),
                    frame: deskRect,
                    rowCount: measurement.rowCount,
                    occupancy: occupancy,
                    suite: suiteRect,
                    breakKind: breakKind
                )
            )

            var roomsBottom = deskRect.maxY
            if measurement.meetingHeight > 0 {
                let rect = CGRect(
                    x: left,
                    y: roomsBottom + metrics.suiteGap,
                    width: width,
                    height: measurement.meetingHeight
                )
                let counted = layOutMeeting(
                    measurement: measurement,
                    rect: rect,
                    floorIndex: floorIndex,
                    projectKey: projectKey,
                    plan: plan,
                    tables: &tables,
                    seats: &seats
                )
                areas.append(
                    SceneZoneArea(
                        id: "f\(floorIndex).meeting",
                        zone: .meeting,
                        title: measurement.rooms.count > 1
                            ? Self.meetingRoomsTitle : Self.meetingTitle,
                        frame: rect,
                        rowCount: measurement.meetingRows,
                        occupancy: counted,
                        laneY: lane,
                        projectKey: projectKey,
                        floorIndex: floorIndex
                    )
                )
                roomsBottom = rect.maxY
            }

            if measurement.breakHeight > 0 {
                let rect = CGRect(
                    x: left,
                    y: roomsBottom + metrics.suiteGap,
                    width: width,
                    height: measurement.breakHeight
                )
                let door = CGPoint(x: rect.maxX - metrics.gateReserve / 2, y: lane)
                let counted = layOutBreakRoom(
                    measurement: measurement,
                    rect: rect,
                    lane: lane,
                    door: door,
                    floorIndex: floorIndex,
                    plan: plan,
                    seats: &seats
                )
                areas.append(
                    SceneZoneArea(
                        id: "f\(floorIndex).break",
                        zone: .breakArea,
                        title: breakKind.title,
                        frame: rect,
                        rowCount: max(1, measurement.restRows + measurement.waitingRows),
                        occupancy: counted,
                        laneY: lane,
                        projectKey: projectKey,
                        floorIndex: floorIndex,
                        overflow: plan.overflow[floor.key] ?? 0,
                        breakKind: breakKind,
                        door: door
                    )
                )
            }

            cursorX += width + metrics.floorGap
            shelfUnits += measurement.units
            shelfHeight = max(shelfHeight, measurement.height)
            buildingRight = max(buildingRight, suiteRect.maxX)
            buildingBottom = max(buildingBottom, suiteRect.maxY)
        }

        // Where somebody is, not where their desk is. A parent who has walked
        // to a table and a child that followed it there are still a delegation,
        // and the line has to go where they went.
        for seat in seats {
            guard let key = seat.session else { continue }
            anchors[key] = seat.anchor
            scales[key] = seat.scale
        }

        // Tethers are drawn between people rather than between desks, so a
        // delegation whose child landed in another suite still gets a line —
        // that crossing is the informative case, not an error to hide — and a
        // family that got up and walked to a table takes its lines with it.
        //
        // Every delegation on the board is in this list. Which of them are
        // *drawn* is a separate question, answered by
        // ``SceneFrame/arcs(focus:limit:)``: a mesh of forty lines says less
        // than six.
        var tethers: [SceneTether] = []
        for key in plan.order {
            guard let parent = plan.parent[key],
                  let from = anchors[parent],
                  let to = anchors[key]
            else { continue }
            tethers.append(
                SceneTether(
                    parent: parent,
                    child: key,
                    from: from,
                    to: to,
                    family: plan.bayRoot[parent] ?? parent
                )
            )
        }

        let isEmpty = outFloors.isEmpty
        let height = isEmpty ? 0 : buildingBottom + metrics.margin
        let width = isEmpty ? 0 : buildingRight + metrics.margin
        return SceneFrame(
            floors: outFloors,
            slots: slots,
            tethers: tethers,
            contentRect: CGRect(x: 0, y: 0, width: width, height: height),
            zones: areas,
            seats: seats,
            tables: tables,
            walkways: SceneWalkways(trunk: metrics.margin / 2, lanes: lanes),
            metrics: metrics
        )
    }

    /// Lays out one suite's meeting rooms, and returns how many chairs have
    /// somebody in them.
    private func layOutMeeting(
        measurement: SuiteMeasurement,
        rect: CGRect,
        floorIndex: Int,
        projectKey: String?,
        plan: Plan,
        tables: inout [SceneTable],
        seats: inout [SceneSeat]
    ) -> Int {
        var occupancy = 0
        let title = Self.title(for: measurement.floor.key)
        for room in measurement.rooms {
            let top = rect.minY + metrics.floorHeaderHeight
                + CGFloat(room.row) * (metrics.tableHeight + metrics.tableGap)
            let frame = CGRect(
                x: rect.minX + room.x, y: top, width: room.width, height: metrics.tableHeight
            )
            let id = "f\(floorIndex).m\(room.id)"
            let children = room.table?.seats ?? []
            tables.append(
                SceneTable(
                    id: id,
                    head: room.table?.head,
                    projectKey: projectKey,
                    title: title,
                    frame: frame,
                    seatCount: children.count,
                    floorIndex: floorIndex
                )
            )
            if room.table != nil { occupancy += 1 }
            seats.append(
                SceneSeat(
                    id: "\(id).head",
                    session: room.table?.head,
                    kind: .tableHead,
                    anchor: CGPoint(
                        x: frame.minX + 30, y: frame.minY + metrics.tableSurfaceBottom
                    ),
                    scale: 1,
                    floorIndex: floorIndex,
                    tableID: id,
                    childCount: room.table.map { plan.childCount[$0.head] ?? 0 } ?? 0
                )
            )
            for (index, child) in children.enumerated() {
                if child != nil { occupancy += 1 }
                let column = index / 2
                let isFarSide = index.isMultiple(of: 2)
                let x = frame.minX + metrics.tableHeadWidth + 20
                    + (CGFloat(column) + 0.5) * metrics.tableSeatSpacing
                let y = isFarSide
                    ? frame.minY + metrics.tableSurfaceTop
                    : frame.minY + metrics.tableNearSeatY
                seats.append(
                    SceneSeat(
                        id: "\(id).c\(index)",
                        session: child,
                        kind: isFarSide ? .tableNorth : .tableSouth,
                        anchor: CGPoint(x: x, y: y),
                        scale: metrics.childScale,
                        floorIndex: floorIndex,
                        tableID: id,
                        childCount: child.map { plan.childCount[$0] ?? 0 } ?? 0
                    )
                )
            }
        }
        return occupancy
    }

    /// Lays out one suite's break room, and returns how many places have
    /// somebody in them.
    ///
    /// ## Why the front row exists
    ///
    /// The break room used to be one grid of benches, and the two things a
    /// person actually comes to this map for — *is anything stuck on me* and
    /// *did anything finish* — were somewhere inside it, next to a dozen
    /// sessions doing nothing. A picture where the urgent thing is laid out
    /// exactly like the unimportant thing is a picture you have to read rather
    /// than glance at.
    ///
    /// So the room has a back and a front. The front row runs along the
    /// corridor, is the last thing between the reader and the door, and holds
    /// only sessions that said something out loud: a red `!` for somebody
    /// waiting on a person, a green `✓` for a receipt nobody has read. The back
    /// is everything that is merely resting, and it is the half that gives way
    /// when a busy repository fills the room.
    private func layOutBreakRoom(
        measurement: SuiteMeasurement,
        rect: CGRect,
        lane: CGFloat,
        door: CGPoint,
        floorIndex: Int,
        plan: Plan,
        seats: inout [SceneSeat]
    ) -> Int {
        let floor = measurement.floor
        let columns = max(1, measurement.breakColumns)

        /// The floor line of one row, counting from the top of the room.
        func rowY(_ row: Int) -> CGFloat {
            rect.minY + metrics.floorHeaderHeight
                + CGFloat(row + 1) * metrics.gardenRowHeight - Self.seatLift
        }

        /// Where the `index`th person in a band stands.
        func anchor(index: Int, firstRow: Int) -> CGPoint {
            CGPoint(
                x: rect.minX + Self.stripPadding
                    + (CGFloat(index % columns) + 0.5) * metrics.gardenSeatSpacing,
                y: rowY(firstRow + index / columns)
            )
        }

        var occupancy = 0
        // The back of the room first, because the strip is drawn top to bottom
        // and the corridor is along the bottom edge.
        for (index, key) in floor.resting.enumerated() {
            if key != nil { occupancy += 1 }
            seats.append(
                SceneSeat(
                    id: "f\(floorIndex).brk.s\(index)",
                    session: key,
                    kind: key.map { plan.place($0).kind } ?? .bench,
                    anchor: anchor(index: index, firstRow: 0),
                    scale: 1,
                    floorIndex: floorIndex,
                    childCount: key.map { plan.childCount[$0] ?? 0 } ?? 0
                )
            )
        }
        // Then the front row, nearest the corridor. Its own id prefix, so a
        // renderer diffing nodes never mistakes a bench at the back for a place
        // on the waiting bench and animates somebody sideways across the room
        // when a receipt arrives.
        for (index, key) in floor.waiting.enumerated() {
            if key != nil { occupancy += 1 }
            seats.append(
                SceneSeat(
                    id: "f\(floorIndex).brk.w\(index)",
                    session: key,
                    kind: key.map { plan.place($0).kind } ?? .note,
                    anchor: anchor(index: index, firstRow: measurement.restRows),
                    scale: 1,
                    floorIndex: floorIndex,
                    childCount: key.map { plan.childCount[$0] ?? 0 } ?? 0
                )
            )
        }
        // And the queue for the door, on the corridor itself. Short by
        // construction: everybody in it is mid-stride, because arriving at the
        // door is what takes somebody off the map.
        for (index, key) in floor.leaving.enumerated() {
            if key != nil { occupancy += 1 }
            seats.append(
                SceneSeat(
                    id: "f\(floorIndex).brk.g\(index)",
                    session: key,
                    kind: .gate,
                    anchor: CGPoint(
                        x: door.x - metrics.gateReserve / 2 - CGFloat(index) * Self.queueSpacing,
                        y: lane
                    ),
                    scale: 1,
                    floorIndex: floorIndex
                )
            )
        }
        return occupancy
    }

    private static func title(for key: FloorKey) -> String {
        switch key {
        case .project(let path): BoardGrouping.projectName(forPath: path)
        case .unplaced: unplacedFloorTitle
        }
    }
}
