import AppKit
import SwiftUI

/// Every colour Auspex draws with.
///
/// ## Why these are built in code
///
/// A SwiftPM target can carry an asset catalog, but that means a resource
/// bundle, which means `build_app.sh` has to place it inside `Contents/`
/// before signing, and it means a colour is defined somewhere no reviewer
/// reads. Dynamic `NSColor`s cost nothing and keep the whole palette on one
/// screen, where the light and dark values sit next to each other and can be
/// compared.
///
/// ## Dark is the hero
///
/// Auspex is a wall of live sessions, usually on a second display, usually
/// glanced at rather than read. The dark palette is built for that: a
/// blue-black canvas so the harness accents and state colours are the only
/// saturated things on screen, and a very small number of surface steps —
/// canvas, panel, hairline — so the grid reads as a grid rather than as a
/// pile of floating cards.
///
/// Light mode is not an afterthought, but it is a translation: the same
/// hierarchy with the surfaces inverted and every accent darkened enough to
/// hold its contrast against white.
enum AuspexPalette {
    // MARK: Surfaces

    /// The board's ground. Near-black with a blue cast, never pure `#000`,
    /// so a black card border still reads as an edge.
    static let canvas = dynamic(dark: 0x0A0B10, light: 0xEFF1F5)

    /// The sidebar and the trace gutter — a step deeper than the canvas, so
    /// the board is the lit surface in the window.
    static let canvasDeep = dynamic(dark: 0x07080C, light: 0xE6E9F0)

    /// A session card, a section header, a popover.
    static let panel = dynamic(dark: 0x12141B, light: 0xFFFFFF)

    /// A card under the pointer, or the selected one.
    static let panelRaised = dynamic(dark: 0x181C26, light: 0xFFFFFF)

    /// The inset well an expanded trace row's JSON sits in.
    static let well = dynamic(dark: 0x0C0E14, light: 0xF3F5F9)

    // MARK: Lines

    /// The default 1px border. Just visible; never a frame.
    static let hairline = dynamic(dark: 0x232735, light: 0xD9DEE8)

    /// A divider that has to survive next to a lit card.
    static let hairlineStrong = dynamic(dark: 0x2F3548, light: 0xC2C9D8)

    /// The board's background grid. Low enough to read as texture rather
    /// than as content, which is the whole point: it gives the wall a scale
    /// so an empty region looks like empty space and not like a broken view.
    static let grid = dynamic(dark: 0x171B27, light: 0xE2E6EE)

    // MARK: Text

    static let textPrimary = dynamic(dark: 0xE8EBF2, light: 0x131722)
    static let textSecondary = dynamic(dark: 0x8D95AB, light: 0x59627A)
    static let textTertiary = dynamic(dark: 0x5C6379, light: 0x8A93A6)

    // MARK: State

    /// Cool and quiet: the model is working and nobody is needed.
    static let stateThinking = dynamic(dark: 0x7AA2F7, light: 0x3557BE)
    /// A tool is open. Amber because it is activity, not alarm.
    static let stateTool = dynamic(dark: 0xF5A524, light: 0xA35F00)
    /// The working tree is being changed — the one tool activity a person
    /// might want to interrupt, so it gets its own colour.
    static let stateWriting = dynamic(dark: 0x3DD68C, light: 0x0C7C46)
    /// Children are running.
    static let stateDelegating = dynamic(dark: 0xA970FF, light: 0x6B31C4)
    /// Blocked on a person. The only colour on the wall that is allowed to
    /// be loud, because it is the only state that will never resolve itself.
    static let statePermission = dynamic(dark: 0xFF5468, light: 0xC81C32)
    /// Nothing outstanding.
    static let stateIdle = dynamic(dark: 0x6E7590, light: 0x707A91)
    /// Over.
    static let stateEnded = dynamic(dark: 0x495066, light: 0x98A0B2)
    /// The "stale" tag: working, but silent for longer than it should be.
    static let stateStale = dynamic(dark: 0xB39755, light: 0x7C6420)

    // MARK: Harness accents

    static let harnessCodex = dynamic(dark: 0x2DD4BF, light: 0x0B8A7D)
    static let harnessChatGPTWork = dynamic(dark: 0x22A06B, light: 0x0F7A53)
    static let harnessClaudeCode = dynamic(dark: 0xE0785A, light: 0xBC4C2B)
    static let harnessClaudeCowork = dynamic(dark: 0xCE8F6E, light: 0xA1653F)
    static let harnessGeminiCLI = dynamic(dark: 0x7DD3FC, light: 0x0C79AE)
    static let harnessAntiGravity = dynamic(dark: 0xB4E048, light: 0x67870F)
    static let harnessGrokBuild = dynamic(dark: 0xF45FA0, light: 0xBC2A6D)
    static let harnessCursor = dynamic(dark: 0x4C8DFF, light: 0x2059D0)

    // MARK: Construction

    /// A colour that resolves itself against whatever appearance it is drawn
    /// in — including the menu bar and popovers, which do not inherit the
    /// window's.
    private static func dynamic(dark: Int, light: Int) -> Color {
        Color(
            nsColor: NSColor(name: nil) { appearance in
                let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                return NSColor(rgb: isDark ? dark : light)
            }
        )
    }
}

private extension NSColor {
    /// Builds a colour from `0xRRGGBB` in the sRGB space.
    ///
    /// sRGB explicitly rather than `deviceRGB`: the hex values above were
    /// chosen against an sRGB reference, and letting them mean whatever the
    /// current device profile says would shift every accent on a wide-gamut
    /// display.
    convenience init(rgb: Int) {
        self.init(
            srgbRed: CGFloat((rgb >> 16) & 0xFF) / 255,
            green: CGFloat((rgb >> 8) & 0xFF) / 255,
            blue: CGFloat(rgb & 0xFF) / 255,
            alpha: 1
        )
    }
}
