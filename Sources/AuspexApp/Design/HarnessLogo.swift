import AgentSessionKit
import AppKit
import CoreGraphics
import SwiftUI

/// The vendor mark for a harness, loaded from the SVGs vendored under
/// `Sources/AuspexApp/Resources/ProviderIcons`.
///
/// ## Why the real logos
///
/// A board's whole job is to be read across a room, and identity is the first
/// thing a person resolves — before the state colour, before the title. A pair
/// of condensed capitals is legible but not *recognisable*: it is something to
/// decode, while Claude's starburst and OpenAI's flower are already known
/// before they are read. So Auspex wears the marks, single-colour
/// and drawn as templates, tinted with the harness accent rather than the
/// vendor's own brand colour — three of the eight brands are black or
/// near-black, which is invisible on a black board.
///
/// Two harnesses can share one mark, because they share a vendor and a binary:
/// Claude Code and Claude Cowork are both Claude's, Codex and ChatGPT Work are
/// both OpenAI's. They are told apart by the accent and by the full name
/// beside them, never by a modified logo.
///
/// ## Loading
///
/// `NSImage(contentsOf:)` reads an SVG directly on macOS 11 and later, and the
/// result is a vector image that redraws at any size — which is why one file
/// serves 13 pt in the sidebar and 28 pt in a header. Every load is cached by
/// `(harness, size)`, because a board frame arrives twenty times a second and
/// re-reading six files per frame would be a file system call per card.
///
/// The cache is `@MainActor` rather than locked: every caller is a SwiftUI
/// `body`, a `SpriteKit` node, or an `ImageRenderer`, and all three already run
/// there.
@MainActor
enum HarnessLogo {
    /// The pixel sizes the app draws marks at, for the doc comment's sake and
    /// for anything that wants to warm the cache.
    static let standardSizes: [CGFloat] = [16, 20, 24, 28]

    /// The mark file for a harness, without its extension.
    ///
    /// A vendor, not a harness: the two Claude harnesses share Claude's mark
    /// and the two OpenAI ones share the flower. Gemini CLI and AntiGravity do
    /// *not* share, because AntiGravity ships its own.
    static func assetName(for harness: Harness) -> String {
        switch harness {
        case .claudeCode, .claudeCowork: "ProviderIcon-claude"
        case .codex, .chatgptWork: "ProviderIcon-codex"
        case .cursor: "ProviderIcon-cursor"
        case .grokBuild: "ProviderIcon-grok"
        case .antigravity: "ProviderIcon-antigravity"
        case .geminiCLI: "ProviderIcon-gemini"
        }
    }

    /// The mark as a template `NSImage` at `size` points, or `nil` when the
    /// resource is missing.
    static func nsImage(for harness: Harness, size: CGFloat) -> NSImage? {
        let key = Key(harness: harness, size: size)
        if let cached = cache[key] { return cached }
        guard let url = Bundle.module.url(
            forResource: assetName(for: harness),
            withExtension: "svg",
            subdirectory: "ProviderIcons"
        ), let image = NSImage(contentsOf: url) else { return nil }
        image.size = NSSize(width: size, height: size)
        // A template image takes its colour from whatever draws it, which is
        // what lets one white glyph be tinted per harness and dimmed for an
        // ended session without a second asset.
        image.isTemplate = true
        cache[key] = image
        return image
    }

    /// The mark as a SwiftUI `Image`, already in template rendering mode.
    ///
    /// `nil` rather than a placeholder, so a caller can decide what a missing
    /// resource should look like — ``fallback(for:)`` is the answer everywhere
    /// in this app, but a renderer that must not silently substitute a symbol
    /// can still tell the difference.
    static func image(for harness: Harness, size: CGFloat) -> Image? {
        nsImage(for: harness, size: size).map { Image(nsImage: $0).renderingMode(.template) }
    }

    /// What to draw when the mark could not be loaded: the harness's SF Symbol.
    ///
    /// It should never be reached — the SVGs ship inside the bundle — and it
    /// exists so a resource that failed to copy degrades to a shape rather than
    /// to a hole where the identity was.
    static func fallback(for harness: Harness) -> Image {
        Image(systemName: harness.style.symbolName)
    }

    /// The mark rasterised for SpriteKit, in white with the glyph's own alpha.
    ///
    /// The scene cannot use the template image: `SKSpriteNode` tints by
    /// blending a colour into the texture's RGB, so it needs real pixels and
    /// does its own colouring through `colorBlendFactor`. Rendered at
    /// `pixelSize` square and cached alongside the rest.
    static func cgImage(for harness: Harness, pixelSize: Int) -> CGImage? {
        let key = Key(harness: harness, size: CGFloat(-pixelSize))
        if let cached = rasterCache[key] { return cached }
        guard let source = nsImage(for: harness, size: CGFloat(pixelSize)) else { return nil }
        guard let representation = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixelSize,
            pixelsHigh: pixelSize,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return nil }

        let context = NSGraphicsContext(bitmapImageRep: representation)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        // Drawn white on transparent: `SKSpriteNode` replaces the RGB with the
        // harness accent at `colorBlendFactor = 1`, and the alpha is what
        // carries the shape.
        source.draw(
            in: NSRect(x: 0, y: 0, width: pixelSize, height: pixelSize),
            from: .zero,
            operation: .sourceOver,
            fraction: 1
        )
        NSGraphicsContext.restoreGraphicsState()

        let raster = representation.cgImage
        rasterCache[key] = raster
        return raster
    }

    private struct Key: Hashable {
        let harness: Harness
        let size: CGFloat
    }

    private static var cache: [Key: NSImage] = [:]
    private static var rasterCache: [Key: CGImage] = [:]
}

/// A harness's mark on a tinted tile — the one identity element every surface
/// shares.
///
/// The tile is not decoration. At 13 pt in the sidebar a bare glyph is a smudge
/// against the panel; a rounded square of the harness accent at 14 % gives it a
/// footprint, a consistent optical size across six marks of very different
/// densities, and an edge that survives next to a state pill. Identity lives in
/// the accent and the mark; activity lives in the pill and the pulse line, and
/// keeping the two channels apart is what lets both use saturated colour.
struct HarnessBadge: View {
    let harness: Harness
    var size: CGFloat = 22
    /// Drops the tile to a flat tint, for a session that has ended.
    var isMuted = false

    var body: some View {
        let style = harness.style
        let accent = isMuted ? AuspexPalette.textTertiary : style.accent
        let glyph = size * 0.62

        RoundedRectangle(cornerRadius: size * 0.18, style: .continuous)
            .fill(accent.opacity(isMuted ? 0.10 : 0.14))
            .overlay(
                RoundedRectangle(cornerRadius: size * 0.18, style: .continuous)
                    .strokeBorder(accent.opacity(isMuted ? 0.20 : 0.42), lineWidth: 1)
            )
            .overlay {
                mark(size: glyph)
                    .foregroundStyle(accent)
                    .opacity(isMuted ? 0.75 : 1)
            }
            .frame(width: size, height: size)
            .accessibilityLabel(style.displayName)
            .help(style.displayName)
    }

    @ViewBuilder
    private func mark(size glyph: CGFloat) -> some View {
        if let logo = HarnessLogo.image(for: harness, size: glyph) {
            logo
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: glyph, height: glyph)
        } else {
            HarnessLogo.fallback(for: harness)
                .font(.system(size: glyph * 0.82, weight: .semibold))
        }
    }
}
