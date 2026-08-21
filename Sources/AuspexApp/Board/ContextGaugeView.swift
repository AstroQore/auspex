import AuspexCore
import SwiftUI

/// How full a session's context window is: a thin bar, the numbers, and the
/// compaction count.
///
/// ## Why the *track* is what goes dotted
///
/// Two of the three harnesses that answer this question write the window size
/// down; Claude Code does not, and Auspex looks it up from the model id. That
/// difference matters to a reader — a gauge at 90 % is a reason to wrap up,
/// and a gauge at 90 % of a number this app guessed is a reason to check —
/// so it has to be visible without a tooltip.
///
/// The uncertainty is in the *denominator*, never in the fill: the tokens are
/// on disk either way. So the fill stays solid and the unfilled remainder —
/// the part that says how much room is left — is drawn as a dotted rule when
/// the window was looked up rather than recorded. Dimming the whole gauge
/// would have said the opposite: that the measurement is soft.
///
/// A reading with no window at all draws no bar. There is nothing to be a
/// fraction of, and a bar filled to an invented denominator is the one thing
/// this view must never do; the label says `421k` and stops.
///
/// ## Why it is `Equatable` and reads no clock
///
/// It sits inside ``SessionCard``, which SwiftUI compares on every graph
/// update across a wall of several hundred. Everything drawn here was computed
/// once per frame into ``ContextGauge`` — the label, the band of the ramp,
/// whether the window was derived — so the comparison is a handful of scalars
/// and nothing here formats a number or asks the time.
struct ContextGaugeView: View, Equatable {
    let gauge: ContextGauge
    /// The bar's thickness. A rule, not a progress view: it is one of four
    /// things on a footer line and the number beside it is the fact.
    var thickness: CGFloat = 3
    /// The narrowest the bar is allowed to be squeezed before the label starts
    /// giving way instead.
    var minimumTrack: CGFloat = 36

    var body: some View {
        HStack(spacing: 8) {
            if gauge.fraction != nil {
                track
                    .frame(height: thickness)
                    .frame(minWidth: minimumTrack, maxWidth: .infinity)
            }
            Text(gauge.label)
                .font(AuspexType.monoSmall)
                .auspexTabularDigits()
                .foregroundStyle(ContextGaugeStyle.colour(gauge.level))
                .lineLimit(1)
                .fixedSize()
            if let badge = gauge.compactionBadge {
                Text(badge)
                    .font(AuspexType.monoSmall)
                    .auspexTabularDigits()
                    .foregroundStyle(AuspexPalette.text3)
                    .fixedSize()
            }
        }
        .help(gauge.helpText)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(gauge.accessibilityLabel)
    }

    /// The bar: a solid fill over a bed that says how certain the window is.
    private var track: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            // Clamped so an overfull window paints to the end rather than past
            // it. The label beside it is what reports the number over 100 %.
            let filled = width * min(max(gauge.fraction ?? 0, 0), 1)
            ZStack(alignment: .leading) {
                bed(width: width)
                Capsule(style: .continuous)
                    .fill(ContextGaugeStyle.colour(gauge.level))
                    .frame(width: max(filled, gauge.used > 0 ? 2 : 0))
            }
        }
    }

    @ViewBuilder
    private func bed(width: CGFloat) -> some View {
        if gauge.isDerived {
            // A window nobody wrote down: the room left is drawn as a dotted
            // rule, one point thick and centred in the bar's own height, so it
            // reads as an estimate of the edge rather than as a shorter bar.
            Path { path in
                path.move(to: CGPoint(x: 0, y: thickness / 2))
                path.addLine(to: CGPoint(x: width, y: thickness / 2))
            }
            .stroke(
                AuspexPalette.line2,
                style: StrokeStyle(lineWidth: 1, lineCap: .round, dash: [1.5, 2.5])
            )
        } else {
            Capsule(style: .continuous).fill(AuspexPalette.bg3)
        }
    }
}

/// One colour per band of the context ramp.
///
/// The board's own state language, reused rather than extended: amber is the
/// colour of a tool call and red is the colour of a session that wants a
/// person, and a window about to compact is closer to the second than to
/// anything new. Under 70 % the gauge is deliberately the quietest ink on the
/// card — most sessions live there all day, and a wall of lit gauges is a wall
/// with no signal in it.
enum ContextGaugeStyle {
    static func colour(_ level: ContextGauge.Level) -> Color {
        switch level {
        case .calm: AuspexPalette.text3
        case .warm: AuspexPalette.stateTool
        case .critical: AuspexPalette.statePermission
        }
    }
}
