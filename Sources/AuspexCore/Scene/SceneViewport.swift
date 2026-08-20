import CoreGraphics
import Foundation

/// Where the camera is pointed and how close it is — as a value, with no
/// SpriteKit in it.
///
/// ## Why the camera's arithmetic lives in Core
///
/// Every interesting thing a camera over a large canvas does is arithmetic:
/// what "fit all" means, where a zoom around the pointer leaves the centre,
/// how far a drag is allowed to go before the map is lost off the edge of the
/// screen. None of it needs a node, a view, or a run loop, and all of it is
/// exactly the kind of thing that is wrong by one sign for a week if nobody
/// can write a test for it. So the arithmetic is a `Sendable` value here and
/// ``SceneCamera`` in the app is the thin part that copies the answer onto an
/// `SKCameraNode`.
///
/// ## Coordinates
///
/// A viewport is expressed in **scene space** — SpriteKit's y-up world, the
/// space ``SceneFrame`` becomes after ``SceneGeometry/scene(from:)`` flips it.
/// ``size`` is the viewport in points, so `size / zoom` is what the reader can
/// see of the world.
///
/// ## Zoom is a ladder, not a slider
///
/// The office is pixel art drawn with nearest-neighbour filtering, and pixel
/// art at 1.37× is a grid of unevenly-doubled columns — the eye reads it as a
/// bad screenshot rather than as a zoom level. So zoom is quantised to
/// ``zoomLadder``: integer multiples on the way in, integer *divisors* on the
/// way out, which are the two families of scale factor that map whole source
/// pixels onto whole screen pixels. Every gesture, preset, and fit lands on a
/// rung; nothing in the app can set a fractional scale.
public struct SceneViewport: Sendable, Equatable {
    /// The world, in scene coordinates. What panning is clamped to.
    public var content: CGRect
    /// How big the viewport is, in points.
    public var size: CGSize
    /// Where the camera is pointed, in scene coordinates.
    public var center: CGPoint
    /// How close the camera is. Greater than one is closer, the way a person
    /// means it — the inverse of an `SKCameraNode`'s scale.
    public var zoom: CGFloat

    public init(
        content: CGRect = .zero,
        size: CGSize = .zero,
        center: CGPoint = .zero,
        zoom: CGFloat = 1
    ) {
        self.content = content
        self.size = size
        self.center = center
        self.zoom = zoom
    }

    // MARK: - The ladder

    /// Every zoom the camera is allowed to stop at, closest last.
    ///
    /// `1/n` below one and `n` above it. A rung like `1/6` is not a power of
    /// two, but it still maps a whole 6×6 block of art pixels onto one screen
    /// pixel, which is what keeps a zoomed-out office looking like a small
    /// office rather than like a moiré pattern.
    public static let zoomLadder: [CGFloat] = [
        1.0 / 16, 1.0 / 12, 1.0 / 8, 1.0 / 6, 1.0 / 4, 1.0 / 3, 1.0 / 2, 1, 2, 3, 4
    ]

    /// The zooms the toolbar offers by name.
    public static let zoomPresets: [CGFloat] = [0.25, 0.5, 1, 2]

    /// How far out the camera will go. Sixteen art pixels to one screen pixel
    /// is roughly a hundred rooms in a window, which is more office than
    /// anybody has.
    public static var minZoom: CGFloat { zoomLadder[0] }
    /// How far in. Beyond four a 16-pixel character is a wall of squares.
    public static var maxZoom: CGFloat { zoomLadder[zoomLadder.count - 1] }

    /// The closest a *fit* is allowed to get.
    ///
    /// Framing one small room should not slam the camera against the near
    /// stop: an office with one desk in it, filling a 900-point window at 4×,
    /// reads as a bug rather than as an empty day.
    public static let maxFitZoom: CGFloat = 2

    /// The air left around whatever is being framed, as a multiplier on the
    /// scale a tight fit would need.
    public static let fitPadding: CGFloat = 1.08
    /// The same, for one room, which wants a little more room to breathe than
    /// the whole building does.
    public static let focusPadding: CGFloat = 1.22

    /// The rung nearest `zoom`, measured the way zoom is perceived — in
    /// ratios, so 0.75 is nearer to 1/2 than to 1 by the same margin at every
    /// magnitude.
    public static func snapped(_ zoom: CGFloat) -> CGFloat {
        guard zoom > 0 else { return 1 }
        return zoomLadder.min { lhs, rhs in
            abs(log(lhs / zoom)) < abs(log(rhs / zoom))
        } ?? 1
    }

    /// The highest rung that is no closer than `zoom`, so that whatever was
    /// being fitted still fits.
    public static func rung(atOrBelow zoom: CGFloat) -> CGFloat {
        zoomLadder.last { $0 <= zoom + 1e-9 } ?? minZoom
    }

    /// The rung `steps` away from the current one, positive being closer.
    public static func rung(_ steps: Int, from zoom: CGFloat) -> CGFloat {
        let current = snapped(zoom)
        let index = zoomLadder.firstIndex(of: current) ?? zoomLadder.count / 2
        let moved = min(zoomLadder.count - 1, max(0, index + steps))
        return zoomLadder[moved]
    }

    // MARK: - Reading

    /// What the reader can see of the world.
    public var visibleRect: CGRect {
        guard zoom > 0 else { return .zero }
        let width = size.width / zoom
        let height = size.height / zoom
        return CGRect(
            x: center.x - width / 2, y: center.y - height / 2, width: width, height: height
        )
    }

    /// Whether `rect` is wholly on screen. What "do not move the camera for
    /// something the reader is already looking at" is decided with.
    public func showsAll(of rect: CGRect) -> Bool {
        guard size.width > 0, size.height > 0, rect.width > 0 || rect.height > 0 else {
            return false
        }
        return visibleRect.insetBy(dx: -0.5, dy: -0.5).contains(rect)
    }

    /// Whether any of `rect` is on screen, with `margin` points of slack. What
    /// the scene decides to keep animating with.
    public func shows(_ rect: CGRect, margin: CGFloat = 0) -> Bool {
        visibleRect.insetBy(dx: -margin, dy: -margin).intersects(rect)
    }

    /// `true` when the world is small enough that panning would only move it
    /// away from the reader.
    public var isFullyVisible: Bool {
        content.width <= visibleRect.width + 0.5 && content.height <= visibleRect.height + 0.5
    }

    // MARK: - Moving

    /// The same viewport with the camera pulled back inside the world.
    ///
    /// A camera with no bounds can be scrolled into empty space, and an office
    /// that has vanished off the edge of an otherwise identical dark rectangle
    /// is indistinguishable from a view that failed to draw. When the world is
    /// smaller than the viewport on an axis there is exactly one sensible
    /// position on it, and a drag that moves away from it produces a view of
    /// nothing — so that axis is pinned to the middle rather than clamped.
    public func clamped() -> Self {
        guard content.width > 0, content.height > 0, size.width > 0, size.height > 0, zoom > 0
        else { return self }
        var moved = self
        let half = CGSize(width: size.width / zoom / 2, height: size.height / zoom / 2)

        func axis(_ value: CGFloat, _ lower: CGFloat, _ upper: CGFloat, _ half: CGFloat)
            -> CGFloat
        {
            if upper - lower <= half * 2 { return (lower + upper) / 2 }
            return min(max(value, lower + half), upper - half)
        }

        moved.center = CGPoint(
            x: axis(center.x, content.minX, content.maxX, half.width),
            y: axis(center.y, content.minY, content.maxY, half.height)
        )
        return moved
    }

    /// Framed on the whole world.
    public func fitted(padding: CGFloat = SceneViewport.fitPadding) -> Self {
        focused(on: content, padding: padding)
    }

    /// Framed on one part of the world — a room, or a desk with air around it.
    public func focused(
        on rect: CGRect,
        padding: CGFloat = SceneViewport.focusPadding
    ) -> Self {
        guard rect.width > 0, rect.height > 0, size.width > 0, size.height > 0 else {
            return self
        }
        let needed = min(size.width / (rect.width * padding), size.height / (rect.height * padding))
        var moved = self
        moved.zoom = min(Self.maxFitZoom, max(Self.minZoom, Self.rung(atOrBelow: needed)))
        moved.center = CGPoint(x: rect.midX, y: rect.midY)
        return moved.clamped()
    }

    /// Moved to `target`, keeping the world point under `anchor` under it
    /// afterwards.
    ///
    /// - Parameter snapping: whether to land on a rung of ``zoomLadder``. A
    ///   pinch passes `false`, because a gesture that jumped between rungs
    ///   under the fingers would feel broken rather than crisp; it lands on a
    ///   rung when the fingers lift, via ``settled(around:)``.
    public func zoomed(
        to target: CGFloat,
        around anchor: CGPoint? = nil,
        snapping: Bool = true
    ) -> Self {
        let wanted = snapping ? Self.snapped(target) : target
        let next = min(Self.maxZoom, max(Self.minZoom, wanted))
        guard next != zoom, zoom > 0 else { return self }
        var moved = self
        moved.zoom = next
        if let anchor {
            // The camera closes exactly the fraction of the distance to the
            // anchor that the zoom just removed, which is what keeps the point
            // under the pointer under the pointer.
            let ratio = zoom / next
            moved.center = CGPoint(
                x: anchor.x + (center.x - anchor.x) * ratio,
                y: anchor.y + (center.y - anchor.y) * ratio
            )
        }
        return moved.clamped()
    }

    /// Moved `steps` rungs, positive being closer.
    public func stepped(_ steps: Int, around anchor: CGPoint? = nil) -> Self {
        zoomed(to: Self.rung(steps, from: zoom), around: anchor)
    }

    /// What the camera does when the fingers lift: the zoom lands on a rung
    /// and anything pulled past the edge springs back.
    ///
    /// Panning itself is the scroll view's — momentum, the elastic edge, and
    /// which way "natural" means are all `NSScrollView`'s. This is the half the
    /// platform has no opinion about: pixel art wants whole-pixel scale
    /// factors, so a pinch that ends between rungs is walked onto the nearest
    /// one, around whatever the fingers were over.
    public func settled(around anchor: CGPoint? = nil) -> Self {
        let rung = min(Self.maxZoom, max(Self.minZoom, Self.snapped(zoom)))
        guard rung != zoom else { return clamped() }
        return zoomed(to: rung, around: anchor, snapping: false).clamped()
    }

    /// `true` when the map has been pulled off its edge — which the scroll
    /// view's elastic scrolling does while the fingers are still on the glass,
    /// and which is what ``settled(around:)`` puts back.
    public var isOverscrolled: Bool {
        let inside = clamped()
        return abs(inside.center.x - center.x) > 0.5 || abs(inside.center.y - center.y) > 0.5
    }

    /// Pointed at one place without changing how close the camera is.
    public func centered(on point: CGPoint) -> Self {
        var moved = self
        moved.center = point
        return moved.clamped()
    }

    /// The same viewport told how big the world is now.
    public func withContent(_ rect: CGRect) -> Self {
        var moved = self
        moved.content = rect
        return moved.clamped()
    }

    /// The same viewport told how big the view is now.
    public func withSize(_ size: CGSize) -> Self {
        guard size.width > 0, size.height > 0 else { return self }
        var moved = self
        moved.size = size
        return moved.clamped()
    }
}
