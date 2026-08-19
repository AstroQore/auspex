// Ported from bloub — https://github.com/jeremy-prt/bloub
// MIT License, © 2026 Jérémy Perret. See THIRD_PARTY_NOTICES.md.

import Foundation

/// Everything one state asks to be drawn at one instant.
public struct BloubPose: Sendable {
    /// The body's silhouette, in ball-radius units.
    public var silhouette: BloubSilhouette
    /// A global offset of the body **and** the eyes.
    public var offsetX: Double
    public var offsetY: Double
    public var gaze: BloubGaze
    /// Half the eyes' separation on the sphere, in degrees.
    public var split: Double
    /// (inner eye, outer eye)
    public var eyes: (BloubEyeConfig, BloubEyeConfig)
    /// The eyes' opacity: what the faceless states turn down.
    public var eyeAlpha: Double
    public var bodyAlpha: Double
    public var dots: [BloubDot]
    public var arcs: [BloubArcSpec]
    public var notify: (x: Double, y: Double, radius: Double, notch: Double)?
    /// true = the decor passes behind the body (the burst's particles).
    public var dotsBehind: Bool

    init(
        silhouette: BloubSilhouette = BloubShape.circle(1),
        offsetX: Double = 0,
        offsetY: Double = 0,
        gaze: BloubGaze = BloubFace.restGaze,
        split: Double = BloubFace.eyeSplit,
        eyes: (BloubEyeConfig, BloubEyeConfig) = (
            BloubEyeConfig(width: BloubFace.eyeWidth, height: BloubFace.eyeHeight),
            BloubEyeConfig(width: BloubFace.eyeWidth, height: BloubFace.eyeHeight)
        ),
        eyeAlpha: Double = 1,
        bodyAlpha: Double = 1,
        dots: [BloubDot] = [],
        arcs: [BloubArcSpec] = [],
        notify: (x: Double, y: Double, radius: Double, notch: Double)? = nil,
        dotsBehind: Bool = false
    ) {
        self.silhouette = silhouette
        self.offsetX = offsetX
        self.offsetY = offsetY
        self.gaze = gaze
        self.split = split
        self.eyes = eyes
        self.eyeAlpha = eyeAlpha
        self.bodyAlpha = bodyAlpha
        self.dots = dots
        self.arcs = arcs
        self.notify = notify
        self.dotsBehind = dotsBehind
    }
}

/// The state catalogue's ids.
public enum BloubStateID: String, Sendable, CaseIterable, Hashable {
    case idle
    case thinking
    case wink
    case wide
    case alert
    case notify
    case exclaim
    case sleep
    case egg
    case hexagon
    case play
    case orbit
    case burst
    case comet
    /// An interface transition, not a catalogue animation: outside ``BloubStates/sequence``.
    case swirl
}

/// One state: how long it holds, how it morphs in, and its pose at a local time.
public struct BloubStateDef: Sendable {
    public var id: BloubStateID
    /// How long it is held when the full sequence is played.
    public var duration: Double
    /// The length below which the animation is cut before it resolves: the "!"
    /// does not come back, the body stays burst. It is **read off** the
    /// constants in `pose` below, it is not chosen. `nil` means the state
    /// ignores time or loops, so any duration suits it.
    public var minDuration: Double?
    /// Length of the entry morph.
    public var morph: Double
    /// true = the entry is hidden by a blink, as in the video.
    public var blinkIn: Bool
    /// true = the body is the "resting" silhouette, so a chosen shape may
    /// replace it. States that draw their own shape (the "!", the dots, the
    /// egg, the triangle…) are false: that shape **is** the animation.
    public var usesBaseBody: Bool
    /// true = the state wears the resting face, so a chosen expression may
    /// replace it. Only `idle` among the catalogue states: the others that
    /// show a face have an expression measured off the video, and that is
    /// precisely what is being reproduced.
    public var usesBaseFace: Bool
    public var pose: @Sendable (Double) -> BloubPose
}

/// The fourteen measured states, plus the one chosen transition.
public enum BloubStates {
    private static func pair(_ w: Double, _ h: Double) -> (BloubEyeConfig, BloubEyeConfig) {
        (BloubEyeConfig(width: w, height: h), BloubEyeConfig(width: w, height: h))
    }

    // MARK: Non-radial shapes

    /// The upright "!"'s bar: the convex hull of two circles.
    /// Measured: top circle (0, -0.505) r 0.132, bottom circle (0, +0.130)
    /// r 0.075, straight flanks. So it is **tapered**, top/bottom ratio 1.76 —
    /// not the same shape as the leaning bar.
    private static let barUprightCenterY = -0.1875
    private static let barUprightRadii: [Double] = BloubShape.profile(
        fromPolygon: BloubShape.hullOfCircles(0, -0.505, 0.132, 0, 0.13, 0.075),
        centerX: 0,
        centerY: barUprightCenterY
    )

    /// The leaning "!"'s bar: a pure capsule (constant width 0.269, length 0.776).
    private static let barItalicRadii: [Double] = BloubShape.profile(
        fromPolygon: BloubShape.hullOfCircles(0, -0.2535, 0.1345, 0, 0.2535, 0.1345),
        centerX: 0,
        centerY: 0
    )

    private static func barUpright() -> BloubSilhouette {
        BloubSilhouette(radii: barUprightRadii, centerY: barUprightCenterY)
    }

    private static func barItalic(
        rotation: Double,
        centerX: Double,
        centerY: Double
    ) -> BloubSilhouette {
        BloubSilhouette(
            radii: barItalicRadii,
            rotation: rotation,
            centerX: centerX,
            centerY: centerY
        )
    }

    /// The leaning "!"'s dot is not a disc: it is a **teardrop**, round end
    /// (r 0.118) towards the bar and a drawn-out point away from it, 0.300 long
    /// along the glyph's axis. Centred on the round end's centroid.
    static let teardrop: [BloubPoint] = BloubShape.hullOfCircles(0, 0, 0.118, 0, 0.172, 0.012)

    /// The triangle does not spin on itself: its centre describes a circle of
    /// radius 0.213 about the origin (measured). That offset is what makes it
    /// read as tumbling rather than pivoting in place.
    private static let triangleOrbit = 0.213

    private static func spinningTriangle(_ rotation: Double) -> BloubSilhouette {
        BloubShape.silhouette(
            .triangle,
            rotation: rotation,
            centerX: -triangleOrbit * sin(rotation),
            centerY: triangleOrbit * cos(rotation)
        )
    }

    /// The pulse wave that runs left to right across the three dots.
    private static func dotPulse(_ t: Double, _ index: Int) -> Double {
        let raw = ((t - Double(index) * 0.5) / 1.5).truncatingRemainder(dividingBy: 1)
        let p = (raw + 1).truncatingRemainder(dividingBy: 1)
        let k = p < 0.5 ? 0.5 - 0.5 * cos(p * bloubTau) : 0
        return BloubMath.clamp(k * 2)
    }

    // MARK: The catalogue

    public static let all: [BloubStateDef] = [
        BloubStateDef(
            id: .idle,
            duration: 2.4,
            minDuration: nil,
            morph: 0.45,
            blinkIn: false,
            usesBaseBody: true,
            usesBaseFace: true,
            pose: { _ in BloubPose() }
        ),

        BloubStateDef(
            id: .thinking,
            duration: 2.6,
            minDuration: nil,
            morph: 0.4,
            blinkIn: true,
            usesBaseBody: false,
            usesBaseFace: false,
            pose: { t in
                let mid = dotPulse(t, 1)
                // The side dots come out of the ball's flanks: in the video
                // they stay fused with it for 1–2 frames before detaching.
                let emerge = 0.3 + 0.7 * BloubMath.easeOutCubic(BloubMath.clamp(t / 0.3))
                return BloubPose(
                    // the ball BECOMES the middle dot: the morph stays continuous
                    silhouette: BloubShape.circle(
                        BloubDecor.dotRadius * (1 + (BloubDecor.dotPeak - 1) * mid),
                        centerX: BloubDecor.dotX[1]
                    ),
                    eyeAlpha: 0,
                    dots: [0, 2].map { i in
                        let k = dotPulse(t, i)
                        return BloubDot(
                            x: BloubDecor.dotX[i] * emerge,
                            y: 0,
                            radius: BloubDecor.dotRadius * (1 + (BloubDecor.dotPeak - 1) * k),
                            opacity: 0.55 + 0.45 * k
                        )
                    }
                )
            }
        ),

        BloubStateDef(
            id: .wink,
            duration: 1.6,
            minDuration: nil,
            morph: 0.3,
            blinkIn: true,
            usesBaseBody: true,
            usesBaseFace: false,
            pose: { _ in
                BloubPose(
                    gaze: BloubGaze(yaw: -5.37, pitch: 4.55, roll: 6.7),
                    split: 16.25,
                    // The shut eye is not the open one squashed: it is a
                    // horizontal dash WIDER than the open eye (0.447 vs 0.236).
                    eyes: (
                        BloubEyeConfig(width: 0.236, height: 0.464),
                        BloubEyeConfig(width: 0.447, height: 0.089)
                    )
                )
            }
        ),

        BloubStateDef(
            id: .wide,
            duration: 1.8,
            minDuration: nil,
            morph: 0.55,
            blinkIn: true,
            usesBaseBody: true,
            usesBaseFace: false,
            pose: { _ in
                BloubPose(
                    gaze: BloubGaze(yaw: 6.92, pitch: -21.96, roll: 11.6),
                    split: 18.43,
                    eyes: pair(0.356, 0.875)
                )
            }
        ),

        BloubStateDef(
            id: .alert,
            duration: 2.4,
            // the "!" is back in place at 1.6 + 0.4
            minDuration: 2,
            morph: 0.45,
            blinkIn: false,
            usesBaseBody: false,
            usesBaseFace: false,
            pose: { t in
                // Measured run: -0.087 → +0.732 in 1.5 s, ease-in-out, micro
                // overshoot.
                let p = BloubMath.clamp(t / 1.5)
                let travel = BloubMath.easeInOutCubic(p) * 0.82 - 0.087
                let back = t > 1.6 ? BloubMath.clamp((t - 1.6) / 0.4) : 0
                let x = travel * (1 - back) + 0.1 * back
                // Secondary 2.5 Hz buzz, bar and dot in antiphase.
                let buzz = sin(t * 2.5 * bloubTau) * 0.005
                let tilt = 17.7 * .pi / 180
                return BloubPose(
                    silhouette: barItalic(rotation: tilt, centerX: x, centerY: -0.325 - buzz),
                    eyeAlpha: 0,
                    dots: [
                        BloubDot(
                            // the dot follows the glyph's axis, 0.580 from the
                            // bar's centre
                            x: x - sin(tilt) * 0.58,
                            y: -0.325 + cos(tilt) * 0.58 + buzz * 2.8,
                            radius: 0.118,
                            opacity: 1,
                            polygon: teardrop,
                            rotation: tilt * 180 / .pi
                        )
                    ]
                )
            }
        ),

        BloubStateDef(
            id: .notify,
            duration: 2.2,
            minDuration: nil,
            morph: 0.5,
            blinkIn: true,
            usesBaseBody: true,
            usesBaseFace: false,
            pose: { t in
                // The blue dot's pop: peaks at +14 % around 0.3 s, then settles.
                // This is the engine's one and only spring, and it is local.
                let p = BloubMath.clamp(t / 0.45)
                let pop = 1 + (BloubDecor.notifyPop - 1) * sin(p * .pi) * (1 - p * 0.35)
                let r = BloubDecor.notifyRadius * (p < 1 ? pop : 1)
                let a = BloubDecor.notifyAngle * .pi / 180
                return BloubPose(
                    // the gaze goes the opposite way from the pastille
                    gaze: BloubGaze(yaw: -21.94, pitch: -5.82, roll: -12.2),
                    split: 18.89,
                    eyes: pair(0.505, 0.498),
                    notify: (
                        x: cos(a) * BloubDecor.notifyDistance,
                        y: sin(a) * BloubDecor.notifyDistance,
                        radius: r,
                        notch: r + BloubDecor.notifyMargin
                    )
                )
            }
        ),

        BloubStateDef(
            id: .exclaim,
            duration: 2,
            minDuration: nil,
            morph: 0.45,
            blinkIn: false,
            usesBaseBody: false,
            usesBaseFace: false,
            pose: { _ in
                BloubPose(
                    silhouette: barUpright(),
                    eyeAlpha: 0,
                    dots: [BloubDot(x: -0.012, y: 0.526, radius: 0.113, opacity: 1)]
                )
            }
        ),

        BloubStateDef(
            id: .sleep,
            duration: 2.4,
            minDuration: nil,
            morph: 0.5,
            blinkIn: false,
            usesBaseBody: false,
            usesBaseFace: false,
            pose: { t in
                BloubPose(
                    // Measured vertical bounce: ±0.19 about +0.11, period 0.6 s.
                    silhouette: BloubShape.circle(
                        0.1585,
                        centerY: 0.11 + sin(t * (bloubTau / 0.6)) * 0.19
                    ),
                    eyeAlpha: 0
                )
            }
        ),

        BloubStateDef(
            id: .egg,
            duration: 1.8,
            minDuration: nil,
            morph: 0.4,
            blinkIn: true,
            usesBaseBody: false,
            usesBaseFace: false,
            pose: { _ in
                BloubPose(
                    silhouette: BloubShape.silhouette(.egg),
                    gaze: BloubGaze(yaw: 19.97, pitch: 26.01, roll: -17.1),
                    // the eyes close up as the body does
                    split: 11.07,
                    eyes: pair(0.164, 0.385)
                )
            }
        ),

        BloubStateDef(
            id: .hexagon,
            duration: 1.6,
            minDuration: nil,
            morph: 0.4,
            blinkIn: true,
            usesBaseBody: false,
            usesBaseFace: false,
            pose: { _ in
                BloubPose(
                    silhouette: BloubShape.silhouette(.hexagon),
                    gaze: BloubGaze(yaw: 23.11, pitch: 24.42, roll: -13.3),
                    split: 13.37,
                    eyes: pair(0.177, 0.411)
                )
            }
        ),

        BloubStateDef(
            id: .play,
            duration: 2,
            minDuration: nil,
            morph: 0.5,
            blinkIn: true,
            usesBaseBody: false,
            usesBaseFace: false,
            pose: { t in
                // The triangle stays almost still while the bouquet crosses it.
                let fade = BloubMath.clamp(t / 0.35) * BloubMath.clamp((2.2 - t) / 0.5)
                return BloubPose(
                    silhouette: spinningTriangle(0),
                    gaze: BloubGaze(yaw: 12, pitch: -8, roll: -6),
                    split: 15,
                    eyes: pair(0.18, 0.34),
                    // the bouquet sweeps right to left over the triangle
                    arcs: BloubDecor.swoosh.enumerated().map { index, seed in
                        var moved = seed
                        moved.centerX = 0.45 - t * 0.42
                        return BloubArcSpec(id: "sw\(index)", seed: moved, time: t, opacity: fade)
                    }
                )
            }
        ),

        BloubStateDef(
            id: .orbit,
            duration: 3.4,
            // the body has finished relaxing from triangle to ball at 1.6 + 0.9
            minDuration: 2.5,
            morph: 0.6,
            blinkIn: false,
            usesBaseBody: false,
            usesBaseFace: false,
            pose: { t in
                // Measured rotation: a 0.35 s ramp then 1.25 turns/s,
                // anticlockwise.
                let ramp = BloubMath.easeInOutCubic(BloubMath.clamp(t / 0.35))
                let rot = -bloubTau * 1.25 * t * ramp
                // The body relaxes from the triangle to the ball during the orbit.
                let back = BloubMath.easeInOutCubic(BloubMath.clamp((t - 1.6) / 0.9))
                let tri = spinningTriangle(rot)
                let ball = BloubShape.circle(1, rotation: rot)
                let silhouette = BloubSilhouette(
                    radii: tri.radii.enumerated().map { i, r in r + (ball.radii[i] - r) * back },
                    rotation: rot,
                    centerX: tri.centerX * (1 - back),
                    centerY: tri.centerY * (1 - back)
                )
                let fade = BloubMath.clamp(t / 0.8) * BloubMath.clamp((3.6 - t) / 0.9)
                return BloubPose(
                    silhouette: silhouette,
                    // the eyes race around the sphere ~3× faster than the outline
                    gaze: BloubGaze(
                        yaw: BloubFace.restGaze.yaw + sin(t * 6.5) * 65 * (1 - back),
                        pitch: -4 + back * 32,
                        roll: -13
                    ),
                    eyes: pair(0.18, 0.34 + back * 0.07),
                    // the rings come in one by one over 0.8 s
                    arcs: BloubDecor.rings.enumerated().map { index, seed in
                        BloubArcSpec(
                            id: "rg\(index)",
                            seed: seed,
                            time: t,
                            opacity: fade
                                * BloubMath.clamp((t - Double(index) * 0.13) / 0.3)
                        )
                    }
                )
            }
        ),

        // Entry into the settings view.
        //
        // The ONLY state not measured off the video: it is chosen, like the
        // interface's ink colour. It borrows `orbit`'s vocabulary — the same
        // rings, with their measured parameters — but cuts short: 1 s instead
        // of 3.4, half the rings, and no triangle.
        //
        // Both flags being true is the whole point of this state: `usesBaseBody`
        // lets the chosen shape replace the body, so a pebble or a droplet
        // morphs towards the ball instead of jumping; `usesBaseFace` makes it
        // wear the resting face, so gaze tracking applies from its first frame.
        //
        // Deliberately NOT in ``sequence``: it is not a catalogue animation.
        BloubStateDef(
            id: .swirl,
            // slightly more than the gaze's turn: the eyes must be settled on
            // the left before the rings fade out
            duration: 1.3,
            minDuration: 1.3,
            morph: 0.3,
            // the shape morph is hidden by a blink, as everywhere else
            blinkIn: true,
            usesBaseBody: true,
            usesBaseFace: true,
            pose: { t in
                BloubPose(
                    // three rings out of `orbit`'s six: half the bouquet is
                    // enough to recognise it, and that is as many arcs fewer
                    // to rasterise per frame
                    arcs: BloubDecor.rings.prefix(3).enumerated().map { index, seed in
                        BloubArcSpec(
                            id: "sw\(index)",
                            seed: seed,
                            time: t,
                            // they enter one after another then fade before the
                            // block ends, so the return to rest starts on an
                            // already clean frame
                            opacity: BloubMath.clamp((t - Double(index) * 0.06) / 0.14)
                                * BloubMath.clamp((1.22 - t) / 0.34)
                        )
                    }
                )
            }
        ),

        BloubStateDef(
            id: .burst,
            duration: 2.6,
            // the body is recomposed at 1.7 + 0.7
            minDuration: 2.4,
            morph: 0.4,
            blinkIn: false,
            usesBaseBody: false,
            usesBaseFace: false,
            pose: { t in
                // Measured collapse: 1.0 → 0.166 in 0.7 s, ease-out, no bounce.
                let collapse = 1 - 0.834 * BloubMath.easeOutQuint(BloubMath.clamp(t / 0.7))
                let regrow = BloubMath.easeOutQuint(BloubMath.clamp((t - 1.7) / 0.7))
                return BloubPose(
                    silhouette: BloubShape.circle(collapse + (1 - collapse) * regrow),
                    eyeAlpha: BloubMath.clamp((t - 1.85) / 0.4),
                    dots: BloubDecor.particles(t, scale: 1),
                    dotsBehind: true
                )
            }
        ),

        BloubStateDef(
            id: .comet,
            duration: 2.4,
            // the dot recomposes at 1.85 + 0.6 = 2.45, i.e. 0.05 s after the
            // video's cut: that remainder finishes during the next fade, as in
            // the reference. So we do not go below the measured duration.
            minDuration: 2.4,
            morph: 0.45,
            blinkIn: false,
            usesBaseBody: false,
            usesBaseFace: false,
            pose: { t in
                let collapse = 1
                    - (1 - BloubDecor.cometDot)
                    * BloubMath.easeOutQuint(BloubMath.clamp(t / 0.55))
                let regrow = BloubMath.easeOutQuint(BloubMath.clamp((t - 1.85) / 0.6))
                let fade = BloubMath.clamp((t - 0.15) / 0.25)
                    * BloubMath.clamp((1.95 - t) / 0.3)
                return BloubPose(
                    // The dot drifts 0.035 down then comes back (measured wobble).
                    silhouette: BloubShape.circle(
                        collapse + (1 - collapse) * regrow,
                        centerY: sin(BloubMath.clamp(t / 1.7) * .pi) * 0.035
                    ),
                    eyeAlpha: BloubMath.clamp((t - 2) / 0.35),
                    arcs: BloubDecor.cometRibbons.enumerated().map { index, seed in
                        BloubArcSpec(id: "cm\(index)", seed: seed, time: t, opacity: fade)
                    }
                )
            }
        )
    ]

    public static let byID: [BloubStateID: BloubStateDef] = Dictionary(
        uniqueKeysWithValues: all.map { ($0.id, $0) }
    )

    public static func state(_ id: BloubStateID) -> BloubStateDef {
        byID[id] ?? all[0]
    }

    /// The date, in local time, at which each state reads most clearly: the
    /// pose the thumbnails and the state board show.
    public static let poseTime: [BloubStateID: Double] = [
        .idle: 1,
        .thinking: 1.1,
        .wink: 0.8,
        .wide: 0.8,
        .alert: 0.75,
        .notify: 0.9,
        .exclaim: 0.8,
        .sleep: 0.45,
        .egg: 0.8,
        .hexagon: 0.8,
        .play: 0.9,
        .orbit: 1.2,
        .swirl: 0.5,
        .burst: 0.45,
        .comet: 1.15
    ]

    /// The reading order of the full sequence, traced on the reference video.
    public static let sequence: [BloubStateID] = [
        .idle, .thinking, .wink, .wide, .alert, .notify, .exclaim,
        .sleep, .egg, .hexagon, .play, .orbit, .burst, .comet
    ]

    /// The floor every montage block shares, **derived** from the catalogue
    /// rather than written by hand. bloub had it hard-coded at 0.6, which only
    /// worked because 0.6 happened to be the longest `morph` in the catalogue.
    /// Adding a state that morphs in 0.8 s would have made the editor stutter
    /// with no test complaining.
    public static let minimumBlock: Double = all.map(\.morph).max() ?? 0.6

    /// A block's minimum length: the engine floor, or the state's own measured
    /// resolve time.
    public static func minimumDuration(of id: BloubStateID) -> Double {
        max(minimumBlock, byID[id]?.minDuration ?? minimumBlock)
    }
}
