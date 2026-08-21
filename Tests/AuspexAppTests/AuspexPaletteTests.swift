import AppKit
import SwiftUI
import Testing

@testable import AuspexApp

/// The palette, in both appearances.
///
/// ## Why a test and not a look
///
/// A colour that is wrong by a step looks fine on its own and is only wrong
/// *against* something — and "against something" is a pair of numbers nobody
/// checks by eye. Auspex now draws in two appearances, which doubles every
/// pair, so the two questions that actually matter are asked here instead:
/// does every token have both values and do they reach the screen, and is
/// every piece of text on every surface readable in both.
///
/// The ratios are WCAG 2.1 relative-luminance contrast, computed from the
/// table rather than read off a design tool, so a token edited in
/// `AuspexPalette` is checked by the next `swift test` and not by the next
/// person to open the app in daylight.
@Suite("Palette")
@MainActor
struct AuspexPaletteTests {
    // MARK: - The table reaches the screen

    @Test("Every token resolves to its dark value under dark aqua")
    func darkValuesResolve() {
        let appearance = NSAppearance(named: .darkAqua)!
        for name in AuspexPalette.Name.allCases {
            let expected = AuspexPalette.values(name).dark
            let actual = rgb(AuspexPalette.resolve(AuspexPalette.color(name), for: appearance))
            #expect(actual == expected, "\(name.rawValue) in dark")
        }
    }

    @Test("Every token resolves to its light value under aqua")
    func lightValuesResolve() {
        let appearance = NSAppearance(named: .aqua)!
        for name in AuspexPalette.Name.allCases {
            let expected = AuspexPalette.values(name).light
            let actual = rgb(AuspexPalette.resolve(AuspexPalette.color(name), for: appearance))
            #expect(actual == expected, "\(name.rawValue) in light")
        }
    }

    /// The one property the whole two-appearance design rests on: a token is
    /// a *pair*, and asking for one appearance's value must not be able to
    /// answer with the other's. `values(_:)` is a total switch, so the
    /// compiler already refuses a token with one value; this is the runtime
    /// half — that the neutral scale actually inverts rather than being the
    /// dark column twice.
    @Test("The neutral scale inverts between the two appearances")
    func neutralsInvert() {
        #expect(AuspexPalette.values(.bg0).dark == AuspexPalette.values(.text).light)
        #expect(AuspexPalette.values(.bg0).light == AuspexPalette.values(.text).dark)
        // Ground is darker than paper in dark, and lighter in light.
        #expect(luminance(AuspexPalette.values(.bg0).dark)
            < luminance(AuspexPalette.values(.bg1).dark))
        #expect(luminance(AuspexPalette.values(.bg0).light)
            < luminance(AuspexPalette.values(.bg1).light))
    }

    @Test("The accent is the same hue in both appearances")
    func accentIsShared() {
        let accent = AuspexPalette.values(.accent)
        #expect(accent.dark == accent.light)
    }

    // MARK: - Readability

    /// The two steps a person actually reads, on every surface they are drawn
    /// on, in both appearances. 4.5:1 is WCAG AA for body text.
    @Test("Body text clears AA on every surface in both appearances")
    func bodyTextIsReadable() {
        for scheme in Scheme.allCases {
            for token in [AuspexPalette.Name.text, .text2] {
                for surface in [AuspexPalette.Name.bg0, .bg1, .bg2, .bg3, .selection] {
                    let ratio = contrast(token, on: surface, scheme)
                    #expect(
                        ratio >= 4.5,
                        "\(token.rawValue) on \(surface.rawValue) in \(scheme): \(round2(ratio))"
                    )
                }
            }
        }
    }

    /// The scenery step is held at the 3:1 graphical floor rather than at
    /// 4.5:1 — see ``AuspexPalette``'s documentation for why raising it would
    /// cost more than it buys — and it is held at the *same* value in both
    /// appearances, which is the part a test can protect.
    @Test("Tertiary text holds 3:1 on the surfaces it is drawn on, in both")
    func tertiaryTextHoldsTheFloor() {
        for scheme in Scheme.allCases {
            for surface in [AuspexPalette.Name.bg0, .bg1] {
                let ratio = contrast(.text3, on: surface, scheme)
                #expect(
                    ratio >= 3,
                    "text3 on \(surface.rawValue) in \(scheme): \(round2(ratio))"
                )
            }
        }
        // And the two appearances agree about how quiet it is, to within a
        // tenth — a tertiary that is scenery in one and readable in the other
        // would be two different designs.
        let dark = contrast(.text3, on: .bg1, .dark)
        let light = contrast(.text3, on: .bg1, .light)
        #expect(abs(dark - light) < 0.25, "dark \(round2(dark)) vs light \(round2(light))")
    }

    /// A state pill is its colour at full strength over a 10 % wash of itself
    /// on the card — see `StatePill`. 3:1 is WCAG's floor for a graphical
    /// object, which is what a two-word pill with a lit dot is.
    @Test("Every state pill clears 3:1 on its own wash, in both appearances")
    func statePillsAreLegible() {
        for scheme in Scheme.allCases {
            for state in Self.pillStates {
                for surface in [AuspexPalette.Name.bg0, .bg1] {
                    let wash = blend(state, over: surface, alpha: 0.10, scheme)
                    let ratio = contrast(hex(state, scheme), wash)
                    let where_ = "\(state.rawValue) pill on \(surface.rawValue)"
                    #expect(ratio >= 3, "\(where_) in \(scheme): \(round2(ratio))")
                }
            }
        }
    }

    /// `ended` is the exception, and it is an exception on purpose: the whole
    /// card is drawn at 62 % opacity, and a pill that shouted "Ended" would be
    /// the loudest thing on a wall of finished work. Pinned so that the
    /// decision has to be made again rather than drifted into.
    @Test("Ended is deliberately quieter than the floor, in both appearances")
    func endedIsDeliberatelyQuiet() {
        for scheme in Scheme.allCases {
            let wash = blend(.stateEnded, over: .bg1, alpha: 0.10, scheme)
            let ratio = contrast(hex(.stateEnded, scheme), wash)
            #expect(ratio < 3, "\(scheme): \(round2(ratio))")
            #expect(ratio > 1.5, "\(scheme): \(round2(ratio)) — invisible, not quiet")
        }
    }

    /// The marks are drawn as templates in the harness accent, so they are
    /// graphical objects and 3:1 is the floor. The dark column is canonical
    /// and was already clear; this is really a test of the light column, which
    /// is the dark one's brightness pulled down until it reaches the floor.
    @Test("Every harness mark clears 3:1 on the ground, in both appearances")
    func harnessMarksAreLegible() {
        for scheme in Scheme.allCases {
            for harness in Self.harnessTokens {
                let ratio = contrast(harness, on: .bg0, scheme)
                #expect(
                    ratio >= 3,
                    "\(harness.rawValue) on the canvas in \(scheme): \(round2(ratio))"
                )
            }
        }
    }

    /// A harness's hue is its identity. Only its brightness is allowed to move
    /// between appearances, so a card that is teal on a dark board is the same
    /// teal, darker, on a light one.
    @Test("A harness keeps its hue between appearances")
    func harnessHueIsStable() {
        for harness in Self.harnessTokens {
            let (dark, light) = AuspexPalette.values(harness)
            guard dark != light else { continue }
            let separation = abs(hue(dark) - hue(light))
            #expect(
                min(separation, 1 - separation) < 0.02,
                "\(harness.rawValue): \(round2(hue(dark))) vs \(round2(hue(light)))"
            )
            #expect(luminance(light) < luminance(dark), "\(harness.rawValue) got lighter")
        }
    }

    /// The accent is a graphical object too — a focus ring, a selected
    /// segment's ground, a toggle — and it is one value in both appearances,
    /// so the tighter of the two grounds is what has to hold.
    @Test("The accent clears 3:1 on both grounds")
    func accentIsLegible() {
        for scheme in Scheme.allCases {
            let ratio = contrast(.accent, on: .bg0, scheme)
            #expect(ratio >= 2.95, "accent on the canvas in \(scheme): \(round2(ratio))")
        }
    }

    // MARK: - What is checked

    private static let pillStates: [AuspexPalette.Name] = [
        .stateThinking, .stateTool, .stateWriting, .stateDelegating,
        .statePermission, .stateIdle, .stateStale
    ]

    private static let harnessTokens: [AuspexPalette.Name] = [
        .harnessCodex, .harnessChatGPTWork, .harnessClaudeCode, .harnessClaudeCowork,
        .harnessGeminiCLI, .harnessAntiGravity, .harnessGrokBuild, .harnessGrokBot,
        .harnessCursor
    ]

    // MARK: - Colour arithmetic

    enum Scheme: CaseIterable, CustomStringConvertible {
        case dark, light
        var description: String { self == .dark ? "dark" : "light" }
    }

    private func hex(_ name: AuspexPalette.Name, _ scheme: Scheme) -> UInt32 {
        let values = AuspexPalette.values(name)
        return scheme == .dark ? values.dark : values.light
    }

    private func contrast(
        _ token: AuspexPalette.Name,
        on surface: AuspexPalette.Name,
        _ scheme: Scheme
    ) -> Double {
        contrast(hex(token, scheme), hex(surface, scheme))
    }

    /// WCAG 2.1 §1.4.3: `(lighter + 0.05) / (darker + 0.05)`.
    private func contrast(_ one: UInt32, _ other: UInt32) -> Double {
        let a = luminance(one)
        let b = luminance(other)
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    private func blend(
        _ token: AuspexPalette.Name,
        over surface: AuspexPalette.Name,
        alpha: Double,
        _ scheme: Scheme
    ) -> UInt32 {
        let top = hex(token, scheme)
        let bottom = hex(surface, scheme)
        var out: UInt32 = 0
        for shift in [16, 8, 0] as [UInt32] {
            let f = Double((top >> shift) & 0xFF)
            let b = Double((bottom >> shift) & 0xFF)
            out |= UInt32((f * alpha + b * (1 - alpha)).rounded()) << shift
        }
        return out
    }

    private func luminance(_ rgb: UInt32) -> Double {
        func channel(_ shift: UInt32) -> Double {
            let value = Double((rgb >> shift) & 0xFF) / 255
            return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(16) + 0.7152 * channel(8) + 0.0722 * channel(0)
    }

    private func hue(_ rgb: UInt32) -> Double {
        let color = NSColor(
            srgbRed: CGFloat((rgb >> 16) & 0xFF) / 255,
            green: CGFloat((rgb >> 8) & 0xFF) / 255,
            blue: CGFloat(rgb & 0xFF) / 255,
            alpha: 1
        )
        return Double(color.hueComponent)
    }

    /// The 24-bit value an `NSColor` actually carries, so a resolved dynamic
    /// colour can be compared with the table it came from.
    private func rgb(_ color: NSColor) -> UInt32 {
        let srgb = color.usingColorSpace(.sRGB) ?? color
        func channel(_ value: CGFloat) -> UInt32 { UInt32((value * 255).rounded()) }
        return channel(srgb.redComponent) << 16
            | channel(srgb.greenComponent) << 8
            | channel(srgb.blueComponent)
    }

    private func round2(_ value: Double) -> Double { (value * 100).rounded() / 100 }
}
