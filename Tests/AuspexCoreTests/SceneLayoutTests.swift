import AgentSessionKit
import AgentSessionLive
import AuspexCore
import CoreGraphics
import Foundation
import Testing

/// What the office guarantees: desks that do not move, gaps that get reused,
/// subagents beside their parents, and rows that wrap.
///
/// These are the properties the scene view is built on rather than incidental
/// facts about the current constants — a test that asserted a desk sits at
/// `x = 236` would fail every time somebody widened a workstation and would
/// never once catch a real bug.
@Suite("Scene layout")
struct SceneLayoutTests {
    // MARK: Fixtures

    private static func session(
        _ id: String,
        harness: Harness = .claudeCode,
        project: String? = "/Users/example/Code/auspex",
        parent: SessionKey? = nil,
        state: SessionState = .thinking
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
            isAlive: !state.isEnded
        )
    }

    private static let epoch = Date(timeIntervalSince1970: 1_767_225_600)

    /// A frame, optionally taken `after` seconds later than the last one.
    ///
    /// The layout measures its one delay — how long a freed desk is held
    /// before the row closes — against the *board's* own instant, so a test
    /// about that rule moves the board's clock rather than the machine's.
    private static func board(
        _ sessions: [SessionSnapshot], after seconds: TimeInterval = 0
    ) -> BoardSnapshot {
        BoardSnapshot(generatedAt: epoch.addingTimeInterval(seconds), sessions: sessions)
    }

    private static func roots(_ count: Int, project: String = "/Users/example/Code/auspex")
        -> [SessionSnapshot]
    {
        (0..<count).map { session("root-\($0)", project: project) }
    }

    /// Where each session ended up, keyed by session.
    private static func anchors(_ frame: SceneFrame) -> [SessionKey: CGPoint] {
        var result: [SessionKey: CGPoint] = [:]
        for slot in frame.slots { if let key = slot.session { result[key] = slot.anchor } }
        return result
    }

    // MARK: Stability

    @Test("The same board twice produces the same office")
    func identicalFramesAgree() {
        var layout = SceneLayout()
        let board = Self.board(Self.roots(5))
        let first = layout.update(with: board)
        let second = layout.update(with: board)
        #expect(first == second)
    }

    @Test("A board reordered by urgency does not rearrange the furniture")
    func reorderingDoesNotMoveDesks() {
        var layout = SceneLayout()
        let calm = Self.roots(6)
        let before = Self.anchors(layout.update(with: Self.board(calm)))

        // The board sorts blocked sessions to the front. The office must not.
        var panicked = calm
        panicked[4] = Self.session(
            "root-4",
            state: .waitingPermission(tool: "Bash")
        )
        let after = Self.anchors(layout.update(with: Self.board(panicked)))

        #expect(before == after)
    }

    @Test("A session that arrives does not move the ones already seated")
    func arrivalMovesNobody() {
        var layout = SceneLayout()
        let existing = Self.roots(4)
        let before = Self.anchors(layout.update(with: Self.board(existing)))

        let after = Self.anchors(
            layout.update(with: Self.board(existing + [Self.session("late")]))
        )

        for (key, anchor) in before {
            #expect(after[key] == anchor, "\(key) moved when a new session appeared")
        }
        #expect(after.count == before.count + 1)
    }

    @Test("A session that leaves does not move the ones that stay")
    func departureMovesNobody() {
        var layout = SceneLayout()
        let all = Self.roots(5)
        let before = Self.anchors(layout.update(with: Self.board(all)))

        var survivors = all
        survivors.remove(at: 2)
        let after = Self.anchors(layout.update(with: Self.board(survivors)))

        for session in survivors {
            #expect(after[session.key] == before[session.key])
        }
    }

    @Test("A vacated desk is reused before the office grows")
    func vacatedDeskIsReused() {
        var layout = SceneLayout()
        let all = Self.roots(5)
        let before = Self.anchors(layout.update(with: Self.board(all)))
        let vacated = before[all[2].key]

        var survivors = all
        survivors.remove(at: 2)
        _ = layout.update(with: Self.board(survivors))

        let after = Self.anchors(
            layout.update(with: Self.board(survivors + [Self.session("newcomer")]))
        )
        let newcomer = SessionKey(harness: .claudeCode, sessionID: "newcomer")
        #expect(after[newcomer] == vacated)
    }

    @Test("A vacated desk is drawn empty rather than closed up")
    func vacatedDeskStaysOnThePlan() {
        var layout = SceneLayout()
        let all = Self.roots(4)
        _ = layout.update(with: Self.board(all))

        var survivors = all
        survivors.remove(at: 1)
        let frame = layout.update(with: Self.board(survivors))

        #expect(frame.slots.count == 4)
        #expect(frame.slots.filter(\.isVacant).count == 1)
    }

    @Test("A gap at the end of a floor closes — a minute after it opens")
    func trailingGapsClose() {
        var layout = SceneLayout()
        let all = Self.roots(4)
        _ = layout.update(with: Self.board(all))

        // Straight away the desks are still there, empty. Closing them the
        // instant a session ends is what re-packed the campus under a person
        // who was reading it — see ``SceneLayout/shrinkDelay``.
        let held = layout.update(with: Self.board(Array(all.prefix(2))))
        #expect(held.slots.count == 4)
        #expect(held.slots.filter(\.isVacant).count == 2)

        // A minute later, nobody having come back for them, the row closes.
        let frame = layout.update(
            with: Self.board(Array(all.prefix(2)), after: SceneLayout.shrinkDelay + 1)
        )
        #expect(frame.slots.count == 2)
        #expect(frame.slots.allSatisfy { !$0.isVacant })
    }

    // MARK: Delegation

    @Test("A subagent sits beside its parent, smaller")
    func childSitsBesideParent() throws {
        var layout = SceneLayout()
        let parent = Self.session("parent", state: .delegating(children: 1))
        let child = Self.session("child", parent: parent.key)
        let frame = layout.update(with: Self.board([parent, child]))

        let parentSlot = try #require(frame.slot(for: parent.key))
        let childSlot = try #require(frame.slot(for: child.key))

        #expect(childSlot.row == parentSlot.row)
        #expect(childSlot.anchor.y == parentSlot.anchor.y)
        #expect(childSlot.anchor.x > parentSlot.anchor.x)
        #expect(childSlot.anchor.x - parentSlot.anchor.x < SceneMetrics.standard.cellWidth)
        #expect(childSlot.scale < parentSlot.scale)
        #expect(childSlot.depth == 1)
    }

    @Test("A delegation draws one tether from parent to child")
    func delegationGetsATether() {
        var layout = SceneLayout()
        let parent = Self.session("parent", state: .delegating(children: 1))
        let child = Self.session("child", parent: parent.key)
        let frame = layout.update(with: Self.board([parent, child]))

        #expect(frame.tethers.count == 1)
        #expect(frame.tethers.first?.parent == parent.key)
        #expect(frame.tethers.first?.child == child.key)
    }

    @Test("A grandchild sits in the same bay as the agent that started it all")
    func grandchildJoinsTheBay() {
        var layout = SceneLayout()
        let parent = Self.session("parent", state: .delegating(children: 1))
        let child = Self.session("child", parent: parent.key, state: .delegating(children: 1))
        let grandchild = Self.session("grandchild", parent: child.key)
        let frame = layout.update(with: Self.board([parent, child, grandchild]))

        let slots = frame.slots.filter { !$0.isVacant }
        #expect(slots.count == 3)
        #expect(Set(slots.map(\.row)).count == 1)
        #expect(frame.slot(for: grandchild.key)?.depth == 2)
        #expect(frame.tethers.count == 2)
    }

    @Test("A subagent's desk is held while it works and released when it stops")
    func subagentDeskIsHeldThenReleased() {
        var layout = SceneLayout()
        let parent = Self.session("parent", state: .delegating(children: 1))
        let child = Self.session("child", parent: parent.key)
        _ = layout.update(with: Self.board([parent, child]))
        let held = Self.anchors(layout.update(with: Self.board([parent, child])))
        #expect(held[child.key] != nil)

        // The bay keeps its width once it has widened, so the parent stays put
        // when the subagent finishes.
        let alone = layout.update(with: Self.board([parent]))
        #expect(alone.slot(for: parent.key)?.anchor == held[parent.key])
        #expect(alone.slots.contains { $0.isVacant })
    }

    @Test("A subagent working in another repository gets its own bay there")
    func crossProjectChildGetsItsOwnFloor() {
        var layout = SceneLayout()
        let parent = Self.session("parent", state: .delegating(children: 1))
        let child = Self.session(
            "child",
            harness: .codex,
            project: "/Users/example/Code/storefront-web",
            parent: parent.key
        )
        let frame = layout.update(with: Self.board([parent, child]))

        #expect(frame.floors.count == 2)
        #expect(frame.slot(for: child.key)?.scale == 1)
        #expect(frame.slot(for: child.key)?.floorIndex != frame.slot(for: parent.key)?.floorIndex)
        // The line still gets drawn: a delegation that crosses repositories is
        // the interesting case, not one to hide.
        #expect(frame.tethers.count == 1)
    }

    // MARK: Floors and wrapping

    @Test("Each project is its own floor, in the order it first appeared")
    func projectsBecomeFloors() {
        var layout = SceneLayout()
        let frame = layout.update(
            with: Self.board(
                [
                    Self.session("a", project: "/Users/example/Code/auspex"),
                    Self.session("b", project: "/Users/example/Code/storefront-web"),
                    Self.session("c", project: "/Users/example/Code/auspex")
                ]
            )
        )

        #expect(frame.floors.count == 2)
        #expect(frame.floors.map(\.title) == ["auspex", "storefront-web"])
        #expect(frame.floors[0].occupancy == 2)
        #expect(frame.floors[1].occupancy == 1)
    }

    @Test("A session with no directory anywhere lands on the unplaced floor")
    func sessionsWithNoProject() {
        var layout = SceneLayout()
        let frame = layout.update(with: Self.board([Self.session("nowhere", project: nil)]))
        #expect(frame.floors.map(\.title) == [SceneLayout.unplacedFloorTitle])
        #expect(frame.floors.first?.projectKey == nil)
    }

    @Test("Desks wrap onto a second row once the floor is full")
    func desksWrap() {
        var layout = SceneLayout()
        let metrics = SceneMetrics.standard
        let perRow = Int(metrics.rowUnits)
        let frame = layout.update(with: Self.board(Self.roots(perRow + 2)))

        let occupied = frame.slots.filter { !$0.isVacant }
        #expect(occupied.filter { $0.row == 0 }.count == perRow)
        #expect(occupied.filter { $0.row == 1 }.count == 2)
        #expect(frame.floors.first?.rowCount == 2)

        // The second row starts at the left edge again, and sits below the
        // first.
        let firstOfRowZero = occupied.first { $0.row == 0 }
        let firstOfRowOne = occupied.first { $0.row == 1 }
        #expect(firstOfRowZero?.anchor.x == firstOfRowOne?.anchor.x)
        #expect((firstOfRowOne?.anchor.y ?? 0) > (firstOfRowZero?.anchor.y ?? 0))
    }

    @Test("A bay too wide for what is left of a row moves down whole")
    func wideBaysDoNotSplit() throws {
        var layout = SceneLayout()
        let metrics = SceneMetrics.standard
        // Blocked agents sort ahead of a delegating one on the board, so the
        // wide bay is the last one allocated — where it no longer fits.
        var sessions = (0..<(Int(metrics.rowUnits) - 1)).map {
            Self.session("aa-\($0)", state: .waitingPermission(tool: "Bash"))
        }
        let boss = Self.session("zz-boss", state: .delegating(children: 3))
        sessions.append(boss)
        sessions += (0..<3).map { Self.session("zz-hand-\($0)", parent: boss.key) }

        let frame = layout.update(with: Self.board(sessions))
        let bossRow = try #require(frame.slot(for: boss.key)?.row)
        #expect(bossRow == 1)
        for index in 0..<3 {
            let key = SessionKey(harness: .claudeCode, sessionID: "zz-hand-\(index)")
            #expect(frame.slot(for: key)?.row == bossRow)
        }
        // Nothing was pushed off the first row to make space.
        #expect(frame.slots.filter { $0.row == 0 }.count == Int(metrics.rowUnits) - 1)
    }

    @Test("The building's bounding box covers every floor")
    func contentRectCoversTheBuilding() {
        var layout = SceneLayout()
        var sessions = Self.roots(8, project: "/Users/example/Code/auspex")
        sessions += (0..<3).map {
            Self.session(
                "pipe-\($0)",
                harness: .grokBuild,
                project: "/Users/example/Code/ingest-pipeline"
            )
        }
        let frame = layout.update(with: Self.board(sessions))

        #expect(frame.floors.count == 2)
        for floor in frame.floors {
            #expect(frame.contentRect.contains(floor.frame))
        }
        #expect(frame.contentRect.width == SceneMetrics.standard.contentWidth)
    }

    @Test("An empty board produces an empty office")
    func emptyBoard() {
        var layout = SceneLayout()
        let frame = layout.update(with: .empty)
        #expect(frame.floors.isEmpty)
        #expect(frame.slots.isEmpty)
        #expect(frame.contentRect.height == 0)
    }

    @Test("Forty sessions fit in a building the camera can frame")
    func fortySessionsStayBounded() {
        var layout = SceneLayout()
        let projects = [
            "/Users/example/Code/auspex",
            "/Users/example/Code/storefront-web",
            "/Users/example/Code/ingest-pipeline",
            "/Users/example/Code/mobile-client"
        ]
        let sessions = (0..<40).map { index in
            Self.session("s-\(index)", project: projects[index % projects.count])
        }
        let frame = layout.update(with: Self.board(sessions))

        #expect(frame.floors.count == 4)
        #expect(frame.slots.filter { !$0.isVacant }.count == 40)
        // Ten desks per project at six to a row: two rows each.
        #expect(frame.floors.allSatisfy { $0.rowCount == 2 })
        #expect(frame.contentRect.width == SceneMetrics.standard.contentWidth)
    }
}
