import AgentSessionKit
import AgentSessionLive
import AuspexCore
import CoreGraphics
import Foundation
import Testing

/// What the office promises once a real scroll view is carrying it: the three
/// coordinate spaces agree, a pinch that travels moves the map as well as
/// scaling it, the camera lands on a rung only when the fingers lift, and the
/// pointer is placed without walking the scene graph.
///
/// Nobody can pinch a headless machine, so what is tested here is the half that
/// is ours — the arithmetic between an `NSEvent`, `NSScrollView.magnification`,
/// and the camera. What is left to `NSScrollView` (momentum, elastic edges,
/// the scroll-direction preference) is asserted as *configuration* in
/// `SceneGestureEventTests`, and felt on hardware.
@Suite("Scene scrolling")
struct SceneScrollTests {
    // MARK: Fixtures

    private static let world = CGRect(x: -120, y: -80, width: 4_000, height: 3_000)
    private static let geometry = SceneScrollGeometry(world: world)
    private static let viewSize = CGSize(width: 800, height: 600)

    /// What the scroll view shows at `magnification`, centred on the middle of
    /// the document.
    private static func documentVisible(magnification: CGFloat) -> CGRect {
        let size = CGSize(
            width: viewSize.width / magnification, height: viewSize.height / magnification
        )
        return CGRect(
            x: (world.width - size.width) / 2,
            y: (world.height - size.height) / 2,
            width: size.width,
            height: size.height
        )
    }

    // MARK: - The three spaces

    @Test("Document space is the floor plan, moved to its own origin")
    func documentIsLayoutShifted() {
        let layout = CGPoint(x: 380, y: 220)
        let document = Self.geometry.document(fromLayout: layout)
        #expect(document == CGPoint(x: 500, y: 300))
        #expect(Self.geometry.layout(fromDocument: document) == layout)
        #expect(Self.geometry.documentSize == Self.world.size)
    }

    @Test("A document point and a scene point are the same place")
    func documentAndSceneRoundTrip() {
        for point in [CGPoint(x: 0, y: 0), CGPoint(x: 4_000, y: 3_000), CGPoint(x: 37, y: 913)] {
            let scene = Self.geometry.scene(fromDocument: point)
            let back = Self.geometry.document(fromScene: scene)
            #expect(abs(back.x - point.x) < 0.001)
            #expect(abs(back.y - point.y) < 0.001)
        }
        // The world the camera is clamped to is the same world the document is.
        #expect(Self.geometry.contentRect == SceneGeometry.scene(from: Self.world))
    }

    @Test("What the scroll view shows and where the camera is are one value")
    func viewportRoundTrips() {
        for magnification in [SceneViewport.minZoom, 0.5, 1, 2, SceneViewport.maxZoom] {
            let visible = Self.documentVisible(magnification: magnification)
            let viewport = Self.geometry.viewport(
                documentVisible: visible, magnification: magnification
            )
            #expect(viewport.zoom == magnification)
            #expect(abs(viewport.size.width - Self.viewSize.width) < 0.001)
            #expect(abs(viewport.size.height - Self.viewSize.height) < 0.001)

            let back = Self.geometry.documentVisible(for: viewport)
            #expect(abs(back.minX - visible.minX) < 0.001)
            #expect(abs(back.minY - visible.minY) < 0.001)
            #expect(abs(back.width - visible.width) < 0.001)
            #expect(abs(back.height - visible.height) < 0.001)
        }
    }

    @Test("A camera pulled past the edge is followed rather than corrected")
    func viewportIsNotClamped() {
        // The clip view is elastic: while the fingers are still on the glass it
        // really is showing air past the corner of the map, and a camera that
        // refused to follow would make the edge look like a dropped gesture.
        let visible = CGRect(x: -300, y: -220, width: 800, height: 600)
        let viewport = Self.geometry.viewport(documentVisible: visible, magnification: 1)
        #expect(!Self.geometry.contentRect.contains(viewport.visibleRect))
        #expect(viewport.center != viewport.clamped().center)
    }

    @Test("The whole map fits the document exactly")
    func fitFillsTheDocument() {
        let viewport = Self.geometry
            .viewport(documentVisible: Self.documentVisible(magnification: 1), magnification: 1)
            .fitted()
        let visible = Self.geometry.documentVisible(for: viewport)
        #expect(visible.insetBy(dx: -1, dy: -1).contains(CGRect(origin: .zero, size: Self.world.size)))
    }

    // MARK: - Zooming around a point

    /// Where a document point sits inside the window, in view points.
    private static func offset(
        of document: CGPoint,
        in viewport: SceneViewport
    ) -> CGPoint {
        let visible = geometry.documentVisible(for: viewport)
        return CGPoint(
            x: (document.x - visible.minX) * viewport.zoom,
            y: (document.y - visible.minY) * viewport.zoom
        )
    }

    @Test("Zooming around the pointer leaves the pointer over the same place")
    func zoomKeepsWhatIsUnderThePointer() {
        // This is `NSScrollView.setMagnification(_:centeredAt:)`'s contract —
        // the named point keeps its position in the window rather than moving
        // to the middle — expressed against our own arithmetic, so that the two
        // cannot drift apart.
        let before = Self.geometry.viewport(
            documentVisible: Self.documentVisible(magnification: 1), magnification: 1
        )
        let pointer = CGPoint(x: 3_100, y: 2_400)
        let after = before.zoomed(to: 2, around: Self.geometry.scene(fromDocument: pointer))

        #expect(after.zoom == 2)
        let start = Self.offset(of: pointer, in: before)
        let end = Self.offset(of: pointer, in: after)
        #expect(abs(start.x - end.x) < 0.001)
        #expect(abs(start.y - end.y) < 0.001)
    }

    // MARK: - A pinch that travels

    @Test("A pinch whose fingers move scales and moves the map at once")
    func pinchZoomsAndPans() {
        // Six events: each grows the content by a tenth *and* slides the point
        // between the fingers up and to the right, which is what a hand
        // actually does. Both have to show up in the result.
        var visible = Self.documentVisible(magnification: 1)
        var magnification: CGFloat = 1
        let start = Self.geometry.viewport(documentVisible: visible, magnification: magnification)
        var centroid = CGPoint(x: 400, y: 300)

        for _ in 0..<6 {
            let next = SceneGesture.zoom(magnification, magnifiedBy: 0.1)
            // The zoom, around the point between the fingers.
            let anchor = CGPoint(
                x: visible.minX + centroid.x / magnification,
                y: visible.minY + (Self.viewSize.height - centroid.y) / magnification
            )
            let zoomed = Self.geometry
                .viewport(documentVisible: visible, magnification: magnification)
                .zoomed(to: next, around: Self.geometry.scene(fromDocument: anchor), snapping: false)
            visible = Self.geometry.documentVisible(for: zoomed)
            magnification = next

            // And the travel, which the zoom alone does not provide.
            let moved = CGPoint(x: centroid.x + 6, y: centroid.y + 4)
            let scroll = SceneGesture.pinchScroll(
                centroidDelta: CGVector(dx: moved.x - centroid.x, dy: moved.y - centroid.y),
                magnification: magnification
            )
            visible.origin.x += scroll.dx
            visible.origin.y += scroll.dy
            centroid = moved
        }

        let end = Self.geometry.viewport(documentVisible: visible, magnification: magnification)
        #expect(end.zoom > start.zoom * 1.6)
        // The map moved as well: fingers travelling right and up carry the map
        // with them, so the window onto it goes left and down.
        #expect(visible.minX < Self.documentVisible(magnification: magnification).minX)
        #expect(end.center != start.center)
    }

    @Test("The map follows the fingers rather than running from them")
    func pinchScrollFollowsTheFingers() {
        let right = SceneGesture.pinchScroll(centroidDelta: CGVector(dx: 10, dy: 0), magnification: 1)
        let up = SceneGesture.pinchScroll(centroidDelta: CGVector(dx: 0, dy: 10), magnification: 1)
        // Fingers to the right push the map right, which moves the window left.
        #expect(right.dx == -10)
        // Fingers up push the map up: the window travels *down* the document,
        // which is y-down.
        #expect(up.dy == 10)
        // A travel of an inch on the glass is an inch of screen at any zoom.
        #expect(
            SceneGesture.pinchScroll(centroidDelta: CGVector(dx: 10, dy: 0), magnification: 2).dx
                == -5
        )
    }

    @Test("A pinch only moves the map itself when the system is not already doing it")
    func pinchDefersToConcurrentScrolling() {
        #expect(SceneGesture.pinchPansItself(secondsSinceScroll: nil))
        #expect(!SceneGesture.pinchPansItself(secondsSinceScroll: 0))
        #expect(!SceneGesture.pinchPansItself(secondsSinceScroll: 0.02))
        #expect(SceneGesture.pinchPansItself(secondsSinceScroll: 0.5))
    }

    @Test("The rung is found when the fingers lift, around what they were over")
    func settleKeepsTheAnchor() {
        let pinched = Self.geometry
            .viewport(documentVisible: Self.documentVisible(magnification: 1), magnification: 1)
            .zoomed(to: 1.7, around: Self.geometry.scene(fromDocument: CGPoint(x: 900, y: 700)),
                    snapping: false)
        #expect(!SceneViewport.zoomLadder.contains(pinched.zoom))

        let anchor = CGPoint(x: 900, y: 700)
        let settled = pinched.settled(around: Self.geometry.scene(fromDocument: anchor))
        #expect(SceneViewport.zoomLadder.contains(settled.zoom))
        #expect(abs(Self.offset(of: anchor, in: pinched).x - Self.offset(of: anchor, in: settled).x)
            < 0.001)
    }

    // MARK: - Flights

    @Test("A flight leaves where the camera was and lands where it was sent")
    func flightIsAnArc() {
        let from = Self.geometry.viewport(
            documentVisible: Self.documentVisible(magnification: 1), magnification: 1
        )
        let to = from.zoomed(to: 4).centered(on: CGPoint(x: 300, y: -400))
        let flight = SceneFlight(from: from, to: to, duration: SceneFlight.travelDuration)

        #expect(flight.viewport(after: 0) == from)
        #expect(flight.viewport(after: flight.duration) == to)
        #expect(flight.hasLanded(after: flight.duration))
        #expect(!flight.hasLanded(after: flight.duration / 2))

        // Ease-out: more than half the journey is done at the halfway point.
        let middle = flight.viewport(after: flight.duration / 2)
        let travelled = (middle.center.x - from.center.x) / (to.center.x - from.center.x)
        #expect(travelled > 0.5)
        #expect(travelled < 1)
        // Zoom moves in ratios, so halfway between 1× and 4× is nearer 2× than
        // 2.5× — before the easing pulls it further along.
        #expect(middle.zoom > 1)
        #expect(middle.zoom < to.zoom)
    }

    @Test("A flight of no duration has already landed, for Reduce Motion")
    func flightCanBeInstant() {
        let from = Self.geometry.viewport(
            documentVisible: Self.documentVisible(magnification: 1), magnification: 1
        )
        let flight = SceneFlight(from: from, to: from.zoomed(to: 2), duration: 0)
        #expect(flight.hasLanded(after: 0))
        #expect(flight.viewport(after: 0).zoom == 2)
    }

    @Test("Zoom is interpolated in ratios, so every step is the same pull")
    func zoomInterpolatesGeometrically() {
        #expect(abs(SceneFlight.interpolate(zoom: 1, to: 4, progress: 0.5) - 2) < 0.001)
        #expect(abs(SceneFlight.interpolate(zoom: 0.25, to: 4, progress: 0.5) - 1) < 0.001)
        #expect(SceneFlight.interpolate(zoom: 1, to: 4, progress: 0) == 1)
        #expect(abs(SceneFlight.interpolate(zoom: 1, to: 4, progress: 1) - 4) < 0.001)
    }

    // MARK: - The pointer

    private static func session(
        _ id: String,
        project: String
    ) -> SessionSnapshot {
        let key = SessionKey(harness: .claudeCode, sessionID: id)
        return SessionSnapshot(
            identity: SessionIdentity(
                key: key,
                sourcePath: "/Users/example/.claude/projects/demo/\(id).jsonl",
                parent: nil,
                cwd: project,
                gitRoot: project
            ),
            state: .thinking,
            isAlive: true
        )
    }

    private static func office(projects: Int, perProject: Int) -> SceneFrame {
        var layout = SceneLayout()
        var sessions: [SessionSnapshot] = []
        for project in 0..<projects {
            for index in 0..<perProject {
                sessions.append(
                    session("p\(project)-s\(index)", project: "/Users/example/Code/project-\(project)")
                )
            }
        }
        return layout.update(
            with: BoardSnapshot(
                generatedAt: Date(timeIntervalSince1970: 1_767_225_600), sessions: sessions
            )
        )
    }

    private static let deskSize = CGSize(width: 104, height: 78)
    private static let deskBaseline: CGFloat = 8

    private static func index(_ frame: SceneFrame) -> SceneHitIndex {
        SceneHitIndex(frame: frame, deskSize: deskSize, deskBaseline: deskBaseline)
    }

    @Test("Every occupied desk answers for the point it is drawn at")
    func everyDeskIsFindable() throws {
        let frame = Self.office(projects: 12, perProject: 3)
        let index = Self.index(frame)
        #expect(index.deskCount == frame.slots.filter { $0.session != nil }.count)

        for slot in frame.slots where slot.session != nil {
            // The middle of the workstation: half a desk above the floor line
            // it stands on.
            let point = CGPoint(x: slot.anchor.x, y: slot.anchor.y - 30 * slot.scale)
            let hit = try #require(index.desk(at: point), "no desk at \(slot.id)")
            #expect(hit.slotID == slot.id)
            #expect(hit.session == slot.session)
        }
    }

    @Test("A point on the floor between the rooms is on no desk")
    func emptyFloorHitsNothing() {
        let index = Self.index(Self.office(projects: 6, perProject: 2))
        #expect(index.desk(at: CGPoint(x: -4_000, y: -4_000)) == nil)
        #expect(index.floor(at: CGPoint(x: -4_000, y: -4_000)) == nil)
    }

    @Test("The index and the floor plan name the same room")
    func indexAgreesWithTheFrame() throws {
        let frame = Self.office(projects: 9, perProject: 2)
        let index = Self.index(frame)
        for floor in frame.floors {
            let point = CGPoint(x: floor.frame.midX, y: floor.frame.midY)
            #expect(index.floor(at: point)?.id == frame.floor(at: point)?.id)
        }
        let room = try #require(frame.floors.last)
        #expect(index.floor(at: CGPoint(x: room.frame.midX, y: room.frame.midY))?.id == room.id)
    }

    @Test("A desk's click target is the furniture, not the whole room")
    func deskRectIsTheFurniture() {
        let rect = SceneHitIndex.deskRect(
            anchor: CGPoint(x: 100, y: 200),
            scale: 1,
            size: Self.deskSize,
            baseline: Self.deskBaseline
        )
        // The anchor is the point on the floor line at the middle of the desk:
        // the target reaches a little below it and most of the way above.
        #expect(rect.midX == 100)
        #expect(rect.maxY == 208)
        #expect(rect.minY == 130)
        #expect(rect.width == Self.deskSize.width)

        // A delegated session's smaller workstation gets a smaller target.
        let small = SceneHitIndex.deskRect(
            anchor: CGPoint(x: 100, y: 200), scale: 0.66,
            size: Self.deskSize, baseline: Self.deskBaseline
        )
        #expect(small.width < rect.width)
        #expect(small.height < rect.height)
    }

    @Test("An empty office has nothing under the pointer and does not mind")
    func emptyIndex() {
        #expect(SceneHitIndex.empty.desk(at: .zero) == nil)
        #expect(SceneHitIndex.empty.floor(at: .zero) == nil)
        #expect(SceneHitIndex.empty.deskCount == 0)
    }
}
