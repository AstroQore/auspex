import CoreGraphics
import Foundation

/// What a trackpad means, as arithmetic.
///
/// ## Why the translation is here and not in the view
///
/// Scrolling itself is the scroll view's now: momentum, elastic edges, and the
/// system's scroll-direction preference are `NSScrollView`'s job, and it does
/// them better than any hand-rolled substitute manages to keep doing. What is
/// left here is the arithmetic the platform does *not* do for a canvas — a
/// pinch that has to move the map as well as scale it, and a wheel notch that
/// has to land on a rung — and arithmetic with a sign in it is arithmetic that
/// is wrong for a week until somebody with a trackpad says "it goes the wrong
/// way". So the signs live here, with tests, and the view is left holding
/// nothing but `event.magnification`.
public enum SceneGesture {
    /// How far the document has to move so that the map keeps up with a pinch
    /// whose fingers are also travelling.
    ///
    /// ## Why this is not free
    ///
    /// Zooming around a centroid keeps the point *currently* under the fingers
    /// where it is; it does not move the map when the fingers slide. Two
    /// fingers that pinch and travel at once are asking for both, which is what
    /// Preview does and what a canvas has to do, so the travel is applied as a
    /// scroll of its own — but only when the system has not already sent scroll
    /// events for the same fingers, or the map would move twice as far as they
    /// did. See ``pinchPansItself(secondsSinceScroll:)``.
    ///
    /// - Parameters:
    ///   - centroidDelta: how far the point between the fingers moved since the
    ///     last event, in window points (y-up, as AppKit reports it).
    ///   - magnification: the scroll view's magnification, so that a travel of
    ///     an inch on the glass is an inch of screen whatever the zoom is.
    /// - Returns: what to add to the clip view's bounds origin, in document
    ///   points — y-down, because the document view is flipped.
    public static func pinchScroll(
        centroidDelta: CGVector,
        magnification: CGFloat
    ) -> CGVector {
        guard magnification > 0 else { return .zero }
        // The map follows the fingers, so the window onto it moves the other
        // way; y flips once more because the document is y-down and a window
        // is y-up.
        return CGVector(
            dx: -centroidDelta.dx / magnification,
            dy: centroidDelta.dy / magnification
        )
    }

    /// Whether a pinch has to move the map itself.
    ///
    /// The system decomposes some two-finger gestures into a magnify stream
    /// *and* a scroll stream, in which case the scroll view is already panning
    /// and adding to it would double every movement. When no scroll event has
    /// arrived for the length of a few frames, the pinch is on its own and has
    /// to carry the travel.
    ///
    /// - Parameter secondsSinceScroll: how long ago the scroll view last
    ///   handled a scroll event, or `nil` if it never has.
    public static func pinchPansItself(secondsSinceScroll: TimeInterval?) -> Bool {
        guard let secondsSinceScroll else { return true }
        return secondsSinceScroll > concurrentScrollWindow
    }

    /// How recently a scroll event has to have arrived to count as part of the
    /// same gesture. Three frames at 60 Hz: long enough to bridge the gap
    /// between two event streams, short enough that a pinch begun after a
    /// scroll has ended is not mistaken for part of it.
    public static let concurrentScrollWindow: TimeInterval = 0.05

    /// The zoom a pinch of `magnification` leaves behind.
    ///
    /// `NSEvent.magnification` is a *fraction of the current size* per event —
    /// a pinch that grows the content by a tenth reports `0.1` — so the events
    /// compose by multiplication. Adding them would make a slow pinch and a
    /// fast one over the same distance end up at different zooms.
    public static func zoom(_ current: CGFloat, magnifiedBy magnification: CGFloat) -> CGFloat {
        max(0.0001, current * (1 + magnification))
    }

    /// How much of a wheel notch is worth one rung of the zoom ladder.
    ///
    /// Wheels report whole notches and trackpads report pixels; only the wheel
    /// path uses this, and one notch is one rung.
    public static let notchesPerRung: CGFloat = 1

    /// The rungs a ⌘-scroll on a mouse asks for.
    public static func rungs(forWheelDelta delta: CGFloat) -> Int {
        guard delta != 0 else { return 0 }
        return delta > 0 ? 1 : -1
    }
}
