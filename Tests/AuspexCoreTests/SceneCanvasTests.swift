import AgentSessionKit
import AgentSessionLive
import AuspexCore
import CoreGraphics
import Foundation
import Testing

/// What the canvas guarantees: a map that grows sideways as well as down, a
/// camera that cannot be flown off the edge of it, a room the camera can be
/// pointed at by name, and a minimap that agrees with both.
///
/// These are properties rather than measurements. Nothing here asserts that a
/// room is 312 points wide — that would fail the next time somebody widened a
/// desk and would never once catch the sign error in a zoom anchor, which is
/// the class of bug this file exists for.
@Suite("Scene canvas")
struct SceneCanvasTests {
    // MARK: Fixtures

    private static func session(
        _ id: String,
        harness: Harness = .claudeCode,
        project: String? = "/Users/example/Code/auspex",
        state: SessionState = .thinking
    ) -> SessionSnapshot {
        let key = SessionKey(harness: harness, sessionID: id)
        return SessionSnapshot(
            identity: SessionIdentity(
                key: key,
                sourcePath: "/Users/example/.claude/projects/demo/\(id).jsonl",
                parent: nil,
                cwd: project,
                gitRoot: project
            ),
            state: state,
            isAlive: !state.isEnded
        )
    }

    private static func board(_ sessions: [SessionSnapshot]) -> BoardSnapshot {
        BoardSnapshot(generatedAt: Date(timeIntervalSince1970: 1_767_225_600), sessions: sessions)
    }

    /// One office with `projects` rooms and `perProject` agents in each.
    private static func campus(projects: Int, perProject: Int = 2) -> SceneFrame {
        var layout = SceneLayout()
        var sessions: [SessionSnapshot] = []
        for project in 0..<projects {
            for index in 0..<perProject {
                sessions.append(
                    session(
                        "p\(project)-s\(index)",
                        project: "/Users/example/Code/project-\(project)"
                    )
                )
            }
        }
        return layout.update(with: board(sessions))
    }

    // MARK: - The map grows

    @Test("A handful of projects keeps the single-column office it always had")
    func smallOfficeIsUnchanged() {
        let frame = Self.campus(projects: 3)
        #expect(frame.floors.count == 3)
        // Three rooms shelve inside the width one full room takes: the campus
        // rule only widens a building that has something to spread out.
        #expect(frame.contentRect.width <= SceneMetrics.standard.contentWidth)
    }

    @Test("A busy day widens the campus instead of only growing it downward")
    func campusWidensWithProjects() {
        let small = Self.campus(projects: 4)
        let large = Self.campus(projects: 40)

        #expect(large.floors.count == 40)
        #expect(large.contentRect.width > small.contentRect.width)
        // The whole point: forty rooms in a column would be a ribbon nobody
        // can read. The map stays within sight of a window's proportions.
        let aspect = large.contentRect.width / large.contentRect.height
        #expect(aspect > 0.6)
        #expect(aspect < 3.0)
    }

    @Test("Every room stays inside the world the camera is told about")
    func worldRectCoversEveryRoom() {
        let frame = Self.campus(projects: 30, perProject: 3)
        #expect(frame.floors.count == 30)
        for floor in frame.floors {
            #expect(frame.contentRect.contains(floor.frame))
        }
        // Rooms are shelved, so a big office has several rooms on one shelf
        // and several shelves.
        let lefts = Set(frame.floors.map { $0.frame.minX })
        let tops = Set(frame.floors.map { $0.frame.minY })
        #expect(lefts.count > 1)
        #expect(tops.count > 1)
    }

    @Test("More projects is always more world, never less")
    func worldGrowsMonotonically() {
        var previous: CGFloat = 0
        for count in [1, 2, 4, 8, 16, 32] {
            let area = Self.campus(projects: count).contentRect
            let size = area.width * area.height
            #expect(size > previous, "\(count) projects did not grow the world")
            previous = size
        }
    }

    // MARK: - Focus

    @Test("A project's focus rect is the room it is in")
    func focusRectIsTheRoom() throws {
        var layout = SceneLayout()
        let frame = layout.update(
            with: Self.board(
                [
                    Self.session("a", project: "/Users/example/Code/auspex"),
                    Self.session("b", project: "/Users/example/Code/storefront-web")
                ]
            )
        )

        let rect = try #require(frame.focusRect(forProject: "/Users/example/Code/storefront-web"))
        let room = try #require(
            frame.floors.first { $0.projectKey == "/Users/example/Code/storefront-web" }
        )
        #expect(rect == room.frame)
        // The other project's room is somewhere else entirely.
        let other = try #require(frame.focusRect(forProject: "/Users/example/Code/auspex"))
        #expect(other != rect)
    }

    @Test("A project nobody is working in has nothing to focus on")
    func focusRectOfAnAbsentProject() {
        var layout = SceneLayout()
        let frame = layout.update(with: Self.board([Self.session("a")]))
        #expect(frame.focusRect(forProject: "/Users/example/Code/nowhere") == nil)
    }

    @Test("The sessions with no directory are a room that can be focused too")
    func unplacedRoomCanBeFocused() {
        var layout = SceneLayout()
        let frame = layout.update(with: Self.board([Self.session("a", project: nil)]))
        #expect(frame.focusRect(forProject: nil) != nil)
    }

    @Test("A point inside a room finds that room, and a point outside finds none")
    func roomHitTesting() throws {
        let frame = Self.campus(projects: 6)
        let room = try #require(frame.floors.last)
        let inside = CGPoint(x: room.frame.midX, y: room.frame.midY)
        #expect(frame.floor(at: inside)?.id == room.id)
        #expect(frame.floor(at: CGPoint(x: -400, y: -400)) == nil)
    }

    // MARK: - Camera

    private static let world = CGRect(x: 0, y: 0, width: 4_000, height: 3_000)
    private static let view = CGSize(width: 800, height: 600)

    private static func camera(zoom: CGFloat = 1) -> SceneViewport {
        SceneViewport(
            content: world,
            size: view,
            center: CGPoint(x: world.midX, y: world.midY),
            zoom: zoom
        )
    }

    @Test("Panning past the edge stops at the edge instead of losing the map")
    func panningIsClamped() {
        let panned = Self.camera().panned(by: CGVector(dx: 100_000, dy: -100_000))
        #expect(Self.world.contains(panned.visibleRect))
        #expect(panned.visibleRect.maxX == Self.world.maxX)
        #expect(panned.visibleRect.minY == Self.world.minY)
    }

    @Test("A world smaller than the window is centred and cannot be dragged")
    func smallWorldIsPinned() {
        let tiny = SceneViewport(
            content: CGRect(x: 0, y: 0, width: 300, height: 200),
            size: Self.view,
            center: .zero,
            zoom: 1
        ).clamped()

        #expect(tiny.center == CGPoint(x: 150, y: 100))
        #expect(tiny.panned(by: CGVector(dx: 500, dy: 500)).center == tiny.center)
        #expect(tiny.isFullyVisible)
    }

    @Test("Zooming around a point leaves that point where it was on screen")
    func zoomKeepsItsAnchor() {
        let before = Self.camera()
        let anchor = CGPoint(x: 2_200, y: 1_600)
        let after = before.zoomed(to: 2, around: anchor)

        #expect(after.zoom == 2)
        func offset(_ viewport: SceneViewport) -> CGPoint {
            CGPoint(
                x: (anchor.x - viewport.center.x) * viewport.zoom,
                y: (anchor.y - viewport.center.y) * viewport.zoom
            )
        }
        #expect(abs(offset(after).x - offset(before).x) < 0.001)
        #expect(abs(offset(after).y - offset(before).y) < 0.001)
    }

    @Test("Fit shows the whole world")
    func fitFramesEverything() {
        let fitted = Self.camera(zoom: 4).fitted()
        #expect(fitted.visibleRect.contains(Self.world))
        #expect(fitted.showsAll(of: Self.world))
    }

    @Test("Fit does not slam the camera into the near stop for a small world")
    func fitStopsShortOfMaximumZoom() {
        let fitted = SceneViewport(
            content: CGRect(x: 0, y: 0, width: 100, height: 80),
            size: Self.view,
            center: .zero,
            zoom: 1
        ).fitted()
        #expect(fitted.zoom == SceneViewport.maxFitZoom)
    }

    @Test("Focusing a room centres it and keeps it wholly on screen")
    func focusFramesOneRoom() {
        let room = CGRect(x: 2_600, y: 400, width: 400, height: 300)
        let focused = Self.camera().focused(on: room)

        #expect(focused.showsAll(of: room))
        #expect(Self.world.contains(focused.visibleRect))
    }

    @Test("Every zoom the camera can stop at keeps the pixel grid whole")
    func zoomStaysOnTheLadder() {
        // Integer multiples in, integer divisors out: the two families that
        // map whole art pixels onto whole screen pixels.
        for rung in SceneViewport.zoomLadder {
            let crisp = rung >= 1
                ? rung == rung.rounded()
                : (1 / rung) == (1 / rung).rounded()
            #expect(crisp, "\(rung) would put seams through the art")
        }
        for preset in SceneViewport.zoomPresets {
            #expect(SceneViewport.zoomLadder.contains(preset))
        }

        var camera = Self.camera(zoom: 1)
        for _ in 0..<12 { camera = camera.stepped(1) }
        #expect(camera.zoom == SceneViewport.maxZoom)
        for _ in 0..<40 { camera = camera.stepped(-1) }
        #expect(camera.zoom == SceneViewport.minZoom)
    }

    @Test("An awkward zoom is snapped to the nearest rung, and stays there")
    func snappingIsIdempotent() {
        #expect(SceneViewport.snapped(0.95) == 1)
        #expect(SceneViewport.snapped(1.9) == 2)
        #expect(SceneViewport.snapped(SceneViewport.snapped(0.4)) == SceneViewport.snapped(0.4))
        #expect(SceneViewport.rung(atOrBelow: 0.9) == 0.5)
        #expect(Self.camera().zoomed(to: 1.37).zoom == 1)
    }

    @Test("A room off the side of the window is not mistaken for one on screen")
    func visibilityTests() {
        let camera = Self.camera(zoom: 1)
        let onScreen = CGRect(x: 1_900, y: 1_400, width: 100, height: 100)
        let offScreen = CGRect(x: 3_500, y: 2_500, width: 100, height: 100)
        #expect(camera.shows(onScreen))
        #expect(!camera.shows(offScreen))
        #expect(camera.showsAll(of: onScreen))
        // The cull margin is what keeps a room that is one point off the edge
        // from stopping and starting as somebody nudges the trackpad.
        #expect(camera.shows(CGRect(x: 2_450, y: 1_500, width: 10, height: 10), margin: 200))
    }

    // MARK: - Trackpad

    @Test("A two-finger scroll moves the map with the fingers")
    func scrollFollowsTheFingers() {
        // With natural scrolling on — the default — AppKit's deltas already
        // describe the content following the fingers.
        let natural = SceneGesture.panDelta(x: 10, y: 6, isDirectionInverted: true)
        let classic = SceneGesture.panDelta(x: 10, y: 6, isDirectionInverted: false)
        #expect(natural.dx == -classic.dx)
        #expect(natural.dy == -classic.dy)
        // Fingers pushing the map left move the camera right.
        #expect(natural.dx < 0)
        // The scroll deltas are y-down and the scene is y-up.
        #expect(natural.dy > 0)
    }

    @Test("Momentum keeps the map moving and still stops at the edge")
    func momentumStopsAtTheEdge() {
        var camera = Self.camera(zoom: 2)
        // A flick: fingers, then eight momentum events with decaying deltas.
        camera = camera.panned(by: CGVector(dx: 1_200, dy: 0), rubberBanding: true)
        var delta: CGFloat = 3_000
        for _ in 0..<8 {
            camera = camera.panned(by: CGVector(dx: delta, dy: 0))
            delta *= 0.7
        }
        #expect(camera.visibleRect.maxX == Self.world.maxX)
        #expect(!camera.isOverscrolled)
    }

    @Test("The map can be pulled off its edge, but only so far, and it comes back")
    func rubberBanding() {
        let camera = Self.camera(zoom: 2)
        var pulled = camera
        for _ in 0..<20 {
            pulled = pulled.panned(by: CGVector(dx: 400, dy: 0), rubberBanding: true)
        }
        let clamped = camera.panned(by: CGVector(dx: 8_000, dy: 0))

        #expect(pulled.isOverscrolled)
        // Past the edge, but never more than the limit however long the drag.
        let overshoot = pulled.center.x - clamped.center.x
        #expect(overshoot > 0)
        #expect(overshoot <= SceneViewport.rubberBandLimit / pulled.zoom + 0.001)
        // And it springs home when the fingers lift.
        #expect(!pulled.settled().isOverscrolled)
        #expect(abs(pulled.settled().center.x - clamped.center.x) < 0.001)
    }

    @Test("A pinch zooms continuously and lands on a rung when the fingers lift")
    func pinchIsContinuousThenCrisp() {
        var camera = Self.camera(zoom: 1)
        let anchor = CGPoint(x: 2_200, y: 1_600)
        func offset(_ viewport: SceneViewport) -> CGPoint {
            CGPoint(
                x: (anchor.x - viewport.center.x) * viewport.zoom,
                y: (anchor.y - viewport.center.y) * viewport.zoom
            )
        }
        let before = offset(camera)

        // Twelve events of a tenth each: a pinch, not a step.
        for _ in 0..<12 {
            camera = camera.zoomed(
                to: SceneGesture.zoom(camera.zoom, magnifiedBy: 0.1),
                around: anchor,
                snapping: false
            )
        }
        #expect(camera.zoom > 3)
        #expect(!SceneViewport.zoomLadder.contains(camera.zoom))
        #expect(abs(offset(camera).x - before.x) < 0.001)
        #expect(abs(offset(camera).y - before.y) < 0.001)

        // The pixel grid comes back when the fingers do.
        let settled = camera.settled(around: anchor)
        #expect(SceneViewport.zoomLadder.contains(settled.zoom))
        #expect(abs(offset(settled).x - before.x) < 0.001)
    }

    @Test("A pinch composes by multiplication, so the same distance is the same zoom")
    func pinchComposes() {
        var slow: CGFloat = 1
        for _ in 0..<10 { slow = SceneGesture.zoom(slow, magnifiedBy: 0.05) }
        var fast: CGFloat = 1
        for _ in 0..<5 { fast = SceneGesture.zoom(fast, magnifiedBy: 0.1025) }
        #expect(abs(slow - fast) < 0.01)
    }

    @Test("A wheel notch is one rung, either way")
    func wheelNotches() {
        #expect(SceneGesture.rungs(forWheelDelta: 1) == 1)
        #expect(SceneGesture.rungs(forWheelDelta: -3) == -1)
        #expect(SceneGesture.rungs(forWheelDelta: 0) == 0)
    }

    @Test("A window resize shows more office rather than a bigger office")
    func resizingKeepsTheZoom() {
        let camera = Self.camera(zoom: 2)
        let wider = camera.withSize(CGSize(width: 1_200, height: 900))
        #expect(wider.zoom == camera.zoom)
        #expect(wider.visibleRect.width > camera.visibleRect.width)
        #expect(Self.world.contains(wider.visibleRect))
    }

    // MARK: - Minimap

    private static let minimapFrame = CGRect(x: 0, y: 0, width: 120, height: 90)

    @Test("The minimap maps the map into its box and back again")
    func minimapRoundTrips() {
        let map = SceneMinimap(world: Self.world, in: Self.minimapFrame)
        for point in [
            CGPoint(x: 0, y: 0),
            CGPoint(x: 4_000, y: 3_000),
            CGPoint(x: 1_234, y: 567)
        ] {
            let there = map.point(point)
            let back = map.worldPoint(there)
            #expect(abs(back.x - point.x) < 0.001)
            #expect(abs(back.y - point.y) < 0.001)
        }
    }

    @Test("A room's rectangle lands inside the minimap, in proportion")
    func minimapKeepsProportions() {
        let map = SceneMinimap(world: Self.world, in: Self.minimapFrame)
        let room = CGRect(x: 1_000, y: 750, width: 1_000, height: 750)
        let drawn = map.rect(room)

        #expect(Self.minimapFrame.insetBy(dx: -0.001, dy: -0.001).contains(drawn))
        // One scale on both axes: a tall office must not be drawn square.
        #expect(abs(drawn.width / drawn.height - room.width / room.height) < 0.001)
        #expect(abs(drawn.width - Self.minimapFrame.width / 4) < 0.001)
    }

    @Test("A tall map gets a tall minimap and a wide one a wide minimap")
    func minimapFrameFollowsTheMap() {
        let tall = SceneMinimap.frame(
            for: CGRect(x: 0, y: 0, width: 900, height: 3_000),
            maximum: CGSize(width: 160, height: 120)
        )
        let wide = SceneMinimap.frame(
            for: CGRect(x: 0, y: 0, width: 3_000, height: 900),
            maximum: CGSize(width: 160, height: 120)
        )
        #expect(tall.height > tall.width)
        #expect(wide.width > wide.height)
        #expect(tall.height <= 120.001)
        #expect(wide.width <= 160.001)
    }

    @Test("Clicking the middle of the minimap points the camera at the middle")
    func minimapClickJumps() {
        let map = SceneMinimap(world: Self.world, in: Self.minimapFrame)
        let target = map.worldPoint(CGPoint(x: Self.minimapFrame.midX, y: Self.minimapFrame.midY))
        #expect(abs(target.x - Self.world.midX) < 0.001)
        #expect(abs(target.y - Self.world.midY) < 0.001)
    }

    @Test("The office's own world can be handed straight to the minimap")
    func minimapDrawsTheRealOffice() throws {
        let frame = Self.campus(projects: 12)
        let box = SceneMinimap.frame(
            for: frame.contentRect, maximum: CGSize(width: 160, height: 120)
        )
        let map = SceneMinimap(world: frame.contentRect, in: box)
        for floor in frame.floors {
            #expect(box.insetBy(dx: -0.001, dy: -0.001).contains(map.rect(floor.frame)))
        }
    }

    // MARK: - The two spaces

    @Test("The floor plan and SpriteKit's world are one negation apart")
    func layoutAndSceneAgree() {
        let plan = CGRect(x: 28, y: 28, width: 400, height: 200)
        let world = SceneGeometry.scene(from: plan)
        #expect(world.minX == plan.minX)
        #expect(world.maxY == -plan.minY)
        #expect(world.height == plan.height)
        #expect(SceneGeometry.layout(from: world) == plan)
        #expect(SceneGeometry.layout(from: SceneGeometry.scene(from: CGPoint(x: 3, y: 4)))
            == CGPoint(x: 3, y: 4))
    }
}
