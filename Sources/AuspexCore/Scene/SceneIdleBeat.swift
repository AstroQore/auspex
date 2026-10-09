import Foundation

/// The rhythm of the office's idle motion: when the room stirs, and who
/// stirs with it.
///
/// ## Why idle motion is a beat and not a loop
///
/// A person with nothing to do still breathes — the drawn characters have a
/// two-frame idle, a dozing session's `z` drifts up, a note in the garden
/// lifts and settles. Run as loops, that is a room that is never still, and a
/// room that is never still is a SpriteKit view that never stops drawing: a
/// garden of finished sessions cost as much to leave on screen as a floor of
/// busy ones. So idle motion happens in *stirs*: every few seconds the room
/// stirs once, about three in five of the idle people on screen play their
/// motion once each, a little out of step with one another, and then the
/// picture is still until the next stir — and a still picture is one the
/// view does not draw at all. Working motion — typing, thinking, a hand up —
/// is a signal, not ambience, and keeps its loops.
///
/// Everything here is a pure function of an id and a stir's number, so the
/// rhythm is the same on every run and can be tested without a clock.
public enum SceneIdleBeat {
    /// The shortest gap between two stirs, in seconds.
    public static let shortestGap: TimeInterval = 3
    /// The longest.
    public static let longestGap: TimeInterval = 8
    /// The longest anybody waits after a stir before joining in. Enough that a
    /// garden does not bob in unison, short enough that one stir still reads
    /// as one moment.
    public static let longestDelay: TimeInterval = 0.6

    /// How long after stir number `round` the next one comes.
    public static func gap(after round: UInt64) -> TimeInterval {
        shortestGap + (longestGap - shortestGap) * unit(mix(round, 0x5EED_0F57))
    }

    /// Whether the place with `id` stirs in stir number `round`. About three
    /// rounds in five, and never the same three for two neighbours.
    public static func joins(_ id: String, round: UInt64) -> Bool {
        mix(hash(id), round) % 5 < 3
    }

    /// How long after stir number `round` the place with `id` starts to move.
    public static func delay(_ id: String, round: UInt64) -> TimeInterval {
        longestDelay * unit(mix(hash(id) ^ 0xA5A5_A5A5, round))
    }

    /// A value in `0..<1` from 64 well-mixed bits.
    private static func unit(_ bits: UInt64) -> Double {
        Double(bits >> 11) / Double(UInt64(1) << 53)
    }

    /// SplitMix64's finaliser over two words: cheap, and every input bit
    /// reaches every output bit, which is what stops neighbouring ids and
    /// consecutive rounds from moving together.
    private static func mix(_ a: UInt64, _ b: UInt64) -> UInt64 {
        var z = a &+ b &* 0x9E37_79B9_7F4A_7C15
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// FNV-1a. Stable across launches, unlike `Hasher`, so a picture of the
    /// demo at one instant is the same picture every time.
    private static func hash(_ id: String) -> UInt64 {
        var value: UInt64 = 0xCBF2_9CE4_8422_2325
        for byte in id.utf8 {
            value ^= UInt64(byte)
            value = value &* 0x100_0000_01B3
        }
        return value
    }
}
