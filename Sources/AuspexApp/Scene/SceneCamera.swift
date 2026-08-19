import CoreGraphics
import SpriteKit

/// The window onto the office: where it is pointed and how far back it is.
///
/// ## Scale is backwards, once, here
///
/// An `SKCameraNode`'s `xScale` is how much of the world one point of the view
/// covers, so *larger* means *further away*. Every call site would otherwise
/// have to remember that; this type takes zoom factors the way a person means
/// them — greater than one is closer — and inverts once, in ``zoom(by:around:)``.
///
/// ## Why panning is clamped
///
/// A camera with no bounds can be scrolled into empty space, and an office that
/// has vanished off the edge of an otherwise identical dark rectangle is
/// indistinguishable from a view that failed. So the camera is kept inside the
/// building plus a margin, and when the whole building already fits it is
/// simply centred and cannot be dragged at all.
@MainActor
final class SceneCamera {
    /// The node to install as the scene's camera.
    let node = SKCameraNode()

    /// The building, in scene coordinates.
    private(set) var contentRect: CGRect = .zero
    /// How big the view is, in points.
    private(set) var viewSize: CGSize = .zero

    /// Closest and furthest the camera will go. The near end is set by how
    /// large a 16-pixel character can usefully be drawn; the far end by the
    /// point at which a desk stops being distinguishable from a smudge.
    static let minZoom: CGFloat = 0.28
    static let maxZoom: CGFloat = 2.6

    /// How much air to leave around the building when framing it.
    private static let fitPadding: CGFloat = 1.08

    /// `true` once the camera has framed a non-empty building, so a first frame
    /// arriving after the view has been sized still gets fitted.
    private(set) var hasFitted = false

    /// The current zoom, the way a person means it.
    var zoom: CGFloat {
        node.xScale > 0 ? 1 / node.xScale : 1
    }

    /// Tells the camera how big its viewport is.
    func setViewSize(_ size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        let changed = viewSize != size
        viewSize = size
        if changed { clamp() }
    }

    /// Tells the camera how big the world is.
    func setContentRect(_ rect: CGRect) {
        contentRect = rect
        clamp()
    }

    /// Frames the whole building.
    func fit(animated: Bool = false) {
        guard contentRect.width > 0, contentRect.height > 0,
              viewSize.width > 0, viewSize.height > 0
        else { return }
        let needed = max(
            contentRect.width / viewSize.width,
            contentRect.height / viewSize.height
        ) * Self.fitPadding
        let scale = min(1 / Self.minZoom, max(1 / Self.maxZoom, needed))
        let centre = CGPoint(x: contentRect.midX, y: contentRect.midY)
        hasFitted = true
        if animated {
            node.run(
                .group([
                    .scale(to: scale, duration: 0.28),
                    .move(to: centre, duration: 0.28)
                ])
            )
        } else {
            node.removeAllActions()
            node.setScale(scale)
            node.position = centre
        }
    }

    /// Zooms by `factor` — greater than one moves closer — keeping the world
    /// point under `anchor` (in scene coordinates) under it afterwards.
    func zoom(by factor: CGFloat, around anchor: CGPoint? = nil) {
        guard factor > 0 else { return }
        let current = zoom
        let target = min(Self.maxZoom, max(Self.minZoom, current * factor))
        guard target != current else { return }
        node.removeAllActions()

        if let anchor {
            // Keep the anchor fixed: the camera moves toward it by exactly the
            // fraction of the distance the zoom just removed.
            let ratio = current / target
            node.position = CGPoint(
                x: anchor.x + (node.position.x - anchor.x) * ratio,
                y: anchor.y + (node.position.y - anchor.y) * ratio
            )
        }
        node.setScale(1 / target)
        clamp()
    }

    /// Moves the camera by a view-space delta.
    func pan(by delta: CGVector) {
        node.removeAllActions()
        let scale = node.xScale
        node.position = CGPoint(
            x: node.position.x - delta.dx * scale,
            y: node.position.y + delta.dy * scale
        )
        clamp()
    }

    /// Centres on one point, for a double-click on a desk.
    func center(on point: CGPoint, animated: Bool = true) {
        node.removeAllActions()
        let clamped = clampedPosition(point)
        if animated {
            let move = SKAction.move(to: clamped, duration: 0.3)
            move.timingMode = .easeInEaseOut
            node.run(move)
        } else {
            node.position = clamped
        }
    }

    /// The point in scene coordinates a view-space point is over.
    func scenePoint(forViewOffset offset: CGPoint) -> CGPoint {
        CGPoint(
            x: node.position.x + offset.x * node.xScale,
            y: node.position.y + offset.y * node.yScale
        )
    }

    private func clamp() {
        node.position = clampedPosition(node.position)
    }

    private func clampedPosition(_ point: CGPoint) -> CGPoint {
        guard contentRect.width > 0, viewSize.width > 0 else { return point }
        let halfWidth = viewSize.width * node.xScale / 2
        let halfHeight = viewSize.height * node.yScale / 2

        func axis(
            _ value: CGFloat, min lower: CGFloat, max upper: CGFloat, half: CGFloat
        ) -> CGFloat {
            // When the world is narrower than the viewport there is exactly one
            // sensible position, and letting a drag move away from it produces
            // a view of nothing.
            if upper - lower <= half * 2 { return (lower + upper) / 2 }
            return min(max(value, lower + half), upper - half)
        }

        return CGPoint(
            x: axis(point.x, min: contentRect.minX, max: contentRect.maxX, half: halfWidth),
            y: axis(point.y, min: contentRect.minY, max: contentRect.maxY, half: halfHeight)
        )
    }
}
