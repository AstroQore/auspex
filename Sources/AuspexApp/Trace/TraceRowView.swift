import AuspexCore
import SwiftUI

/// One row of the trace waterfall.
///
/// Three columns, always in the same places, because a trace is read by
/// scanning down a column rather than across a line:
///
/// - **the gutter** — the source's own timestamp to a tenth of a second,
///   monospaced so the digits stack;
/// - **the spine** — a continuous hairline with a coloured node on it, which
///   is what turns a list of rows into something that reads as one session's
///   thread through time;
/// - **the content** — a title, an optional target, and a duration once a tool
///   call has closed.
///
/// The spine is drawn per row rather than as one overlay behind the list,
/// because a `List` recycles rows and a background that has to know the height
/// of everything above it cannot be lazy.
struct TraceRowView: View {
    let entry: TraceEntry
    let isExpanded: Bool
    let onToggle: () -> Void

    /// Where the spine sits, measured from the row's leading edge. Shared by
    /// the row and its expansion so the two line up.
    static let spineOffset: CGFloat = 84

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 0) {
                gutter
                // The spine's column is reserved with padding rather than a
                // spacer view: a `Color.clear` with only a width set is greedy
                // vertically, which quietly makes every row as tall as the
                // tallest thing in the list.
                content.padding(.leading, 16)
            }
            .padding(.vertical, 2)
            if isExpanded { expansion }
        }
        // The spine is an overlay rather than a column so it fills the row's
        // natural height instead of forcing the row to be as tall as an
        // infinitely greedy child. That is what keeps the waterfall dense: rows
        // are as tall as their content and no taller, and the line still runs
        // unbroken from one row into the next.
        .overlay(alignment: .topLeading) { spine }
        .contentShape(Rectangle())
        .onTapGesture { if entry.isExpandable { onToggle() } }
        .accessibilityElement(children: .combine)
    }

    // MARK: Columns

    private var gutter: some View {
        Text(Self.timeFormatter.string(from: entry.timestamp))
            .font(AuspexType.monoTime)
            .auspexTabularDigits()
            .foregroundStyle(AuspexPalette.textTertiary)
            .frame(width: 76, alignment: .trailing)
            .padding(.trailing, 8)
            .padding(.top, 1)
    }

    private var spine: some View {
        ZStack(alignment: .top) {
            Rectangle()
                .fill(AuspexPalette.hairline)
                .frame(width: 1)
                .frame(maxHeight: .infinity)
            Circle()
                .fill(tint)
                .frame(width: 6, height: 6)
                .overlay(Circle().strokeBorder(AuspexPalette.canvas, lineWidth: 1.5))
                .offset(y: 5)
        }
        .frame(width: 8)
        .offset(x: Self.spineOffset)
        .allowsHitTesting(false)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Image(systemName: Self.symbolName(for: entry.glyph))
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 12)

                Text(entry.title)
                    .font(AuspexType.rowTitle)
                    .foregroundStyle(AuspexPalette.textPrimary)
                    .lineLimit(1)

                if let duration = entry.duration {
                    Text(DurationFormat.short(duration))
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundStyle(AuspexPalette.textSecondary)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(AuspexPalette.hairline))
                }

                if entry.isError {
                    Text("Failed")
                        .auspexLabel(AuspexType.labelSmall)
                        .foregroundStyle(AuspexPalette.statePermission)
                }

                Spacer(minLength: 4)

                // Trailing, where a disclosure belongs. Beside the title it
                // makes every row's headline end in a different place, and a
                // ragged column of titles is much harder to scan than a tidy
                // one with a marker at the edge.
                if entry.isExpandable {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 7, weight: .bold))
                        .foregroundStyle(AuspexPalette.textTertiary)
                }
            }

            if let detail = entry.detail {
                let shown = PathDisplay.abbreviate(detail)
                Text(shown)
                    .font(AuspexType.monoSmall)
                    .foregroundStyle(AuspexPalette.textSecondary)
                    .lineLimit(isExpanded ? 6 : 1)
                    .truncationMode(PathDisplay.truncation(for: shown))
                    .padding(.leading, 18)
                    .textSelection(.enabled)
            }
        }
        .padding(.trailing, 12)
    }

    /// What a click opens: the full text when the row carries one, and the
    /// event payload underneath it.
    ///
    /// Both are selectable. A trace is something a person copies out of — into
    /// a bug report, into a prompt — and a pane that will not let you take the
    /// text is a screenshot with extra steps.
    private var expansion: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let body = entry.body {
                labelled("Full text") {
                    Text(body)
                        .font(AuspexType.body)
                        .foregroundStyle(AuspexPalette.textPrimary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if let json = entry.detailJSON {
                labelled("Event payload") {
                    Text(json)
                        .font(AuspexType.monoBlock)
                        .foregroundStyle(AuspexPalette.textSecondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(AuspexPalette.well)
        .overlay(alignment: .leading) {
            Rectangle().fill(tint.opacity(0.5)).frame(width: 2)
        }
        .overlay(Rectangle().strokeBorder(AuspexPalette.hairline, lineWidth: 1))
        .padding(.leading, Self.spineOffset + 18)
        .padding(.trailing, 12)
        .padding(.top, 4)
        .padding(.bottom, 4)
    }

    private func labelled(
        _ key: String,
        @ViewBuilder content: () -> some View
    ) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(key)
                .auspexLabel(AuspexType.labelSmall)
                .foregroundStyle(AuspexPalette.textTertiary)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Style

    /// The node's colour: the same language the board uses, so a green node
    /// means the same thing as a green card.
    private var tint: Color {
        if entry.isError { return AuspexPalette.statePermission }
        switch entry.glyph {
        case .prompt: return AuspexPalette.textPrimary
        case .thinking, .assistant: return AuspexPalette.stateThinking
        case .fileWrite: return AuspexPalette.stateWriting
        case .permission: return AuspexPalette.statePermission
        case .subagent: return AuspexPalette.stateDelegating
        case .tool, .shell, .fileRead, .search, .web, .mcp: return AuspexPalette.stateTool
        case .sessionStart: return AuspexPalette.stateWriting
        case .sessionEnd: return AuspexPalette.stateEnded
        case .usage, .turn, .compaction, .liveness, .note: return AuspexPalette.textTertiary
        }
    }

    /// The semantic glyph's symbol. The mapping lives on the view side; the
    /// meaning lives in ``TraceEntry/Glyph``.
    static func symbolName(for glyph: TraceEntry.Glyph) -> String {
        switch glyph {
        case .sessionStart: "play.fill"
        case .sessionEnd: "stop.fill"
        case .turn: "arrow.turn.down.right"
        case .prompt: "text.bubble.fill"
        case .thinking: "brain"
        case .assistant: "quote.opening"
        case .tool: "wrench.adjustable"
        case .shell: "terminal"
        case .fileRead: "doc.text"
        case .fileWrite: "square.and.pencil"
        case .search: "magnifyingglass"
        case .web: "globe"
        case .mcp: "cable.connector"
        case .subagent: "arrow.triangle.branch"
        case .permission: "exclamationmark.triangle.fill"
        case .usage: "number"
        case .compaction: "arrow.down.right.and.arrow.up.left"
        case .liveness: "waveform.path.ecg"
        case .note: "info.circle"
        }
    }

    /// `HH:mm:ss.S` — tenths, because two tool calls in the same second is
    /// normal and a trace that cannot order them is not a trace.
    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.S"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()
}

/// The rule between turns.
///
/// Turns are the unit a person actually remembers ("it went wrong on the
/// second thing I asked for"), so they get a real divider rather than extra
/// whitespace.
struct TraceTurnSeparator: View {
    let turn: Int
    let timestamp: Date

    var body: some View {
        HStack(spacing: 8) {
            Text("Turn \(turn)")
                .auspexLabel(AuspexType.labelSmall)
                .foregroundStyle(AuspexPalette.textSecondary)
            Rectangle()
                .fill(AuspexPalette.hairline)
                .frame(height: 1)
            Text(Self.formatter.string(from: timestamp))
                .font(AuspexType.monoTime)
                .foregroundStyle(AuspexPalette.textTertiary)
        }
        .padding(.horizontal, 12)
        .padding(.top, 12)
        .padding(.bottom, 5)
    }

    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()
}
