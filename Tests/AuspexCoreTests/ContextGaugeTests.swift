import AgentSessionKit
import AgentSessionLive
import Foundation
import Testing

@testable import AuspexCore

@Suite("ContextFormat")
struct ContextFormatTests {
    @Test(
        "one decimal, and a trailing .0 dropped",
        arguments: [
            (0, "0"),
            (843, "843"),
            (1_000, "1k"),
            (12_900, "12.9k"),
            (200_000, "200k"),
            (258_400, "258.4k"),
            (898_800, "898.8k"),
            (1_000_000, "1M"),
            (1_240_000, "1.2M")
        ]
    )
    func tokens(_ value: Int, _ expected: String) {
        #expect(ContextFormat.tokens(value) == expected)
    }

    @Test("the gauge reads as a fraction of a window")
    func gaugeLabel() {
        #expect(
            ContextFormat.gauge(used: 898_800, window: 1_000_000, fraction: 0.8988)
                == "898.8k / 1M · 90 %"
        )
    }

    @Test("no window means a count and nothing that implies a denominator")
    func gaugeWithoutWindow() {
        #expect(ContextFormat.gauge(used: 421_000, window: nil, fraction: nil) == "421k")
    }

    @Test("percents are whole")
    func percent() {
        #expect(ContextFormat.percent(0.8988) == "90 %")
        #expect(ContextFormat.percent(0) == "0 %")
        #expect(ContextFormat.percent(1) == "100 %")
    }
}

@Suite("ContextGauge")
struct ContextGaugeTests {
    private func gauge(
        used: Int,
        window: Int? = 200_000,
        cached: Int? = nil,
        source: ContextUsage.Source = .measured,
        compactions: Int = 0
    ) -> ContextGauge {
        ContextGauge(
            usage: ContextUsage(
                used: used, window: window, cached: cached, at: Fixtures.date(0), source: source
            ),
            compactions: compactions
        )!
    }

    // MARK: - The ramp

    @Test(
        "the ramp bands are where a person's options change",
        arguments: [
            (0, ContextGauge.Level.calm),
            (139_999, ContextGauge.Level.calm),
            (140_000, ContextGauge.Level.warm),
            (179_999, ContextGauge.Level.warm),
            (180_000, ContextGauge.Level.critical),
            (200_000, ContextGauge.Level.critical),
            (240_000, ContextGauge.Level.critical)
        ]
    )
    func ramp(_ used: Int, _ expected: ContextGauge.Level) {
        #expect(gauge(used: used).level == expected)
    }

    @Test("a fill with no window is calm, because nothing is known about it")
    func unknownWindowIsCalm() {
        let gauge = gauge(used: 900_000, window: nil)
        #expect(gauge.level == .calm)
        #expect(gauge.fraction == nil)
        #expect(gauge.label == "900k")
    }

    @Test("an overfull window is over 100 %, not capped at it")
    func overfull() {
        let gauge = gauge(used: 240_000)
        #expect((gauge.fraction ?? 0) > 1)
        #expect(gauge.label.hasSuffix("120 %"))
    }

    @Test("a zero window does not divide by it")
    func zeroWindow() {
        let gauge = gauge(used: 100, window: 0)
        #expect(gauge.fraction == nil)
        #expect(gauge.level == .calm)
    }

    // MARK: - Provenance

    @Test("a derived window is marked as one, and says so in the tooltip")
    func derivedIsMarked() {
        let derived = gauge(used: 100_000, source: .derived)
        #expect(derived.isDerived)
        #expect(derived.helpText.contains("looked up from the model"))

        let measured = gauge(used: 100_000, source: .measured)
        #expect(!measured.isDerived)
        #expect(measured.helpText.contains("recorded by the harness"))
    }

    @Test("a session with no reading has no gauge, rather than an empty one")
    func absentReading() {
        #expect(ContextGauge(usage: nil, compactions: 0) == nil)
        // Not even when it has compacted: a compaction count with no fill is
        // not a gauge, and a gauge at zero would say something nobody said.
        #expect(ContextGauge(usage: nil, compactions: 3) == nil)
    }

    // MARK: - Compactions

    @Test("the compaction badge counts, and is absent at zero")
    func compactionBadge() {
        #expect(gauge(used: 10, compactions: 0).compactionBadge == nil)
        #expect(gauge(used: 10, compactions: 1).compactionBadge == "⟲ 1")
        #expect(gauge(used: 10, compactions: 12).compactionBadge == "⟲ 12")
    }

    @Test("the cached share is named when there is one")
    func cachedShare() {
        #expect(gauge(used: 100_000, cached: 88_000).helpText.contains("88k of it served from cache"))
        #expect(!gauge(used: 100_000, cached: 0).helpText.contains("cache"))
    }

    @Test("the spoken label spells out what the drawn one abbreviates")
    func accessibility() {
        let spoken = gauge(used: 180_000, source: .derived, compactions: 2).accessibilityLabel
        #expect(spoken.contains("90 % full"))
        #expect(spoken.contains("180000 of 200000 tokens"))
        #expect(spoken.contains("estimated"))
        #expect(spoken.contains("compacted 2 times"))
    }
}

@Suite("QuotaLine")
struct QuotaLineTests {
    private let now = Fixtures.date(0)

    @Test("the line is what the rollout said, in the order it is read")
    func label() {
        let line = QuotaLine(
            usedPercent: 43.2,
            resetsAt: now.addingTimeInterval(7_800),
            plan: "pro",
            at: now
        )
        #expect(line.label(now: now) == "used 43 % · resets in 2 h 10 m · plan pro")
    }

    @Test("a clause the rollout did not carry is dropped, never filled in")
    func sparseLine() {
        let line = QuotaLine(usedPercent: 3.5, resetsAt: nil, plan: nil, at: now)
        #expect(line.label(now: now) == "used 4 %")
    }

    @Test(
        "the countdown says what a person is asking",
        arguments: [
            (0.0, "now"),
            (30.0, "now"),
            (840.0, "in 14 m"),
            (3_600.0, "in 1 h"),
            (7_800.0, "in 2 h 10 m"),
            (93_600.0, "in 1 d 2 h"),
            (172_800.0, "in 2 d")
        ]
    )
    func countdown(_ seconds: TimeInterval, _ expected: String) {
        #expect(QuotaFormat.countdown(to: now.addingTimeInterval(seconds), from: now) == expected)
    }

    @Test("a window whose reset already passed has rolled over, not gone negative")
    func staleReset() {
        #expect(QuotaFormat.countdown(to: now.addingTimeInterval(-9_000), from: now) == "now")
    }

    @Test("a harness that records no quota has no line")
    func absentQuota() {
        #expect(QuotaLine(nil) == nil)
    }

    @Test("the tooltip says where the numbers came from and how old they are")
    func helpText() {
        let line = QuotaLine(usedPercent: 12, resetsAt: nil, plan: "team", at: now)
        let help = line.helpText(now: now.addingTimeInterval(90))
        #expect(help.contains("not from a network call"))
        #expect(help.contains("1m 30s ago"))
    }
}
