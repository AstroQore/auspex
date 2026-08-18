import AgentSessionKit
import SwiftUI

/// A harness's fixed visual identity: one accent hue and one two-letter
/// monogram, for every surface that has to say *which agent this is*.
///
/// The board, the trace header, the sidebar, the menu bar, and M2's scene
/// view all answer that question, and they must answer it identically —
/// a harness whose colour shifts between two views is not an identity, it is
/// decoration. So the mapping lives here, once, and is total over `Harness`:
/// adding a harness to the kit fails this switch rather than silently drawing
/// it grey.
///
/// ## Why a monogram and not a logo
///
/// Auspex is not affiliated with any of these vendors and should not wear
/// their marks. A monogram in the harness's own hue is unambiguous at 18 pt,
/// carries no trademark, and — unlike a logo — still reads when the card is
/// desaturated because the session went stale.
///
/// ## Choosing the hues
///
/// The five harnesses a person is likely to run at once get hues spaced
/// around the wheel — coral, teal, azure, magenta, chartreuse — so two cards
/// are distinguishable by edge colour alone in peripheral vision. They are
/// deliberately *not* the vendors' brand colours: three of the five brands are
/// black or near-black, which is useless on a black board.
///
/// The accent appears in exactly two places on a card: the left rail and the
/// monogram tile. State owns the pill and the pulse line. Keeping identity and
/// activity in separate channels is what lets both use saturated colour
/// without competing.
struct HarnessStyle: Sendable, Hashable {
    /// The harness this describes.
    let harness: Harness
    /// The accent hue: the card's left rail and its monogram tile.
    let accent: Color
    /// Two letters, uppercase. Unique across the catalog.
    let monogram: String
    /// An SF Symbol for the places too small for a monogram — a menu row, a
    /// filter chip.
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
                monogram: "CX",
                symbolName: "chevron.left.forwardslash.chevron.right"
            )
        case .chatgptWork:
            HarnessStyle(
                harness: self,
                accent: AuspexPalette.harnessChatGPTWork,
                monogram: "GW",
                symbolName: "briefcase"
            )
        case .claudeCode:
            HarnessStyle(
                harness: self,
                accent: AuspexPalette.harnessClaudeCode,
                monogram: "CC",
                symbolName: "terminal"
            )
        case .claudeCowork:
            HarnessStyle(
                harness: self,
                accent: AuspexPalette.harnessClaudeCowork,
                monogram: "CK",
                symbolName: "person.2"
            )
        case .geminiCLI:
            HarnessStyle(
                harness: self,
                accent: AuspexPalette.harnessGeminiCLI,
                monogram: "GM",
                symbolName: "sparkle"
            )
        case .antigravity:
            HarnessStyle(
                harness: self,
                accent: AuspexPalette.harnessAntiGravity,
                monogram: "AG",
                symbolName: "arrow.up.forward"
            )
        case .grokBuild:
            HarnessStyle(
                harness: self,
                accent: AuspexPalette.harnessGrokBuild,
                monogram: "GB",
                symbolName: "hammer"
            )
        case .cursor:
            HarnessStyle(
                harness: self,
                accent: AuspexPalette.harnessCursor,
                monogram: "CU",
                symbolName: "cursorarrow.rays"
            )
        }
    }

    /// The harnesses the board watches for, in display order.
    ///
    /// The same list `Harness.allCases` gives, named here so a view reads as
    /// what it means rather than as an enum detail.
    static var boardOrder: [Harness] { allCases }
}

/// The monogram tile: two condensed capitals on a tinted square.
///
/// Drawn rather than composed from a `Label` so the tile is exactly square at
/// every size and the letters sit on its optical centre — a monogram that
/// drifts a point off centre is the kind of thing that makes a dense grid feel
/// sloppy without anyone being able to say why.
struct HarnessBadge: View {
    let harness: Harness
    var size: CGFloat = 22
    /// Drops the tile to a flat tint, for a session that has ended.
    var isMuted = false

    var body: some View {
        let style = harness.style
        let accent = isMuted ? AuspexPalette.textTertiary : style.accent
        RoundedRectangle(cornerRadius: size * 0.18, style: .continuous)
            .fill(accent.opacity(isMuted ? 0.10 : 0.16))
            .overlay(
                RoundedRectangle(cornerRadius: size * 0.18, style: .continuous)
                    .strokeBorder(accent.opacity(isMuted ? 0.20 : 0.42), lineWidth: 1)
            )
            .overlay(
                Text(style.monogram)
                    .font(.system(size: size * 0.45, weight: .bold).width(.condensed))
                    .tracking(0.4)
                    .foregroundStyle(accent)
            )
            .frame(width: size, height: size)
            .accessibilityLabel(style.displayName)
    }
}
