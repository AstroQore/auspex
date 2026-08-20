import CoreGraphics
import Foundation

/// The mapping between the office's floor plan and a scroll view's document.
///
/// ## Why a scroll view is the canvas
///
/// Panning, momentum, elastic edges, the scroll-direction preference, and — the
/// one that cannot be approximated — a pinch whose centroid moves the content
/// while it scales it, are all things `NSScrollView` already does correctly and
/// nothing hand-rolled does correctly for long. So the office is hung on one:
/// an empty, world-sized document view carries the scrollable extent, the
/// scroll view owns where the reader is and how close, and the `SKView`
/// underneath simply draws whatever rectangle the clip view is currently
/// showing.
///
/// What that costs is a translation, twice per frame, between three coordinate
/// spaces that all mean the same thing:
///
/// - **layout space** — ``SceneFrame``'s floor plan, y-down, origin wherever
///   the building happens to start;
/// - **document space** — the scroll view's document view, y-down (it is
///   flipped) with its origin at the top left of the *document*, so it is
///   layout space shifted by ``world``'s origin;
/// - **scene space** — SpriteKit's y-up world, which is what ``SceneViewport``
///   and the camera speak.
///
/// The shift and the flip are arithmetic, they are exactly the kind of
/// arithmetic that is wrong by one sign for a week, and they do not need a view
/// to be tested. So they live here.
///
/// ## Magnification is zoom
///
/// `NSScrollView.magnification` and ``SceneViewport/zoom`` mean the same thing —
/// points of screen per point of world, greater than one being closer — so no
/// inversion happens on this boundary. The one inversion in the scene is still
/// where it always was, on the `SKCameraNode`'s scale.
public struct SceneScrollGeometry: Sendable, Equatable {
    /// The building, in layout space. The document view is this size.
    public let world: CGRect

    public init(world: CGRect = .zero) {
        self.world = world
    }

    /// How big the document view has to be.
    public var documentSize: CGSize { world.size }

    /// The world in SpriteKit's axes, for ``SceneViewport/content``.
    public var contentRect: CGRect { SceneGeometry.scene(from: world) }

    /// `true` when there is nothing to scroll around yet.
    public var isEmpty: Bool { world.width <= 0 || world.height <= 0 }

    // MARK: - Layout and document

    public func document(fromLayout point: CGPoint) -> CGPoint {
        CGPoint(x: point.x - world.minX, y: point.y - world.minY)
    }

    public func layout(fromDocument point: CGPoint) -> CGPoint {
        CGPoint(x: point.x + world.minX, y: point.y + world.minY)
    }

    public func document(fromLayout rect: CGRect) -> CGRect {
        CGRect(origin: document(fromLayout: rect.origin), size: rect.size)
    }

    public func layout(fromDocument rect: CGRect) -> CGRect {
        CGRect(origin: layout(fromDocument: rect.origin), size: rect.size)
    }

    /// The document point a scene-space point is at.
    public func document(fromScene point: CGPoint) -> CGPoint {
        document(fromLayout: SceneGeometry.layout(from: point))
    }

    /// The scene point a document point is at.
    public func scene(fromDocument point: CGPoint) -> CGPoint {
        SceneGeometry.scene(from: layout(fromDocument: point))
    }

    // MARK: - The scroll view and the camera

    /// Where the camera has to be to show what the scroll view is showing.
    ///
    /// Deliberately not clamped: while the reader is pulling the map past its
    /// edge the clip view really is showing air, and a camera that quietly
    /// refused to follow would make the elastic edge look like a dropped
    /// gesture rather than like an edge.
    ///
    /// - Parameters:
    ///   - documentVisible: `NSScrollView.documentVisibleRect`.
    ///   - magnification: `NSScrollView.magnification`.
    public func viewport(
        documentVisible: CGRect,
        magnification: CGFloat
    ) -> SceneViewport {
        let middle = CGPoint(x: documentVisible.midX, y: documentVisible.midY)
        return SceneViewport(
            content: contentRect,
            size: CGSize(
                width: documentVisible.width * magnification,
                height: documentVisible.height * magnification
            ),
            center: scene(fromDocument: middle),
            zoom: magnification
        )
    }

    /// What the scroll view has to show for the camera to be at `viewport`.
    public func documentVisible(for viewport: SceneViewport) -> CGRect {
        guard viewport.zoom > 0 else { return CGRect(origin: .zero, size: documentSize) }
        let size = CGSize(
            width: viewport.size.width / viewport.zoom,
            height: viewport.size.height / viewport.zoom
        )
        let middle = document(fromScene: viewport.center)
        return CGRect(
            x: middle.x - size.width / 2,
            y: middle.y - size.height / 2,
            width: size.width,
            height: size.height
        )
    }

    /// Where the clip view's bounds origin has to be for the camera to be at
    /// `viewport`.
    public func documentOrigin(for viewport: SceneViewport) -> CGPoint {
        documentVisible(for: viewport).origin
    }
}
