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

    @inlinable
    public static func easeInOutCubic(_ t: Double) -> Double {
        t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2
    }

    @inlinable
    public static func easeOutQuint(_ t: Double) -> Double { 1 - pow(1 - t, 5) }

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
