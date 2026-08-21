import AgentSessionLive
import Foundation

/// The plan window a harness said it was billing against, as one line.
///
/// Read off a rollout and nothing else. Auspex does not ask anybody's API what
/// a quota is, and this line is therefore exactly as fresh as the session that
/// wrote it — which is why ``QuotaLine/at`` is part of the value and gets
/// said out loud on the surface that draws it.
public enum QuotaFormat {
    /// A wall-clock reset, for a row that already carries its own timestamps:
    /// `11:10`. Same day or not is the reader's problem to notice from the
    /// countdown beside it; a date here would double the width of a trace row.
    public static func reset(at date: Date) -> String {
        clock.string(from: date)
    }

    /// `in 2 h 10 m`, `in 14 m`, `now`. What a person is actually asking when
    /// they look at a limit.
    ///
    /// A window whose reset has already passed reads `now` rather than a
    /// negative countdown: the rollout is simply older than the window it
    /// described, and the true answer is that the limit has rolled over.
    public static func countdown(to date: Date, from now: Date) -> String {
        let seconds = date.timeIntervalSince(now)
        guard seconds > 60 else { return "now" }
        let minutes = Int(seconds / 60)
        if minutes < 60 { return "in \(minutes) m" }
        let hours = minutes / 60
        let remainder = minutes % 60
        if hours < 24 {
            return remainder == 0 ? "in \(hours) h" : "in \(hours) h \(remainder) m"
        }
        let days = hours / 24
        let leftover = hours % 24
        return leftover == 0 ? "in \(days) d" : "in \(days) d \(leftover) h"
    }

    /// `43 %`. Whole percents; a tenth of a plan window is not a decision.
    public static func used(_ percent: Double) -> String {
        "\(Int(percent.rounded())) %"
    }

    private static let clock: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()
}

/// One harness's rate-limit line, precomputed for the row that draws it.
///
/// A value rather than a formatting call in a `body`, for the same reason
/// ``BoardRow`` is a value: the Harnesses page redraws whenever the board does,
/// and a `DateFormatter` in a view body is a cost paid per redraw for a string
/// that changes once every few minutes.
public struct QuotaLine: Hashable, Sendable {
    /// How much of the window is spent, 0–100 as the harness spelled it.
    public let usedPercent: Double
    /// When it rolls over, when the harness said.
    public let resetsAt: Date?
    /// The plan name the harness recorded, verbatim.
    public let plan: String?
    /// The timestamp of the record this was read from — how old the claim is.
    public let at: Date

    public init(usedPercent: Double, resetsAt: Date?, plan: String?, at: Date) {
        self.usedPercent = usedPercent
        self.resetsAt = resetsAt
        self.plan = plan
        self.at = at
    }

    /// The line for a snapshot's quota, or `nil` when its harness records none.
    public init?(_ quota: SessionQuota?) {
        guard let quota else { return nil }
        self.init(
            usedPercent: quota.usedPercent,
            resetsAt: quota.resetsAt,
            plan: quota.plan,
            at: quota.at
        )
    }

    /// `used 43 % · resets in 2 h 10 m · plan pro`.
    ///
    /// Each clause is dropped rather than filled in when the rollout did not
    /// carry it: a reset time nobody wrote down is not "now", and a plan
    /// nobody named is not "free".
    public func label(now: Date) -> String {
        var parts = ["used \(QuotaFormat.used(usedPercent))"]
        if let resetsAt {
            parts.append("resets \(QuotaFormat.countdown(to: resetsAt, from: now))")
        }
        if let plan, !plan.isEmpty { parts.append("plan \(plan)") }
        return parts.joined(separator: " · ")
    }

    /// Where the numbers came from and how old they are — the tooltip, and the
    /// part that keeps this from reading as a live meter.
    public func helpText(now: Date) -> String {
        """
        Read from the harness's own session log, not from a network call.
        Last written \(DurationFormat.short(max(0, now.timeIntervalSince(at)))) ago.
        """
    }
}
