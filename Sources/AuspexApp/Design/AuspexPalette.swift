import SwiftUI

/// Every colour Auspex draws with — the "Signal Room" palette.
///
/// ## Why these are built in code
///
/// A SwiftPM target can carry an asset catalog, but that means a resource
/// bundle, which means `build_app.sh` has to place it inside `Contents/`
/// before signing, and it means a colour is defined somewhere no reviewer
/// reads. Static `NSColor`s cost nothing and keep the whole palette on one
/// screen, where every value can be compared against its neighbours.
///
/// ## Dark only, on purpose
///
/// Auspex is a wall of live sessions, usually on a second display, usually
/// glanced at rather than read. There is exactly one appearance, and the
/// window forces it (`.preferredColorScheme(.dark)`): a light translation
/// would need every state colour darkened to hold its contrast against white,
/// and a state colour that means two slightly different things depending on
/// the system appearance is not a signal, it is decoration.
///
/// ## The grammar
///
/// Four surface steps and three text steps, and that is the whole of the
/// neutral scale. Saturated colour is spent on two channels and no others:
/// **state** — what a session is doing — and **harness accent** — whose
/// session it is. Keeping them apart is what lets both be loud without
/// competing, and it is why nothing else on the board is allowed a hue.
enum AuspexPalette {
    // MARK: Surfaces

    /// `bg0` — the window's ground: the board, the sidebar, the trace gutter.
    /// Near-black with a faint warm-neutral cast, never `#000`, so a card
    /// border still reads as an edge.
    static let bg0 = srgb(0x10_1012)

    /// `bg1` — a session card, a rack row, a popover. One step up from the
    /// ground, which is all the lift a tile needs when the ground is this
    /// dark.
    static let bg1 = srgb(0x16_1619)

    /// `bg2` — an inset well: a chip, a code block, an expanded payload.
    static let bg2 = srgb(0x1C_1C20)

    /// `bg3` — a control that is *on*: the selected sidebar row, the active
    /// segment of the view-mode picker, the selected filter tab.
    static let bg3 = srgb(0x23_2328)

    // MARK: Lines

    /// The default 1 px border. Just visible; never a frame.
    static let line = srgb(0x26_262C)

    /// A divider that has to survive next to a lit card, and the menu bar
    /// panel's edge.
    static let line2 = srgb(0x33_333A)

    // MARK: Text

    /// Titles, values, anything a person actually reads.
    static let text = srgb(0xED_EDEF)
    /// Supporting copy: activity lines, chip text, secondary counts.
    static let text2 = srgb(0xA0_A0A8)
    /// Keys, units, section labels, and everything that is scenery.
    static let text3 = srgb(0x6C_6C75)

    // MARK: State — the only saturated colour on the board besides identity

    /// Cool and quiet: the model is working and nobody is needed.
    static let stateThinking = srgb(0x6E_A8FE)
    /// A tool is open. Amber because it is activity, not alarm.
    static let stateTool = srgb(0xF2_B544)
    /// The working tree is being changed — the one tool activity a person
    /// might want to interrupt, so it gets its own colour.
    static let stateWriting = srgb(0x4F_D08A)
    /// Children are running.
    static let stateDelegating = srgb(0xB4_8CFF)
    /// Blocked on a person. The only colour on the wall that is allowed to be
    /// loud, because it is the only state that will never resolve itself.
    static let statePermission = srgb(0xFF_5C6C)
    /// Nothing outstanding.
    static let stateIdle = srgb(0x7A_7A85)
    /// The "stale" tag: working, but silent for longer than it should be.
    static let stateStale = srgb(0xB3_9755)
    /// Over.
    static let stateEnded = srgb(0x46_464E)

    // MARK: Harness accents
    //
    // Canonical and fixed. They are spaced around the wheel so two cards are
    // distinguishable by their marks' tint alone in peripheral vision, and
    // they are deliberately *not* the vendors' brand colours: three of those
    // are black or near-black, which is invisible on a black board.

    static let harnessCodex = srgb(0x2D_D4BF)
    static let harnessChatGPTWork = srgb(0x22_A06B)
    static let harnessClaudeCode = srgb(0xE0_785A)
    static let harnessClaudeCowork = srgb(0xCE_8F6E)
    static let harnessGeminiCLI = srgb(0x7D_D3FC)
    static let harnessAntiGravity = srgb(0xB4_E048)
    static let harnessGrokBuild = srgb(0xF4_5FA0)
    /// xAI's other harness — a lighter, softer magenta than Grok Build's, so
    /// the pair reads as one vendor and still as two harnesses.
    static let harnessGrokBot = srgb(0xF9_8BBE)
    static let harnessCursor = srgb(0x4C_8DFF)

    // MARK: Role aliases
    //
    // The names the view layer had before the palette was named. Kept as
    // aliases rather than renamed at four dozen call sites: a role name says
    // what a colour is *for*, which is the more useful thing to read in a
    // view body, while the `bg0…text3` names are what the design system calls
    // them and what a mock is checked against.

    /// The board's ground. See ``bg0``.
    static let canvas = bg0
    /// The sidebar and the trace gutter. The same ground as the board: the
    /// mock's window is one continuous surface divided by hairlines, not a
    /// stack of trays.
    static let canvasDeep = bg0
    /// A card, a panel, a rack row. See ``bg1``.
    static let panel = bg1
    /// A card that is selected or under the pointer. See ``bg3``.
    static let panelRaised = bg3
    /// An inset well. See ``bg2``.
    static let well = bg2
    /// The default border. See ``line``.
    static let hairline = line
    /// A divider that has to survive next to a lit card. See ``line2``.
    static let hairlineStrong = line2
    /// The board's background grid, which is one step off the ground: enough
    /// to give the wall a scale, not enough to read as content.
    static let grid = bg1
    /// See ``text``.
    static let textPrimary = text
    /// See ``text2``.
    static let textSecondary = text2
    /// See ``text3``.
    static let textTertiary = text3

    // MARK: Construction

    /// Builds a colour from `0xRRGGBB` in the sRGB space.
    ///
    /// sRGB explicitly rather than `deviceRGB`: the hex values above were
    /// chosen against an sRGB reference, and letting them mean whatever the
    /// current display profile says would shift every accent on a wide-gamut
    /// screen.
    private static func srgb(_ rgb: Int) -> Color {
        Color(
            .sRGB,
            red: Double((rgb >> 16) & 0xFF) / 255,
            green: Double((rgb >> 8) & 0xFF) / 255,
            blue: Double(rgb & 0xFF) / 255,
            opacity: 1
        )
    }
}
