import AgentSessionKit
import AgentSessionLive
import AuspexCore
import CoreGraphics
import Foundation
import Testing

/// What the annexes promise: the office is untouched when they are off, the
/// right people leave their desks when they are on, and nobody who needs a
/// human ever walks away from where the human will look.
@Suite("Scene zones")
struct SceneZoneTests {
    // MARK: Fixtures

    private static let project = "/Users/example/Code/auspex"

    private static func session(
        _ id: String,
        harness: Harness = .claudeCode,
        project: String? = SceneZoneTests.project,
        parent: SessionKey? = nil,
        state: SessionState = .thinking,
        stale: Bool = false
    ) -> SessionSnapshot {
        let key = SessionKey(harness: harness, sessionID: id)
        return SessionSnapshot(
            identity: SessionIdentity(
                key: key,
                sourcePath: "/Users/example/.claude/projects/demo/\(id).jsonl",
                parent: parent,
                cwd: project,
                gitRoot: project
            ),
            state: state,
            isAlive: !state.isEnded,
            isStale: stale
        )
    }

    private static func key(_ id: String, _ harness: Harness = .claudeCode) -> SessionKey {
        SessionKey(harness: harness, sessionID: id)
    }

    private static func board(_ sessions: [SessionSnapshot]) -> BoardSnapshot {
        BoardSnapshot(generatedAt: Date(timeIntervalSince1970: 1_767_225_600), sessions: sessions)
    }

    /// The delegation edges a board admits to, worked out the way the layout
    /// works them out.
    private static func parents(_ sessions: [SessionSnapshot]) -> [SessionKey: SessionKey] {
        let present = Set(sessions.map(\.key))
        var edges: [SessionKey: SessionKey] = [:]
        for session in sessions {
            guard let claimed = session.identity.parent,
                  claimed != session.key,
                  present.contains(claimed)
            else { continue }
            edges[session.key] = claimed
        }
        return edges
    }

    private static func placements(
        _ sessions: [SessionSnapshot],
        attention: [SessionKey: AttentionState] = [:],
        options: SceneZoneOptions = .all
    ) -> [SessionKey: SceneZoning.Placement] {
        SceneZoning.placements(
            sessions: sessions,
            parent: parents(sessions),
            attention: attention,
            options: options
        )
    }

    /// One session reporting that it finished.
    private static func reported(_ id: String) -> [SessionKey: AttentionState] {
        [key(id): .doneReported(summary: "shipped", source: .agent)]
    }

    /// One session asking for a person.
    private static func calling(_ id: String) -> [SessionKey: AttentionState] {
        [key(id): .needsYou(reason: "which one?", source: .agent)]
    }

    // MARK: Placement

    @Test("Working sessions stay at their desks")
    func workersStayInTheOffice() {
        let sessions = [
            Self.session("a", state: .thinking),
            Self.session("b", state: .toolCalling(name: "Bash")),
            Self.session("c", state: .writingFile(path: "x.swift"))
        ]
        let places = Self.placements(sessions)
        for session in sessions {
            #expect(places[session.key]?.zone == .office)
            #expect(places[session.key]?.kind == .desk)
        }
    }

    @Test("A session waiting on a person walks to the front row")
    func blockedGoesToTheWaitingBench() {
        // Everything else about it says stay: it is stale and it has a
        // delegating parent whose table it would otherwise sit at. Attention
        // beats all of it.
        //
        // This is a change of mind from the office-only scene, and the reason
        // is what a person's eye does: a raised hand among forty desks is
        // something you have to find, and the front row by the path is where
        // you look first.
        let parent = Self.session("parent", state: .delegating(children: 1))
        let blocked = Self.session(
            "blocked",
            parent: parent.key,
            state: .waitingPermission(tool: "Bash"),
            stale: true
        )
        let places = Self.placements([parent, blocked])
        #expect(places[blocked.key]?.kind == .call)
        #expect(places[blocked.key]?.kind.isWaitingBench == true)
        #expect(places[parent.key]?.zone == .meeting)
    }

    @Test("With the garden switched off a blocked session keeps its desk")
    func blockedStaysWithoutAGarden() {
        // There is nowhere to walk to, and the desk is where the strobing
        // monitor already is.
        let blocked = Self.session("blocked", state: .waitingPermission(tool: "Bash"))
        #expect(
            Self.placements([blocked], options: .officeOnly)[blocked.key] == .desk
        )
    }

    @Test("A delegating family takes one table, however deep it goes")
    func familySharesOneTable() {
        let root = Self.session("root", state: .delegating(children: 1))
        let middle = Self.session(
            "middle", parent: root.key, state: .delegating(children: 1)
        )
        let leaf = Self.session("leaf", parent: middle.key, state: .toolCalling(name: "Read"))
        let places = Self.placements([root, middle, leaf])

        #expect(places[root.key]?.kind == .tableHead)
        #expect(places[root.key]?.table == root.key)
        // The middle session delegates too, but the person asked for one thing.
        #expect(places[middle.key]?.table == root.key)
        #expect(places[leaf.key]?.table == root.key)
        #expect(places[leaf.key]?.zone == .meeting)
    }

    @Test("Two delegating families take two tables")
    func familiesGetTheirOwnTables() {
        let first = Self.session("first", state: .delegating(children: 1))
        let second = Self.session("second", state: .delegating(children: 1))
        let child = Self.session("child", parent: second.key)
        let places = Self.placements([first, second, child])
        #expect(places[first.key]?.table == first.key)
        #expect(places[second.key]?.table == second.key)
        #expect(places[child.key]?.table == second.key)
    }

    @Test("A child that has finished leaves the meeting rather than sitting on")
    func finishedChildrenLeave() {
        let root = Self.session("root", state: .delegating(children: 1))
        let done = Self.session("done", parent: root.key, state: .ended(reason: .exited))
        let places = Self.placements([root, done])
        #expect(places[done.key]?.kind == .gate)
    }

    @Test("The garden sorts the front row from the back lawn")
    func gardenKinds() {
        let idle = Self.session("idle", state: .idle)
        let stale = Self.session("stale", state: .thinking, stale: true)
        let over = Self.session("over", state: .ended(reason: .exited))
        let reported = Self.session("reported", state: .idle)
        let places = Self.placements(
            [idle, stale, over, reported], attention: Self.reported("reported")
        )
        #expect(places[idle.key]?.kind == .bench)
        #expect(places[stale.key]?.kind == .doze)
        #expect(places[over.key]?.kind == .gate)
        #expect(places[reported.key]?.kind == .note)
        // The lawn and the front row are different tables, and the layout
        // relies on being able to tell them apart.
        #expect(places[idle.key]?.kind.isBreakRest == true)
        #expect(places[reported.key]?.kind.isBreakRest == false)
        #expect(places[reported.key]?.kind.isWaitingBench == true)
    }

    @Test("A receipt waits on the bench rather than walking out")
    func reportedBeatsEnded() {
        // The process exiting does not un-finish the work or un-write the line
        // somebody still has to read.
        let over = Self.session("over", state: .ended(reason: .exited))
        let places = Self.placements([over], attention: Self.reported("over"))
        #expect(places[over.key]?.kind == .note)
    }

    @Test("Both attention buckets share the one front row")
    func bothBucketsShareTheRow() {
        // One place to look rather than a hunt through the building. What the
        // two have in common is that you are the next thing that has to happen.
        let asking = Self.session("asking", state: .thinking)
        let reported = Self.session("reported", state: .toolCalling(name: "swift"))
        let places = Self.placements(
            [asking, reported],
            attention: Self.calling("asking").merging(Self.reported("reported")) { a, _ in a }
        )
        #expect(places[asking.key]?.kind == .call)
        #expect(places[reported.key]?.kind == .note)
        #expect(places[asking.key]?.zone == .breakArea)
        #expect(places[reported.key]?.zone == .breakArea)
    }

    @Test("A stale session that was only idle is idle, not asleep")
    func staleIdleIsJustIdle() {
        let quiet = Self.session("quiet", state: .idle, stale: true)
        #expect(Self.placements([quiet])[quiet.key]?.kind == .bench)
    }

    @Test("Switching an annex off puts its people back at their desks")
    func annexesOffKeepEverybodyInTheOffice() {
        let root = Self.session("root", state: .delegating(children: 1))
        let child = Self.session("child", parent: root.key)
        let idle = Self.session("idle", state: .idle)
        let sessions = [root, child, idle]

        let noMeeting = Self.placements(sessions, options: SceneZoneOptions(meetingRooms: false))
        #expect(noMeeting[root.key]?.zone == .office)
        #expect(noMeeting[child.key]?.zone == .office)
        #expect(noMeeting[idle.key]?.zone == .breakArea)

        let noGarden = Self.placements(sessions, options: SceneZoneOptions(breakAreas: false))
        #expect(noGarden[root.key]?.zone == .meeting)
        #expect(noGarden[idle.key]?.zone == .office)

        for place in Self.placements(sessions, options: .officeOnly).values {
            #expect(place == .desk)
        }
    }

    @Test("A delegation that claims itself as its own parent does not hang")
    func selfParentTerminates() {
        let key = Self.key("loop")
        let looped = SessionSnapshot(
            identity: SessionIdentity(
                key: key,
                sourcePath: "/Users/example/.claude/projects/demo/loop.jsonl",
                parent: key,
                cwd: Self.project
            ),
            state: .delegating(children: 1),
            isAlive: true
        )
        #expect(Self.placements([looped])[key]?.kind == .tableHead)
    }

    // MARK: The map

    @Test("With both annexes off the map is exactly the office")
    func officeOnlyIsUnchanged() {
        let sessions = [
            Self.session("work", state: .thinking),
            Self.session("rest", state: .idle),
            Self.session("boss", state: .delegating(children: 1))
        ]
        var layout = SceneLayout()
        let frame = layout.update(with: Self.board(sessions), zones: .officeOnly)

        #expect(frame.zones.isEmpty)
        #expect(frame.seats.isEmpty)
        #expect(frame.tables.isEmpty)
        #expect(frame.doors.isEmpty)
        // A suite with no other rooms is exactly its desks.
        for floor in frame.floors { #expect(floor.suite == floor.frame) }
        // Nobody has gone anywhere, so nothing is drawn as an empty desk.
        for slot in frame.slots { #expect(!slot.isAway) }
        // And the map is the building with a margin round it and nothing else
        // hanging below, which is the property a switched-off annex has to
        // have if the picture is to be the one that shipped before it existed.
        var union = CGRect.null
        for floor in frame.floors { union = union.union(floor.frame) }
        #expect(frame.contentRect.height == union.maxY + SceneMetrics.standard.margin)
        #expect(frame.contentRect.width == union.maxX + SceneMetrics.standard.margin)
    }

    @Test("The annexes hang below the office and never move it")
    func annexesGrowDownward() {
        let sessions = [
            Self.session("work", state: .thinking),
            Self.session("rest", state: .idle),
            Self.session("boss", state: .delegating(children: 1)),
            Self.session("kid", parent: Self.key("boss"))
        ]
        var layout = SceneLayout()
        var reference = SceneLayout()
        let board = Self.board(sessions)
        let full = layout.update(with: board, zones: .all)
        let office = reference.update(with: board, zones: .officeOnly)

        // Same desks, in the same places.
        #expect(full.slots.map(\.anchor) == office.slots.map(\.anchor))
        #expect(full.floors.map(\.frame) == office.floors.map(\.frame))
        // And more map below them.
        #expect(full.contentRect.height > office.contentRect.height)
        for floor in full.floors {
            for area in full.zones { #expect(area.frame.minY > floor.frame.maxY) }
        }
    }

    @Test("Everybody who left a desk is still holding it, marked away")
    func deskIsHeldWhileAway() {
        let sessions = [
            Self.session("rest", state: .idle),
            Self.session("work", state: .thinking)
        ]
        var layout = SceneLayout()
        let frame = layout.update(with: Self.board(sessions))

        let resting = frame.slot(for: Self.key("rest"))
        #expect(resting?.isAway == true)
        #expect(resting?.isOccupied == false)
        #expect(frame.slot(for: Self.key("work"))?.isAway == false)
        #expect(frame.seat(for: Self.key("rest"))?.kind == .bench)
        // And "where is this session" answers with the bench, not the desk.
        #expect(frame.place(of: Self.key("rest"))?.anchor == frame.seat(for: Self.key("rest"))?.anchor)
    }

    @Test("A session that rests and goes back to work returns to its own desk")
    func deskIsKeptAcrossATripToTheGarden() {
        var layout = SceneLayout()
        let busy = (0..<4).map { Self.session("s\($0)", state: .thinking) }
        let before = layout.update(with: Self.board(busy))

        var resting = busy
        resting[1] = Self.session("s1", state: .idle)
        _ = layout.update(with: Self.board(resting))

        let after = layout.update(with: Self.board(busy))
        #expect(before.slots.map(\.anchor) == after.slots.map(\.anchor))
        #expect(before.slot(for: Self.key("s1"))?.id == after.slot(for: Self.key("s1"))?.id)
    }

    @Test("A garden seat is held while its occupant stays in the garden")
    func gardenSeatsAreStable() {
        var layout = SceneLayout()
        let resting = (0..<3).map { Self.session("r\($0)", state: .idle) }
        let before = layout.update(with: Self.board(resting))

        // The middle one reports finishing, so it gets up and walks to the
        // front row. Nobody else moves.
        let after = layout.update(
            with: Self.board(resting), attention: Self.reported("r1")
        )
        #expect(after.seat(for: Self.key("r1"))?.kind == .note)
        #expect(before.seat(for: Self.key("r0"))?.anchor == after.seat(for: Self.key("r0"))?.anchor)
        #expect(before.seat(for: Self.key("r2"))?.anchor == after.seat(for: Self.key("r2"))?.anchor)
    }

    @Test("A table seats the head at one end and the children down the sides")
    func tableSeating() throws {
        let root = Self.session("root", state: .delegating(children: 3))
        let children = (0..<3).map { Self.session("c\($0)", parent: root.key) }
        var layout = SceneLayout()
        let frame = layout.update(with: Self.board([root] + children))

        #expect(frame.tables.count == 1)
        let table = try #require(frame.tables.first)
        let head = try #require(frame.seat(for: root.key))
        #expect(head.kind == .tableHead)
        #expect(head.tableID == table.id)

        let sides = children.compactMap { frame.seat(for: $0.key)?.kind }
        #expect(sides == [.tableNorth, .tableSouth, .tableNorth])
        // The head really is at the head: everybody else is to the right of it.
        for child in children {
            guard let seat = frame.seat(for: child.key) else { continue }
            #expect(seat.anchor.x > head.anchor.x)
        }
        // And the table is wide enough to hold them.
        for child in children {
            guard let seat = frame.seat(for: child.key) else { continue }
            #expect(table.frame.minX < seat.anchor.x)
            #expect(seat.anchor.x < table.frame.maxX)
        }
    }

    @Test("A family that walks to a table takes its delegation lines with it")
    func tethersFollowThePeople() {
        let root = Self.session("root", state: .delegating(children: 1))
        let child = Self.session("child", parent: root.key)
        var layout = SceneLayout()
        let frame = layout.update(with: Self.board([root, child]))

        let tether = frame.tethers.first
        #expect(frame.tethers.count == 1)
        // Drawn between where they are sitting, not between the desks they got
        // up from.
        #expect(tether?.from == frame.seat(for: root.key)?.anchor)
        #expect(tether?.to == frame.seat(for: child.key)?.anchor)
        #expect(tether?.from != frame.slot(for: root.key)?.anchor)
    }

    @Test("A subagent working in another repository is not pulled into the meeting")
    func crossProjectChildKeepsItsDesk() {
        // The office puts it in a bay of its own for the same reason: the one
        // delegation worth seeing is the one that crosses a repository, and
        // seating it at its parent's table would hide the crossing.
        let root = Self.session("root", state: .delegating(children: 1))
        let elsewhere = Self.session(
            "elsewhere",
            harness: .codex,
            project: "/Users/example/Code/storefront-web",
            parent: root.key
        )
        var layout = SceneLayout()
        let frame = layout.update(with: Self.board([root, elsewhere]))

        #expect(frame.seat(for: root.key)?.kind == .tableHead)
        #expect(frame.seat(for: elsewhere.key) == nil)
        #expect(frame.slot(for: elsewhere.key)?.isAway == false)
        #expect(frame.tethers.count == 1)
    }

    @Test("Sessions on their way out queue at the gate, clear of the benches")
    func leavingQueuesAtTheGate() throws {
        let leaving = (0..<3).map { Self.session("e\($0)", state: .ended(reason: .exited)) }
        let resting = (0..<2).map { Self.session("r\($0)", state: .idle) }
        var layout = SceneLayout()
        let frame = layout.update(with: Self.board(leaving + resting))

        let suite = try #require(frame.floors.first)
        let gate = try #require(frame.door(ofSuite: suite.index))
        let queue = leaving.compactMap { frame.seat(for: $0.key) }
        #expect(queue.count == 3)
        for seat in queue {
            #expect(seat.kind == .gate)
            #expect(seat.anchor.x < gate.x)
            #expect(seat.anchor.y == gate.y)
        }
        // Nobody is queueing through the picnic.
        let benches = resting.compactMap { frame.seat(for: $0.key)?.anchor.x }
        for x in benches { for seat in queue { #expect(seat.anchor.x > x) } }
    }

    @Test("Focusing a project frames its whole suite, wherever its people are")
    func focusFramesTheSuite() throws {
        // The old map had to choose: the project's desks were at the top of
        // the campus and its meeting was in a strip at the bottom, so framing
        // both was framing everything. A suite is one rectangle, so there is
        // nothing to choose between — which is the point of the suite.
        let root = Self.session("root", state: .delegating(children: 1))
        let child = Self.session("child", parent: root.key)
        var layout = SceneLayout()
        let frame = layout.update(with: Self.board([root, child]))

        let suite = try #require(frame.focusRect(forProject: Self.project))
        let table = try #require(frame.tables.first { $0.head != nil })
        #expect(suite.contains(table.frame))
        for room in frame.floors(forProject: Self.project) {
            #expect(suite.contains(room.frame))
        }
        for area in frame.zones where area.projectKey == Self.project {
            #expect(suite.contains(area.frame))
        }
    }

    @Test("An empty board draws no annexes")
    func emptyBoardIsEmpty() {
        var layout = SceneLayout()
        let frame = layout.update(with: Self.board([]))
        #expect(frame.zones.isEmpty)
        #expect(frame.seats.isEmpty)
        #expect(frame.doors.isEmpty)
        #expect(frame.contentRect == .zero)
    }

    @Test("The same board twice produces the same map")
    func stableAcrossFrames() {
        let sessions = [
            Self.session("boss", state: .delegating(children: 1)),
            Self.session("kid", parent: Self.key("boss")),
            Self.session("rest", state: .idle),
            Self.session("over", state: .ended(reason: .exited))
        ]
        var layout = SceneLayout()
        let board = Self.board(sessions)
        let first = layout.update(with: board, attention: Self.reported("rest"))
        let second = layout.update(with: board, attention: Self.reported("rest"))
        #expect(first == second)
    }

    @Test("The walkways are inside the strips they serve")
    func walkwaysAreOnTheMap() {
        let sessions = [
            Self.session("boss", state: .delegating(children: 1)),
            Self.session("kid", parent: Self.key("boss")),
            Self.session("rest", state: .idle)
        ]
        var layout = SceneLayout()
        let frame = layout.update(with: Self.board(sessions))

        // One corridor per suite, along the bottom of it, and every room in
        // the company reports the same one.
        for area in frame.zones {
            #expect(frame.walkways.lane(floor: area.floorIndex) == area.laneY)
        }
        // Exactly one room per suite draws it: the last one.
        for floor in frame.floors {
            let rooms = frame.zones.filter { $0.floorIndex == floor.index }
            #expect(rooms.count(where: { $0.drawsLane }) == 1)
            #expect(floor.suite.contains(CGPoint(x: floor.suite.midX, y: rooms[0].laneY)))
        }
        // The gutter runs down the left of everything.
        for floor in frame.floors { #expect(frame.walkways.trunk < floor.frame.minX) }
        #expect(frame.walkways.trunk > 0)
    }

    // MARK: The suite

    @Test("A project's rooms are inside that project's own suite")
    func suiteHoldsItsOwnRooms() throws {
        let other = "/Users/example/Code/storefront-web"
        let sessions = [
            Self.session("boss", state: .delegating(children: 1)),
            Self.session("kid", parent: Self.key("boss")),
            Self.session("rest", state: .idle),
            Self.session("far", harness: .codex, project: other, state: .idle),
            Self.session("far2", harness: .codex, project: other, state: .thinking)
        ]
        var layout = SceneLayout()
        let frame = layout.update(with: Self.board(sessions))

        // Two companies, and neither has a room in the other's building.
        #expect(frame.floors.count == 2)
        for area in frame.zones {
            let suite = try #require(
                frame.floors.first { $0.index == area.floorIndex }
            ).suite
            #expect(suite.contains(area.frame))
            #expect(area.projectKey == frame.floors.first { $0.index == area.floorIndex }?.projectKey)
        }
        for table in frame.tables {
            let suite = try #require(
                frame.floors.first { $0.index == table.floorIndex }
            ).suite
            #expect(suite.contains(table.frame))
        }
        // And every seat is in the suite of the project its occupant works in.
        for seat in frame.seats {
            guard let key = seat.session else { continue }
            let floor = try #require(frame.floors.first { $0.index == seat.floorIndex })
            let expected = key == Self.key("far", .codex) ? other : Self.project
            #expect(floor.projectKey == expected)
        }
        // Suites do not overlap each other.
        let first = try #require(frame.floors.first).suite
        let second = try #require(frame.floors.last).suite
        #expect(!first.intersects(second))
    }

    @Test("A company gets a meeting room per family, and one once it is big enough")
    func meetingRoomsGrowOnDemand() {
        // Two sessions and nobody delegating: the talking happens across the
        // desk.
        var small = SceneLayout()
        let quiet = small.update(
            with: Self.board([Self.session("a"), Self.session("b")])
        )
        #expect(quiet.tables.isEmpty)

        // Three, and the company has a meeting room whether or not it is in it.
        var medium = SceneLayout()
        let idle = medium.update(
            with: Self.board([Self.session("a"), Self.session("b"), Self.session("c")])
        )
        #expect(idle.tables.count == 1)
        #expect(idle.tables.first?.head == nil)

        // Two families delegating at once: two rooms, each with its own head.
        var busy = SceneLayout()
        let meeting = busy.update(
            with: Self.board(
                [
                    Self.session("one", state: .delegating(children: 1)),
                    Self.session("one-kid", parent: Self.key("one")),
                    Self.session("two", state: .delegating(children: 1)),
                    Self.session("two-kid", parent: Self.key("two"))
                ]
            )
        )
        #expect(meeting.tables.count == 2)
        #expect(Set(meeting.tables.compactMap(\.head)) == [Self.key("one"), Self.key("two")])
    }

    @Test("The waiting bench is inside the project's own break room")
    func waitingBenchIsInTheBreakRoom() throws {
        let sessions = [
            Self.session("asking", state: .thinking),
            Self.session("busy", state: .toolCalling(name: "Bash"))
        ]
        var layout = SceneLayout()
        let frame = layout.update(
            with: Self.board(sessions), attention: Self.calling("asking")
        )
        let seat = try #require(frame.seat(for: Self.key("asking")))
        #expect(seat.kind == .call)
        let room = try #require(frame.zones.first { $0.zone == .breakArea })
        #expect(room.projectKey == Self.project)
        #expect(room.frame.contains(seat.anchor))
        #expect(room.breakKind != nil)
        // And the door out of the company is in that same room.
        #expect(frame.door(ofSuite: seat.floorIndex) != nil)
    }

    // MARK: Break rooms

    @Test("A project's break room is the same kind every time it is asked")
    func breakKindIsSeeded() {
        let options = SceneZoneOptions.all
        let projects = [
            "/Users/example/Code/auspex",
            "/Users/example/Code/storefront-web",
            "/Users/example/Code/ingest-pipeline",
            "/Users/example/Code/mobile-client",
            "/Users/example/Code/design-tokens"
        ]
        // Stable: the same path answers the same way, run after run. Not
        // `hashValue`, which is seeded per process — a company whose break room
        // changed every time the app restarted is one nobody can learn.
        for project in projects {
            let first = options.breakKind(forProject: project)
            #expect(options.breakKind(forProject: project) == first)
        }
        // The unplaced suite has one too, and it is not a crash.
        #expect(SceneZoneOptions.all.breakKind(forProject: nil) == options.breakKind(forProject: nil))
        // And a handful of real project names does not all land on one kind.
        let kinds = Set(projects.map(options.breakKind(forProject:)))
        #expect(kinds.count >= 2)
    }

    @Test("A pinned style overrides the seed, and an override overrides the style")
    func breakKindCanBePinned() {
        var options = SceneZoneOptions.all
        options.breakStyle = .lounge
        for project in [Self.project, "/Users/example/Code/other"] {
            #expect(options.breakKind(forProject: project) == .lounge)
        }
        options.breakOverrides[Self.project] = .teaRoom
        #expect(options.breakKind(forProject: Self.project) == .teaRoom)
        #expect(options.breakKind(forProject: "/Users/example/Code/other") == .lounge)
    }

    @Test("A settings file written before the suites existed still decodes")
    func oldSettingsDecode() throws {
        let json = Data(#"{"meetingRoom":true,"garden":false}"#.utf8)
        let options = try JSONDecoder().decode(SceneZoneOptions.self, from: json)
        #expect(options.meetingRooms)
        #expect(!options.breakAreas)
        #expect(options.breakStyle == .perProject)
        // And a round trip of the new shape survives.
        var pinned = SceneZoneOptions.all
        pinned.breakStyle = .teaRoom
        pinned.breakOverrides[Self.project] = .garden
        let encoded = try JSONEncoder().encode(pinned)
        #expect(try JSONDecoder().decode(SceneZoneOptions.self, from: encoded) == pinned)
    }

    @Test("The kind a project is drawn with is the kind the options say")
    func frameCarriesTheBreakKind() throws {
        var options = SceneZoneOptions.all
        options.breakStyle = .teaRoom
        var layout = SceneLayout()
        let frame = layout.update(
            with: Self.board([Self.session("rest", state: .idle)]), zones: options
        )
        let room = try #require(frame.zones.first { $0.zone == .breakArea })
        #expect(room.breakKind == .teaRoom)
        #expect(room.title == SceneBreakKind.teaRoom.title)
        #expect(frame.floors.first?.breakKind == .teaRoom)
    }

    // MARK: Leaving

    @Test("A session that has walked out is drawn nowhere and holds nothing")
    func departedIsGone() throws {
        let sessions = [
            Self.session("busy", state: .thinking),
            Self.session("over", state: .ended(reason: .exited))
        ]
        var layout = SceneLayout()
        let board = Self.board(sessions)
        let leaving = layout.update(with: board)

        // On its way: a place in the queue at its own company's door, and the
        // desk it is still holding.
        #expect(leaving.seat(for: Self.key("over"))?.kind == .gate)
        #expect(leaving.slot(for: Self.key("over"))?.isAway == true)

        let after = layout.update(with: board, departed: [Self.key("over")])
        #expect(after.place(of: Self.key("over")) == nil)
        #expect(after.seat(for: Self.key("over")) == nil)
        #expect(after.slot(for: Self.key("over")) == nil)
        // The desk it held is released, so the company is one desk narrower.
        #expect(after.slots.count < leaving.slots.count)
        // And whoever is still working has not moved.
        #expect(
            after.place(of: Self.key("busy"))?.anchor == leaving.place(of: Self.key("busy"))?.anchor
        )
    }

    @Test("Everybody leaving empties the suite rather than leaving a stub")
    func everybodyLeavingClosesTheSuite() {
        let sessions = (0..<3).map { Self.session("e\($0)", state: .ended(reason: .exited)) }
        var layout = SceneLayout()
        let board = Self.board(sessions)
        _ = layout.update(with: board)
        let after = layout.update(with: board, departed: Set(sessions.map(\.key)))
        #expect(after.floors.isEmpty)
        #expect(after.seats.isEmpty)
        #expect(after.contentRect == .zero)
    }

    @Test("With the break rooms off, an ended session keeps its desk")
    func endedStaysWithoutABreakRoom() {
        // There is nowhere to walk to, so there is nothing to walk out of.
        let over = Self.session("over", state: .ended(reason: .exited))
        var layout = SceneLayout()
        let frame = layout.update(with: Self.board([over]), zones: .officeOnly)
        #expect(frame.slot(for: over.key)?.isAway == false)
        #expect(frame.seats.isEmpty)
    }

    // MARK: Arcs

    @Test("Nothing focused draws no arcs at all")
    func arcsAreQuietByDefault() {
        let root = Self.session("root", state: .delegating(children: 2))
        let children = (0..<2).map { Self.session("c\($0)", parent: root.key) }
        var layout = SceneLayout()
        let frame = layout.update(with: Self.board([root] + children))

        // Every delegation is still on the frame — the arcs are a *drawing*
        // decision, and a renderer that had to re-derive the family would be a
        // second place deciding who is related to whom.
        #expect(frame.tethers.count == 2)
        #expect(frame.arcs(focus: nil).isEmpty)
    }

    @Test("Focusing anybody in a family draws that family and no other")
    func arcsFollowTheFamily() {
        let root = Self.session("root", state: .delegating(children: 2))
        let children = (0..<2).map { Self.session("c\($0)", parent: root.key) }
        let other = Self.session("other", state: .delegating(children: 1))
        let cousin = Self.session("cousin", parent: other.key)
        var layout = SceneLayout()
        let frame = layout.update(with: Self.board([root] + children + [other, cousin]))

        // The parent, and any of its children, all point at the same family.
        let fromParent = frame.arcs(focus: root.key)
        #expect(fromParent.count == 2)
        #expect(Set(fromParent.map(\.child)) == Set(children.map(\.key)))
        #expect(frame.arcs(focus: children[1].key).map(\.id) == fromParent.map(\.id))
        // And the other family is not in it.
        #expect(!fromParent.contains { $0.parent == other.key })
        #expect(frame.arcs(focus: other.key).map(\.child) == [cousin.key])
        // Somebody with no delegation either way draws nothing.
        #expect(frame.arcs(focus: Self.key("nobody")).isEmpty)
    }

    @Test("A big family draws six arcs, not sixteen")
    func arcsAreCapped() {
        let root = Self.session("root", state: .delegating(children: 16))
        let children = (0..<16).map { Self.session("c\($0)", parent: root.key) }
        var layout = SceneLayout()
        let frame = layout.update(with: Self.board([root] + children))

        #expect(frame.tethers.count == 16)
        #expect(frame.arcs(focus: root.key).count == 6)
        #expect(frame.arcs(focus: root.key, limit: 2).count == 2)
        #expect(frame.arcs(focus: root.key, limit: 0).isEmpty)
        // The count a reader would have made by following them is on the desk
        // instead.
        #expect(frame.place(of: root.key) != nil)
        let seat = frame.seat(for: root.key) ?? frame.seats.first { $0.session == root.key }
        #expect((seat?.childCount ?? frame.slot(for: root.key)?.childCount) == 16)
    }

    @Test("A delegation that crosses repositories is still one family")
    func arcsCrossSuites() throws {
        let root = Self.session("root", state: .delegating(children: 1))
        let elsewhere = Self.session(
            "elsewhere",
            harness: .codex,
            project: "/Users/example/Code/storefront-web",
            parent: root.key
        )
        var layout = SceneLayout()
        let frame = layout.update(with: Self.board([root, elsewhere]))

        let arcs = frame.arcs(focus: root.key)
        #expect(arcs.count == 1)
        let arc = try #require(arcs.first)
        #expect(arc.family == root.key)
        // The two ends really are in different suites, which is the case the
        // line exists for.
        let parent = try #require(frame.place(of: root.key))
        let child = try #require(frame.place(of: elsewhere.key))
        #expect(parent.floorIndex != child.floorIndex)
    }
}
