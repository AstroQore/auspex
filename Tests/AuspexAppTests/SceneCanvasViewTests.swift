import AgentSessionLive
import AppKit
import AuspexCore
import CoreGraphics
import Foundation
import QuartzCore
import SpriteKit
import Testing

@testable import AuspexApp

/// The canvas, as far as a test can hold one.
///
/// Nobody can pinch a headless machine, and `NSScrollView` will not act on a
/// synthesised scroll event without a real gesture behind it. So what is
/// asserted here is everything on either side of the platform: that the office
/// is *configured* to let the scroll view do its job, that the conversions
/// between a window point, the floor plan and the camera agree, that the camera
/// follows the clip view frame by frame, and that the parts we kept — a
/// ⌘-scroll zoom, the landing on a crisp rung, one hit test per drawn frame —
/// do what they say.
///
/// What is left for a person to confirm on hardware is the *feel*: momentum
/// decay, the elastic edge, and two fingers that pinch and travel at once. That
/// list is in the branch's report.
@MainActor
@Suite("Scene canvas view")
struct SceneCanvasViewTests {
    /// A canvas showing the demo office, laid out at a known size.
    private static func canvas(
        elapsed: TimeInterval = 16,
        size: CGSize = CGSize(width: 800, height: 600)
    ) -> (SceneCanvasView, OfficeScene) {
        // Any AppKit at all needs the shared application; the policy keeps it
        // out of the Dock while the test runs.
        NSApplication.shared.setActivationPolicy(.prohibited)
        let appearance = NSAppearance(named: .darkAqua) ?? NSAppearance()
        let theme = SceneTheme.resolved(for: appearance)
        let scene = OfficeScene(theme: theme)
        let view = SceneCanvasView(scene: scene, frame: CGRect(origin: .zero, size: size))
        view.layoutSubtreeIfNeeded()
        scene.update(
            board: SceneSnapshotRenderer.demoBoard(elapsed: elapsed),
            selected: nil,
            focusedProject: nil,
            // No animation, so the camera is where it is told immediately.
            reduceMotion: true,
            theme: theme
        )
        view.layoutSubtreeIfNeeded()
        scene.update(CACurrentMediaTime())
        return (view, scene)
    }

    /// The same office the scene laid out, so a test can point at a desk.
    private static func floorPlan(elapsed: TimeInterval = 16) -> SceneFrame {
        var layout = SceneLayout()
        return layout.update(with: SceneSnapshotRenderer.demoBoard(elapsed: elapsed))
    }

    // MARK: - What the platform is allowed to do

    @Test("The office hangs on a scroll view that pans and magnifies itself")
    func scrollViewIsConfigured() {
        let (view, _) = Self.canvas()
        let scroll = view.scrollView

        #expect(scroll.allowsMagnification)
        #expect(scroll.minMagnification == SceneViewport.minZoom)
        #expect(scroll.maxMagnification == SceneViewport.maxZoom)
        // A canvas moves in two dimensions at once; the predominant-axis rule
        // is for documents read down a column.
        #expect(!scroll.usesPredominantAxisScrolling)
        // The elastic edge is the platform's, and it has to be switched on for
        // both axes or a map has a hard stop on one of them.
        #expect(scroll.horizontalScrollElasticity == .allowed)
        #expect(scroll.verticalScrollElasticity == .allowed)
        // Transparent: the office is drawn by the `SKView` underneath.
        #expect(!scroll.drawsBackground)
    }

    @Test("The document is the building, flipped, and draws nothing")
    func documentIsTheBuilding() throws {
        let (view, scene) = Self.canvas()
        let document = try #require(view.scrollView.documentView)
        let world = SceneGeometry.layout(from: scene.contentBounds)

        #expect(abs(document.frame.width - world.width) < 0.001)
        #expect(abs(document.frame.height - world.height) < 0.001)
        // Flipped, so its coordinates are the floor plan's: y down.
        #expect(document.isFlipped)
        // Never a backing store: at 4× this view is four times the size of a
        // building that is already larger than any window.
        #expect(document.wantsUpdateLayer)
    }

    @Test("The SpriteKit view is the size of the window, not of the building")
    func skViewIsWindowSized() {
        // A window smaller than the office, which is the interesting case: a
        // document view would have to be the size of the *building* times the
        // zoom, and this one is the size of the window whatever the zoom.
        let (view, scene) = Self.canvas(size: CGSize(width: 400, height: 300))
        let world = SceneGeometry.layout(from: scene.contentBounds)
        #expect(world.width > view.bounds.width)
        #expect(view.skView.bounds.size == view.bounds.size)
        #expect(view.scrollView.documentView?.frame.width ?? 0 > view.bounds.width)
    }

    // MARK: - The clip view and the camera

    @Test("A fit stays fitted until somebody takes over")
    func fitIsAState() {
        let (view, scene) = Self.canvas()
        scene.fitAll()
        scene.update(CACurrentMediaTime())
        let fitted = scene.viewport

        // Something nudges the clip view without a hand behind it — a room
        // opening, a window being dragged. The building stays framed.
        view.scrollView.contentView.setBoundsOrigin(NSPoint(x: 90, y: 60))
        scene.update(CACurrentMediaTime())
        #expect(scene.viewport.zoom == fitted.zoom)
        #expect(scene.viewport.showsAll(of: scene.contentBounds))
    }

    @Test("Moving the clip view moves the camera with it")
    func cameraFollowsTheClipView() {
        let (view, scene) = Self.canvas()
        // What every gesture does on its way in: the reader is driving now.
        view.cancelFlight()
        let before = scene.viewport.center

        view.scrollView.magnification = 1
        view.scrollView.contentView.setBoundsOrigin(NSPoint(x: 200, y: 140))
        view.scrollView.reflectScrolledClipView(view.scrollView.contentView)
        // The camera is copied immediately before the frame that shows it.
        scene.update(CACurrentMediaTime())

        #expect(scene.viewport.center != before)
        #expect(scene.viewport.zoom == 1)
        let visible = view.scrollView.documentVisibleRect
        let middle = CGPoint(x: visible.midX, y: visible.midY)
        let expected = SceneScrollGeometry(
            world: SceneGeometry.layout(from: scene.contentBounds)
        ).scene(fromDocument: middle)
        #expect(abs(scene.viewport.center.x - expected.x) < 0.001)
        #expect(abs(scene.viewport.center.y - expected.y) < 0.001)
    }

    @Test("A point in the window is a point on the floor plan")
    func windowPointsBecomeFloorPlanPoints() {
        let (view, scene) = Self.canvas()
        // The middle of the canvas is whatever the camera is pointed at.
        let middle = view.convert(
            CGPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil
        )
        let layout = view.layoutPoint(fromWindow: middle)
        let camera = SceneGeometry.layout(from: scene.viewport.center)
        #expect(abs(layout.x - camera.x) < 0.5)
        #expect(abs(layout.y - camera.y) < 0.5)
    }

    // MARK: - Zooming

    @Test("Fit frames the whole building")
    func fitFramesEverything() {
        let (_, scene) = Self.canvas()
        scene.fitAll()
        #expect(scene.viewport.showsAll(of: scene.contentBounds))
        #expect(SceneViewport.zoomLadder.contains(scene.viewport.zoom))
    }

    @Test("A window that grows keeps framing the building it was framing")
    func resizeKeepsTheFraming() {
        let (view, scene) = Self.canvas()
        scene.fitAll()
        view.setFrameSize(NSSize(width: 1_200, height: 600))
        view.layoutSubtreeIfNeeded()
        scene.update(CACurrentMediaTime())
        #expect(scene.viewport.showsAll(of: scene.contentBounds))
    }

    @Test("A window that grows after a zoom shows more office, not a bigger one")
    func resizeKeepsTheZoom() {
        let (view, scene) = Self.canvas()
        scene.setZoom(1)
        scene.update(CACurrentMediaTime())
        let before = scene.viewport

        view.setFrameSize(NSSize(width: 1_200, height: 600))
        view.layoutSubtreeIfNeeded()
        scene.update(CACurrentMediaTime())

        #expect(scene.viewport.zoom == before.zoom)
        #expect(scene.viewport.visibleRect.width > before.visibleRect.width)
    }

    @Test("A wheel's ⌘-scroll steps the zoom by whole rungs")
    func commandScrollSteps() throws {
        let (view, scene) = Self.canvas()
        scene.setZoom(1)
        scene.update(CACurrentMediaTime())
        let before = scene.viewport.zoom

        view.scrollView.scrollWheel(
            with: try #require(Self.scroll(y: 1, precise: false, command: true))
        )
        scene.update(CACurrentMediaTime())
        let after = scene.viewport.zoom
        #expect(after > before)
        #expect(SceneViewport.zoomLadder.contains(after))

        view.scrollView.scrollWheel(
            with: try #require(Self.scroll(y: -1, precise: false, command: true))
        )
        scene.update(CACurrentMediaTime())
        #expect(scene.viewport.zoom == before)
    }

    @Test("A trackpad's ⌘-scroll zooms continuously rather than in steps")
    func commandScrollIsContinuousOnATrackpad() throws {
        let (view, scene) = Self.canvas()
        scene.setZoom(1)
        scene.update(CACurrentMediaTime())
        let before = scene.viewport.zoom

        view.scrollView.scrollWheel(
            with: try #require(Self.scroll(y: 20, precise: true, command: true))
        )
        scene.update(CACurrentMediaTime())
        let after = scene.viewport.zoom

        #expect(after > before)
        // A fifth of the distance to a doubling is a fifth of the way there,
        // not a whole rung.
        #expect(after < SceneViewport.rung(1, from: before))
    }

    @Test("The zoom lands on a crisp rung when the fingers lift")
    func settleFindsTheLadder() {
        let (view, scene) = Self.canvas()
        // Where a pinch leaves it: somewhere between two rungs.
        view.zoom(to: 1.7, atWindowPoint: CGPoint(x: 400, y: 300))
        scene.update(CACurrentMediaTime())
        #expect(!SceneViewport.zoomLadder.contains(scene.viewport.zoom))

        view.settleZoom(atWindowPoint: CGPoint(x: 400, y: 300))
        // The settle is a short flight, so it lands over a few frames.
        let start = CACurrentMediaTime()
        scene.update(start)
        scene.update(start + SceneFlight.settleDuration + 0.01)
        #expect(SceneViewport.zoomLadder.contains(scene.viewport.zoom))
    }

    @Test("A pinch that travels carries the map with it")
    func pinchTravelMovesTheMap() {
        // Close enough that there is somewhere to travel to.
        let (view, scene) = Self.canvas()
        scene.setZoom(2)
        scene.update(CACurrentMediaTime())
        let before = scene.viewport.center

        // What `magnify(with:)` does with the distance the centroid moved
        // between two events, when the system is not scrolling for it.
        view.scrollDocument(
            by: SceneGesture.pinchScroll(
                centroidDelta: CGVector(dx: -40, dy: 0),
                magnification: view.scrollView.magnification
            )
        )
        scene.update(CACurrentMediaTime())

        // Fingers travelling left drag the map left, so the camera goes right.
        #expect(scene.viewport.center.x > before.x)
    }

    @Test("A gesture takes a flight over from wherever it had got to")
    func gesturesInterruptFlights() {
        let (view, scene) = Self.canvas()
        scene.fitAll()
        scene.update(CACurrentMediaTime())

        // A flight starts...
        view.apply(scene.viewport.zoomed(to: 2), animated: true, framingEverything: false)
        let start = CACurrentMediaTime()
        scene.update(start)
        let midway = scene.viewport
        // ...and a hand arrives while it is still in the air.
        view.zoom(to: 0.5, atWindowPoint: CGPoint(x: 400, y: 300))
        scene.update(start + SceneFlight.travelDuration)

        #expect(scene.viewport.zoom == 0.5)
        #expect(scene.viewport.zoom != midway.zoom)
    }

    // MARK: - The pointer

    @Test("Hovering is answered once per drawn frame, however often the pointer moves")
    func hoverIsCoalesced() throws {
        let (_, scene) = Self.canvas()
        let slot = try #require(Self.floorPlan().slots.first { $0.isOccupied })
        let onTheDesk = CGPoint(x: slot.anchor.x, y: slot.anchor.y - 30 * slot.scale)

        // Fifty mouse-moved events between two frames is an ordinary trackpad.
        for step in 0..<50 {
            scene.hover(atLayoutPoint: CGPoint(x: onTheDesk.x, y: onTheDesk.y - CGFloat(step) / 50))
        }
        // Nothing has happened yet: the pointer is recorded, not chased.
        #expect(scene.hoveredSlotID == nil)

        scene.update(CACurrentMediaTime())
        #expect(scene.hoveredSlotID == slot.id)

        // And leaving the view clears it, at the next frame.
        scene.hover(atLayoutPoint: nil)
        scene.update(CACurrentMediaTime())
        #expect(scene.hoveredSlotID == nil)
    }

    @Test("Clicking a desk selects the session sitting at it")
    func clickingADeskSelects() throws {
        let (_, scene) = Self.canvas()
        var selected: SessionKey??
        scene.onSelect = { selected = .some($0) }
        scene.onFocusProject = { _ in }

        let slot = try #require(Self.floorPlan().slots.first { $0.isOccupied })
        scene.click(
            atLayoutPoint: CGPoint(x: slot.anchor.x, y: slot.anchor.y - 30 * slot.scale),
            clickCount: 1
        )
        #expect(selected == .some(slot.session))

        // And clicking the floor between the rooms clears it.
        scene.click(atLayoutPoint: CGPoint(x: -4_000, y: -4_000), clickCount: 1)
        #expect(selected == .some(nil))
    }

    @Test("A smart zoom frames the room under the pointer and pulls back out again")
    func smartZoomTogglesARoom() throws {
        let (_, scene) = Self.canvas()
        scene.onFocusProject = { _ in }
        scene.fitAll()
        scene.update(CACurrentMediaTime())
        let fitted = scene.viewport.zoom

        let room = try #require(Self.floorPlan().floors.first)
        let inside = CGPoint(x: room.frame.midX, y: room.frame.midY)
        scene.smartZoom(atLayoutPoint: inside)
        scene.update(CACurrentMediaTime() + SceneFlight.travelDuration)
        #expect(scene.viewport.zoom > fitted)
        #expect(scene.viewport.showsAll(of: SceneGeometry.scene(from: room.frame)))

        // The second tap goes back out.
        scene.smartZoom(atLayoutPoint: inside)
        scene.update(CACurrentMediaTime() + SceneFlight.travelDuration)
        #expect(scene.viewport.showsAll(of: scene.contentBounds))
    }

    // MARK: - Costing nothing when nobody is looking

    @Test("The scene stops when nothing is looking at it")
    func suspendStopsTheClock() {
        let (view, scene) = Self.canvas()
        view.suspend()
        #expect(view.skView.isPaused)
        #expect(scene.isPaused)
        #expect(view.skView.preferredFramesPerSecond == 1)
    }

    @Test("A gesture buys the display's frame rate, and only for as long as it lasts")
    func gesturesRaiseTheFrameRate() {
        let (view, _) = Self.canvas()
        // Headless there is no window to be visible in, so the view has already
        // put itself to sleep; a running one is what the rate is about.
        view.skView.isPaused = false

        view.noteInteraction()
        #expect(view.skView.preferredFramesPerSecond == 60)

        // A moment after the last event, it is back to the resting rate.
        view.advance(to: CACurrentMediaTime() + 10)
        #expect(view.skView.preferredFramesPerSecond == 30)
    }

    // MARK: - Events

    /// A scroll wheel event, as the window would deliver it.
    private static func scroll(
        y: Int32,
        precise: Bool,
        command: Bool
    ) -> NSEvent? {
        guard let event = CGEvent(
            scrollWheelEvent2Source: nil,
            units: precise ? .pixel : .line,
            wheelCount: 2,
            wheel1: y,
            wheel2: 0,
            wheel3: 0
        ) else { return nil }
        if command { event.flags = .maskCommand }
        return NSEvent(cgEvent: event)
    }
}
