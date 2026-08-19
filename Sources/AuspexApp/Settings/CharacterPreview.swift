import AppKit
import AuspexCore
import CoreGraphics
import ImageIO
import SwiftUI

/// Frame 0 of a character's most representative pose, for anything outside the
/// scene that has to show what a package looks like.
///
/// The scene cannot help here: its frames are `SKTexture`s, which only exist
/// once there is a renderer, and the Settings pane has to draw a character
/// whether or not the office is on screen. So this reads the same PNG a second
/// time and cuts one cell out of it.
///
/// Frame 0 specifically, and not a running animation. It is the frame the
/// handoff document requires to stand on its own — it is what Reduce Motion
/// shows, and what a person judges a character by — so a preview that animated
/// would be showing something the office might never draw.
@MainActor
enum CharacterPreview {
    /// The box a preview is drawn in, in points: four times a 32-pixel cell.
    /// A 48-pixel character fills the same box rather than a bigger one, which
    /// is the rule the scene follows too.
    static let boxSize: CGFloat = 128

    /// Frame 0 of `package`, or `nil` when it has no strips at all.
    static func image(for package: CharacterPackage) -> NSImage? {
        let key = Key(id: package.id, path: package.directory.path)
        if let cached = cache[key] { return cached }
        let image = render(package)
        cache[key] = image
        return image
    }

    /// Throws every cached preview away. Called on reload, because a package
    /// can be redrawn without its id or its path changing.
    static func invalidate() {
        cache.removeAll(keepingCapacity: true)
    }

    private static func render(_ package: CharacterPackage) -> NSImage? {
        guard let file = package.previewPose,
              let source = CGImageSourceCreateWithURL(file.url as CFURL, nil),
              let sheet = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return nil }

        let cell = min(file.cell, sheet.width)
        guard cell > 0 else { return nil }
        let cropped = sheet.cropping(
            to: CGRect(x: 0, y: 0, width: cell, height: min(cell, sheet.height))
        ) ?? sheet
        // Sized in points equal to its pixels, so the SwiftUI `Image` that
        // scales it up is scaling a known quantity.
        return NSImage(cgImage: cropped, size: NSSize(width: cropped.width, height: cropped.height))
    }

    private struct Key: Hashable {
        let id: String
        let path: String
    }

    private static var cache: [Key: NSImage?] = [:]
}

/// A character, drawn at four times its size on the well the rest of the app
/// uses for insets.
///
/// `interpolation(.none)` is the whole point: a pixel character scaled with any
/// filtering at all arrives as mush, and the Settings pane is where a person
/// checks their own pixels.
struct CharacterPreviewTile: View {
    let package: CharacterPackage
    var size: CGFloat = CharacterPreview.boxSize

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(AuspexPalette.well)
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .strokeBorder(AuspexPalette.hairline, lineWidth: 1)
            if let image = CharacterPreview.image(for: package) {
                Image(nsImage: image)
                    .interpolation(.none)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: size - 8, height: size - 8)
            } else {
                VStack(spacing: 4) {
                    Image(systemName: "square.dashed")
                        .font(.system(size: 16))
                    Text("No art")
                        .auspexLabel(AuspexType.labelSmall)
                }
                .foregroundStyle(AuspexPalette.textTertiary)
            }
        }
        .frame(width: size, height: size)
        .accessibilityLabel("\(package.displayName), \(package.previewPose?.name ?? "no art")")
    }
}
