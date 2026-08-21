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

/// The system's own sidebar material, behind the sidebar's tokens.
///
/// ## Why an `NSVisualEffectView` and not a translucent fill
///
/// A blur of *what is behind the window* cannot be expressed in SwiftUI on
/// macOS without one of these — `.background(.ultraThinMaterial)` samples the
/// view behind it inside the window, which for a column sitting on the app's
/// own canvas is a blur of a flat colour, which is a flat colour. The
/// behind-window blend mode is the thing that makes a Mac sidebar look like a
/// Mac sidebar, and it is also what tells a person which of two windows is in
/// front, because the material desaturates when the window loses key.
///
/// The material is `.sidebar` rather than one of the generic ones because that
/// is the one AppKit varies with the window's active state and with the
/// vibrancy of what is on it, and because a sidebar that used a popover's
/// material would be a sidebar that looks like a popover.
struct VisualEffectBackground: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .sidebar
    var blendingMode: NSVisualEffectView.BlendingMode = .behindWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        // Active regardless of key window state. `followsWindowActiveState`
        // is the default and it drains the material to a flat grey the moment
        // the person clicks into their editor — which is exactly when they are
        // most likely to glance at the board on the other screen.
        view.state = .followsWindowActiveState
        view.isEmphasized = false
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
        view.blendingMode = blendingMode
    }
}

/// The sidebar's ground: the material when it is switched on, the canvas token
/// when it is not.
///
/// One view rather than a conditional at the call site, because "which of
/// these two" is a decision the column should not have to restate, and because
/// the flat case has to be the *same* colour the board's ground is — a sidebar
/// a shade off the board is a tray, and the window is one surface.
struct SidebarBackground: View {
    let isTranslucent: Bool

    var body: some View {
        if isTranslucent {
            VisualEffectBackground()
        } else {
            AuspexPalette.canvas
        }
    }
}
