import AgentSessionLive
import Foundation

/// Token counts, at the precision a context gauge reads at.
///
/// Not ``TokenFormat``, and the difference is the point. `TokenFormat` is for a
/// *ledger* — five characters, three numbers side by side, and 899k is as good
/// an answer as 898.8k when the column beside it says how many tools ran. A
/// gauge is one number a person is watching approach a wall, and the tenth of
/// a percent it drops is the difference between "nearly full" and "about to
/// compact".
///
/// One rule: one decimal place, and a trailing `.0` dropped. That is what makes
/// `898.8k / 1M` read as a fraction of a window rather than as two unrelated
/// magnitudes — 1M is exactly a million and saying `1.0M` implies a rounding
/// that did not happen.
public enum ContextFormat {
    /// `843`, `12.9k`, `898.8k`, `200k`, `1M`.
    public static func tokens(_ value: Int) -> String {
        let magnitude = abs(value)
        if magnitude < 1_000 { return "\(value)" }
        if magnitude < 1_000_000 { return decimal(Double(value) / 1_000, unit: "k") }
        return decimal(Double(value) / 1_000_000, unit: "M")
    }

    /// `90 %`. Rounded to a whole percent: the gauge is a fill, and a tenth of
    /// a percent of a million tokens is not a fact anybody acts on.
    public static func percent(_ fraction: Double) -> String {
        "\(Int((fraction * 100).rounded())) %"
    }

    /// `898.8k / 1M · 90 %`, or `898.8k` when nothing said how big the window
    /// is. Never a denominator this app invented.
    public static func gauge(used: Int, window: Int?, fraction: Double?) -> String {
        guard let window else { return tokens(used) }
        var text = "\(tokens(used)) / \(tokens(window))"
        if let fraction { text += " · \(percent(fraction))" }
        return text
    }

    private static func decimal(_ value: Double, unit: String) -> String {
        let text = String(format: "%.1f", value)
        return (text.hasSuffix(".0") ? String(text.dropLast(2)) : text) + unit
    }
}

/// How full one session's context window is, reduced to what a surface draws.
///
/// A ``BoardRow`` holds one of these rather than the kit's ``ContextUsage``,
/// for the reason the row exists at all: the card compares its whole value on
/// every frame, so everything it draws is precomputed once — the label, the
/// band of the colour ramp, whether the gauge should be drawn as a measurement
/// or as an estimate.
///
/// `nil` on a row is the common case and an honest one. Cursor, AntiGravity,
/// Grok Bot, Claude Cowork and Gemini CLI write nothing to disk that answers
/// "how full is the window", and a gauge at zero would say something none of
/// them said.
public struct ContextGauge: Hashable, Sendable {
    /// Which band of the ramp the fill is in.
    ///
    /// Three, because there are three different things to do about it: nothing,
    /// notice, and finish the thought before the harness forgets it. The
    /// thresholds are where a person's options change, not where a designer
    /// liked the colour.
    public enum Level: String, Sendable, Hashable, CaseIterable {
        /// Under 70 %. Room to work; drawn in the quietest ink on the card.
        case calm
        /// 70 % to 90 %. Worth knowing before starting something long.
        case warm
        /// 90 % and over. The next long tool result compacts this session, and
        /// what it forgets is whatever it was told first.
        case critical
    }

    /// Where 'warm' begins.
    public static let warmThreshold = 0.70
    /// Where 'critical' begins.
    public static let criticalThreshold = 0.90

    /// Tokens in the window when the model was last called.
    public let used: Int
    /// The window, when the store or the model table could say.
    public let window: Int?
    /// How much of ``used`` was served from a prompt cache, when the store
    /// separated it out.
    public let cached: Int?
    /// ``used`` over ``window``, or `nil` without a window.
    public let fraction: Double?
    /// `true` when the window was looked up from the model id rather than
    /// recorded on disk — see ``ContextUsage/Source``. Drawn differently,
    /// because a reader deciding whether to trust a number has to be told
    /// which of the two it is.
    public let isDerived: Bool
    /// How many times this session has already compacted.
    public let compactions: Int
    /// When the reading was taken.
    public let at: Date

    public init(
        used: Int,
        window: Int?,
        cached: Int?,
        isDerived: Bool,
        compactions: Int,
        at: Date
    ) {
        self.used = used
        self.window = window
        self.cached = cached
        self.isDerived = isDerived
        self.compactions = compactions
        self.at = at
        self.fraction = window.flatMap { $0 > 0 ? Double(used) / Double($0) : nil }
    }

    /// The gauge for a snapshot's reading, or `nil` when it has none.
    public init?(usage: ContextUsage?, compactions: Int) {
        guard let usage else { return nil }
        self.init(
            used: usage.used,
            window: usage.window,
            cached: usage.cached,
            isDerived: usage.source == .derived,
            compactions: compactions,
            at: usage.at
        )
    }

    /// Which band the fill is in.
    ///
    /// A fill with no window is ``Level/calm``: nothing is known about how
    /// close it is to anything, and colouring an unknown as an alarm is the
    /// one reading that would make a person act on no evidence.
    public var level: Level {
        guard let fraction else { return .calm }
        if fraction >= Self.criticalThreshold { return .critical }
        if fraction >= Self.warmThreshold { return .warm }
        return .calm
    }

    /// `898.8k / 1M · 90 %`, or `898.8k` with no window.
    public var label: String {
        ContextFormat.gauge(used: used, window: window, fraction: fraction)
    }

    /// The compaction badge — `⟲ 2` — or `nil` when this session has not
    /// compacted. Zero is not drawn: an absent badge already says it.
    public var compactionBadge: String? {
        compactions > 0 ? "⟲ \(compactions)" : nil
    }

    /// What a screen reader says, spelled out rather than abbreviated.
    public var accessibilityLabel: String {
        var parts = ["Context window"]
        if let fraction {
            parts.append("\(ContextFormat.percent(fraction)) full")
            parts.append("\(used) of \(window ?? 0) tokens")
        } else {
            parts.append("\(used) tokens used, window size unknown")
        }
        if isDerived { parts.append("window size estimated from the model") }
        if compactions > 0 {
            parts.append(compactions == 1 ? "compacted once" : "compacted \(compactions) times")
        }
        return parts.joined(separator: ", ")
    }

    /// The sentence the gauge's tooltip carries, which is mostly about how
    /// much of it was measured and how much was looked up.
    public var helpText: String {
        var lines = [label]
        if let cached, cached > 0 {
            lines.append("\(ContextFormat.tokens(cached)) of it served from cache")
        }
        lines.append(
            isDerived
                ? "Fill read from the transcript; window size looked up from the model."
                : "Fill and window both recorded by the harness."
        )
        if compactions > 0 {
            lines.append(
                compactions == 1
                    ? "Compacted once already."
                    : "Compacted \(compactions) times already."
            )
        }
        return lines.joined(separator: "\n")
    }
}
