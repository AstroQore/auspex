import SwiftUI

/// The board's own button style: no chrome, and no system focus ring.
///
/// ## Why every custom control needs this
///
/// Almost every control in this window is drawn by hand — a chip, a pill, a
/// segment, a sidebar row, a card. They were all plain buttons, which
/// removes the *button's* appearance and leaves the *focus* appearance alone:
/// with full keyboard access on, or simply after a click, macOS draws its blue
/// ring around the control's bounding box. On a 22 pt chip that reads "1,176
/// done" the ring is bigger than the chip, it is the one blue thing in a
/// window with no blue in its palette, and it points at whatever was clicked
/// last rather than at anything a person needs.
///
/// So the ring is replaced rather than merely removed. The three columns of
/// the window switch the system effect off wholesale — see
/// ``SwiftUI/View/auspexControlFocus()`` — and this style puts a 1 pt `line2`
/// hairline back on whichever control keyboard focus is actually on. Focus
/// still moves, tab order still works, and what a keyboard user sees is the
/// board's own hairline instead of AppKit's ring.
///
/// ## Why the radius is a parameter
///
/// A ring that does not follow the shape it is around reads as a second
/// control behind the first. The window has three radii — 6 for pills and
/// chips, 7 for sidebar and list rows, 10 for cards and panels — so the style
/// takes one, defaulting to the row's.
struct AuspexButtonStyle: ButtonStyle {
    /// The corner the focus hairline follows. Matches the control's own
    /// background shape.
    var cornerRadius: CGFloat = 7

    func makeBody(configuration: Configuration) -> some View {
        FocusRing(cornerRadius: cornerRadius) { configuration.label }
    }

    /// The label, with the board's hairline around it while it has focus.
    ///
    /// A view of its own because `isFocused` is an environment value and a
    /// `ButtonStyle` is not a view — reading it needs something with a body,
    /// and that something has to sit *inside* the style so the answer is about
    /// this button rather than about its container.
    private struct FocusRing<Label: View>: View {
        let cornerRadius: CGFloat
        @ViewBuilder let label: Label

        @Environment(\.isFocused) private var isFocused

        var body: some View {
            label.overlay {
                if isFocused {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(AuspexPalette.line2, lineWidth: 1)
                }
            }
        }
    }
}

extension ButtonStyle where Self == AuspexButtonStyle {
    /// The board's button: no chrome, no system focus ring, a hairline where
    /// keyboard focus lands.
    static var auspex: AuspexButtonStyle { AuspexButtonStyle() }

    /// The same, following a control whose corner is not the row's 7 pt.
    static func auspex(cornerRadius: CGFloat) -> AuspexButtonStyle {
        AuspexButtonStyle(cornerRadius: cornerRadius)
    }
}

extension View {
    /// Switches the system focus effect off for a region of hand-drawn
    /// controls.
    ///
    /// Applied to the window's columns rather than to each button, because
    /// `isFocusEffectDisabled` is an environment value and the ring is drawn by
    /// the button *around* its style — so switching it off from inside a
    /// `ButtonStyle` cannot work, and switching it off once per column cannot
    /// be forgotten by the next control somebody adds.
    ///
    /// Deliberately *not* applied at the window root: the sheets and the
    /// Settings pane are made of system controls — toggles, steppers, text
    /// fields, default-styled buttons — whose focus ring is the only thing
    /// telling a keyboard user where they are, and those keep it. See
    /// ``auspexSystemControlFocus()``.
    func auspexControlFocus() -> some View {
        focusEffectDisabled()
    }

    /// Puts the system focus effect back, inside a region that switched it off.
    ///
    /// For the panes made of AppKit's own controls, which draw nothing of their
    /// own to say where focus is.
    func auspexSystemControlFocus() -> some View {
        focusEffectDisabled(false)
    }
}
