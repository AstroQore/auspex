import AuspexCore
import CoreGraphics
import SpriteKit

/// The window onto the office: where it is pointed and how far back it is.
///
/// ## What is here and what is in Core
///
/// All of the arithmetic — clamping, fitting, framing a room, zooming around
/// the pointer, the ladder of crisp zoom levels — is ``SceneViewport``, a
/// value with tests. This class is the part that cannot be a value: it owns
/// the `SKCameraNode`, and it knows how to move it either instantly or over a
/// third of a second.
///
/// ## Scale is backwards, once, here
///
/// An `SKCameraNode`'s `xScale` is how much of the world one point of the view
/// covers, so *larger* means *further away*. ``SceneViewport`` speaks in zoom
/// the way a person means it — greater than one is closer — and the inversion
/// happens at the two lines in this file that touch the node's scale.
///
/// ## Target and live
///
/// While the camera is flying to a room there are two answers to "where is
/// it": the place it is going, which every gesture and clamp is computed
/// against, and the place it is right now, which is what decides whether a
/// desk is on screen and where the minimap draws its box. ``viewport`` is the
/// first and ``live`` is the second.
@MainActor
final class SceneCamera {
    /// The node to install as the scene's camera.
    let node = SKCameraNode()

    /// Where the camera is going, and the value every gesture is applied to.
    private(set) var viewport = SceneViewport()

    /// Whether the system asked for less motion. When it did, the camera
    /// arrives rather than travels — a map that slides under the reader is
    /// exactly the kind of movement Reduce Motion is asking about.
    var reduceMotion = false

    /// `true` once the camera has framed a non-empty building, so a first
    /// frame arriving after the view has been sized still gets fitted.
    private(set) var hasFitted = false

    /// How long a flight across the map takes.
    private static let flightDuration: TimeInterval = 0.32
    /// How long the map takes to spring back after a gesture lets go of it.
    private static let settleDuration: TimeInterval = 0.2

    /// The building, in scene coordinates.
    var contentRect: CGRect { viewport.content }
    /// How big the view is, in points.
    var viewSize: CGSize { viewport.size }
    /// The current zoom, the way a person means it.
    var zoom: CGFloat { viewport.zoom }

    /// Where the camera is at this instant, mid-flight included.
    var live: SceneViewport {
        var current = viewport
        current.center = node.position
        current.zoom = node.xScale > 0 ? 1 / node.xScale : viewport.zoom
        return current
    }

    // MARK: - Being told about the world

    /// Whether the camera is still showing exactly what "fit" showed, with
    /// nobody having panned or zoomed since.
    ///
    /// It is what makes a window resize feel native: a map that was framed
    /// stays framed as the window grows, and a map somebody had zoomed into
    /// keeps the zoom they chose and simply shows more of the world. The
    /// alternative — always re-fitting — throws away a reader's place every
    /// time they drag a window edge.
    private(set) var isFramingEverything = false

    /// Tells the camera how big its viewport is.
    ///
    /// The zoom is deliberately not touched: during a live resize the content
    /// must re-lay out rather than scale, which is the difference between a
    /// window that feels native and one that looks like a stretched
    /// screenshot until the drag ends.
    func setViewSize(_ size: CGSize) {
        guard size.width > 0, size.height > 0, size != viewport.size else { return }
        reframe(viewport.withSize(size))
    }

    /// Tells the camera how big the world is.
    func setContentRect(_ rect: CGRect) {
        guard rect != viewport.content else { return }
        reframe(viewport.withContent(rect))
    }

    /// Applies a viewport the *world* changed rather than the reader: the
    /// window was resized, or a room opened. A camera that was framing
    /// everything goes on framing everything; one somebody had put somewhere
    /// stays where they put it.
    private func reframe(_ next: SceneViewport) {
        let framing = isFramingEverything
        apply(framing ? next.fitted() : next, animated: false)
        isFramingEverything = framing
    }

    // MARK: - Moving

    /// Frames the whole building.
    func fit(animated: Bool = false) {
        guard viewport.content.width > 0, viewport.size.width > 0 else { return }
        hasFitted = true
        apply(viewport.fitted(), animated: animated)
        isFramingEverything = true
    }

    /// Frames one room, with air around it.
    func focus(on rect: CGRect, animated: Bool = true) {
        guard rect.width > 0, viewport.size.width > 0 else { return }
        hasFitted = true
        apply(viewport.focused(on: rect), animated: animated)
    }

    /// Centres on one point without changing how close the camera is.
    func center(on point: CGPoint, animated: Bool = true) {
        apply(viewport.centered(on: point), animated: animated)
    }

    /// Moves `steps` rungs up or down the zoom ladder.
    func step(_ steps: Int, around anchor: CGPoint? = nil) {
        apply(viewport.stepped(steps, around: anchor), animated: false)
    }

    /// Goes to one of the named zooms, keeping the middle of the view fixed.
    func setZoom(_ zoom: CGFloat, around anchor: CGPoint? = nil, animated: Bool = false) {
        apply(viewport.zoomed(to: zoom, around: anchor), animated: animated)
    }

    /// Moves the camera by a delta in view points, already in the scene's
    /// axes — see ``SceneGesture/panDelta(x:y:isDirectionInverted:)``.
    func pan(by delta: CGVector, rubberBanding: Bool = false) {
        apply(viewport.panned(by: delta, rubberBanding: rubberBanding), animated: false)
    }

    /// Zooms without landing on a rung, for the length of a pinch.
    func zoom(continuouslyTo target: CGFloat, around anchor: CGPoint?) {
        apply(viewport.zoomed(to: target, around: anchor, snapping: false), animated: false)
    }

    /// What happens when the fingers lift: the zoom lands on a rung and
    /// anything pulled past the edge springs back.
    func settle(around anchor: CGPoint? = nil) {
        let settled = viewport.settled(around: anchor)
        guard settled != viewport else { return }
        // Animated, because this is the camera moving on its own: an
        // instantaneous snap after a gesture reads as the map jumping away
        // from the fingers that just let go. Quicker than a flight across the
        // map, because it is a settle rather than a journey.
        apply(settled, animated: true, duration: Self.settleDuration)
    }

    /// The point in scene coordinates a view-space offset from the middle of
    /// the view is over.
    func scenePoint(forViewOffset offset: CGPoint) -> CGPoint {
        live.scenePoint(forViewOffset: offset)
    }

    /// Points the node at exactly `scale` and `centre`, for the offscreen
    /// renderer, which frames the building itself rather than asking for a
    /// fit.
    func park(at centre: CGPoint, scale: CGFloat) {
        node.removeAllActions()
        node.position = centre
        node.setScale(scale)
    }

    // MARK: - The one place the node is written

    private func apply(
        _ next: SceneViewport,
        animated: Bool,
        duration: TimeInterval = SceneCamera.flightDuration
    ) {
        // Anything that moves the camera is somebody choosing where to look;
        // only `fit` puts it back to framing the lot. Set before the early
        // exits below so a no-op still counts as a choice.
        isFramingEverything = false
        viewport = next
        node.removeAllActions()
        let scale = next.zoom > 0 ? 1 / next.zoom : 1
        guard animated, !reduceMotion else {
            node.setScale(scale)
            node.position = next.center
            return
        }
        let move = SKAction.move(to: next.center, duration: duration)
        move.timingMode = .easeOut
        let zoom = SKAction.scale(to: scale, duration: duration)
        zoom.timingMode = .easeOut
        node.run(.group([move, zoom]))
    }
}
