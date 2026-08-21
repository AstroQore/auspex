import AgentSessionKit
import AgentSessionLive
import AppKit
import AuspexCore
import CoreGraphics
import Foundation
import QuartzCore
import SpriteKit
import Testing

@testable import AuspexApp

/// The annexes, as far as a headless test can hold them.
///
/// Nobody can watch a walk on a machine with no screen, so what is asserted
/// here is everything on either side of the animation: that the map the scene
/// lays out has the annexes in it, that a click in the garden lands on the
/// person sitting there rather than on the desk they left, that the demo board
/// really does produce one of everything the annexes draw, and that switching
/// them off puts the map back exactly as it was.
@MainActor
@Suite("Scene annexes")
struct SceneZoneViewTests {
    private static let elapsed: TimeInterval = 16

    /// A scene showing the demo map, laid out at a known size.
    private static func scene(
        zones: SceneZoneOptions = .all,
        size: CGSize = CGSize(width: 900, height: 640)
    ) -> (SceneCanvasView, OfficeScene) {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let appearance = NSAppearance(named: .darkAqua) ?? NSAppearance()
        let theme = SceneTheme.resolved(for: appearance)
        let scene = OfficeScene(theme: theme)
        let view = SceneCanvasView(scene: scene, frame: CGRect(origin: .zero, size: size))
        view.layoutSubtreeIfNeeded()
        let board = SceneSnapshotRenderer.demoBoard(elapsed: elapsed)
        scene.update(
            board: board,
            selected: nil,
            focusedProject: nil,
            reduceMotion: true,
            theme: theme,
            zones: zones,
            attention: SceneSnapshotRenderer.demoAttention(board)
        )
        view.layoutSubtreeIfNeeded()
        scene.update(CACurrentMediaTime())
        return (view, scene)
    }

    /// The map the scene is actually drawing.
    ///
    /// Read off the scene rather than derived from a fresh ``SceneLayout``,
    /// because the two are no longer the same picture: the scene knows who has
    /// already walked out of a door and a fresh layout does not, so a test that
    /// pointed at a bench derived without that would be pointing at a bench the
    /// scene does not have.
    private static func map(zones: SceneZoneOptions = .all) -> SceneFrame {
        scene(zones: zones).1.map
    }

    // MARK: The demo really covers it

    @Test("The demo map holds one of everything the annexes draw")
    func demoCoversTheWholeVocabulary() throws {
        let frame = Self.map()

        // A delegating family of three at one table. There are other tables:
        // a company of three has a meeting room whether or not it is using it.
        let table = try #require(frame.tables.first { $0.head != nil })
        #expect(frame.tables.count(where: { $0.head != nil }) == 1)
        #expect(frame.tables.contains { $0.head == nil })
        #expect(table.seatCount >= 2)
        let atTheTable = frame.seats.filter { $0.tableID == table.id && $0.session != nil }
        #expect(atTheTable.count == 3)
        #expect(atTheTable.filter { $0.kind == .tableHead }.count == 1)

        // The break rooms' four ways of not being at a desk: the front row's
        // two, and the back of the room's two. The fifth — walking out — is
        // not in a still: a session that reached the door has left, which is
        // the whole point of the door.
        let kinds = Set(frame.seats.filter { $0.session != nil }.map(\.kind))
        #expect(kinds.contains(.call))
        #expect(kinds.contains(.note))
        #expect(kinds.contains(.bench))
        #expect(kinds.contains(.doze))
        #expect(!kinds.contains(.gate))
        #expect(!frame.doors.isEmpty)

        // And every company gets one of the three kinds of break room, more
        // than one kind between them.
        let rooms = Set(frame.zones.compactMap(\.breakKind))
        #expect(rooms.count >= 2)
    }

    @Test("Everybody in an annex still holds the desk they walked away from")
    func awayDesksAreHeld() {
        let frame = Self.map()
        for seat in frame.seats {
            guard let key = seat.session else { continue }
            #expect(frame.slot(for: key)?.isAway == true)
        }
        // And nobody who is at their desk is marked away.
        for slot in frame.slots where slot.session != nil && !slot.isAway {
            #expect(frame.seat(for: slot.session!) == nil)
        }
    }

    @Test("Everybody waiting on a person is on the front row, together")
    func blockedIsOnTheWaitingBench() {
        // One place to look. A raised hand among forty desks is something you
        // have to find; the bench by the path is where the eye lands first,
        // and it is the same row whether the harness reported the block or the
        // agent said so.
        let board = SceneSnapshotRenderer.demoBoard(elapsed: Self.elapsed)
        let frame = Self.map()
        let blocked = board.sessions.filter {
            if case .waitingPermission = $0.state { return true }
            return false
        }
        #expect(!blocked.isEmpty, "the demo has to have one for this to mean anything")
        for session in blocked {
            #expect(frame.seat(for: session.key)?.kind == .call)
            #expect(frame.slot(for: session.key)?.isAway == true)
        }

        // The front row runs below the back of the room, along the corridor: it
        // is the last thing between the reader and the door. Per suite, because
        // there is a break room per company and comparing one company's bench
        // with another's is comparing two different rooms.
        for floor in frame.floors {
            let here = frame.seats.filter { $0.floorIndex == floor.index }
            let waiting = here.filter { $0.kind.isWaitingBench }
            let rest = here.filter { $0.kind.isBreakRest }
            guard let deepest = rest.map(\.anchor.y).max(),
                  let front = waiting.map(\.anchor.y).min()
            else { continue }
            #expect(front > deepest)
        }
    }

    // MARK: The pointer

    @Test("Clicking somebody in the garden selects them, not the desk they left")
    func clickingAGardenSeatSelects() throws {
        let (_, scene) = Self.scene()
        var selected: SessionKey??
        scene.onSelect = { selected = .some($0) }
        scene.onFocusProject = { _ in }

        let frame = Self.map()
        let seat = try #require(frame.seats.first { $0.session != nil && $0.kind == .bench })
        scene.click(
            atLayoutPoint: CGPoint(x: seat.anchor.x, y: seat.anchor.y - 30),
            clickCount: 1
        )
        #expect(selected == .some(seat.session))

        // The desk they walked away from is drawn empty, and answers for
        // nobody: clicking it must not select the person sitting outside.
        let desk = try #require(frame.slot(for: seat.session!))
        scene.click(
            atLayoutPoint: CGPoint(x: desk.anchor.x, y: desk.anchor.y - 30),
            clickCount: 1
        )
        #expect(selected == .some(nil))
    }

    @Test("Clicking somebody at a table selects them")
    func clickingATableSeatSelects() throws {
        let (_, scene) = Self.scene()
        var selected: SessionKey??
        scene.onSelect = { selected = .some($0) }
        scene.onFocusProject = { _ in }

        let frame = Self.map()
        let seat = try #require(frame.seats.first { $0.kind == .tableHead && $0.session != nil })
        scene.click(
            atLayoutPoint: CGPoint(x: seat.anchor.x, y: seat.anchor.y - 20),
            clickCount: 1
        )
        #expect(selected == .some(seat.session))
    }

    // MARK: Switching them off

    @Test("With the other rooms off a suite is its desks and nothing else")
    func roomsOffIsTheOffice() throws {
        let full = Self.map()
        let office = Self.map(zones: .officeOnly)

        #expect(office.zones.isEmpty)
        #expect(office.seats.isEmpty)
        #expect(office.tables.isEmpty)
        for slot in office.slots { #expect(!slot.isAway) }
        // A suite with no other rooms *is* its desks.
        for floor in office.floors { #expect(floor.suite == floor.frame) }

        // The desks did not move inside their own company to make room for the
        // rooms below them. Where the companies themselves land on the campus
        // does change — a suite with a meeting room in it is a taller building,
        // and taller buildings shelve differently — which is a fact about the
        // campus rather than about any project's room.
        // Matched by project rather than by allocation index: with the rooms
        // on, the sessions that walked out of a door released their suites,
        // and a released suite is reused by whoever comes next.
        var compared = 0
        for room in office.floors {
            let candidates = full.floors.filter { $0.projectKey == room.projectKey }
            guard candidates.count == 1,
                  office.floors.count(where: { $0.projectKey == room.projectKey }) == 1,
                  let same = candidates.first
            else { continue }
            compared += 1
            #expect(same.frame.size == room.frame.size)
            let before = office.slots.filter { $0.floorIndex == room.index }
                .map { CGPoint(x: $0.anchor.x - room.frame.minX, y: $0.anchor.y - room.frame.minY) }
            let after = full.slots.filter { $0.floorIndex == same.index }
                .map { CGPoint(x: $0.anchor.x - same.frame.minX, y: $0.anchor.y - same.frame.minY) }
            // Relative to a floor origin that itself moved, so compare to a
            // hair rather than to the last bit of a double.
            #expect(before.count == after.count)
            for (b, a) in zip(before, after) {
                #expect(abs(b.x - a.x) < 0.001 && abs(b.y - a.y) < 0.001)
            }
        }
        #expect(compared >= 3, "the demo has to have that many projects for this to mean anything")
        // The map is taller with the rooms and no taller without.
        #expect(full.contentRect.height > office.contentRect.height)
    }

    @Test("The scene renders the map with the annexes on and with them off")
    func bothMapsRender() throws {
        for zones in [SceneZoneOptions.all, .officeOnly] {
            let (view, scene) = Self.scene(zones: zones)
            let bounds = scene.contentBounds
            #expect(bounds.width > 1)
            #expect(bounds.height > 1)
            _ = view
        }
    }

    // MARK: Walking

    @Test("A walk is straight legs the character has a strip for")
    func walksAreAxisAligned() throws {
        let frame = Self.map()
        let seat = try #require(frame.seats.first { $0.session != nil && $0.kind == .bench })
        let desk = try #require(frame.slot(for: seat.session!))

        let waypoints = SceneRoute.waypoints(
            from: desk.anchor,
            to: seat.anchor,
            lanes: (
                departure: frame.walkways.lane(floor: desk.floorIndex),
                arrival: frame.walkways.lane(floor: seat.floorIndex)
            ),
            trunk: frame.walkways.trunk
        )
        let legs = SceneRoute.legs(waypoints)
        #expect(legs.count > 1)
        for leg in legs {
            let straight = abs(leg.from.x - leg.to.x) < 0.001
                || abs(leg.from.y - leg.to.y) < 0.001
            #expect(straight)
            // Every direction has a strip, or a strip it is the mirror of.
            #expect(CharacterPose(rawValue: leg.direction.poseName) != nil)
        }
        // And it takes a length of time somebody would sit through.
        let seconds = SceneRoute.duration(of: waypoints, speed: frame.metrics.walkSpeed)
        #expect(seconds > 0)
        #expect(seconds <= 6)
    }

    @Test("Reduce Motion puts everybody in their seat with no walking at all")
    func reduceMotionDoesNotWalk() {
        // The scene the tests build already runs with Reduce Motion on, which
        // is what makes a render reproducible. What it must not do is leave
        // anybody in transit: a still with half a walk in it is a picture of
        // neither end.
        let (_, scene) = Self.scene()
        #expect(scene.reduceMotion)
        let frame = Self.map()
        for seat in frame.seats where seat.session != nil {
            #expect(frame.place(of: seat.session!)?.id == seat.id)
        }
    }

    // MARK: Leaving, and the arcs

    @Test("An ended session is gone from the map the scene draws")
    func endedCharactersLeave() throws {
        let (_, scene) = Self.scene()
        let board = SceneSnapshotRenderer.demoBoard(elapsed: Self.elapsed)
        // Not the ones holding a receipt: a session that reported finishing is
        // waiting to be *read*, and the process exiting does not un-write the
        // line somebody still has to look at. Those sit on the bench.
        let attention = SceneSnapshotRenderer.demoAttention(board)
        let over = board.sessions.filter {
            $0.state.isEnded && !(attention[$0.key]?.isSignalling ?? false)
        }
        #expect(!over.isEmpty, "the demo has to have some for this to mean anything")

        // Nobody is standing at a door: a character that reached one has left,
        // and in a still — Reduce Motion, no walking — it reached one at once.
        for session in over {
            #expect(scene.hasDeparted(session.key))
            #expect(scene.map.place(of: session.key) == nil)
        }
        #expect(scene.map.seats.allSatisfy { $0.kind != .gate || $0.session == nil })
        // And the desks they were holding went with them.
        for session in over { #expect(scene.map.slot(for: session.key) == nil) }
    }

    @Test("The scene draws no arcs until somebody is looking at a family")
    func arcsAreDrawnForOneFamily() throws {
        let (_, scene) = Self.scene()
        // At rest the room has no lines across it at all.
        #expect(scene.drawnArcCount == 0)

        let board = SceneSnapshotRenderer.demoBoard(elapsed: Self.elapsed)
        let head = try #require(scene.map.tables.first { $0.head != nil }?.head)
        let family = scene.map.arcs(focus: head)
        #expect(!family.isEmpty)

        scene.update(
            board: board,
            selected: head,
            focusedProject: nil,
            reduceMotion: true,
            theme: SceneTheme.resolved(for: NSAppearance(named: .darkAqua) ?? NSAppearance()),
            zones: .all,
            attention: SceneSnapshotRenderer.demoAttention(board)
        )
        #expect(scene.drawnArcCount == family.count)
        #expect(scene.drawnArcCount <= SceneDirector.arcLimit)

        // Letting go of it puts the room back the way it was.
        scene.update(
            board: board,
            selected: nil,
            focusedProject: nil,
            reduceMotion: true,
            theme: SceneTheme.resolved(for: NSAppearance(named: .darkAqua) ?? NSAppearance()),
            zones: .all,
            attention: SceneSnapshotRenderer.demoAttention(board)
        )
        #expect(scene.drawnArcCount == 0)
    }
}
