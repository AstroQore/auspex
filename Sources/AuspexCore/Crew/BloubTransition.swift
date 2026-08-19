import Foundation

/// How Auspex times a change of state — and the one place this port knowingly
/// leaves bloub.
///
/// ## Why it deviates
///
/// bloub is a montage. Its states are cut together at a couple of seconds each,
/// they are watched at the size of a hero illustration, and a change of shape is
/// **hidden inside a 0.2 s blink**: the eye is shut over the fastest part of the
/// morph, so the morph is a damping mechanism the viewer never quite sees.
///
/// Auspex is a wall. A card is 200 points wide, twelve to sixty of them are on
/// screen, and nobody is looking at any one of them when it changes — they
/// notice it out of the corner of an eye and look over. On that wall the
/// hide-it-in-a-blink trick reads as a snap: the shape was one thing, there was
/// a flicker, and now it is another. The morph has to be the event, not the
/// thing being covered up.
///
/// So the timing here is chosen, not measured:
///
/// - a state change is a **visible** morph, held inside a 420–600 ms band
///   whatever the state asked for;
/// - it is sampled along an **ease-in-out**, which leaves the old pose and
///   arrives at the new one with zero speed, instead of bloub's exponential
///   ease-out, which departs at full speed;
/// - the **face trails the body** by 60 ms, so the head follows the shape
///   rather than moving with it. Under 40 ms it reads as a rendering fault;
///   over about 100 ms the eyes look detached from the body they sit on;
/// - there is still a blink, and it is still 0.2 s, but it is centred on the
///   **midpoint of the morph** rather than fired at its start. Two thirds of
///   the morph happen with the eyes open, which is the whole point.
///
/// Everything bloub measured that is *not* timing — the poses, the silhouettes,
/// the decor, the gaze angles, the eye capsules — is untouched, and stays
/// untouchable. See `THIRD_PARTY_NOTICES.md`.
public enum BloubTransition {
    /// The floor of the band. Below this a morph across a wall of cards is over
    /// before the eye that caught it has arrived.
    public static let shortest = 0.42

    /// The ceiling. Beyond this the avatar looks viscous, and a session that
    /// changes state twice in a second would never finish a morph.
    public static let longest = 0.60

    /// How far the face trails the body.
    public static let eyeLag = 0.06

    /// The morph a state asked for, brought inside the band.
    ///
    /// The catalogue's own `morph` values run 0.3 to 0.6, and their *ordering*
    /// is kept — a state bloub gave a longer entry to still gets one — but the
    /// short end is lifted off the floor.
    public static func duration(_ morph: Double) -> Double {
        min(max(morph, shortest), longest)
    }

    /// How long the whole transition occupies, face included. The engine has to
    /// keep the state it is leaving for exactly this long, because the eyes are
    /// still arriving after the body has settled.
    public static func span(_ morph: Double) -> Double {
        duration(morph) + eyeLag
    }

    /// The curve every transition is sampled along.
    ///
    /// Written as a pure function of `t` rather than as a spring so that
    /// ``BloubEngine/sample(_:)`` stays replayable: re-reading an instant from
    /// the middle of a morph must give the same frame back, and a spring
    /// integrated frame by frame could not promise that.
    @inlinable
    public static func curve(_ t: Double) -> Double {
        BloubMath.easeInOutCubic(BloubMath.clamp(t))
    }

    /// The body's progress, `since` seconds into a morph of `duration`.
    @inlinable
    public static func body(_ since: Double, _ duration: Double) -> Double {
        curve(since / duration)
    }

    /// The face's progress: the same curve, ``eyeLag`` behind.
    @inlinable
    public static func face(_ since: Double, _ duration: Double) -> Double {
        curve((since - eyeLag) / duration)
    }

    /// When the blink that accompanies a morph should start, so that the eye is
    /// fully shut at the morph's midpoint.
    public static func blinkStart(_ morph: Double, blinkDuration: Double) -> Double {
        duration(morph) / 2 - blinkDuration / 2
    }
}
