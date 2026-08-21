import AppKit
import SwiftUI

/// Every colour Auspex draws with — the "Signal Room" palette, in two
/// appearances.
///
/// ## Why these are built in code
///
/// A SwiftPM target can carry an asset catalog, but that means a resource
/// bundle, which means `build_app.sh` has to place it inside `Contents/`
/// before signing, and it means a colour is defined somewhere no reviewer
/// reads. `NSColor`s cost nothing and keep the whole palette on one screen,
/// where every value can be compared against its neighbours.
///
/// ## Two appearances, one table
///
/// Auspex used to force `.preferredColorScheme(.dark)`, and the palette was
/// one column of near-black. It follows the system now, so every token is a
/// *pair* — and the pair is declared in one place, ``values(_:)``, which is a
/// `switch` over ``Name`` and therefore total: a token cannot be added with a
/// dark value and no light one, because the compiler will not let the switch
/// compile. The named `Color`s below are one line each and do nothing but read
/// a row out of that table.
///
/// The dark column is no longer near-black either. Both columns are derived
/// from one pair — background `#2D2D2B`, foreground `#F9F9F7` — swapped, so
/// the two appearances are the same room with the lights on or off rather than
/// two designs. The neutral is a warm charcoal, which is what stops a wall of
/// terracotta and amber cards reading as if it were lit by a different lamp
/// than its own ground.
///
/// ## The grammar
///
/// Four surface steps and three text steps, and that is the whole of the
/// neutral scale. Saturated colour is spent on three channels and no others:
/// **state** — what a session is doing — **harness accent** — whose session it
/// is — and the single app **accent**, which means "this is the thing you
/// picked or the thing focus is on" and never means anything else. Keeping
/// them apart is what lets all three be loud without competing.
///
/// ## Contrast, measured
///
/// WCAG 2.1 ratios, computed by `AuspexPaletteTests` on every build so the
/// numbers below cannot rot. `text` and `text2` clear 4.5:1 on every surface
/// in both appearances; the worst case is `text2` on `raised` in dark, at
/// 5.47:1.
///
/// | token | dark on panel | light on panel |
/// | --- | --- | --- |
/// | `text` | 11.66 | 13.80 |
/// | `text2` | 6.17 | 6.51 |
/// | `text3` | 3.32 | 3.38 |
///
/// `text3` is the scenery step — keys, units, section labels, the things a
/// person reads in their first ten minutes and never again — and it is
/// deliberately held at the 3:1 graphical-object floor rather than raised to
/// 4.5:1. Raising it would put it within one perceptual step of `text2` and
/// collapse a three-step scale into two, which costs more legibility than it
/// buys. The two appearances are matched (3.32 against 3.38), so the choice is
/// the same choice in both.
///
/// Every state colour clears 3:1 against its own 10 %-tinted pill except
/// `ended`, at 1.78 dark / 2.03 light. That one is intentional: an ended
/// session's whole card is drawn at 62 % opacity, and a pill that shouted the
/// word "Ended" would be the loudest thing on a wall of finished work.
enum AuspexPalette {
    // MARK: - The table

    /// Every colour that has a name, so that a token cannot exist in one
    /// appearance only and so the tests can walk the whole palette.
    ///
    /// The role aliases (`canvas`, `panel`, `hairline`, …) are *not* cases:
    /// they are second names for these rows, not extra colours.
    enum Name: String, CaseIterable, Sendable {
        // Surfaces
        /// The window's ground: the board, the sidebar, the trace gutter.
        case bg0
        /// A session card, a rack row, a popover.
        case bg1
        /// An inset well: a chip, a code block, an expanded payload.
        case bg2
        /// A surface that is lifted — a card under the pointer, a popover over
        /// a popover.
        case bg3
        /// The board's measured grid, one step off the ground.
        case grid

        // Lines
        /// The default 1 px border. Just visible; never a frame.
        case line
        /// A divider that has to survive next to a lit card, and the menu bar
        /// panel's edge.
        case line2

        // Text
        /// Titles, values, anything a person actually reads.
        case text
        /// Supporting copy: activity lines, chip text, secondary counts.
        case text2
        /// Keys, units, section labels, and everything that is scenery.
        case text3

        // The app's own tint
        /// Selection, keyboard focus, links, the active segment, every system
        /// control's `.tint`. One hue, the same in both appearances, and the
        /// only colour in the window that means "you chose this".
        case accent
        /// The ground under something that is selected: the accent, laid over
        /// the canvas at a fifth strength, baked so it is a surface rather
        /// than a translucency over whatever happens to be behind it.
        case selection

        // State — what a session is doing
        /// Cool and quiet: the model is working and nobody is needed.
        case stateThinking
        /// A tool is open. Amber because it is activity, not alarm.
        case stateTool
        /// The working tree is being changed.
        case stateWriting
        /// Children are running.
        case stateDelegating
        /// Blocked on a person. The only colour on the wall allowed to be
        /// loud, because it is the only state that will never resolve itself.
        case statePermission
        /// Nothing outstanding.
        case stateIdle
        /// Working, but silent for longer than it should be.
        case stateStale
        /// Over.
        case stateEnded

        // Harness identity
        case harnessCodex
        case harnessChatGPTWork
        case harnessClaudeCode
        case harnessClaudeCowork
        case harnessGeminiCLI
        case harnessAntiGravity
        case harnessGrokBuild
        case harnessGrokBot
        case harnessCursor
    }

    /// The two values behind a name, as `0xRRGGBB`.
    ///
    /// A `switch` rather than a dictionary so it is total: adding a case to
    /// ``Name`` without giving it both appearances does not compile.
    ///
    /// ## Where the light column comes from
    ///
    /// The neutrals are the dark column's derivation run the other way from
    /// the same anchor pair (`#2D2D2B` / `#F9F9F7`). The state colours keep
    /// their hue and are re-balanced for a white ground: every one of them
    /// clears 3:1 on its own pill in both appearances (`ended` excepted — see
    /// the type's documentation).
    ///
    /// The harness accents keep their hue exactly — an identity that shifted
    /// between appearances would not be an identity — and only their
    /// brightness moves, by the least that brings them to 3:1 against the
    /// light canvas. Four of the nine were already legible and are unchanged
    /// (`chatgptWork` 3.16, `cursor` 3.04 against the light canvas);
    /// `antigravity` needed the most, at ×0.70, because chartreuse on white is
    /// the worst case a hue can be. Ratios against the light canvas after the
    /// adjustment: codex 3.02, ChatGPT Work 3.16, Claude Code 3.01, Claude
    /// Cowork 3.03, Gemini CLI 3.00, AntiGravity 3.03, Grok Build 3.02, Grok
    /// Bot 3.03, Cursor 3.04.
    static func values(_ name: Name) -> (dark: UInt32, light: UInt32) {
        switch name {
        case .bg0: (0x2D_2D2B, 0xF9_F9F7)
        case .bg1: (0x35_3533, 0xFF_FFFF)
        case .bg2: (0x26_2624, 0xF1_F1EE)
        case .bg3: (0x3D_3D3A, 0xFF_FFFF)
        case .grid: (0x35_3533, 0xEC_ECE8)

        case .line: (0x3F_3F3C, 0xE4_E4E0)
        case .line2: (0x4A_4A46, 0xD3_D3CE)

        case .text: (0xF9_F9F7, 0x2D_2D2B)
        case .text2: (0xB8_B8B3, 0x5E_5E5A)
        case .text3: (0x85_8580, 0x8C_8C87)

        case .accent: (0xCC_7D5E, 0xCC_7D5E)
        case .selection: (0x4A_3B34, 0xF0_E0D8)

        case .stateThinking: (0x7F_B0F5, 0x2F_6FD6)
        case .stateTool: (0xE8_B04A, 0xB0_780A)
        case .stateWriting: (0x5F_C98B, 0x1E_8F52)
        case .stateDelegating: (0xB5_94FF, 0x6E_47D4)
        case .statePermission: (0xFF_6B74, 0xD4_313F)
        // Two steps darker in light than the tertiary grey it matches in dark:
        // a pill is its colour over a 10 % wash of itself, and that wash is
        // what takes `#8C8C87` under 3:1 on a white ground.
        case .stateIdle: (0x8C_8C87, 0x86_8681)
        case .stateStale: (0xB5_9A5A, 0x8E_6E1F)
        case .stateEnded: (0x5E_5E5A, 0xB0_B0AB)

        case .harnessCodex: (0x2D_D4BF, 0x13_A290)
        case .harnessChatGPTWork: (0x22_A06B, 0x22_A06B)
        case .harnessClaudeCode: (0xE0_785A, 0xDA_7456)
        case .harnessClaudeCowork: (0xCE_8F6E, 0xBF_8262)
        case .harnessGeminiCLI: (0x7D_D3FC, 0x51_99BC)
        case .harnessAntiGravity: (0xB4_E048, 0x78_9C22)
        case .harnessGrokBuild: (0xF4_5FA0, 0xEE_5B9B)
        case .harnessGrokBot: (0xF9_8BBE, 0xD4_6F9E)
        case .harnessCursor: (0x4C_8DFF, 0x4C_8DFF)
        }
    }

    // MARK: - Surfaces

    static let bg0 = color(.bg0)
    static let bg1 = color(.bg1)
    static let bg2 = color(.bg2)
    static let bg3 = color(.bg3)

    // MARK: - Lines

    static let line = color(.line)
    static let line2 = color(.line2)

    // MARK: - Text

    static let text = color(.text)
    static let text2 = color(.text2)
    static let text3 = color(.text3)

    // MARK: - The app's own tint

    /// The one hue that means "chosen". See ``Name/accent``.
    static let accent = color(.accent)
    /// The ground under a selected row or segment. See ``Name/selection``.
    static let selection = color(.selection)

    // MARK: - State

    static let stateThinking = color(.stateThinking)
    static let stateTool = color(.stateTool)
    static let stateWriting = color(.stateWriting)
    static let stateDelegating = color(.stateDelegating)
    static let statePermission = color(.statePermission)
    static let stateIdle = color(.stateIdle)
    static let stateStale = color(.stateStale)
    static let stateEnded = color(.stateEnded)

    // MARK: - Harness accents
    //
    // Canonical and fixed. They are spaced around the wheel so two cards are
    // distinguishable by their marks' tint alone in peripheral vision, and
    // they are deliberately *not* the vendors' brand colours: three of those
    // are black or near-black, which is invisible on a dark board.

    static let harnessCodex = color(.harnessCodex)
    static let harnessChatGPTWork = color(.harnessChatGPTWork)
    static let harnessClaudeCode = color(.harnessClaudeCode)
    static let harnessClaudeCowork = color(.harnessClaudeCowork)
    static let harnessGeminiCLI = color(.harnessGeminiCLI)
    static let harnessAntiGravity = color(.harnessAntiGravity)
    static let harnessGrokBuild = color(.harnessGrokBuild)
    /// xAI's other harness — a lighter, softer magenta than Grok Build's, so
    /// the pair reads as one vendor and still as two harnesses.
    static let harnessGrokBot = color(.harnessGrokBot)
    static let harnessCursor = color(.harnessCursor)

    // MARK: - Shadow
    //
    // Not a `Name`, because it is not a paint: it is the colour a drop shadow
    // is cast in, and it carries an alpha rather than a hue. A light window
    // gets a much weaker one — the same 50 % black that reads as depth under a
    // popover on charcoal reads as dirt on white.

    /// The drop shadow under a popover, a sheet, or a floating panel.
    static let shade = dynamic(dark: (0x00_0000, 0.50), light: (0x00_0000, 0.16))

    /// How much of a coloured glow's dark-appearance alpha survives in light.
    ///
    /// A glow is light spilling from a lit thing, and there is far less to
    /// spill onto when the ground is already white. Six tenths is where the
    /// halo around a `Needs you` card still reads as a halo on white without
    /// becoming a smudge.
    static func glow(_ alpha: Double, _ scheme: ColorScheme) -> Double {
        scheme == .dark ? alpha : alpha * 0.6
    }

    // MARK: - Role aliases
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
    /// A card that is lifted — under the pointer, or over another panel.
    /// See ``bg3``.
    static let panelRaised = bg3
    /// An inset well. See ``bg2``.
    static let well = bg2
    /// The default border. See ``line``.
    static let hairline = line
    /// A divider that has to survive next to a lit card. See ``line2``.
    static let hairlineStrong = line2
    /// The board's background grid, which is one step off the ground: enough
    /// to give the wall a scale, not enough to read as content.
    static let grid = color(.grid)
    /// See ``text``.
    static let textPrimary = text
    /// See ``text2``.
    static let textSecondary = text2
    /// See ``text3``.
    static let textTertiary = text3

    // MARK: - Construction

    /// The colour for a name, as a `Color` that re-resolves itself whenever
    /// the appearance it is drawn in changes.
    ///
    /// `NSColor(name:dynamicProvider:)` is the only mechanism on this platform
    /// that gives a *dynamic* colour without an asset catalog, and dynamic is
    /// the whole point: a `Color` built from one `0xRRGGBB` would be baked at
    /// launch, and switching appearance would repaint the system's chrome
    /// around a window whose own pixels never moved.
    static func color(_ name: Name) -> Color {
        let (dark, light) = values(name)
        return dynamic(dark: (dark, 1), light: (light, 1))
    }

    /// The concrete sRGB colour a name has in one appearance.
    ///
    /// For the surfaces that cannot hold a dynamic colour — a `CALayer`'s
    /// `backgroundColor`, a baked bitmap tile, a SpriteKit texture — which
    /// have to resolve once and be told to resolve again. Everything that goes
    /// through SwiftUI should use ``color(_:)`` and never this.
    static func nsColor(_ name: Name, dark: Bool) -> NSColor {
        let (darkValue, lightValue) = values(name)
        return srgb(dark ? darkValue : lightValue, alpha: 1)
    }

    /// Resolves any of this palette's colours — including one that arrived as
    /// a `Color` from somewhere else — against an explicit appearance.
    ///
    /// The one correct way to get bytes out of a dynamic colour: the drawing
    /// appearance has to be current *while* the conversion happens, or AppKit
    /// answers with whatever the last view to draw was using.
    static func resolve(_ color: Color, for appearance: NSAppearance) -> NSColor {
        var out = NSColor.gray
        appearance.performAsCurrentDrawingAppearance {
            out = NSColor(color).usingColorSpace(.sRGB) ?? .gray
        }
        return out
    }

    /// Whether an appearance is one of the dark ones.
    static func isDark(_ appearance: NSAppearance) -> Bool {
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }

    /// A colour that answers to the appearance it is drawn in.
    private static func dynamic(
        dark: (rgb: UInt32, alpha: Double),
        light: (rgb: UInt32, alpha: Double)
    ) -> Color {
        Color(
            nsColor: NSColor(name: nil) { appearance in
                isDark(appearance)
                    ? srgb(dark.rgb, alpha: dark.alpha)
                    : srgb(light.rgb, alpha: light.alpha)
            }
        )
    }

    /// Builds a colour from `0xRRGGBB` in the sRGB space.
    ///
    /// sRGB explicitly rather than `deviceRGB`: the hex values above were
    /// chosen against an sRGB reference, and letting them mean whatever the
    /// current display profile says would shift every accent on a wide-gamut
    /// screen.
    private static func srgb(_ rgb: UInt32, alpha: Double) -> NSColor {
        NSColor(
            srgbRed: CGFloat((rgb >> 16) & 0xFF) / 255,
            green: CGFloat((rgb >> 8) & 0xFF) / 255,
            blue: CGFloat(rgb & 0xFF) / 255,
            alpha: alpha
        )
    }
}
