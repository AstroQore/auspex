// Ported from bloub — https://github.com/jeremy-prt/bloub
// MIT License, © 2026 Jérémy Perret. See THIRD_PARTY_NOTICES.md.

import Foundation

/// A head orientation, in degrees.
public struct BloubGaze: Sendable, Hashable {
    /// Yaw. Positive looks right.
    public var yaw: Double
    /// Pitch. Positive looks up.
    public var pitch: Double
    /// Roll: the head's own tilt.
    public var roll: Double

    public init(yaw: Double, pitch: Double, roll: Double) {
        self.yaw = yaw
        self.pitch = pitch
        self.roll = roll
    }
}

/// One eye's placement and tangent frame.
public struct BloubEyePose: Sendable, Hashable {
    public var x: Double
    public var y: Double
    /// The 2×2 tangent matrix, in the sense of `matrix(a, b, c, d, e, f)`.
    public var a: Double
    public var b: Double
    public var c: Double
    public var d: Double
    /// z component of the normal: > 0 means the face is turned towards us.
    public var depth: Double
}

/// What the resting body does on its own: gaze drift, saccades, blinks.
public struct BloubLiveliness: Sendable, Hashable {
    public var deltaYaw: Double
    public var deltaPitch: Double
    public var deltaRoll: Double
    /// 1 = open, 0 = shut (a vertical squash in screen space).
    public var lid: Double
    public var driftX: Double
    public var driftY: Double
    public var breath: Double
}

/// The face: where the eyes sit, how big they are, and how they live.
///
/// ## The eyes live on a sphere
///
/// Measured on the video: the eye nearer the edge is 0.69 times the width of
/// the other and 0.663 times its area — exactly the depth factor (z = 0.669)
/// of a point on a sphere at that distance from the centre. So the model is a
/// real head orientation: each eye takes the sphere's tangent frame, projected
/// orthographically. The compression, the tilt and the passage behind the limb
/// all follow on their own, and that is what gives the volume.
///
/// The constants below are not hand-picked: they come from fitting that model
/// to positions and sizes measured frame by frame, with about 1 px of residual
/// error on a 190 px ball.
public enum BloubFace {
    /// Half the eyes' separation on the sphere, in degrees (total ≈ 31°).
    public static let eyeSplit = 15.46
    /// Resting eye size, in ball-radius units.
    public static let eyeWidth = 0.186
    public static let eyeHeight = 0.412

    /// Resting head orientation, fitted on the reference frames.
    ///
    /// The rest tilt is not a constant anywhere: it emerges from this through
    /// the tangent frame, at about 26° off vertical. And the eyes lean like
    /// `\\`, not `//` — one of the verified traps.
    public static let restGaze = BloubGaze(yaw: 28.49, pitch: 28.62, roll: -13)

    /// Measured: 1 to 2 frames at 10 fps.
    public static let blinkDuration = 0.18

    /// The forced blink that hides a shape change. Measured at 0.2 s.
    public static let forcedBlinkDuration = 0.2

    private static func deg(_ d: Double) -> Double { d * .pi / 180 }

    /// Rotates two vectors of an orthonormal frame within their common plane.
    private static func spin(
        _ u: (Double, Double, Double),
        _ v: (Double, Double, Double),
        _ angle: Double
    ) -> ((Double, Double, Double), (Double, Double, Double)) {
        let c = cos(angle)
        let s = sin(angle)
        return (
            (u.0 * c + v.0 * s, u.1 * c + v.1 * s, u.2 * c + v.2 * s),
            (v.0 * c - u.0 * s, v.1 * c - u.1 * s, v.2 * c - u.2 * s)
        )
    }

    /// The head's frame, then the two eyes'.
    ///
    /// Screen frame: x right, y down, z towards the viewer. Index 0 is the
    /// inner eye, index 1 the outer one.
    public static func eyePoses(
        gaze: BloubGaze,
        scale: Double,
        split: Double = BloubFace.eyeSplit
    ) -> (BloubEyePose, BloubEyePose) {
        var f = (0.0, 0.0, 1.0)
        var right = (1.0, 0.0, 0.0)
        var down = (0.0, 1.0, 0.0)

        // yaw: forward tips towards right
        (f, right) = spin(f, right, deg(gaze.yaw))
        // pitch: forward tips up, so away from down
        (down, f) = spin(down, f, deg(gaze.pitch))
        // roll: the head leans in its own plane
        (right, down) = spin(right, down, deg(gaze.roll))

        func build(_ side: Double) -> BloubEyePose {
            let (ef, er) = spin(f, right, deg(split * side))
            return BloubEyePose(
                x: ef.0 * scale,
                y: ef.1 * scale,
                a: er.0,
                b: er.1,
                c: down.0,
                d: down.1,
                depth: ef.2
            )
        }

        return (build(-1), build(1))
    }

    /// The pre-drawn blink schedule: deterministic and stateless, which is
    /// what lets ``BloubEngine/sample(_:)`` stay a pure function of time.
    static let blinks: [Double] = {
        var rng = BloubRNG(seed: 0x5eed)
        var out: [Double] = []
        var t = 1.4
        while t < 900 {
            out.append(t)
            // 1.9 to 4.6 s between blinks, plus an occasional double blink
            t += 1.9 + rng.next() * 2.7
            if rng.next() < 0.18 {
                out.append(t)
                t += 0.24
            }
        }
        return out
    }()

    static func blinkLid(_ t: Double) -> Double {
        for start in blinks {
            if t < start { break }
            let k = (t - start) / blinkDuration
            if k >= 0, k <= 1 { return lidCurve(k) }
        }
        return 1
    }

    /// A lid's travel over one blink, `k` in 0…1.
    ///
    /// Asymmetric in both halves, which is what a lid actually does and what
    /// the previous straight-line version could not say:
    ///
    /// - **shutting** takes 45 % of the blink on an ease-*in*, so the lid
    ///   leaves the open eye at rest and arrives shut at speed;
    /// - **opening** takes the other 55 % on an ease-*out*, so it leaves shut
    ///   at speed and settles back open.
    ///
    /// The consequence worth naming: both *ends* of the blink have zero
    /// velocity, so nothing kinks where the blink begins or finishes, while the
    /// bottom keeps its corner — the lid really does hit and rebound there.
    static func lidCurve(_ k: Double) -> Double {
        k < 0.45
            ? 1 - BloubMath.easeInCubic(k / 0.45)
            : BloubMath.easeOutCubic((k - 0.45) / 0.55)
    }

    /// The lid of the blink that punctuates a state change, `k` in 0…1.
    ///
    /// Same easings as ``lidCurve(_:)`` but shut exactly half-way, because this
    /// one is placed so that its midpoint is the morph's midpoint. Moving the
    /// shut point would move the accent off the beat it was put on.
    public static func forcedLid(_ k: Double) -> Double {
        if k <= 0 || k >= 1 { return 1 }
        return k < 0.5
            ? 1 - BloubMath.easeInCubic(k / 0.5)
            : BloubMath.easeOutCubic((k - 0.5) / 0.5)
    }

    /// Resting life: slow gaze drift, saccades, blinks.
    ///
    /// A pure function of time with no internal state, so pausing, resuming
    /// and jumping to an arbitrary date always give the same image. The values
    /// are **offsets** to add to the current state's pose.
    ///
    /// At rest the video is very nearly still — the centre is stable to ±0.003
    /// and the radius constant — so all the life goes through the gaze and the
    /// blinks. What is kept here is just enough not to freeze the image
    /// completely. **Do not add a float on top.**
    public static func liveliness(
        _ t: Double,
        wander: Double = 1,
        blink: Bool = true,
        float: Bool = true
    ) -> BloubLiveliness {
        // Periods coprime with each other: the drift never visibly repeats.
        BloubLiveliness(
            deltaYaw: (BloubMath.loopNoise(t, 11.3, 0.4) * 5.5
                + BloubMath.loopNoise(t, 3.7, 2.1) * 1.6) * wander,
            deltaPitch: (BloubMath.loopNoise(t, 9.1, 1.3) * 4.2
                + BloubMath.loopNoise(t, 4.3, 0.7) * 1.3) * wander,
            deltaRoll: BloubMath.loopNoise(t, 13.7, 3.2) * 2.2 * wander,
            lid: blink ? blinkLid(t) : 1,
            driftX: float ? BloubMath.loopNoise(t, 7.9, 1.9) * 0.006 : 0,
            driftY: float ? BloubMath.loopNoise(t, 5.3, 0.3) * 0.007 : 0,
            // The width is constant; only the height breathes, very slightly.
            breath: float ? 1 + sin((t / 3.4) * .pi * 2) * 0.005 : 1
        )
    }

    /// A blink is a **vertical** squash in screen space about the eye's centre
    /// (measured: the bbox width is preserved, the height falls to ≈ 0.35),
    /// not a shrink along the capsule's tilted axis. So it is composed after
    /// the tangent matrix, affecting only the y outputs.
    public static func blinkScale(_ lid: Double) -> Double {
        0.06 + 0.94 * BloubMath.clamp(lid)
    }
}
