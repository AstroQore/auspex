import CoreGraphics
import Foundation

/// The camera moving on its own: a fit, a room being framed, a rung being
/// snapped to when the fingers lift.
///
/// ## Why the scene animates this rather than AppKit
///
/// A scroll view can animate itself — `contentView.animator()` and
/// `animator().magnification` both exist — but the office is drawn by a
/// SpriteKit view *underneath* the scroll view, and the two have to agree on
/// every frame or the picture slides out from under the scrollers. There is
/// exactly one clock that is guaranteed to tick immediately before each drawn
/// frame, and it is the scene's own `update(_:)`. So a flight is a value that
/// answers "where should the camera be at this instant", the scene asks it once
/// per frame, and the scroll view and the camera are written from the same
/// answer.
///
/// It also makes the arithmetic testable, which an `NSAnimationContext` block
/// is not, and it makes Reduce Motion one branch rather than a policy: a
/// duration of zero is a flight that has already landed.
public struct SceneFlight: Sendable, Equatable {
    /// Where the camera was when it was asked to move.
    public let from: SceneViewport
    /// Where it is going.
    public let to: SceneViewport
    /// How long the journey takes.
    public let duration: TimeInterval

    /// How long a flight across the map takes.
    public static let travelDuration: TimeInterval = 0.32
    /// How long the map takes to settle onto a rung after a gesture lets go of
    /// it. Quicker than a journey, because it is a settle rather than a
    /// journey.
    public static let settleDuration: TimeInterval = 0.2

    public init(from: SceneViewport, to: SceneViewport, duration: TimeInterval) {
        self.from = from
        self.to = to
        self.duration = max(0, duration)
    }

    /// `true` once `elapsed` has carried the camera all the way there.
    public func hasLanded(after elapsed: TimeInterval) -> Bool {
        elapsed >= duration
    }

    /// Where the camera is `elapsed` seconds in.
    ///
    /// The centre moves linearly and the zoom moves *geometrically* — every
    /// step multiplies rather than adds — because zoom is perceived in ratios.
    /// Interpolating 1/8 → 2 linearly spends most of the flight above 1×, so
    /// the office appears to leap towards the reader and then crawl the last
    /// of the way; in log space it is one smooth pull.
    public func viewport(after elapsed: TimeInterval) -> SceneViewport {
        guard duration > 0, elapsed < duration else { return to }
        guard elapsed > 0 else { return from }
        let progress = Self.ease(CGFloat(elapsed / duration))
        var moved = to
        moved.center = CGPoint(
            x: from.center.x + (to.center.x - from.center.x) * progress,
            y: from.center.y + (to.center.y - from.center.y) * progress
        )
        moved.zoom = Self.interpolate(zoom: from.zoom, to: to.zoom, progress: progress)
        return moved
    }

    /// Ease-out: the camera leaves quickly and arrives gently, which is what
    /// makes a flight read as the map being brought to the reader rather than
    /// as the reader being thrown at the map.
    public static func ease(_ progress: CGFloat) -> CGFloat {
        let clamped = min(1, max(0, progress))
        let remaining = 1 - clamped
        return 1 - remaining * remaining * remaining
    }

    /// One step of a geometric interpolation between two zooms.
    public static func interpolate(
        zoom from: CGFloat,
        to target: CGFloat,
        progress: CGFloat
    ) -> CGFloat {
        guard from > 0, target > 0 else { return target }
        return from * pow(target / from, progress)
    }
}
