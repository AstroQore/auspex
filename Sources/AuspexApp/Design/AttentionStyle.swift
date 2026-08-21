import AuspexCore
import SwiftUI

/// How the two attention buckets look, everywhere they appear.
///
/// One table, read by the card, the header chip, the sidebar dot, the menu bar
/// label, the crew badge, the trajectory banner and the scene's bubbles. The
/// point of centralising it is not tidiness: it is that `! 2 needs you` in the
/// header and the two cards wearing red rings have to be *obviously* the same
/// claim, and six view bodies each picking a colour is six chances for them to
/// drift apart.
///
/// Two colours and no more. Red is the only thing on the board allowed to
/// shout, and it means exactly one thing — a person has to do something or
/// nothing will happen. Green means an agent reported finishing and is waiting
/// to be read, which is good news rather than live news, so it never breathes
/// and never sounds an alert louder than a banner.
enum AttentionStyle {
    /// The colour, or `nil` for a session saying nothing.
    static func colour(_ attention: AttentionState) -> Color? {
        switch attention {
        case .none: nil
        case .needsYou: AuspexPalette.statePermission
        case .doneReported: AuspexPalette.stateWriting
        }
    }

    /// The one character that stands for a bucket wherever a word will not
    /// fit: over an agent's head in the scene, in a corner badge, in front of
    /// a banner.
    static func mark(_ attention: AttentionState) -> String? {
        switch attention {
        case .none: nil
        case .needsYou: "!"
        case .doneReported: "✓"
        }
    }

    /// An SF Symbol, for the places AppKit will only take one.
    static func symbol(_ attention: AttentionState) -> String? {
        switch attention {
        case .none: nil
        case .needsYou: "exclamationmark"
        case .doneReported: "checkmark"
        }
    }

    /// The word in front of the reason on a banner.
    ///
    /// `nil` for `needsYou`, where the agent's own sentence *is* the headline
    /// and a "Needs you:" in front of it would be the card saying the same
    /// thing twice. A receipt needs the word, because "the tailer now handles
    /// partial lines" on its own does not say whether it is a plan or a
    /// result.
    static func headline(_ attention: AttentionState) -> String? {
        switch attention {
        case .none, .needsYou: nil
        case .doneReported: "Done"
        }
    }

    /// Whether the card's glow breathes.
    ///
    /// Only red. A breath is what makes a ring read as *a thing waiting for
    /// you* rather than as a sticker, and a wall where the good news breathed
    /// too would be a wall with no quiet in it for the bad news to stand out
    /// against.
    static func breathes(_ attention: AttentionState) -> Bool { attention.wantsPerson }

    /// What VoiceOver says.
    static func label(_ attention: AttentionState) -> String? {
        switch attention {
        case .none: nil
        case .needsYou(let reason, let source):
            "needs you — \(reason)\(source == .agent ? ", the agent says so" : "")"
        case .doneReported(let summary, _): "finished — \(summary)"
        }
    }
}

/// The reason a session is asking, or the receipt it filed, across the top of
/// whatever is drawing it.
///
/// The only line on a card somebody wrote on purpose — either the agent, in
/// its own words, or the harness naming the tool it is blocked on. So it sits
/// above the inferred lines: a person scanning a wall for what needs them
/// should not have to read past two guesses to find the statement.
///
/// Dismissing is right here rather than in a menu, because the thing a person
/// does after reading a call for help is answer it somewhere else and then
/// clear it — and a two-click clear is a clear nobody performs, which leaves a
/// board of stale red.
struct AttentionBanner: View {
    let attention: AttentionState
    var onDismiss: (() -> Void)?

    var body: some View {
        if let colour = AttentionStyle.colour(attention), let message = attention.message {
            HStack(alignment: .top, spacing: 7) {
                // The caret means "this text has an author"; the mark means
                // "this is which bucket". A harness's permission wait has no
                // author, so it gets the mark and no caret.
                Text(
                    attention.source == .agent
                        ? NoticeStyle.selfReportedMark
                        : AttentionStyle.mark(attention) ?? ""
                )
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(colour)
                Group {
                    if let headline = AttentionStyle.headline(attention) {
                        Text("\(headline): ").foregroundStyle(colour) + Text(message)
                            .foregroundStyle(AuspexPalette.text)
                    } else {
                        Text(message).foregroundStyle(AuspexPalette.text)
                    }
                }
                .font(AuspexType.body)
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
                    .buttonStyle(.auspex)
                    .help(
                        attention.wantsPerson
                            ? "Dismiss — the card goes quiet and stops being counted"
                            : "Dismiss — you have read it"
                    )
                }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(colour.opacity(0.10))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(colour.opacity(0.32), lineWidth: 1)
            )
            .accessibilityElement(children: .combine)
            .accessibilityLabel(AttentionStyle.label(attention) ?? message)
        }
    }
}

/// The `!` or `✓` in a corner, for the surfaces that have no room for a
/// sentence: the crew wall's cards, the sidebar, a task row.
struct AttentionBadge: View {
    let attention: AttentionState
    var size: CGFloat = 16

    var body: some View {
        if let colour = AttentionStyle.colour(attention),
           let symbol = AttentionStyle.symbol(attention) {
            Image(systemName: symbol)
                .font(.system(size: size * 0.56, weight: .black))
                .foregroundStyle(AuspexPalette.bg0)
                .frame(width: size, height: size)
                .background(Circle().fill(colour))
                .accessibilityLabel(AttentionStyle.label(attention) ?? "")
        }
    }
}
