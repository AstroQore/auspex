import AppKit
import AuspexCore
import CoreGraphics
import Foundation
import SpriteKit
import Testing

@testable import AuspexApp

/// The trackpad, as far as a test can hold one.
///
/// Nobody can pinch a headless machine, but the *plumbing* between an
/// `NSEvent` and the camera is exactly where a sign error hides, so these
/// synthesise real scroll events with `CGEvent`, hand them to the view the way
/// the window would, and check the camera moved the way a hand would expect.
/// What is left for a person to confirm on hardware is the *feel* — momentum
/// decay, pinch centroid, the two-finger double tap — and that list is in the
/// branch's report.
@MainActor
@Suite("Scene trackpad")
struct SceneGestureEventTests {
    /// A scene of the demo office, presented in a view of a known size, with
    /// the camera close enough that there is somewhere to pan to.
    private static func office(zoom: CGFloat = 2) -> (OfficeScene, OfficeSKView) {
        // Any AppKit at all needs the shared application; the policy keeps it
        // out of the Dock while the test runs.
        NSApplication.shared.setActivationPolicy(.prohibited)
        let appearance = NSAppearance(named: .darkAqua) ?? NSAppearance()
        let theme = SceneTheme.resolved(for: appearance)
        let scene = OfficeScene(theme: theme)
        let view = OfficeSKView(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        view.presentScene(scene)
        scene.update(
            board: SceneSnapshotRenderer.demoBoard(elapsed: 16),
            selected: nil,
            focusedProject: nil,
            // No animation, so the camera is where it is told immediately.
            reduceMotion: true,
            theme: theme
        )
        scene.setZoom(zoom)
        return (scene, view)
    }

    /// A two-finger scroll, as the window would deliver it.
    private static func scroll(
        x: Int32,
        y: Int32,
        precise: Bool = true,
        command: Bool = false
    ) -> NSEvent? {
        guard let event = CGEvent(
            scrollWheelEvent2Source: nil,
            units: precise ? .pixel : .line,
            wheelCount: 2,
            wheel1: y,
            wheel2: x,
            wheel3: 0
        ) else { return nil }
        if command { event.flags = .maskCommand }
        return NSEvent(cgEvent: event)
    }

    @Test("A two-finger scroll pans the camera, and the other way pans it back")
    func scrollPans() throws {
        let (scene, view) = Self.office()
        let start = scene.viewport.center
        let forward = try #require(Self.scroll(x: 0, y: -60))
        view.scrollWheel(with: forward)
        let after = scene.viewport.center

        #expect(after != start)
        // The sign is the one `SceneGesture` decided on, applied to the
        // event's own deltas — not a second opinion held by the view.
        let expected = SceneGesture.panDelta(
            x: forward.scrollingDeltaX,
            y: forward.scrollingDeltaY,
            isDirectionInverted: forward.isDirectionInvertedFromDevice
        )
        #expect((after.y - start.y).sign == expected.dy.sign)

        let back = try #require(Self.scroll(x: 0, y: 60))
        view.scrollWheel(with: back)
        #expect(abs(scene.viewport.center.y - start.y) < 0.001)
    }

    @Test("A horizontal scroll moves the camera horizontally and nothing else")
    func horizontalScroll() throws {
        let (scene, view) = Self.office()
        let start = scene.viewport.center
        view.scrollWheel(with: try #require(Self.scroll(x: 40, y: 0)))
        #expect(scene.viewport.center.x != start.x)
        #expect(scene.viewport.center.y == start.y)
    }

    @Test("A mouse's ⌘-scroll steps the zoom by whole rungs")
    func commandScrollSteps() throws {
        let (scene, view) = Self.office(zoom: 1)
        let before = scene.viewport.zoom
        view.scrollWheel(with: try #require(Self.scroll(x: 0, y: 1, precise: false, command: true)))
        let after = scene.viewport.zoom

        #expect(after > before)
        #expect(SceneViewport.zoomLadder.contains(after))
        view.scrollWheel(
            with: try #require(Self.scroll(x: 0, y: -1, precise: false, command: true))
        )
        #expect(scene.viewport.zoom == before)
    }

    @Test("A trackpad's ⌘-scroll zooms continuously rather than in steps")
    func commandScrollIsContinuousOnATrackpad() throws {
        let (scene, view) = Self.office(zoom: 1)
        let before = scene.viewport.zoom
        view.scrollWheel(with: try #require(Self.scroll(x: 0, y: 20, precise: true, command: true)))
        let after = scene.viewport.zoom

        #expect(after > before)
        // A fifth of the distance to a doubling is a fifth of the way there,
        // not a whole rung.
        #expect(after < SceneViewport.rung(1, from: before))
    }

    @Test("A pinch zooms around the fingers and lands on a rung when they lift")
    func pinchSettlesOnARung() {
        let (scene, _) = Self.office(zoom: 1)
        let point = CGPoint(x: 320, y: 90)
        for _ in 0..<6 { scene.magnify(by: 0.12, atViewPoint: point) }
        let pinched = scene.viewport.zoom
        #expect(pinched > 1)

        scene.settle(atViewPoint: point)
        #expect(SceneViewport.zoomLadder.contains(scene.viewport.zoom))
    }

    @Test("Resizing the window shows more office at the same zoom")
    func resizeKeepsTheZoom() {
        let (scene, view) = Self.office(zoom: 2)
        let before = scene.viewport
        view.setFrameSize(NSSize(width: 700, height: 300))

        #expect(scene.viewport.zoom == before.zoom)
        #expect(scene.viewport.visibleRect.width > before.visibleRect.width)
    }

    @Test("The scene stops when nothing is looking at it")
    func suspendStopsTheClock() {
        let (scene, view) = Self.office()
        view.suspend()
        #expect(view.isPaused)
        #expect(scene.isPaused)
        #expect(view.preferredFramesPerSecond == 1)
    }
}
