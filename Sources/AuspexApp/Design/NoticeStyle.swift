import AuspexCore
import SwiftUI

/// How an agent's own call for a person is drawn.
///
/// ## Why it looks different from a state
///
/// Every other pill on a card is an *observation*: Auspex read a transcript and
/// worked out what the session is doing. A notice is a *statement*: the agent
/// said it, in words it chose, and it is the only thing on the board with an
/// author. The two must not be confusable — a person who cannot tell "Auspex
/// thinks this is idle" from "this session says it is waiting for you" will
/// eventually trust the wrong one.
///
/// So a notice keeps the state palette (one colour per state is the rule) and
/// changes the *shape*: a filled pill rather than a tinted one, and a small
/// speech caret in front of the words wherever the agent's own sentence is
/// quoted. Colour says how urgent; the caret says who is speaking.
enum NoticeStyle {
    /// The glyph in front of anything an agent wrote about itself. One
    /// character, used on the card, in the trace header, and on a task row, so
    /// its meaning is learned once.
    static let selfReportedMark = "▸"

    /// The colour for each kind.
    ///
    /// `needs_input` and `blocked` are the "needs you" red the board already
    /// uses for a permission prompt, because they land in the same bucket and a
    /// second red would be a distinction without a difference. A review is
    /// amber: somebody has to look, but nothing is on fire. `done` is the
    /// writing green, which is what "finished" already means everywhere else.
    static func color(_ kind: AgentNoticeKind) -> Color {
        switch kind {
        case .needsInput, .blocked: AuspexPalette.statePermission
        case .needsReview: AuspexPalette.stateTool
        case .done: AuspexPalette.stateWriting
        }
    }

    /// The symbol beside the words.
    static func symbol(_ kind: AgentNoticeKind) -> String {
        switch kind {
        case .needsInput: "questionmark.bubble.fill"
        case .needsReview: "eye.fill"
        case .blocked: "exclamationmark.octagon.fill"
        case .done: "checkmark.circle.fill"
        }
    }
}

/// The pill that says an agent called, and what for.
///
/// Filled rather than tinted, which is the one shape on the board that means
/// "somebody said this".
struct NoticePill: View {
    let kind: AgentNoticeKind
    var isCompact = false

    var body: some View {
        let color = NoticeStyle.color(kind)
        HStack(spacing: 5) {
            Image(systemName: NoticeStyle.symbol(kind))
                .font(.system(size: 9, weight: .bold))
            if !isCompact {
                Text(kind.label)
                    .font(AuspexType.pill)
                    .fixedSize()
            }
        }
        .foregroundStyle(AuspexPalette.bg0)
        .padding(.horizontal, isCompact ? 6 : 9)
        .frame(height: 22)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous).fill(color)
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("the agent says: \(kind.label)")
    }
}

/// The agent's own sentence, under whatever it is attached to.
///
/// The caret is load-bearing: it is the only mark on a card that means "this
/// text has an author". Dismissing is right here rather than in a menu, because
/// the thing a person does after reading a call for help is answer it
/// somewhere else and then clear it — and a two-click clear is a clear nobody
/// performs, which leaves a board of stale red.
struct NoticeBanner: View {
    let notice: BoardRow.RowNotice
    var onDismiss: (() -> Void)?

    var body: some View {
        let color = NoticeStyle.color(notice.kind)
        HStack(alignment: .top, spacing: 7) {
            Text(NoticeStyle.selfReportedMark)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(color)
            Text(notice.message)
                .font(AuspexType.body)
                .foregroundStyle(AuspexPalette.text)
                .fixedSize(horizontal: false, vertical: true)
                .multilineTextAlignment(.leading)
                .textSelection(.enabled)
            Spacer(minLength: 4)
            if let onDismiss {
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(AuspexPalette.text3)
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Dismiss — the agent stops asking and the card goes quiet")
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(color.opacity(0.10))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(color.opacity(0.32), lineWidth: 1)
        )
    }
}
