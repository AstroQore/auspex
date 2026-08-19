// Ported from bloub — https://github.com/jeremy-prt/bloub
// MIT License, © 2026 Jérémy Perret. See THIRD_PARTY_NOTICES.md.
//
// Deviation, on purpose: the *timing* of the transitions in this file is
// Auspex's, not bloub's — a visible eased morph rather than a change hidden in
// a blink, and no straight lines left in the catalogue. Every pose, silhouette,
// amplitude and gaze angle is still the measurement. See BloubTransition.swift
// and THIRD_PARTY_NOTICES.md.

import Foundation

/// A dot the engine draws beside the body: the thinking dots, the "!"'s dot,
/// the burst particles.
public struct BloubDot: Sendable, Hashable {
    public var x: Double
    public var y: Double
    public var radius: Double
    public var opacity: Double
    /// An explicit colour. When absent the renderer uses the body's.
    public var color: BloubRGB?
    /// Depth haze: 0 = blended into the page behind, 1 = the body's colour at
    /// full strength. Mixed at render time, which is the only place the chosen
    /// colour is known.
    public var depth: Double?
    /// A non-circular shape, in ball-radius units, centred on the origin — the
    /// leaning "!"'s dot is a **teardrop**, not a disc. When present `radius`
    /// is no longer used for the outline.
    public var polygon: [BloubPoint]?
    /// Rotation applied to `polygon`, in degrees.
    public var rotation: Double

    public init(
        x: Double,
        y: Double,
        radius: Double,
        opacity: Double,
        color: BloubRGB? = nil,
        depth: Double? = nil,
        polygon: [BloubPoint]? = nil,
        rotation: Double = 0
    ) {
        self.x = x
        self.y = y
        self.radius = radius
        self.opacity = opacity
        self.color = color
        self.depth = depth
        self.polygon = polygon
        self.rotation = rotation
    }
}

/// What a state declares for an orbit ring or a comet ribbon. The geometry
/// stays in ball-radius units; only the engine, which knows the viewBox scale,
/// rasterises it. Without that split the states would have to know the viewBox.
public struct BloubArcSeed: Sendable, Hashable {
    /// Semi-major axis, in ball-radius units.
    public var a: Double
    /// Flattening b/a: measured ≤ 0.45, the orbit planes are seen edge-on.
    public var k: Double
    /// The major axis's tilt on screen, radians.
    public var tilt: Double
    /// Turns per second.
    public var speed: Double
    public var phase: Double
    /// Fraction of the turn actually drawn.
    public var sweep: Double
    public var hue: Double
    public var hueSpan: Double
    public var width: Double
    public var centerX: Double
    public var centerY: Double
}

/// A ring or ribbon a state asked for, at a given time and opacity.
public struct BloubArcSpec: Sendable, Hashable {
    public var id: String
    public var seed: BloubArcSeed
    public var time: Double
    public var opacity: Double
}

/// A rasterised arc: the part in front of the body and the part behind it.
public struct BloubArc: Sendable, Hashable {
    public var id: String
    /// Sub-polylines in front of the body.
    public var front: [[BloubPoint]]
    /// Sub-polylines behind it — drawn first, so the silhouette occludes them.
    public var back: [[BloubPoint]]
    public var width: Double
    public var opacity: Double
    /// The hue gradient along the stroke.
    public var gradientStart: BloubPoint
    public var gradientEnd: BloubPoint
    public var gradientStops: [BloubRGB]
}

/// Rings, swoosh, dots, particles, comet ribbons, notification pastille.
public enum BloubDecor {
    // MARK: Colours

    /// The rings are not flat colours: the video shows a full hue wheel at
    /// constant lightness, with a gradient along each stroke. Measured:
    /// S 45–62 %, L 50–67 %.
    static func wheel(_ hue: Double, s: Double = 0.55, l: Double = 0.62) -> BloubRGB {
        let h = hue.truncatingRemainder(dividingBy: 360) < 0
            ? hue.truncatingRemainder(dividingBy: 360) + 360
            : hue.truncatingRemainder(dividingBy: 360)
        let c = (1 - abs(2 * l - 1)) * s
        let x = c * (1 - abs((h / 60).truncatingRemainder(dividingBy: 2) - 1))
        let m = l - c / 2
        let rgb: (Double, Double, Double)
        switch h {
        case ..<60: rgb = (c, x, 0)
        case ..<120: rgb = (x, c, 0)
        case ..<180: rgb = (0, c, x)
        case ..<240: rgb = (0, x, c)
        case ..<300: rgb = (x, 0, c)
        default: rgb = (c, 0, x)
        }
        return BloubRGB(red: rgb.0 + m, green: rgb.1 + m, blue: rgb.2 + m)
    }

    // MARK: 3-D elliptical arc

    /// Projects a tilted 3-D circle orthographically.
    ///
    /// The circle lives in the plane spanned by u (in the screen) and v (which
    /// dives into depth). The z component splits the arc in two: the back half
    /// is drawn before the body, so the body occludes it. That real depth sort
    /// is what makes the rings read as orbits rather than as flat drawing.
    public static func render(
        _ seed: BloubArcSeed,
        time t: Double,
        scale: Double,
        id: String,
        opacity: Double = 1
    ) -> BloubArc {
        let spin = seed.phase + t * seed.speed * bloubTau
        let cu = cos(seed.tilt)
        let su = sin(seed.tilt)
        let kz = max(0, 1 - seed.k * seed.k).squareRoot()

        let n = 64
        let span = seed.sweep * bloubTau
        var front: [[BloubPoint]] = []
        var back: [[BloubPoint]] = []
        var previouslyBehind: Bool?

        for i in 0...n {
            let th = spin + Double(i) / Double(n) * span
            let ct = cos(th)
            let st = sin(th)
            // u = (cos tilt, sin tilt, 0) ; v = (-sin tilt * k, cos tilt * k, kz)
            let x = seed.a * (ct * cu + st * -su * seed.k) + seed.centerX
            let y = seed.a * (ct * su + st * cu * seed.k) + seed.centerY
            let z = seed.a * st * kz

            let behind = z < 0
            let point = BloubPoint(x: x * scale, y: y * scale)
            let starts = behind != previouslyBehind
            if behind {
                if starts { back.append([point]) } else { back[back.count - 1].append(point) }
            } else {
                if starts { front.append([point]) } else { front[front.count - 1].append(point) }
            }
            previouslyBehind = behind
        }

        let gx = cos(seed.tilt) * seed.a * scale
        let gy = sin(seed.tilt) * seed.a * scale
        return BloubArc(
            id: id,
            front: front,
            back: back,
            width: seed.width * scale,
            opacity: opacity,
            gradientStart: BloubPoint(x: seed.centerX * scale - gx, y: seed.centerY * scale - gy),
            gradientEnd: BloubPoint(x: seed.centerX * scale + gx, y: seed.centerY * scale + gy),
            gradientStops: [
                wheel(seed.hue),
                wheel(seed.hue + seed.hueSpan * 0.5),
                wheel(seed.hue + seed.hueSpan)
            ]
        )
    }

    // MARK: Rings

    /// 6 rings, semi-major axis 1.30–1.40 (so distinctly bigger than the ball),
    /// flattening always ≤ 0.45, thickness 0.055, ≈ 3.3 turns per second.
    ///
    /// The generator is consumed in declaration order — that order is part of
    /// the measured look, so the fields below must be drawn in exactly the
    /// sequence bloub's object literal evaluates them.
    public static let rings: [BloubArcSeed] = {
        var rng = BloubRNG(seed: 0xa11ce)
        var out: [BloubArcSeed] = []
        for i in 0..<6 {
            let a: Double = 1.3 + rng.next() * 0.1
            let k: Double = 0.05 + rng.next() * 0.4
            let tilt: Double = Double(i) / 6 * .pi + rng.next() * 0.5
            let speed: Double = 3 + rng.next() * 0.7
            let phase: Double = rng.next() * bloubTau
            let sweep: Double = 0.6 + rng.next() * 0.25
            let hue: Double = Double(i) * 360 / 6 + rng.next() * 30
            let hueSpan: Double = 60 + rng.next() * 60
            let width: Double = 0.05 + rng.next() * 0.012
            out.append(
                BloubArcSeed(
                    a: a,
                    k: k,
                    tilt: tilt,
                    speed: speed,
                    phase: phase,
                    sweep: sweep,
                    hue: hue,
                    hueSpan: hueSpan,
                    width: width,
                    centerX: 0,
                    centerY: 0.1
                )
            )
        }
        return out
    }()

    /// The nested bouquet that sweeps across the triangle just before the
    /// orbits. Seen almost edge-on (hence the hairpin look), rmax 1.37.
    public static let swoosh: [BloubArcSeed] = (0..<4).map { index in
        let i = Double(index)
        return BloubArcSeed(
            a: 0.78 + i * 0.2,
            k: 0.05 + i * 0.02,
            tilt: -0.62 + i * 0.05,
            speed: 0.3,
            phase: 0.06 * i,
            sweep: 0.4,
            hue: 95 + i * 62,
            hueSpan: 100,
            width: 0.05,
            centerX: 0,
            centerY: -0.12
        )
    }

    // MARK: The three dots

    /// Measured x: -0.557 / -0.013 / +0.532, y = 0.
    public static let dotX: [Double] = [-0.557, -0.013, 0.532]
    public static let dotRadius = 0.165
    public static let dotPeak = 1.25

    // MARK: Burst particles

    private static let particleSeeds: [(birth: Double, angle: Double, rho: Double)] = {
        var rng = BloubRNG(seed: 0xbeef)
        return (0..<5).map { i in
            (birth: Double(i) * 0.2, angle: rng.next() * bloubTau, rho: 0.58 + rng.next() * 0.18)
        }
    }()

    /// 5 particles, a new one every 0.2 s, lifetime 0.55 s.
    ///
    /// They do not fly off in a straight line: they spiral **inwards** (radius
    /// ×0.75 per frame) while growing, and pass behind the core where they are
    /// swallowed. The inward run keeps bloub's exponential, which decelerates
    /// on its own; what is eased here is everything that was a straight line.
    ///
    /// The sweep is the visible one: bloub turned each particle at a flat
    /// 100°/s, so it appeared already at full speed and stopped mid-turn when
    /// it died. It now covers the same 62° of arc, easing in and out of it, so
    /// a particle drifts out of the core rather than being flicked out of it.
    public static func particles(_ t: Double, scale: Double) -> [BloubDot] {
        /// Lifetime, and the total sweep it used to cover at 100°/s.
        let life = 0.62
        let sweep = 100 * life * .pi / 180

        var out: [BloubDot] = []
        for p in particleSeeds {
            let u = t - p.birth
            if u < 0 || u > life { continue }
            let rho = p.rho * pow(0.75, u * 10)
            let a = p.angle + BloubMath.easeInOutCubic(BloubMath.clamp(u / life)) * sweep
            out.append(
                BloubDot(
                    x: cos(a) * rho * scale,
                    y: sin(a) * rho * scale,
                    radius: (0.04 + 0.028 * BloubMath.smoothstep(u / 0.55)) * scale,
                    opacity: BloubMath.rampUp(u, 0, 0.06) * BloubMath.rampDown(u, life, 0.08),
                    depth: BloubMath.clamp(1 - rho / 0.8)
                )
            )
        }
        return out
    }

    // MARK: Comet

    /// Against intuition, the dot does **not** cross the screen: it stays at
    /// the centre and the trail orbits it. Ellipse a = 0.85, b = 0.15, major
    /// axis tilted +34°, 4 ribbons, ≈ 210°/s.
    public static let cometRibbons: [BloubArcSeed] = {
        var rng = BloubRNG(seed: 0xc0e7)
        return (0..<4).map { i in
            let d = Double(i) - 1.5
            // Field order matters: `phase` draws before `hue`, exactly as the
            // source object literal evaluates them.
            let phase = -Double(i) * 0.045 + rng.next() * 0.012
            let hue = Double(i) * 85 + rng.next() * 20
            return BloubArcSeed(
                a: 0.85 * (1 + d * 0.03),
                // same flattening to within ±5 %: the ribbons form a tight beam
                k: (0.15 / 0.85) * (1 + d * 0.16),
                tilt: 34 * .pi / 180 + d * 0.035,
                speed: 210.0 / 360.0,
                phase: phase,
                sweep: 0.34,
                hue: hue,
                hueSpan: 80,
                width: 0.095,
                centerX: 0,
                centerY: 0
            )
        }
    }()

    /// Radius of the comet's dot, measured at 0.129.
    public static let cometDot = 0.129

    // MARK: Notification pastille

    /// Blue sampled at the pixel.
    public static let notifyBlue = BloubRGB(hex: "#2496e8")
    /// The pastille sits exactly on the circumference, at -42°.
    public static let notifyAngle = -42.0
    public static let notifyDistance = 1.003
    /// Resting radius; the pop peaks 14 % above it.
    public static let notifyRadius = 0.15
    public static let notifyPop = 1.14
    /// The notch is a disc concentric with the pastille, subtracted from the
    /// body. The margin is constant (0.054 R) and follows the body's scale.
    public static let notifyMargin = 0.054
}
