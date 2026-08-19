import CoreGraphics
import Foundation

/// What a trackpad means, as arithmetic.
///
/// ## Why the translation is here and not in the view
///
/// The gesture handlers themselves have to be real AppKit responder methods on
/// the view that owns the canvas — there is no SwiftUI approximation of
/// momentum, of a pinch's centroid, or of a two-finger double tap. But what an
/// `NSEvent`'s numbers *mean* is arithmetic, and arithmetic with a sign in it
/// is arithmetic that is wrong for a week until somebody with a trackpad says
/// "it goes the wrong way". So the signs live here, with tests, and the view
/// is left holding nothing but `event.scrollingDeltaX`.
public enum SceneGesture {
    /// How far the camera should move for one scroll event.
    ///
    /// ## Which way a canvas goes
    ///
    /// A canvas moves *with* the fingers: two fingers pushing left push the
    /// map left, the way Maps and Preview and every drawing tool on this
    /// platform behave. That is the same thing as the camera moving right, so
    /// the camera's delta is the negative of the content's.
    ///
    /// AppKit has already applied the system's scroll-direction preference to
    /// the numbers by the time they arrive: with "natural" scrolling on — the
    /// default, and what ``NSEvent/isDirectionInvertedFromDevice`` reports —
    /// the deltas describe the content following the fingers, which is what
    /// this wants. With it off they arrive reversed, so the sign goes back and
    /// a wheel keeps behaving like a wheel.
    ///
    /// - Parameters:
    ///   - x: `NSEvent.scrollingDeltaX`.
    ///   - y: `NSEvent.scrollingDeltaY`.
    ///   - isDirectionInverted: `NSEvent.isDirectionInvertedFromDevice`.
    /// - Returns: a delta in view points, in the scene's y-up axes, ready for
    ///   ``SceneViewport/panned(by:rubberBanding:)``.
    public static func panDelta(
        x: CGFloat,
        y: CGFloat,
        isDirectionInverted: Bool
    ) -> CGVector {
        let sign: CGFloat = isDirectionInverted ? 1 : -1
        // The y flips once more than the x because the scroll deltas are in
        // the window's y-down space and the scene is y-up.
        return CGVector(dx: -sign * x, dy: sign * y)
    }

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
