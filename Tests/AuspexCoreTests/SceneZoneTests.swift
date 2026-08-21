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
        #expect(places[idle.key]?.kind.isGardenRest == true)
        #expect(places[reported.key]?.kind.isGardenRest == false)
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
        #expect(places[asking.key]?.zone == .garden)
        #expect(places[reported.key]?.zone == .garden)
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

        let noMeeting = Self.placements(sessions, options: SceneZoneOptions(meetingRoom: false))
        #expect(noMeeting[root.key]?.zone == .office)
        #expect(noMeeting[child.key]?.zone == .office)
        #expect(noMeeting[idle.key]?.zone == .garden)

        let noGarden = Self.placements(sessions, options: SceneZoneOptions(garden: false))
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
        #expect(frame.gate == nil)
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

        let gate = try #require(frame.gate)
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

    @Test("Focusing a project whose room has emptied frames the table instead")
    func focusFollowsTheFamily() throws {
        let root = Self.session("root", state: .delegating(children: 1))
        let child = Self.session("child", parent: root.key)
        var layout = SceneLayout()
        let frame = layout.update(with: Self.board([root, child]))

        // Nobody is at a desk of this project's: they are all at the table.
        let table = try #require(frame.tables.first)
        #expect(frame.focusRect(forProject: Self.project) == table.frame)

        // One of them goes back to work, and the room is what to look at
        // again — framing both would be framing most of the map.
        var back = SceneLayout()
        let working = back.update(
            with: Self.board([root, Self.session("child", parent: root.key, state: .thinking),
                              Self.session("solo", state: .toolCalling(name: "Bash"))])
        )
        let rooms = working.floors(forProject: Self.project)
        let focus = try #require(working.focusRect(forProject: Self.project))
        for room in rooms { #expect(focus.contains(room.frame)) }
        for area in working.zones { #expect(!focus.intersects(area.frame)) }
    }

    @Test("An empty board draws no annexes")
    func emptyBoardIsEmpty() {
        var layout = SceneLayout()
        let frame = layout.update(with: Self.board([]))
        #expect(frame.zones.isEmpty)
        #expect(frame.seats.isEmpty)
        #expect(frame.gate == nil)
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

        for area in frame.zones {
            #expect(area.laneY > area.frame.minY)
            #expect(area.laneY < area.frame.maxY)
            #expect(frame.walkways.lane(area.zone) == area.laneY)
        }
        // The gutter runs down the left of everything.
        for floor in frame.floors { #expect(frame.walkways.trunk < floor.frame.minX) }
        #expect(frame.walkways.trunk > 0)
    }
}
