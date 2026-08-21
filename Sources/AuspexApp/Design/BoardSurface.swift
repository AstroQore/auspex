import AppKit
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
    var spacing: CGFloat = 28

    /// The tile is bytes, and bytes cannot re-resolve themselves. Reading the
    /// scheme here is what makes the view re-evaluate — and therefore ask for
    /// the other tile — the moment the appearance changes.
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        // A tiled bitmap, not a `Canvas`. During a live window resize AppKit
        // stretches a rasterised layer's last contents until the next draw,
        // so a Canvas grid visibly scales and then snaps — which is exactly
        // the non-native feel a board should never have. A tiling image is
        // repeated by the layer itself at every size, so it is always crisp
        // and costs nothing to resize.
        Image(nsImage: GridTile.image(spacing: spacing, isDark: colorScheme == .dark))
            .resizable(resizingMode: .tile)
            .background(AuspexPalette.canvas)
            .accessibilityHidden(true)
    }
}

/// One cell of the board's grid, drawn once per spacing *and appearance*, and
/// cached.
///
/// Keyed by both because the tile is a baked bitmap: a dynamic `NSColor`
/// resolves when it is *drawn*, and `NSImage(size:flipped:)` draws lazily
/// under whatever appearance happens to be current at the time — which for a
/// cached tile is whichever window asked for it first. So the two concrete
/// values are read out of the palette by hand and each one gets its own entry.
@MainActor
private enum GridTile {
    private struct Key: Hashable {
        let spacing: CGFloat
        let isDark: Bool
    }

    private static var cache: [Key: NSImage] = [:]

    static func image(spacing: CGFloat, isDark: Bool) -> NSImage {
        let key = Key(spacing: spacing, isDark: isDark)
        if let cached = cache[key] { return cached }
        let size = NSSize(width: spacing, height: spacing)
        let ground = AuspexPalette.nsColor(.bg0, dark: isDark)
        let rule = AuspexPalette.nsColor(.grid, dark: isDark)
        let image = NSImage(size: size, flipped: false) { _ in
            ground.setFill()
            NSRect(origin: .zero, size: size).fill()
            rule.setFill()
            // One-pixel lines on the cell's left and bottom edges; tiled,
            // they meet into a continuous grid.
            NSRect(x: 0, y: 0, width: 1, height: spacing).fill()
            NSRect(x: 0, y: 0, width: spacing, height: 1).fill()
            return true
        }
        image.resizingMode = .tile
        cache[key] = image
        return image
    }
}

struct PanelChrome: ViewModifier {
    var isSelected = false
    var isHighlighted = false
    /// Whether the glow breathes rather than sitting still.
    ///
    /// Reserved for the one thing on the board that is *asking*. A still ring
    /// is a label; a breathing one is something waiting for you, and the
    /// difference is what a person reads from the far side of a desk without
    /// looking directly at the window.
    var breathes = false
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
            .modifier(
                ConditionalGlow(isOn: isHighlighted, breathes: breathes, color: highlightColor)
            )
    }

    private var borderColor: Color {
        if isHighlighted { return highlightColor.opacity(0.45) }
        if isSelected { return AuspexPalette.accent }
        return AuspexPalette.line
    }
}

/// A glow that exists only while it is on, and breathes only when it is
/// asking.
///
/// ## The radius is constant, and that is not a detail
///
/// A shadow enlarges the view's drawing bounds, so a radius that changes is a
/// *layout* change — and a layout change inside a lazy grid re-places every
/// subview the container is tracking. The crew wall learned this the
/// expensive way (see ``BreathingRing``): 14 % of a core became 100 %, pinned,
/// with the main thread inside `LazySubviewPlacements.placeSubviews`.
///
/// So the breath is in the *colour*, which is a paint change and nothing else,
/// and only the cards that are actually shouting pay for it.
///
/// ## And it is weaker in light
///
/// A glow is light spilling from a lit thing, and there is far less to spill
/// onto when the ground is already white — see ``AuspexPalette/glow(_:_:)``.
/// The breath's two ends both scale, so an asking card still pulses; it
/// pulses between two quieter alphas.
private struct ConditionalGlow: ViewModifier {
    let isOn: Bool
    var breathes = false
    let color: Color
    @State private var isDim = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        if isOn, breathes, !reduceMotion {
            content
                .shadow(
                    color: color.opacity(
                        AuspexPalette.glow(isDim ? 0.10 : 0.34, colorScheme)
                    ),
                    radius: 14
                )
                .animation(
                    .easeInOut(duration: 1.6).repeatForever(autoreverses: true),
                    value: isDim
                )
                .onAppear { isDim = true }
        } else if isOn {
            content.shadow(
                color: color.opacity(AuspexPalette.glow(0.22, colorScheme)),
                radius: 14
            )
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
        breathes: Bool = false,
        highlightColor: Color = .clear,
        cornerRadius: CGFloat = 10
    ) -> some View {
        modifier(
            PanelChrome(
                isSelected: isSelected,
                isHighlighted: isHighlighted,
                breathes: breathes,
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
            // Gated, and every scroll view in this app goes through here for
            // that reason: without it, a parent dividing space between its
            // children asks the scroll view how tall it would be, the scroll
            // view asks its lazy stack, and the lazy stack measures every row
            // it has — on every graph update. See ``ScrollSizeGate``.
            ScrollSizeGate {
                ScrollView {
                    content
                }
                .scrollContentBackground(.hidden)
            }
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
    /// Whether a segment can be pressed. A segment that leads somewhere with
    /// nothing in it is dimmed rather than hidden: a control that appears and
    /// disappears as the selection changes is a control nobody learns.
    var isEnabled: (Value) -> Bool = { _ in true }

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.value) { option in
                let isOn = option.value == selection
                let canPress = isEnabled(option.value)
                Button { selection = option.value } label: {
                    Text(option.title)
                        .font(AuspexType.pill)
                        .foregroundStyle(isOn ? AuspexPalette.text : AuspexPalette.text3)
                        .padding(.horizontal, 10)
                        .frame(height: 24)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(isOn ? AuspexPalette.selection : .clear)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.auspex(cornerRadius: 6))
                .disabled(!canPress)
                .opacity(canPress ? 1 : 0.4)
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
