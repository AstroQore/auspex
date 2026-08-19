// Ported from bloub — https://github.com/jeremy-prt/bloub
// MIT License, © 2026 Jérémy Perret. See THIRD_PARTY_NOTICES.md.
//
// bloub's own rule travels with the port: **the numeric constants are
// measurements taken off the reference video, not settings.** Gaze angles, eye
// sizes, radii, timings — all of it comes from frame-by-frame analysis. Do not
// round them, do not simplify them, do not replace them with values that look
// tidier. Doing so breaks the resemblance, which is the only success criterion
// this file has.

import Foundation

/// Two pi, spelled once.
public let bloubTau = Double.pi * 2

/// Small numeric helpers, ported one for one from `src/bot/math.ts`.
public enum BloubMath {
    @inlinable
    public static func clamp(_ v: Double, _ lo: Double = 0, _ hi: Double = 1) -> Double {
        v < lo ? lo : (v > hi ? hi : v)
    }

    @inlinable
    public static func lerp(_ a: Double, _ b: Double, _ t: Double) -> Double {
        a + (b - a) * t
    }

    // MARK: Easings

    /// The transition curves measured on the video.
    ///
    /// They are exponential ease-outs and **the body never overshoots**. The
    /// only spring effect in the whole engine is local and written into the
    /// state that needs it — the notification pastille's +14 % pop. There is
    /// deliberately no spring engine here; a new bouncing effect belongs in
    /// the state concerned.
    @inlinable
    public static func easeOutCubic(_ t: Double) -> Double { 1 - pow(1 - t, 3) }

    /// The mirror of ``easeOutCubic``: leaves at zero speed and arrives at
    /// full speed. What a lid does on its way down.
    @inlinable
    public static func easeInCubic(_ t: Double) -> Double { t * t * t }

    @inlinable
    public static func easeInOutCubic(_ t: Double) -> Double {
        t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2
    }

    @inlinable
    public static func easeOutQuint(_ t: Double) -> Double { 1 - pow(1 - t, 5) }

    /// The classic S: zero slope at both ends, so anything driven by it leaves
    /// and rejoins its neighbours with no visible corner.
    ///
    /// This is what replaced every bare `clamp(t / span)` in the state
    /// catalogue. Those linear ramps were invisible individually and audible in
    /// aggregate: an opacity that starts at a constant rate and stops dead is
    /// the difference between a decor that breathes in and one that is switched
    /// on.
    @inlinable
    public static func smoothstep(_ t: Double) -> Double {
        let u = clamp(t)
        return u * u * (3 - 2 * u)
    }

    /// A smooth 0 → 1 ramp that begins at `start` and takes `span` seconds.
    @inlinable
    public static func rampUp(_ t: Double, _ start: Double, _ span: Double) -> Double {
        smoothstep((t - start) / span)
    }

    /// A smooth 1 → 0 ramp that is finished at `end`, having taken `span`
    /// seconds to get there.
    @inlinable
    public static func rampDown(_ t: Double, _ end: Double, _ span: Double) -> Double {
        smoothstep((end - t) / span)
    }

    /// Distance covered by `t` seconds of a speed that eases from 0 to 1 over
    /// `span` — that is, ∫₀ᵗ smoothstep(s / span) ds, in closed form.
    ///
    /// Spinning something up by multiplying its *angle* by a ramp is the
    /// obvious mistake and it lurches: with θ = ω·t·ramp(t) the angular speed
    /// is ω(ramp + t·ramp′), which peaks at twice ω half-way through the ramp
    /// and then falls back. Integrating the ramp instead gives a speed that
    /// rises monotonically to ω and stays there, which is what a wheel does.
    ///
    /// Closed form and not an accumulator on purpose: the engine is a pure
    /// function of time, and an integrator would be state.
    @inlinable
    public static func easedTravel(_ t: Double, span: Double) -> Double {
        if t <= 0 { return 0 }
        if t >= span { return t - span / 2 }
        let u = t / span
        return span * (u * u * u - u * u * u * u / 2)
    }

    // MARK: Noise

    /// Periodic 1-D noise: loops seamlessly over `period`, which is what makes
    /// the gaze drift a pure function of time rather than a random walk.
    public static func loopNoise(_ t: Double, _ period: Double, _ seed: Double = 0) -> Double {
        let p = (t / period) * bloubTau
        return 0.55 * sin(p + seed)
            + 0.3 * sin(2 * p + seed * 1.7 + 1.1)
            + 0.15 * sin(3 * p + seed * 2.3 + 2.4)
    }
}

/// mulberry32, the deterministic PRNG bloub seeds its pre-drawn schedules with.
///
/// Ported on `UInt32` wrapping arithmetic rather than on `Int`, because that is
/// exactly what JavaScript's `Math.imul` and `>>>` do: every intermediate is
/// taken modulo 2³². A port that let the products widen would produce a
/// different blink schedule and different ring seeds, and the tables built from
/// this generator are part of the measured look.
public struct BloubRNG: Sendable {
    private var state: UInt32

    public init(seed: UInt32) { state = seed }

    public mutating func next() -> Double {
        state = state &+ 0x6d2b_79f5
        var t = (state ^ (state >> 15)) &* (1 | state)
        t = (t &+ ((t ^ (t >> 7)) &* (61 | t))) ^ t
        return Double(t ^ (t >> 14)) / 4_294_967_296
    }

    /// One value in [0, 1) for an (index, salt, seed) triple.
    ///
    /// A hash and not a stream, because the caller has to be able to ask for
    /// segment 412 without having drawn the 411 before it. The resting gaze's
    /// schedule is *regenerated* from the seed on every sample rather than
    /// remembered — that is what lets a per-avatar random walk stay a pure
    /// function of time.
    ///
    /// The first draw is discarded: mulberry32 seeded with two nearby values
    /// returns two nearby first outputs, and adjacent segments would drift
    /// towards each other instead of being independent.
    public static func value(index: Int, salt: UInt32, seed: UInt32) -> Double {
        var rng = BloubRNG(
            seed: seed
                &+ salt &* 0x9e37_79b9
                &+ UInt32(truncatingIfNeeded: index) &* 0x85eb_ca6b
        )
        _ = rng.next()
        return rng.next()
    }
}

/// A colour in linear 0…1 components, as the decor's hue wheel produces them.
///
/// Not a `Color`: `AuspexCore` is framework-free by construction, and the
/// engine has to stay renderable from a test with no window.
public struct BloubRGB: Sendable, Hashable {
    public var red: Double
    public var green: Double
    public var blue: Double

    public init(red: Double, green: Double, blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    /// Parses `#rrggbb`. Returns black for anything else — the callers are
    /// harness accents resolved at compile time, not user input.
    public init(hex: String) {
        var value = hex
        if value.hasPrefix("#") { value.removeFirst() }
        let n = UInt32(value, radix: 16) ?? 0
        self.init(
            red: Double((n >> 16) & 0xFF) / 255,
            green: Double((n >> 8) & 0xFF) / 255,
            blue: Double(n & 0xFF) / 255
        )
    }

    /// Mixes towards `other`. Used for the burst particles' depth haze, which
    /// fades a particle into the page behind the body.
    public func mixed(towards other: BloubRGB, _ t: Double) -> BloubRGB {
        BloubRGB(
            red: BloubMath.lerp(red, other.red, t),
            green: BloubMath.lerp(green, other.green, t),
            blue: BloubMath.lerp(blue, other.blue, t)
        )
    }
}
