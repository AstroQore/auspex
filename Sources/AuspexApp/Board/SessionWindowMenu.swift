import AuspexCore
import SwiftUI

/// How far back the board reaches, as a menu.
///
/// ## Why the control is beside the grouping and not only in Settings
///
/// The window is not a preference in the way "which character does Codex
/// wear" is. It decides what every number in the header counts and how much
/// map there is, and the moment a person notices it — "where did this
/// afternoon's sessions go" — they are looking at the board, not at Settings.
/// So the control is where the answer is needed, and Settings → Scene carries
/// the same setting for somebody who went looking there instead.
///
/// The same view is used twice with two labels: as the header's `Last 12 h`
/// button, and as the `28 older than 12 h, hidden` hint under the collapsed
/// `Ended` section. Both are the same question, so both open the same menu —
/// a hint that only *said* something would leave the reader to go and find the
/// control that acts on it.
struct SessionWindowMenu<Label: View>: View {
    let window: SessionWindow
    /// What the current window is leaving out, or `nil` when it leaves out
    /// nothing.
    var hint: String?
    let onSelect: (SessionWindow) -> Void
    @ViewBuilder let label: Label

    var body: some View {
        Menu {
            Section("Show sessions active in the last") {
                Picker(
                    "Show sessions active in the last",
                    selection: Binding(get: { window }, set: onSelect)
                ) {
                    ForEach(SessionWindow.allCases) { option in
                        Text(option.title).tag(option)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            }
            if let hint {
                Divider()
                // Disabled rather than absent: the number is what makes the
                // menu worth opening, and a live count in a menu somebody is
                // about to click through is the one place it cannot be missed.
                Text(hint)
            }
            Divider()
            Text("Everything stays in the store — this is how much is drawn.")
        } label: {
            label
        }
        .menuStyle(.button)
        .buttonStyle(.auspex(cornerRadius: 8))
        .menuIndicator(.hidden)
    }
}

extension SessionWindowMenu where Label == SessionWindowLabel {
    /// The header's form: `Last 12 h`, in the same chrome the grouping menu
    /// and the search field wear.
    init(window: SessionWindow, hint: String?, onSelect: @escaping (SessionWindow) -> Void) {
        self.init(window: window, hint: hint, onSelect: onSelect) {
            SessionWindowLabel(window: window, isNarrowing: hint != nil)
        }
    }
}

/// A clock and `12 h`, with a dot when the window is actually holding
/// something back.
///
/// The dot is the whole reason the header carries this control rather than
/// only Settings: a board that is quiet because nothing is running and a board
/// that is quiet because the window is narrow look identical, and a person who
/// cannot tell them apart stops trusting the board.
///
/// A glyph rather than the word "Last", and the short form of the duration,
/// because everything to the right of the summary chips takes width away from
/// them — and a chip that has been squeezed off the header is a number a
/// person came to the board to read.
struct SessionWindowLabel: View {
    let window: SessionWindow
    var isNarrowing = false

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "clock")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(AuspexPalette.text3)
            Text(window.shortTitle).foregroundStyle(AuspexPalette.text2)
            if isNarrowing {
                Circle()
                    .fill(AuspexPalette.text3)
                    .frame(width: 4, height: 4)
            }
            Image(systemName: "chevron.down")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(AuspexPalette.text3)
        }
        .font(AuspexType.body)
        .fixedSize()
    }
}
