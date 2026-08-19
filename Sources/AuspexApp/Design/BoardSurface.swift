import SwiftUI

/// The board's ground: the canvas with a faint measured grid on it.
///
/// The grid is doing a job, not decorating. An unlit dark region with nothing
/// in it is ambiguous — a person cannot tell an empty board from a view that
/// failed to draw — and a grid gives the space a scale, so a half-full wall
/// reads as a half-full wall. It is drawn once per size into a `Canvas`, which
/// is a single drawing pass rather than hundreds of views.
///
/// 28 pt, which is the mock's rhythm and a little under half a card's row
/// height, so the two never beat against each other.
struct BoardSurfaceBackground: View {
    /// Distance between grid lines.
    var spacing: CGFloat = 28

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
        // it in the tree redraws — which, on a board that updates several
        // times a second, is constantly.
        .accessibilityHidden(true)
    }
}

/// The chrome shared by everything that sits on the board: a flat panel a step
/// above the ground, a hairline border, and a 10 pt corner.
///
/// The one thing that ever glows is a card whose session is blocked on a
/// person, and it glows because nothing else does.
struct PanelChrome: ViewModifier {
    var isSelected = false
    var isHighlighted = false
    var highlightColor: Color = .clear
    var cornerRadius: CGFloat = 10

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(AuspexPalette.panel)
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(borderColor, lineWidth: isSelected || isHighlighted ? 1.5 : 1)
            )
            // Applied only when it is actually drawn. A `shadow` with a clear
            // colour is not free — it still allocates the offscreen buffer the
            // blur would need — and on a wall of forty cards that is forty
            // buffers redrawn for nothing.
            .modifier(ConditionalGlow(isOn: isHighlighted, color: highlightColor))
    }

    private var borderColor: Color {
        if isHighlighted { return highlightColor.opacity(0.45) }
        if isSelected { return AuspexPalette.text.opacity(0.35) }
        return AuspexPalette.line
    }
}

/// A glow that exists only while it is on.
private struct ConditionalGlow: ViewModifier {
    let isOn: Bool
    let color: Color

    func body(content: Content) -> some View {
        if isOn {
            content.shadow(color: color.opacity(0.22), radius: 14)
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
        cornerRadius: CGFloat = 10
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

/// `true` while the window is being drawn by ``WindowSnapshotRenderer``
/// rather than by a real window.
///
/// One flag, read by the three views that scroll. `ImageRenderer` has no
/// window and therefore no viewport, so a `ScrollView` proposes nothing to its
/// content and every lazy stack inside it draws zero rows — a screenshot of an
/// empty board. Laying the content out eagerly at the image's own size is what
/// makes the render show what a person would see.
private struct SnapshotRenderKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var isSnapshotRender: Bool {
        get { self[SnapshotRenderKey.self] }
        set { self[SnapshotRenderKey.self] = newValue }
    }
}

/// A scroll view, except while the window is being rendered offscreen.
struct BoardScroll<Content: View>: View {
    @Environment(\.isSnapshotRender) private var isSnapshotRender
    @ViewBuilder let content: Content

    var body: some View {
        if isSnapshotRender {
            // An overlay, not a frame: `frame(maxHeight: .infinity)` resolves
            // to whichever is *larger* of the proposal and the content, so a
            // board taller than the image would grow the column and push the
            // header off the top of it. An overlay never changes the size of
            // what it is over.
            Color.clear
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay(alignment: .topLeading) {
                    content.fixedSize(horizontal: false, vertical: true)
                }
                .clipped()
        } else {
            ScrollView {
                content
            }
            .scrollContentBackground(.hidden)
        }
    }
}

/// An inset chip: a fact that is worth boxing but not worth colouring.
///
/// Project, branch, working directory, an MCP server's name. One shape for all
/// of them, so a reader learns "boxed grey text is a fact about where this
/// session is" once rather than four times.
struct FactChip<Content: View>: View {
    var tint: Color?
    var isMono = false
    @ViewBuilder let content: Content

    var body: some View {
        content
            .font(isMono ? AuspexType.monoSmall : AuspexType.caption)
            .foregroundStyle(tint ?? AuspexPalette.text2)
            .lineLimit(1)
            .truncationMode(.middle)
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(tint.map { $0.opacity(0.08) } ?? AuspexPalette.bg2)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(tint.map { $0.opacity(0.25) } ?? AuspexPalette.line, lineWidth: 1)
            )
    }
}

extension FactChip where Content == Text {
    /// The common case: one string.
    init(_ text: String, tint: Color? = nil, isMono: Bool = false) {
        self.init(tint: tint, isMono: isMono) { Text(text) }
    }
}

/// A segmented control in the board's own chrome.
///
/// AppKit's segmented control cannot be made to look like this — it insists on
/// its own material, its own corner, and its own selection tint — and the
/// header bar is the one place in the window where the app's own idiom has to
/// win, because everything under it is drawn by hand.
struct SegmentedPicker<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [(value: Value, title: String)]

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.value) { option in
                let isOn = option.value == selection
                Button { selection = option.value } label: {
                    Text(option.title)
                        .font(AuspexType.pill)
                        .foregroundStyle(isOn ? AuspexPalette.text : AuspexPalette.text3)
                        .padding(.horizontal, 10)
                        .frame(height: 24)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(isOn ? AuspexPalette.bg3 : .clear)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isOn ? [.isButton, .isSelected] : .isButton)
            }
        }
        .padding(2)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous).fill(AuspexPalette.bg1)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(AuspexPalette.line, lineWidth: 1)
        )
    }
}

/// A key/value pair in a card footer or a session header: a small tertiary key
/// beside a monospaced value.
///
/// The key is tiny on purpose. A person scanning a wall reads the values; the
/// keys are there for the first ten minutes and then never again.
struct MetaField: View {
    let key: String
    let value: String
    var isMono = true
    var tint: Color?

    var body: some View {
        HStack(spacing: 5) {
            Text(key)
                .font(AuspexType.caption)
                .foregroundStyle(AuspexPalette.text3)
            Text(value)
                .font(isMono ? AuspexType.monoSmall : AuspexType.caption)
                .auspexTabularDigits()
                .foregroundStyle(tint ?? AuspexPalette.text)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .accessibilityElement(children: .combine)
    }
}

/// A count with a word after it: `28 live`, `457 done`.
///
/// The number is lit and the word is not, because the number is the thing
/// being compared down a column and the word is the unit.
struct CountBadge: View {
    let value: Int
    let label: String
    let tint: Color

    var body: some View {
        HStack(spacing: 5) {
            Text("\(value)")
                .font(AuspexType.monoCount)
                .auspexTabularDigits()
                .foregroundStyle(value == 0 ? AuspexPalette.text3 : tint)
            Text(label)
                .font(AuspexType.caption)
                .foregroundStyle(AuspexPalette.text3)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(value) \(label)")
    }
}
