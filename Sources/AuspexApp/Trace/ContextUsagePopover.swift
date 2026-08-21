import AgentSessionLive
import AuspexCore
import SwiftUI

/// The detail-pane control: `Context 898.8k / 1M (90 %)`, and the popover
/// behind it.
///
/// A button rather than a `MetaField` because there is more to say than fits
/// on a header row, and because what is behind it is the thing a person opens
/// when the card's gauge made them ask a question — *how close is that really,
/// and what is filling it up*.
struct ContextHeaderGauge: View {
    let gauge: ContextGauge
    /// The whole snapshot's output, for the popover's ledger.
    let tokensOut: Int
    /// The estimate, once somebody asked for it. `nil` while it has not been
    /// loaded, or when there is nothing to estimate from.
    let composition: ContextComposition?
    /// Asked to load the estimate. Called when the popover opens, not when the
    /// header is drawn: it is two index seeks and a few thousand decodes, and
    /// a header that did it per frame would be a query on the frame path.
    var onOpen: (() -> Void)?

    @State private var isPresented = false

    var body: some View {
        Button {
            isPresented = true
            onOpen?()
        } label: {
            HStack(spacing: 5) {
                Text("context")
                    .font(AuspexType.caption)
                    .foregroundStyle(AuspexPalette.text3)
                Text(headline)
                    .font(AuspexType.monoSmall)
                    .auspexTabularDigits()
                    .foregroundStyle(ContextGaugeStyle.colour(gauge.level))
                if let badge = gauge.compactionBadge {
                    Text(badge)
                        .font(AuspexType.monoSmall)
                        .auspexTabularDigits()
                        .foregroundStyle(AuspexPalette.text3)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(gauge.helpText)
        .accessibilityLabel(gauge.accessibilityLabel)
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            ContextUsagePopover(
                gauge: gauge, tokensOut: tokensOut, composition: composition
            )
        }
    }

    /// `898.8k / 1M (90 %)` — the header spells the percent in brackets rather
    /// than after a middle dot, because this line sits among other `key value`
    /// pairs and a third separator would make it read as four fields.
    private var headline: String {
        guard let window = gauge.window else { return ContextFormat.tokens(gauge.used) }
        var text = "\(ContextFormat.tokens(gauge.used)) / \(ContextFormat.tokens(window))"
        if let fraction = gauge.fraction { text += " (\(ContextFormat.percent(fraction)))" }
        return text
    }
}

/// What is in the window, and how much of it anybody actually measured.
///
/// Three blocks, in the order the questions come: the fill, what is taking it
/// up, and the numbers behind both. The last line of every one of them is
/// provenance, because the entire value of this panel is that a reader can
/// tell which figures came off disk and which Auspex worked out.
struct ContextUsagePopover: View {
    let gauge: ContextGauge
    let tokensOut: Int
    let composition: ContextComposition?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            fill
            if let composition {
                Divider().overlay(AuspexPalette.line)
                breakdown(composition)
            }
            Divider().overlay(AuspexPalette.line)
            ledger
        }
        .padding(16)
        .frame(width: 320)
        .background(AuspexPalette.panel)
    }

    // MARK: The fill

    private var fill: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Context window")
                .auspexLabel(AuspexType.label)
                .foregroundStyle(AuspexPalette.text3)
            Text(gauge.label)
                .font(AuspexType.mono)
                .auspexTabularDigits()
                .foregroundStyle(ContextGaugeStyle.colour(gauge.level))
            ContextGaugeView(gauge: gauge, thickness: 5, showsLabel: false).equatable()
            Text(provenance)
                .font(AuspexType.caption)
                .foregroundStyle(AuspexPalette.text3)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Which half of the gauge was measured. The one sentence this panel
    /// exists for.
    private var provenance: String {
        gauge.isDerived
            ? "Fill read from the transcript. Window size looked up from the model — "
                + "the harness does not record it."
            : "Fill and window size both recorded by the harness."
    }

    // MARK: What is in it

    private func breakdown(_ composition: ContextComposition) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("What is in it")
                .auspexLabel(AuspexType.label)
                .foregroundStyle(AuspexPalette.text3)
            CompositionBar(composition: composition)
            VStack(alignment: .leading, spacing: 4) {
                ForEach(composition.slices) { slice in
                    CompositionRow(slice: slice, window: composition.window)
                }
            }
            Text(estimateCaption(composition))
                .font(AuspexType.caption)
                .foregroundStyle(AuspexPalette.text3)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// The caption under the bar. Never omitted, and never softened: every
    /// number above it came from dividing a character count by four.
    private func estimateCaption(_ composition: ContextComposition) -> String {
        var lines = [
            gauge.isDerived
                ? "Estimate, from the \(composition.sampledEvents) messages Auspex indexed — "
                    + "Claude Code's own /context is exact."
                : "Estimate, from the \(composition.sampledEvents) messages Auspex indexed. "
                    + "The harness records the fill but does not itemise it."
        ]
        if composition.sinceCompaction {
            lines.append("Counted from the last compaction.")
        }
        if composition.isTruncated {
            lines.append("Older messages were not read, so the measured bands are a floor.")
        }
        if composition.isOverEstimated {
            lines.append("Four characters to the token over-counted here; the bands were scaled to fit.")
        }
        // The case that would otherwise read as a claim about the system
        // prompt: a session Auspex met late, or one whose harness writes no
        // tool output, has almost nothing measured and almost everything left
        // over. Saying so is the difference between "the system prompt is 96k"
        // and "we did not see most of this".
        if composition.isMostlyUnattributed {
            lines.append(
                "Little of this session's text is indexed here, so most of the window "
                    + "falls into “everything else” rather than being attributed."
            )
        }
        return lines.joined(separator: " ")
    }

    // MARK: The numbers

    private var ledger: some View {
        VStack(alignment: .leading, spacing: 5) {
            LedgerRow(key: "used", value: exact(gauge.used))
            LedgerRow(key: "window", value: gauge.window.map(exact) ?? "not recorded")
            LedgerRow(key: "cached", value: gauge.cached.map(exact) ?? "not reported")
            // Cumulative, and labelled so. The snapshot counts every token a
            // session ever generated; nothing on disk separates the newest
            // turn's share of it.
            LedgerRow(key: "output, all turns", value: exact(tokensOut))
            LedgerRow(key: "compactions", value: "\(gauge.compactions)")
        }
    }

    /// Every digit, grouped. This block is the one somebody opened *because*
    /// `898.8k` was not precise enough, so nothing here is abbreviated — but
    /// six unbroken digits is a number a person has to count, and grouping
    /// them costs no precision at all.
    private func exact(_ value: Int) -> String {
        value.formatted(.number.grouping(.automatic))
    }
}

/// The stacked bar: measured bands solid, the inferred one hatched, the free
/// end empty.
private struct CompositionBar: View {
    let composition: ContextComposition

    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 1) {
                ForEach(composition.slices) { slice in
                    band(slice)
                        .frame(width: max(0, geometry.size.width * slice.fraction - 1))
                }
            }
        }
        .frame(height: 8)
        .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
        .background(
            RoundedRectangle(cornerRadius: 3, style: .continuous).fill(AuspexPalette.bg3)
        )
    }

    @ViewBuilder
    private func band(_ slice: ContextComposition.Slice) -> some View {
        switch slice.kind {
        case .messages:
            Rectangle().fill(AuspexPalette.stateThinking)
        case .toolResults:
            Rectangle().fill(AuspexPalette.stateTool)
        case .everythingElse:
            // The band nobody measured, drawn at half strength: it is the
            // remainder after subtraction, and it should not look like the two
            // beside it that were counted.
            Rectangle().fill(AuspexPalette.text3.opacity(0.55))
        case .free:
            Rectangle().fill(AuspexPalette.bg3)
        }
    }
}

/// One legend line: a swatch, a name, and the estimate.
private struct CompositionRow: View {
    let slice: ContextComposition.Slice
    let window: Int

    var body: some View {
        HStack(spacing: 7) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(swatch)
                .frame(width: 8, height: 8)
            Text(slice.title)
                .font(AuspexType.caption)
                .foregroundStyle(slice.isMeasured ? AuspexPalette.text2 : AuspexPalette.text3)
            Spacer(minLength: 6)
            Text("\(ContextFormat.tokens(slice.tokens)) · \(ContextFormat.percent(slice.fraction))")
                .font(AuspexType.monoSmall)
                .auspexTabularDigits()
                .foregroundStyle(AuspexPalette.text3)
        }
    }

    private var swatch: Color {
        switch slice.kind {
        case .messages: AuspexPalette.stateThinking
        case .toolResults: AuspexPalette.stateTool
        case .everythingElse: AuspexPalette.text3.opacity(0.55)
        case .free: AuspexPalette.bg3
        }
    }
}

/// A `key   value` line in the popover's exact-numbers block. Raw counts, not
/// abbreviations: this is the block somebody opened *because* `898.8k` was not
/// precise enough.
private struct LedgerRow: View {
    let key: String
    let value: String

    var body: some View {
        HStack(spacing: 8) {
            Text(key)
                .font(AuspexType.caption)
                .foregroundStyle(AuspexPalette.text3)
            Spacer(minLength: 8)
            Text(value)
                .font(AuspexType.monoSmall)
                .auspexTabularDigits()
                .foregroundStyle(AuspexPalette.text2)
        }
        .accessibilityElement(children: .combine)
    }
}
