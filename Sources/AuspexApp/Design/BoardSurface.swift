import SwiftUI

/// The board's ground: a near-black field with a faint measured grid on it.
///
/// The grid is doing a job, not decorating. An unlit dark region with nothing
/// in it is ambiguous — a person cannot tell an empty board from a view that
/// failed to draw — and a grid gives the space a scale, so a half-full wall
/// reads as a half-full wall. It is drawn once per size into a `Canvas`, which
/// is a single drawing pass rather than hundreds of views.
///
/// The spacing is tied to the card grid's rhythm so the two never beat against
/// each other at awkward zoom levels.
struct BoardSurfaceBackground: View {
    /// Distance between grid lines.
    var spacing: CGFloat = 26

    var body: some View {
        Canvas { context, size in
            var path = Path()
            var x: CGFloat = 0
            while x <= size.width {
                path.move(to: CGPoint(x: x + 0.5, y: 0))
                path.addLine(to: CGPoint(x: x + 0.5, y: size.height))
                x += spacing
            }
            var y: CGFloat = 0
            while y <= size.height {
                path.move(to: CGPoint(x: 0, y: y + 0.5))
                path.addLine(to: CGPoint(x: size.width, y: y + 0.5))
                y += spacing
            }
            context.stroke(path, with: .color(AuspexPalette.grid), lineWidth: 1)
        }
        .background(AuspexPalette.canvas)
        // No `drawingGroup()`: `Canvas` already rasterises, and wrapping it
        // adds a second offscreen pass that is redone whenever anything above
        // it in the tree redraws — which, on a board that updates twenty times
        // a second, is constantly.
        .accessibilityHidden(true)
    }
}

/// The chrome shared by everything that sits on the board: a flat panel with
/// a hairline border and a corner radius small enough to read as a cut edge
/// rather than as a rounded rectangle.
///
/// 3 pt, not 12. Rounded cards float; an operations board wants tiles that
/// tessellate. The one thing that ever glows is a card whose session is
/// blocked on a person, and it glows because nothing else does.
struct PanelChrome: ViewModifier {
    var isSelected = false
    var isHighlighted = false
    var highlightColor: Color = .clear
    var cornerRadius: CGFloat = 3

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(isSelected ? AuspexPalette.panelRaised : AuspexPalette.panel)
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(borderColor, lineWidth: isSelected ? 1.5 : 1)
            )
            // Applied only when it is actually drawn. A `shadow` with a clear
            // colour is not free — it still allocates the offscreen buffer the
            // blur would need — and on a wall of forty cards that is forty
            // buffers redrawn for nothing.
            .modifier(ConditionalGlow(isOn: isHighlighted, color: highlightColor))
    }

    private var borderColor: Color {
        if isSelected { return AuspexPalette.textSecondary.opacity(0.8) }
        if isHighlighted { return highlightColor.opacity(0.65) }
        return AuspexPalette.hairline
    }
}

/// A glow that exists only while it is on.
private struct ConditionalGlow: ViewModifier {
    let isOn: Bool
    let color: Color

    func body(content: Content) -> some View {
        if isOn {
            content.shadow(color: color.opacity(0.35), radius: 10)
        } else {
            content
        }
    }
}

extension View {
    /// Applies the standard panel chrome.
    func panelChrome(
        isSelected: Bool = false,
        isHighlighted: Bool = false,
        highlightColor: Color = .clear,
        cornerRadius: CGFloat = 3
    ) -> some View {
        modifier(
            PanelChrome(
                isSelected: isSelected,
                isHighlighted: isHighlighted,
                highlightColor: highlightColor,
                cornerRadius: cornerRadius
            )
        )
    }
}

/// A key/value pair in a card footer or a session header: a condensed
/// uppercase key over a monospaced value.
///
/// The key is tertiary and tiny on purpose. A person scanning a wall reads the
/// values; the keys are there for the first ten minutes and then never again.
struct MetaField: View {
    let key: String
    let value: String
    var isMono = true
    var tint: Color?

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(key)
                .auspexLabel(AuspexType.labelSmall)
                .foregroundStyle(AuspexPalette.textTertiary)
            Text(value)
                .font(isMono ? AuspexType.monoSmall : AuspexType.body)
                .foregroundStyle(tint ?? AuspexPalette.textSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .accessibilityElement(children: .combine)
    }
}

/// A count with a label under it, for section headers and the empty state's
/// watch list.
struct CountBadge: View {
    let value: Int
    let label: String
    let tint: Color

    var body: some View {
        HStack(spacing: 4) {
            Text("\(value)")
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(value == 0 ? AuspexPalette.textTertiary : tint)
            Text(label)
                .auspexLabel(AuspexType.labelSmall)
                .foregroundStyle(AuspexPalette.textTertiary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(value) \(label)")
    }
}
