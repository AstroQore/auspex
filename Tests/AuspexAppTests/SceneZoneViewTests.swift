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

    /// The same map the scene laid out, so a test can point at a bench.
    private static func map(zones: SceneZoneOptions = .all) -> SceneFrame {
        var layout = SceneLayout()
        let board = SceneSnapshotRenderer.demoBoard(elapsed: elapsed)
        return layout.update(
            with: board,
            zones: zones,
            attention: SceneSnapshotRenderer.demoAttention(board)
        )
    }

    // MARK: The demo really covers it

    @Test("The demo map holds one of everything the annexes draw")
    func demoCoversTheWholeVocabulary() throws {
        let frame = Self.map()

        // A delegating family of three at one table.
        let table = try #require(frame.tables.first)
        #expect(frame.tables.count == 1)
        #expect(table.seatCount >= 2)
        let atTheTable = frame.seats.filter { $0.tableID == table.id && $0.session != nil }
        #expect(atTheTable.count == 3)
        #expect(atTheTable.filter { $0.kind == .tableHead }.count == 1)

        // The garden's five ways of not being at a desk: the front row's two,
        // and the back lawn's three.
        let kinds = Set(frame.seats.filter { $0.session != nil }.map(\.kind))
        #expect(kinds.contains(.call))
        #expect(kinds.contains(.note))
        #expect(kinds.contains(.bench))
        #expect(kinds.contains(.doze))
        #expect(kinds.contains(.gate))
        #expect(frame.gate != nil)
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

        // The front row runs below the back lawn, along the walkway: it is the
        // last thing between the reader and the path.
        let waiting = frame.seats.filter { $0.kind.isWaitingBench }
        let lawn = frame.seats.filter { $0.kind.isGardenRest }
        if let lowestLawn = lawn.map(\.anchor.y).max(), let front = waiting.map(\.anchor.y).min() {
            #expect(front > lowestLawn)
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

    @Test("With the annexes off the map is the office and nothing else")
    func annexesOffIsTheOffice() {
        let full = Self.map()
        let office = Self.map(zones: .officeOnly)

        #expect(office.zones.isEmpty)
        #expect(office.seats.isEmpty)
        #expect(office.tables.isEmpty)
        for slot in office.slots { #expect(!slot.isAway) }
        // The desks did not move to make room for the annexes, and did not
        // move back when they went away.
        #expect(full.slots.map(\.anchor) == office.slots.map(\.anchor))
        #expect(full.floors.map(\.frame) == office.floors.map(\.frame))
        // The map is taller with them and no taller without.
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
                departure: frame.walkways.lane(.office),
                arrival: frame.walkways.lane(.garden)
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
}
