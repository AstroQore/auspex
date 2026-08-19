import AgentSessionKit
import SwiftUI

/// A harness's fixed visual identity: one accent hue and one vendor mark, for
/// every surface that has to say *which agent this is*.
///
/// The board, the trace header, the sidebar, the menu bar, and the scene view
/// all answer that question, and they must answer it identically — a harness
/// whose colour shifts between two views is not an identity, it is decoration.
/// So the mapping lives here, once, and is total over `Harness`: adding a
/// harness to the kit fails this switch rather than silently drawing it grey.
///
/// ## The mark, and the name
///
/// The glyph itself is ``HarnessLogo``'s job — the vendors' own single-colour
/// marks, drawn as templates in the accent below. There are no initials: a
/// pair of condensed capitals is something a person decodes, and the marks are
/// recognised before they are read. Wherever a mark could be ambiguous — two Claude
/// harnesses share one glyph, and so do the two OpenAI ones — the accent and
/// the harness's **full** name resolve it. Auspex never abbreviates a harness
/// name in a UI string.
///
/// ## Choosing the hues
///
/// The harnesses a person is likely to run at once get hues spaced around the
/// wheel — coral, teal, azure, magenta, chartreuse — so two cards are
/// distinguishable by edge colour alone in peripheral vision. They are
/// deliberately *not* the vendors' brand colours: three of the eight brands are
/// black or near-black, which is useless on a black board. The two pairs that
/// share a mark get neighbouring but distinct hues, so the pair reads as one
/// vendor and the two harnesses still read as two things.
///
/// The accent appears in exactly two places on a card: the left rail and the
/// mark's tile. State owns the pill and the pulse line. Keeping identity and
/// activity in separate channels is what lets both use saturated colour
/// without competing.
struct HarnessStyle: Sendable, Hashable {
    /// The harness this describes.
    let harness: Harness
    /// The accent hue: the card's left rail and its mark tile.
    let accent: Color
    /// An SF Symbol, used only when the vendor mark cannot be loaded. See
    /// ``HarnessLogo/fallback(for:)``.
    let symbolName: String

    /// The harness's own name, for a tooltip or a section header.
    var displayName: String { harness.displayName }
}

extension Harness {
    /// This harness's fixed identity.
    var style: HarnessStyle {
        switch self {
        case .codex:
            HarnessStyle(
                harness: self,
                accent: AuspexPalette.harnessCodex,
                symbolName: "chevron.left.forwardslash.chevron.right"
            )
        case .chatgptWork:
            HarnessStyle(
                harness: self,
                accent: AuspexPalette.harnessChatGPTWork,
                symbolName: "briefcase"
            )
        case .claudeCode:
            HarnessStyle(
                harness: self,
                accent: AuspexPalette.harnessClaudeCode,
                symbolName: "terminal"
            )
        case .claudeCowork:
            HarnessStyle(
                harness: self,
                accent: AuspexPalette.harnessClaudeCowork,
                symbolName: "person.2"
            )
        case .geminiCLI:
            HarnessStyle(
                harness: self,
                accent: AuspexPalette.harnessGeminiCLI,
                symbolName: "sparkle"
            )
        case .antigravity:
            HarnessStyle(
                harness: self,
                accent: AuspexPalette.harnessAntiGravity,
                symbolName: "arrow.up.forward"
            )
        case .grokBuild:
            HarnessStyle(
                harness: self,
                accent: AuspexPalette.harnessGrokBuild,
                symbolName: "hammer"
            )
        case .cursor:
            HarnessStyle(
                harness: self,
                accent: AuspexPalette.harnessCursor,
                symbolName: "cursorarrow.rays"
            )
        case .grokBot:
            HarnessStyle(
                harness: self,
                accent: AuspexPalette.harnessGrokBot,
                symbolName: "bubble.left.and.text.bubble.right"
            )
        }
    }

    /// The harnesses the board watches for, in display order.
    ///
    /// The same list `Harness.allCases` gives, named here so a view reads as
    /// what it means rather than as an enum detail.
    static var boardOrder: [Harness] { allCases }
}
