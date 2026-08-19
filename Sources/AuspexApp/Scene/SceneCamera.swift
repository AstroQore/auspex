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

    /// Tells the camera how big its viewport is.
    func setViewSize(_ size: CGSize) {
        guard size.width > 0, size.height > 0, size != viewport.size else { return }
        apply(viewport.withSize(size), animated: false)
    }

    /// Tells the camera how big the world is.
    func setContentRect(_ rect: CGRect) {
        guard rect != viewport.content else { return }
        apply(viewport.withContent(rect), animated: false)
    }

    // MARK: - Moving

    /// Frames the whole building.
    func fit(animated: Bool = false) {
        guard viewport.content.width > 0, viewport.size.width > 0 else { return }
        hasFitted = true
        apply(viewport.fitted(), animated: animated)
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

    /// Moves the camera by a view-space delta.
    func pan(by delta: CGVector) {
        // The view's y runs the other way from the scene's, and a scroll's
        // delta is where the *content* should go, not the camera.
        apply(viewport.panned(by: CGVector(dx: -delta.dx, dy: delta.dy)), animated: false)
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

    private func apply(_ next: SceneViewport, animated: Bool) {
        viewport = next
        node.removeAllActions()
        let scale = next.zoom > 0 ? 1 / next.zoom : 1
        guard animated, !reduceMotion else {
            node.setScale(scale)
            node.position = next.center
            return
        }
        let move = SKAction.move(to: next.center, duration: Self.flightDuration)
        move.timingMode = .easeInEaseOut
        let zoom = SKAction.scale(to: scale, duration: Self.flightDuration)
        zoom.timingMode = .easeInEaseOut
        node.run(.group([move, zoom]))
    }
}
