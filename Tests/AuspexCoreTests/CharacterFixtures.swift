import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

@testable import AuspexCore

/// Builds character packages on disk for the tests that read them.
///
/// The strips are real PNGs rather than fixture files, because every check the
/// loader makes is about pixel dimensions — a synthetic strip is the only way
/// to write "this one is 47 pixels tall" as a test rather than as a comment.
enum CharacterFixtures {
    /// A fresh temporary directory standing in for the user's home.
    static func temporaryHome() throws -> URL {
        let home = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("auspex-characters-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        return home
    }

    /// Writes a transparent PNG with one opaque block in the middle of every
    /// frame, so frame 0 is never empty and the left and right margins are.
    @discardableResult
    static func writeStrip(
        to url: URL,
        cell: Int,
        frames: Int,
        height: Int? = nil
    ) throws -> URL {
        let width = cell * frames
        let tall = height ?? cell
        let bytesPerRow = width * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * tall)

        for frame in 0..<max(frames, 1) {
            let originX = frame * cell
            // Inside the middle sixteen columns and off the bottom edge: the
            // same box `validate_character.py` insists on.
            for y in (tall / 4)..<tall {
                for x in (cell / 4)..<(cell * 3 / 4) {
                    let offset = (y * width + originX + x) * 4
                    guard offset + 3 < pixels.count else { continue }
                    pixels[offset] = 0xE0
                    pixels[offset + 1] = 0x78
                    pixels[offset + 2] = 0x5A
                    pixels[offset + 3] = 0xFF
                }
            }
        }

        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let image = CGImage(
                  width: width,
                  height: tall,
                  bitsPerComponent: 8,
                  bitsPerPixel: 32,
                  bytesPerRow: bytesPerRow,
                  space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                  provider: provider,
                  decode: nil,
                  shouldInterpolate: false,
                  intent: .defaultIntent
              ),
              let destination = CGImageDestinationCreateWithURL(
                  url as CFURL, UTType.png.identifier as CFString, 1, nil
              )
        else {
            throw FixtureError.couldNotWritePNG(url)
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw FixtureError.couldNotWritePNG(url)
        }
        return url
    }

    /// Writes a package folder: `character.json` plus a strip per pose.
    @discardableResult
    static func writePackage(
        in root: URL,
        id: String,
        displayName: String? = nil,
        kind: String = "person",
        harness: String? = "claudeCode",
        accent: String? = "#E0785A",
        cell: Int = 32,
        poses: [String: (frames: Int, fps: Double)] = ["idle": (2, 2)],
        writeStrips: Bool = true,
        manifestOverride: String? = nil
    ) throws -> URL {
        let directory = root.appendingPathComponent(id, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        if let manifestOverride {
            try manifestOverride.write(
                to: directory.appendingPathComponent("character.json"),
                atomically: true,
                encoding: .utf8
            )
        } else {
            var json: [String: Any] = [
                "id": id,
                "displayName": displayName ?? id,
                "kind": kind,
                "cell": cell,
                "anchor": "bottomCenter",
                "poses": poses.mapValues { ["frames": $0.frames, "fps": $0.fps] }
            ]
            if let harness { json["harness"] = harness }
            if let accent { json["accent"] = accent }
            let data = try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
            try data.write(to: directory.appendingPathComponent("character.json"))
        }

        if writeStrips {
            for (name, spec) in poses {
                try writeStrip(
                    to: directory.appendingPathComponent("\(name).png"),
                    cell: cell,
                    frames: spec.frames
                )
            }
        }
        return directory
    }

    enum FixtureError: Error {
        case couldNotWritePNG(URL)
    }
}
