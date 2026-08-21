import AppKit
import AuspexCore
import SwiftUI

extension AppearanceMode {
    /// What SwiftUI has to be told at the root. `nil` is "no preference",
    /// which is how a window is made to follow the Mac.
    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }

    /// The AppKit appearance this resolves to, for the surfaces that have to
    /// bake bytes rather than hold a dynamic colour — a `CALayer`, a SpriteKit
    /// texture, an offscreen render. `system` asks the application, which is
    /// the only thing that knows.
    @MainActor
    var nsAppearance: NSAppearance {
        switch self {
        case .system: NSApplication.shared.effectiveAppearance
        case .light: NSAppearance(named: .aqua) ?? NSAppearance()
        case .dark: NSAppearance(named: .darkAqua) ?? NSAppearance()
        }
    }

    /// The mode a command-line `appearance=light|dark` argument names.
    ///
    /// Only the two explicit ones: a headless render that asked for "the
    /// system's appearance" would be a screenshot whose colours depend on what
    /// time of day the build ran, which is the opposite of what the renderers
    /// exist for.
    static func rendered(from token: String) -> AppearanceMode? {
        switch token {
        case "light": .light
        case "dark": .dark
        default: nil
        }
    }
}

extension View {
    /// Applies the window's appearance: the scheme itself, and the accent that
    /// every system control in it tints with.
    ///
    /// Both at one root rather than per view, so that popovers, menus, sheets
    /// and the search field's own chrome — none of which inherit a background
    /// colour — inherit the appearance instead.
    func auspexAppearance(_ mode: AppearanceMode) -> some View {
        preferredColorScheme(mode.colorScheme)
            // Toggles, sliders, steppers, links, the Settings window's own
            // controls. AppKit's default is the system accent, which is
            // whatever colour a person set in System Settings and therefore
            // the one hue in this window that is not part of its design.
            .tint(AuspexPalette.accent)
    }
}

/// The sidebar's ground: the system's own, or the board's.
///
/// ## Why "translucent" is a view that draws nothing
///
/// It is tempting to host an `NSVisualEffectView` here, and it would be
/// wrong. On this platform a `NavigationSplitView`'s sidebar column is already
/// inside the system's sidebar material — dumping the hierarchy under a
/// hosting view shows the column's host sitting in an
/// `NSContainerConcentricGlassEffectView` over a `BackdropView` — so the
/// material is not something to add, it is something Auspex used to paint
/// over. It painted over it because there was one appearance and the board's
/// ground had to be exactly one colour everywhere; with two appearances and a
/// person who can choose, the honest options are "let the platform's sidebar
/// be a sidebar" and "make it the same flat ground the board is". Adding a
/// second behind-window blur inside the first would be neither, and would
/// compound into a milkier surface than either.
///
/// Flat is not a lesser option. Somebody running a wall of these on a second
/// display wants the window to be one continuous surface divided by
/// hairlines, and a sidebar showing their desktop through it is noise.
struct SidebarBackground: View {
    let isTranslucent: Bool

    var body: some View {
        if isTranslucent {
            // Nothing. The column keeps the material the split view gave it.
            Color.clear
        } else {
            AuspexPalette.canvas
        }
    }
}
