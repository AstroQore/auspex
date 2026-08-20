import AuspexCore
import CoreGraphics
import SpriteKit

/// The window onto the office: where it is pointed and how far back it is.
///
/// ## What is here and what is elsewhere
///
/// All of the arithmetic — clamping, fitting, framing a room, zooming around
/// the pointer, the ladder of crisp zoom levels — is ``SceneViewport``, a value
/// with tests. All of the *navigation* — panning, momentum, elastic edges, a
/// pinch that moves the map while it scales it — is the scroll view in
/// ``SceneCanvasView``, because those are behaviours the platform has and a
/// hand-rolled camera only approximates.
///
/// What is left for this class is the one thing neither of them can do: copy an
/// answer onto an `SKCameraNode`. It is a mirror, written once per drawn frame
/// from wherever the scroll view has got to, and it is also the whole camera
/// when there is no scroll view at all — which is how the offscreen renderer
/// frames a building with no window in sight.
///
/// ## Scale is backwards, once, here
///
/// An `SKCameraNode`'s `xScale` is how much of the world one point of the view
/// covers, so *larger* means *further away*. ``SceneViewport`` speaks in zoom
/// the way a person means it — greater than one is closer — and the inversion
/// happens at the two lines in this file that touch the node's scale.
@MainActor
final class SceneCamera {
    /// The node to install as the scene's camera.
    let node = SKCameraNode()

    /// Where the camera is, and the value every gesture is computed against.
    private(set) var viewport = SceneViewport()

    /// The building, in scene coordinates.
    var contentRect: CGRect { viewport.content }
    /// How big the view is, in points.
    var viewSize: CGSize { viewport.size }
    /// The current zoom, the way a person means it.
    var zoom: CGFloat { viewport.zoom }

    // MARK: - Being told where the reader is

    /// Copies a viewport onto the node.
    ///
    /// The one place the node is written. Instantaneous on purpose: when a
    /// scroll view is carrying the office this is called immediately before
    /// every drawn frame, so any smoothing here would be a second animation
    /// fighting the first, and the picture would slide out from under the
    /// scrollers.
    func mirror(_ next: SceneViewport) {
        guard next != viewport else { return }
        viewport = next
        node.position = next.center
        node.setScale(next.zoom > 0 ? 1 / next.zoom : 1)
    }

    /// Tells the camera how big its viewport is.
    ///
    /// The zoom is deliberately not touched: during a live resize the content
    /// must re-lay out rather than scale, which is the difference between a
    /// window that feels native and one that looks like a stretched screenshot
    /// until the drag ends.
    func setViewSize(_ size: CGSize) {
        guard size.width > 0, size.height > 0, size != viewport.size else { return }
        mirror(viewport.withSize(size))
    }

    /// Tells the camera how big the world is.
    func setContentRect(_ rect: CGRect) {
        guard rect != viewport.content else { return }
        mirror(viewport.withContent(rect))
    }

    /// Points the node at exactly `scale` and `centre`, for the offscreen
    /// renderer, which frames the building itself rather than asking for a fit.
    func park(at centre: CGPoint, scale: CGFloat) {
        node.removeAllActions()
        node.position = centre
        node.setScale(scale)
    }
}
