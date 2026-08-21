import AuspexCore
import SwiftUI

/// One row of the trace waterfall.
///
/// Four columns, always in the same places, because a trace is read by
/// scanning down a column rather than across a line:
///
/// - **the time**, to the second, monospaced so the digits stack;
/// - **the glyph**, one character in the colour of what happened — the same
///   mark the card's activity line uses, so a yellow `›_` means the same thing
///   in both places;
/// - **the text**, in mono for anything the machine wrote and in the system
///   face for anything a person or the model wrote;
/// - **the duration**, right-aligned, once a tool call has closed.
///
/// The one row that is drawn differently is an open permission prompt: a red
/// hairline around it and a wash behind it, because it is the only row in the
/// list that is *waiting for the reader*.
struct TraceRowView: View, Equatable {
    let entry: TraceEntry
    /// `true` for the one row the board is blocked on. Decided by the model,
    /// which is the only place that knows whether the session is still waiting.
    var isWaiting = false
    let isExpanded: Bool
    let onToggle: () -> Void

    /// The gutter's width. Wide enough for `08:26:49`, and fixed so the glyph
    /// column lines up whatever the timestamps are.
    static let timeWidth: CGFloat = 58

    nonisolated static func == (lhs: TraceRowView, rhs: TraceRowView) -> Bool {
        lhs.entry == rhs.entry
            && lhs.isWaiting == rhs.isWaiting
            && lhs.isExpanded == rhs.isExpanded
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 10) {
                Text(Self.timeFormatter.string(from: entry.timestamp))
                    .font(AuspexType.monoTime)
                    .auspexTabularDigits()
                    .foregroundStyle(AuspexPalette.text3)
                    .frame(width: Self.timeWidth, alignment: .leading)

                Text(glyph)
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(tint)
                    .frame(width: 16, alignment: .center)

                // One line, not two. A trace is scanned, and a row that
                // wraps its target underneath its verb halves how much of the
                // session fits on screen for a fact that is usually a path
                // whose tail is all anybody reads.
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(entry.title)
                        .font(isProse ? AuspexType.rowTitle : AuspexType.mono)
                        .foregroundStyle(titleColor)
                        .lineLimit(1)
                        .fixedSize()
                    if let detail = entry.detail {
                        let shown = PathDisplay.abbreviate(detail)
                        Text(shown)
                            .font(AuspexType.monoSmall)
                            .foregroundStyle(AuspexPalette.text3)
                            .lineLimit(isExpanded ? 6 : 1)
                            .truncationMode(PathDisplay.truncation(for: shown))
                            .textSelection(.enabled)
                    }
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if let trailing {
                    Text(trailing)
                        .font(AuspexType.monoTime)
                        .foregroundStyle(
                            entry.isError ? AuspexPalette.statePermission : AuspexPalette.text3
                        )
                        .fixedSize()
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            if isExpanded { expansion }
        }
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isWaiting ? AuspexPalette.statePermission.opacity(0.08) : .clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(
                    isWaiting ? AuspexPalette.statePermission.opacity(0.25) : .clear,
                    lineWidth: 1
                )
        )
        .contentShape(Rectangle())
        .onTapGesture { if entry.isExpandable { onToggle() } }
        .accessibilityElement(children: .combine)
    }

    /// The right-hand column: how long a finished call took, or how long an
    /// open one has been going.
    private var trailing: String? {
        if let duration = entry.duration { return DurationFormat.short(duration) }
        if entry.isError { return "failed" }
        return nil
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
                        .foregroundStyle(AuspexPalette.text)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if let json = entry.detailJSON {
                labelled("Event payload") {
                    Text(json)
                        .font(AuspexType.monoBlock)
                        .foregroundStyle(AuspexPalette.text2)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous).fill(AuspexPalette.bg2)
        )
        .overlay(alignment: .leading) {
            Rectangle().fill(tint.opacity(0.5)).frame(width: 2)
        }
        .padding(.leading, Self.timeWidth + 26)
        .padding(.trailing, 8)
        .padding(.bottom, 6)
    }

    private func labelled(
        _ key: String,
        @ViewBuilder content: () -> some View
    ) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(key)
                .auspexLabel(AuspexType.labelSmall)
                .foregroundStyle(AuspexPalette.text3)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Style

    /// A prompt, an assistant message, or a note is prose and is set in the
    /// system face. Everything else is something the machine wrote and is set
    /// in mono, because its characters are what matter.
    private var isProse: Bool {
        switch entry.glyph {
        case .prompt, .assistant, .note, .permission: true
        default: false
        }
    }

    /// The prompt is the one row a person wrote, so it is the one row drawn at
    /// full strength. Everything else is the machine talking.
    private var titleColor: Color {
        entry.glyph == .prompt ? AuspexPalette.text : AuspexPalette.text2
    }

    /// The glyph's colour: the same language the board uses, so a green mark
    /// means the same thing as a green card.
    private var tint: Color {
        if entry.isError { return AuspexPalette.statePermission }
        switch entry.glyph {
        case .prompt: return AuspexPalette.text
        case .thinking, .assistant: return AuspexPalette.stateThinking
        case .fileWrite: return AuspexPalette.stateWriting
        case .permission: return AuspexPalette.statePermission
        case .subagent: return AuspexPalette.stateDelegating
        case .tool, .shell, .fileRead, .search, .web, .mcp: return AuspexPalette.stateTool
        case .sessionStart: return AuspexPalette.stateWriting
        case .sessionEnd: return AuspexPalette.stateEnded
        case .usage, .quota, .turn, .compaction, .liveness, .note: return AuspexPalette.text3
        // The one mark on the trace that carries the board's context ramp, so
        // a row saying 92 % looks the same colour as the gauge that says it.
        case .context: return AuspexPalette.text3
        }
    }

    /// The one-character mark for a row.
    ///
    /// Characters rather than SF Symbols, because the column they sit in is a
    /// monospaced one and a symbol's optical weight changes from glyph to
    /// glyph — a column of symbols does not line up, and lining up is the
    /// whole point of a gutter.
    private var glyph: String {
        Self.glyph(for: entry.glyph)
    }

    static func glyph(for glyph: TraceEntry.Glyph) -> String {
        switch glyph {
        case .sessionStart: "▶"
        case .sessionEnd: "■"
        case .turn: "↳"
        case .prompt: "❯"
        case .thinking: "◌"
        case .assistant: "¶"
        case .tool, .shell, .fileRead, .search, .web, .mcp: "›_"
        case .fileWrite: "✎"
        case .subagent: "↳"
        case .permission: "!"
        case .usage: "Σ"
        case .context: "▮"
        case .quota: "%"
        case .compaction: "⇥"
        case .liveness: "~"
        case .note: "·"
        }
    }

    /// `HH:mm:ss` — the mock's gutter. Tenths lived here once, and they cost
    /// the column twenty per cent of its width to disambiguate two calls in
    /// the same second, which the row order already does.
    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
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
                .auspexLabel(AuspexType.label)
                .foregroundStyle(AuspexPalette.text3)
            Text(Self.formatter.string(from: timestamp))
                .font(AuspexType.monoTime)
                .foregroundStyle(AuspexPalette.text3)
            Rectangle()
                .fill(AuspexPalette.line)
                .frame(height: 1)
        }
        .padding(.horizontal, 8)
        .padding(.top, 10)
        .padding(.bottom, 4)
    }

    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()
}
