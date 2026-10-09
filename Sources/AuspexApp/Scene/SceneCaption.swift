import AgentSessionKit
import AppKit
import AuspexCore
import Foundation

/// One balloon over one person on Now's stage, in the words it will print.
///
/// Built from a ``NowFrame/Caption`` by ``NowCopy`` and handed to the scene
/// whole. Equatable, so a desk that is handed the balloon it already wears does
/// nothing but advance its stopwatch — see `DeskNode.setCaption(_:now:)`.
struct SceneCaption: Equatable {
    /// The three colours a balloon comes in. Idle and finished people wear
    /// none: the stage annotates what is happening, not what has stopped.
    enum Tone: Equatable {
        case working
        case needsYou
        case mayNeedYou

        init?(_ tone: NowFrame.Tone) {
            switch tone {
            case .working: self = .working
            case .needsYou: self = .needsYou
            case .mayNeedYou: self = .mayNeedYou
            case .done, .idle: return nil
            }
        }
    }

    let tone: Tone
    /// Drawn in the app's accent ahead of the body — the harness, on a
    /// working balloon.
    let lead: String?
    /// The words, without the stopwatch.
    let body: String
    /// What the stopwatch measures from. `nil` prints no stopwatch.
    let since: Date?

    /// The whole line at `now`: `Claude Code · WebSearch「Dots」 · 2m10s`.
    func text(now: Date) -> String {
        var parts: [String] = []
        if let lead { parts.append(lead) }
        parts.append(body)
        if let since { parts.append(NowFrame.compactDuration(now.timeIntervalSince(since))) }
        return parts.joined(separator: " · ")
    }

    /// The line, set in the balloon's ink with the lead in the accent.
    func attributed(_ text: String, theme: SceneTheme) -> NSAttributedString {
        let dark = theme.isDark
        let weight: NSFont.Weight = tone == .working ? .medium : .semibold
        let result = NSMutableAttributedString(
            string: text,
            attributes: [
                .font: NSFont.systemFont(ofSize: 11, weight: weight),
                .foregroundColor: Self.ink(tone, dark: dark)
            ]
        )
        if let lead, text.hasPrefix(lead) {
            result.addAttribute(
                .foregroundColor,
                value: AuspexPalette.nsColor(.accent, dark: dark),
                range: NSRange(location: 0, length: (lead as NSString).length)
            )
        }
        return result
    }

    /// The balloon's fill. Working is the board's own ink — near-black on a
    /// light office, near-white on a dark one — so it reads as speech rather
    /// than as a state colour; the other two are their list's mark.
    static func fill(_ tone: Tone, dark: Bool) -> NSColor {
        switch tone {
        case .working: AuspexPalette.nsColor(.text, dark: dark)
        case .needsYou: AuspexPalette.nsColor(.nowNeeds, dark: dark)
        case .mayNeedYou: AuspexPalette.nsColor(.nowMaybe, dark: dark)
        }
    }

    /// The words on that fill.
    ///
    /// White on the light red, as drawn. Charcoal on the amber in both
    /// appearances: white on `#C9931F` is 2.7:1, under even the graphical
    /// floor, and a balloon is read at a glance or not at all.
    static func ink(_ tone: Tone, dark: Bool) -> NSColor {
        let charcoal = AuspexPalette.nsColor(.bg0, dark: true)
        switch tone {
        case .working: return AuspexPalette.nsColor(.bg0, dark: dark)
        case .needsYou: return dark ? charcoal : .white
        case .mayNeedYou: return charcoal
        }
    }
}
