import AgentSessionKit
import AgentSessionLive
import AppKit
import AuspexCore
import SpriteKit
import SwiftUI

/// Every colour the office is built from, resolved against one appearance.
///
/// SpriteKit has no equivalent of SwiftUI's dynamic colour: a texture is bytes,
/// and bytes cannot re-resolve themselves when a person switches to light mode.
/// So the scene resolves the whole palette once, keeps it as concrete sRGB
/// values, and throws its texture cache away when the appearance changes. The
/// shared colours come from ``AuspexPalette`` rather than from copies, because
/// a harness whose hue differs between the board and the scene is not an
/// identity — it is two decorations that happen to be near each other.
///
/// The furniture tones are the only colours defined here, and they are defined
/// here because nothing else in the app has furniture.
struct SceneTheme: Equatable {
    /// The appearance this was resolved for. Keys the texture cache.
    let id: String
    let isDark: Bool

    let canvas: NSColor
    let grid: NSColor
    let panel: NSColor
    let hairline: NSColor
    let hairlineStrong: NSColor
    let textPrimary: NSColor
    let textSecondary: NSColor
    let textTertiary: NSColor

    /// The lit surface of a desk.
    let deskTop: NSColor
    /// Its front panel, in shadow.
    let deskFront: NSColor
    /// Legs and the shadow they cast.
    let deskLeg: NSColor
    /// An office chair.
    let chair: NSColor
    /// A face. Deliberately a warm neutral rather than any particular skin
    /// tone: these are placeholder agents, not people, and the harness hue is
    /// what identifies them.
    let face: NSColor
    /// Outlines and eyes.
    let ink: NSColor
    /// A dark monitor, before any state lights it.
    let screenOff: NSColor
    /// The meeting room's carpet, and the tone its tables sit on.
    let carpet: NSColor
    /// The garden's ground.
    let grass: NSColor
    /// Leaves, hedges, the top of a tree.
    let leaf: NSColor
    /// Trunks, benches, the gate.
    let bark: NSColor
    /// The path, and the stone the gate is set in.
    let stone: NSColor

    private let harnessAccents: [Harness: NSColor]
    private let stateColors: [String: NSColor]

    /// This harness's accent, the same hue the board's rail uses.
    func accent(_ harness: Harness) -> NSColor {
        harnessAccents[harness] ?? textSecondary
    }

    /// This state's colour, the same hue the board's pulse line uses.
    func color(for state: SessionState) -> NSColor {
        stateColors[Self.stateKey(state)] ?? textSecondary
    }

    /// A stable name for a state, ignoring its payload. Two `toolCalling`
    /// states with different tool names are the same colour and the same
    /// animation, and treating them as one is what keeps the director from
    /// restarting an animation every time a tool name changes.
    static func stateKey(_ state: SessionState) -> String {
        switch state {
        case .idle: "idle"
        case .thinking: "thinking"
        case .toolCalling: "tool"
        case .writingFile: "writing"
        case .delegating: "delegating"
        case .waitingPermission: "permission"
        case .ended: "ended"
        }
    }

    /// Resolves the palette for `appearance`.
    static func resolved(for appearance: NSAppearance) -> SceneTheme {
        let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        func resolve(_ color: Color) -> NSColor {
            var out = NSColor.gray
            appearance.performAsCurrentDrawingAppearance {
                out = NSColor(color).usingColorSpace(.sRGB) ?? .gray
            }
            return out
        }
        func furniture(dark: Int, light: Int) -> NSColor {
            NSColor(sceneRGB: isDark ? dark : light)
        }

        var accents: [Harness: NSColor] = [:]
        for harness in Harness.allCases { accents[harness] = resolve(harness.style.accent) }

        var states: [String: NSColor] = [:]
        for state: SessionState in [
            .idle, .thinking, .toolCalling(name: ""), .writingFile(path: nil),
            .delegating(children: 1), .waitingPermission(tool: nil), .ended(reason: .exited)
        ] {
            states[stateKey(state)] = resolve(state.style.color)
        }

        return SceneTheme(
            id: appearance.name.rawValue,
            isDark: isDark,
            canvas: resolve(AuspexPalette.canvas),
            grid: resolve(AuspexPalette.grid),
            panel: resolve(AuspexPalette.panel),
            hairline: resolve(AuspexPalette.hairline),
            hairlineStrong: resolve(AuspexPalette.hairlineStrong),
            textPrimary: resolve(AuspexPalette.textPrimary),
            textSecondary: resolve(AuspexPalette.textSecondary),
            textTertiary: resolve(AuspexPalette.textTertiary),
            deskTop: furniture(dark: 0x39405A, light: 0xB6BFD2),
            deskFront: furniture(dark: 0x252B3D, light: 0x9CA6BC),
            deskLeg: furniture(dark: 0x1A1F2D, light: 0x7F8AA2),
            chair: furniture(dark: 0x2C3247, light: 0x8E98AE),
            face: furniture(dark: 0xD3C3B4, light: 0xC0AE9E),
            ink: furniture(dark: 0x0A0B10, light: 0x1B2030),
            screenOff: furniture(dark: 0x11141D, light: 0x6E7891),
            // The annexes are the same room seen from another chair, so their
            // tones are the furniture palette pushed a step warmer and a step
            // greener rather than a second colour scheme. A garden that
            // arrived in daylight green would be the one thing on a dark
            // board loud enough to read as an alert.
            carpet: furniture(dark: 0x2A2434, light: 0xB8B0C4),
            grass: furniture(dark: 0x23342A, light: 0xB3C9B6),
            leaf: furniture(dark: 0x3C5D43, light: 0x84A88A),
            bark: furniture(dark: 0x4A3B2E, light: 0x9C8570),
            stone: furniture(dark: 0x2E3138, light: 0xAEB3BE),
            harnessAccents: accents,
            stateColors: states
        )
    }
}

/// A tiny indexed canvas for hand-placed pixels.
///
/// Pixel art wants to be authored one pixel at a time, and every drawing API on
/// this platform wants to anti-alias. So the art is composed into a plain RGBA
/// buffer, handed to Core Graphics as an image without interpolation, and drawn
/// by SpriteKit with nearest-neighbour filtering. Three steps, and none of them
/// can soften an edge.
///
/// The origin is the **top left** and `y` increases downward, which is the
/// convention every pixel-art tool uses and the order the rows are stored in.
struct PixelCanvas {
    let width: Int
    let height: Int
    private var bytes: [UInt8]

    init(width: Int, height: Int) {
        self.width = width
        self.height = height
        self.bytes = [UInt8](repeating: 0, count: width * height * 4)
    }

    /// Paints one pixel. Out-of-bounds coordinates are ignored, so a pose can
    /// reach past the edge of the sprite without the caller checking.
    mutating func set(_ x: Int, _ y: Int, _ color: NSColor, alpha: CGFloat = 1) {
        guard x >= 0, y >= 0, x < width, y < height, alpha > 0 else { return }
        let (red, green, blue) = Self.components(color)
        let a = UInt8(clamping: Int((alpha * 255).rounded()))
        let index = (y * width + x) * 4
        // Premultiplied, because that is what the bitmap info promises.
        bytes[index] = UInt8(clamping: Int(CGFloat(red) * alpha))
        bytes[index + 1] = UInt8(clamping: Int(CGFloat(green) * alpha))
        bytes[index + 2] = UInt8(clamping: Int(CGFloat(blue) * alpha))
        bytes[index + 3] = a
    }

    /// Paints a filled rectangle.
    mutating func fill(
        _ x: Int, _ y: Int, _ w: Int, _ h: Int, _ color: NSColor, alpha: CGFloat = 1
    ) {
        guard w > 0, h > 0 else { return }
        for row in y..<(y + h) {
            for column in x..<(x + w) { set(column, row, color, alpha: alpha) }
        }
    }

    /// Clears a rectangle back to transparent. Distinct from filling with a
    /// clear colour, which would write opaque black: the buffer is
    /// premultiplied, so "no colour" and "no coverage" are the same four zero
    /// bytes and neither can be expressed as a paint.
    mutating func erase(_ x: Int, _ y: Int, _ w: Int, _ h: Int) {
        guard w > 0, h > 0 else { return }
        for row in max(0, y)..<min(height, y + h) {
            for column in max(0, x)..<min(width, x + w) {
                let index = (row * width + column) * 4
                bytes[index] = 0
                bytes[index + 1] = 0
                bytes[index + 2] = 0
                bytes[index + 3] = 0
            }
        }
    }

    /// Stamps `other` onto this canvas with its top-left corner at `x`, `y`.
    ///
    /// Only pixels the source actually covers are written, so a rig assembled
    /// out of two canvases keeps the transparent gaps of both. Both buffers are
    /// premultiplied and every pixel in this art is either fully opaque or
    /// fully clear, so copying the four bytes is the whole composite.
    mutating func blit(_ other: PixelCanvas, x: Int, y: Int) {
        for row in 0..<other.height {
            let destinationRow = y + row
            guard destinationRow >= 0, destinationRow < height else { continue }
            for column in 0..<other.width {
                let destinationColumn = x + column
                guard destinationColumn >= 0, destinationColumn < width else { continue }
                let source = (row * other.width + column) * 4
                guard other.bytes[source + 3] != 0 else { continue }
                let destination = (destinationRow * width + destinationColumn) * 4
                bytes[destination] = other.bytes[source]
                bytes[destination + 1] = other.bytes[source + 1]
                bytes[destination + 2] = other.bytes[source + 2]
                bytes[destination + 3] = other.bytes[source + 3]
            }
        }
    }

    /// The finished art as a Core Graphics image, at one pixel per pixel.
    ///
    /// The scene never needs this — it wants a texture — but everything
    /// *outside* the scene that has to show a procedural character does: an
    /// `SKTexture` only becomes pixels once there is a renderer, and the
    /// Settings pane draws characters whether or not the office is on screen.
    func cgImage() -> CGImage? {
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let space = CGColorSpace(name: CGColorSpace.sRGB)
        else { return nil }
        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: space,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
    }

    /// The finished sprite, at one texel per pixel and no interpolation.
    func texture() -> SKTexture {
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let image = CGImage(
                  width: width,
                  height: height,
                  bitsPerComponent: 8,
                  bitsPerPixel: 32,
                  bytesPerRow: width * 4,
                  space: space,
                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                  provider: provider,
                  decode: nil,
                  shouldInterpolate: false,
                  intent: .defaultIntent
              )
        else { return SKTexture() }
        let texture = SKTexture(cgImage: image)
        texture.filteringMode = .nearest
        return texture
    }

    private static func components(_ color: NSColor) -> (UInt8, UInt8, UInt8) {
        let srgb = color.usingColorSpace(.sRGB) ?? .gray
        return (
            UInt8(clamping: Int((srgb.redComponent * 255).rounded())),
            UInt8(clamping: Int((srgb.greenComponent * 255).rounded())),
            UInt8(clamping: Int((srgb.blueComponent * 255).rounded()))
        )
    }
}

/// What an agent's body is doing. One texture per pose, per harness.
///
/// Poses, not frames: the placeholder rig animates by swapping between two
/// poses and by moving whole nodes, which is enough for the six rhythms the
/// board's state language already defines and costs nothing to author. Real
/// frame strips, when they arrive, replace the whole rig — see ``SpriteLibrary``.
enum AgentPose: String, CaseIterable, Hashable {
    /// Hands on the desk. The resting pose, and the one half of typing.
    case rest
    /// Hands lifted a pixel. The other half of typing.
    case type
    /// One hand up. Blocked on a person, and the loudest pose there is.
    case raise
    /// Reaching sideways with a note. Handing work to a subagent.
    case offer
    /// Sunk into the chair. Nothing outstanding.
    case slump
}

/// A speech bubble's contents.
enum BubbleKind: String, Hashable {
    /// A person is needed. The only glyph on screen allowed to shout.
    case alert
    /// Working, but silent for longer than it should be.
    case asleep
    /// Work being handed over.
    case note
    /// Something finished while you were elsewhere and is waiting to be read.
    case done
}

/// The procedural sprite sheet: everything the office is made of, drawn in
/// code, cached per appearance.
///
/// Nothing here is loaded from disk. That is a temporary state — the atlas
/// package format in `docs/CHARACTERS.md` describes the art that replaces it —
/// but it is also the fallback that has to keep working forever, because a
/// harness whose sprites nobody has drawn yet still has to appear on the wall.
@MainActor
final class PlaceholderArt {
    static let shared = PlaceholderArt()

    private var theme: SceneTheme?
    private var cache: [String: SKTexture] = [:]

    private init() {}

    /// Points per art pixel. Two, so that on a Retina display one art pixel is
    /// exactly four device pixels and the grid stays square at rest.
    static let pixelScale: CGFloat = 2

    /// Adopts `theme`, discarding every texture baked for the previous one.
    func use(theme: SceneTheme) {
        guard self.theme?.id != theme.id else { return }
        self.theme = theme
        cache.removeAll(keepingCapacity: true)
    }

    private func current() -> SceneTheme {
        if let theme { return theme }
        let resolved = SceneTheme.resolved(for: NSApplication.shared.effectiveAppearance)
        theme = resolved
        return resolved
    }

    private func cached(_ key: String, _ build: (SceneTheme) -> PixelCanvas) -> SKTexture {
        if let hit = cache[key] { return hit }
        let texture = build(current()).texture()
        cache[key] = texture
        return texture
    }

    // MARK: - The agent

    /// The head: hair, a face, and one eye looking at the monitor.
    func head(harness: Harness) -> SKTexture {
        cached("head.\(harness.rawValue)") { theme in
            Self.headCanvas(accent: theme.accent(harness), theme: theme)
        }
    }

    /// The head, before it is a texture. Split out because the Settings pane
    /// composes the rig into one still image and cannot get pixels back out of
    /// an `SKTexture`.
    static func headCanvas(accent: NSColor, theme: SceneTheme) -> PixelCanvas {
        let hair = accent.blended(withFraction: 0.55, of: theme.ink) ?? accent
        var canvas = PixelCanvas(width: 10, height: 8)
        canvas.fill(1, 0, 8, 3, hair)          // crown
        canvas.fill(1, 3, 8, 4, theme.face)    // face
        canvas.fill(1, 3, 3, 2, hair)          // fringe, swept back
        canvas.fill(0, 4, 1, 2, theme.face)    // ear
        canvas.set(7, 4, theme.ink)            // eye, on the monitor
        canvas.fill(6, 6, 3, 1, theme.face.blended(withFraction: 0.35, of: theme.ink) ?? theme.face)
        canvas.fill(3, 7, 4, 1, theme.face)    // neck
        return canvas
    }

    /// The torso and one arm, in a pose. The lower half is drawn even though
    /// the desk hides it, so a person leaning over a zoomed-in desk does not
    /// find their agent cut off at the waist.
    func body(harness: Harness, pose: AgentPose) -> SKTexture {
        cached("body.\(harness.rawValue).\(pose.rawValue)") { theme in
            Self.bodyCanvas(accent: theme.accent(harness), pose: pose, theme: theme)
        }
    }

    /// The torso, before it is a texture.
    static func bodyCanvas(accent: NSColor, pose: AgentPose, theme: SceneTheme) -> PixelCanvas {
        let shirt = accent
        let shade = accent.blended(withFraction: 0.4, of: theme.ink) ?? accent
        let light = accent.blended(withFraction: 0.3, of: .white) ?? accent
        let drop = pose == .slump ? 1 : 0

        var canvas = PixelCanvas(width: 18, height: 15)
        canvas.fill(4, 0 + drop, 10, 2, shirt)       // shoulders
        canvas.fill(3, 2 + drop, 12, 8, shirt)       // torso
        canvas.fill(8, 0 + drop, 2, 2, light)        // collar
        canvas.fill(3, 6 + drop, 12, 1, shade)       // belt shadow
        canvas.fill(4, 10 + drop, 10, 5, shade)      // legs, behind the desk

        switch pose {
        case .rest, .slump:
            canvas.fill(13, 4 + drop, 4, 2, shade)
            canvas.fill(16, 5 + drop, 2, 1, theme.face)
        case .type:
            canvas.fill(13, 3 + drop, 4, 2, shade)
            canvas.fill(16, 3 + drop, 2, 1, theme.face)
        case .raise:
            canvas.fill(13, 0, 2, 5, shade)          // forearm, vertical
            canvas.fill(13, -1, 2, 2, theme.face)    // hand, clipped at the top
            canvas.fill(12, 4, 2, 2, shade)
        case .offer:
            canvas.fill(13, 3, 5, 2, shade)          // arm extended sideways
            canvas.fill(16, 2, 2, 1, theme.face)
        }
        return canvas
    }

    /// The rig as one still image, composed into a standard character cell.
    ///
    /// The office never needs this: it hangs a head node off a body node and
    /// lets SpriteKit place them. Everything *outside* the office that has to
    /// show what the built-in look is — the Settings pane, most of all — needs
    /// one picture, at the same proportions a drawn package would occupy, so
    /// that the built-in figure can sit in a grid of packages as a peer rather
    /// than as a diagram of one.
    ///
    /// - Parameters:
    ///   - accent: the hue the figure is built from. The office passes a
    ///     harness's accent; a surface naming the rig itself rather than any
    ///     one harness passes Auspex's own.
    ///   - pose: which pose. `slump` is the idle pose, and the one a still
    ///     image should show.
    ///   - cell: the square cell to compose into, in art pixels.
    func portrait(
        accent: NSColor,
        pose: AgentPose = .slump,
        cell: Int = CharacterManifest.defaultCell
    ) -> CGImage? {
        guard cell > 0 else { return nil }
        let theme = current()
        let torso = Self.bodyCanvas(accent: accent, pose: pose, theme: theme)
        let skull = Self.headCanvas(accent: accent, theme: theme)
        // The scene's own geometry, read back in art pixels: the head's feet
        // sit this far above the body's. Derived rather than written down, so
        // a change to the rig's proportions cannot leave a floating head here.
        let lift = Int((AgentSprite.bodySize.height - 2) / Self.pixelScale)

        var canvas = PixelCanvas(width: cell, height: cell)
        // Feet on the bottom row, the same rule `docs/CHARACTERS.md` gives
        // whoever is drawing a package.
        canvas.blit(torso, x: (cell - torso.width) / 2, y: cell - torso.height)
        canvas.blit(skull, x: (cell - skull.width) / 2, y: cell - lift - skull.height)
        return canvas.cgImage()
    }

    /// The appearance the cached art was baked for.
    ///
    /// Anything holding an image derived from the rig has to key its cache on
    /// this. Baked pixels cannot re-resolve themselves when somebody switches
    /// to light mode, which is the same bargain ``SceneTheme`` makes.
    var themeID: String { current().id }

    // MARK: - The workstation

    /// A desk: a lit top, a front panel in shadow, and two legs.
    func desk() -> SKTexture {
        cached("desk") { theme in
            var canvas = PixelCanvas(width: 44, height: 11)
            canvas.fill(0, 0, 44, 1, theme.deskTop.blended(withFraction: 0.25, of: .white) ?? theme.deskTop)
            canvas.fill(0, 1, 44, 2, theme.deskTop)
            canvas.fill(1, 3, 42, 5, theme.deskFront)
            canvas.fill(2, 8, 3, 3, theme.deskLeg)
            canvas.fill(39, 8, 3, 3, theme.deskLeg)
            return canvas
        }
    }

    /// An office chair, seen from behind the agent.
    func chair() -> SKTexture {
        cached("chair") { theme in
            let back = theme.chair
            let seat = theme.chair.blended(withFraction: 0.2, of: theme.ink) ?? theme.chair
            var canvas = PixelCanvas(width: 12, height: 13)
            canvas.fill(2, 0, 8, 7, back)
            canvas.fill(3, 1, 6, 5, back.blended(withFraction: 0.18, of: .white) ?? back)
            canvas.fill(0, 7, 12, 2, seat)
            canvas.fill(5, 9, 2, 2, theme.deskLeg)
            canvas.fill(2, 11, 8, 1, theme.deskLeg)
            canvas.fill(1, 12, 10, 1, theme.deskLeg)
            return canvas
        }
    }

    /// A monitor shell with the screen cut out of it, so the lit rectangle
    /// behind it can be any colour without a second texture per state.
    func monitor() -> SKTexture {
        cached("monitor") { theme in
            let shell = theme.deskLeg
            var canvas = PixelCanvas(width: 18, height: 15)
            canvas.fill(0, 0, 18, 12, shell)
            canvas.erase(2, 2, 14, 8)                 // the window the screen shows through
            canvas.fill(1, 1, 16, 1, shell.blended(withFraction: 0.3, of: .white) ?? shell)
            canvas.fill(8, 12, 2, 1, shell)           // neck
            canvas.fill(5, 13, 8, 2, shell)           // foot
            return canvas
        }
    }

    /// A sheet of paper on the desk, for a session that is writing files.
    func paper() -> SKTexture {
        cached("paper") { theme in
            let sheet = NSColor(sceneRGB: theme.isDark ? 0xC9D2E4 : 0xFAFBFF)
            var canvas = PixelCanvas(width: 7, height: 9)
            canvas.fill(0, 0, 7, 9, sheet)
            for row in stride(from: 2, to: 8, by: 2) {
                canvas.fill(1, row, 5, 1, theme.deskLeg, alpha: 0.55)
            }
            return canvas
        }
    }

    // MARK: - The annexes

    /// A long table, seen from three quarters on.
    ///
    /// Drawn once and stretched: the middle six pixels are the slice that
    /// repeats, so a table for one pair of chairs and a table for four are the
    /// same texture with the same ends and no seam. The alternative — a left
    /// cap, a tiled middle and a right cap as three nodes — is three nodes per
    /// table for a picture nobody could tell apart.
    func table() -> SKTexture {
        cached("table") { theme in
            let top = theme.deskTop.blended(withFraction: 0.18, of: theme.ink) ?? theme.deskTop
            var canvas = PixelCanvas(width: 24, height: 15)
            canvas.fill(0, 0, 24, 1, top.blended(withFraction: 0.28, of: .white) ?? top)
            canvas.fill(0, 1, 24, 7, top)
            canvas.fill(0, 8, 24, 1, theme.deskFront)
            canvas.fill(0, 9, 24, 4, theme.deskLeg)
            canvas.fill(0, 12, 24, 1, theme.ink)
            canvas.fill(2, 13, 3, 2, theme.deskLeg)
            canvas.fill(19, 13, 3, 2, theme.deskLeg)
            return canvas
        }
    }

    /// The slice of ``table()`` that repeats when it is stretched.
    static let tableCenterRect = CGRect(x: 8.0 / 24, y: 0, width: 8.0 / 24, height: 1)

    /// A laptop, with its screen cut out so the state colour behind it shows
    /// through — the same trick the monitor plays, so the meeting room and the
    /// office say a state the same way.
    func laptop() -> SKTexture {
        cached("laptop") { theme in
            let shell = theme.deskLeg
            var canvas = PixelCanvas(width: 10, height: 8)
            canvas.fill(1, 0, 8, 6, shell)
            canvas.erase(2, 1, 6, 4)                  // the lit rectangle
            canvas.fill(1, 0, 8, 1, shell.blended(withFraction: 0.3, of: .white) ?? shell)
            canvas.fill(0, 6, 10, 2, shell.blended(withFraction: 0.2, of: .white) ?? shell)
            return canvas
        }
    }

    /// The screen at the far end of a table. Its light is the *parent*
    /// session's state, so a meeting is readable from across the map exactly
    /// as a desk is — without it, a table would be the one part of a board
    /// read by its lighting with no light in it.
    ///
    /// A display on a stand rather than a projector screen on a wall: the
    /// annexes have no walls, and a rectangle hanging in the air over a table
    /// reads as a bug in the renderer rather than as a screen.
    func projectorScreen() -> SKTexture {
        cached("projectorScreen") { theme in
            let shell = theme.deskLeg
            var canvas = PixelCanvas(width: 26, height: 20)
            canvas.fill(0, 0, 26, 15, shell)
            canvas.erase(2, 2, 22, 10)                // the lit rectangle
            canvas.fill(1, 1, 24, 1, shell.blended(withFraction: 0.32, of: .white) ?? shell)
            canvas.fill(11, 15, 4, 2, shell)          // neck
            canvas.fill(7, 17, 12, 2, theme.ink)      // foot
            canvas.fill(6, 19, 14, 1, theme.ink)
            return canvas
        }
    }

    /// A garden bench: slats, arms, and two legs.
    func bench() -> SKTexture {
        cached("bench") { theme in
            let wood = theme.bark
            let lit = wood.blended(withFraction: 0.25, of: .white) ?? wood
            var canvas = PixelCanvas(width: 20, height: 10)
            canvas.fill(1, 0, 18, 1, lit)             // back rail
            canvas.fill(1, 2, 18, 1, wood)
            canvas.fill(0, 4, 20, 3, lit)             // seat
            canvas.fill(0, 7, 20, 1, wood)
            canvas.fill(2, 8, 2, 2, theme.ink)
            canvas.fill(16, 8, 2, 2, theme.ink)
            return canvas
        }
    }

    /// A picnic blanket, checked, lying flat.
    func picnicBlanket() -> SKTexture {
        cached("picnicBlanket") { theme in
            let cloth = theme.color(for: .waitingPermission(tool: nil))
                .blended(withFraction: 0.55, of: theme.grass) ?? theme.grass
            let pale = cloth.blended(withFraction: 0.3, of: .white) ?? cloth
            var canvas = PixelCanvas(width: 18, height: 11)
            canvas.fill(1, 0, 16, 11, cloth)
            canvas.fill(0, 2, 18, 7, cloth)
            for row in stride(from: 1, to: 10, by: 3) {
                canvas.fill(0, row, 18, 1, pale, alpha: 0.55)
            }
            for column in stride(from: 2, to: 17, by: 4) {
                canvas.fill(column, 0, 1, 11, pale, alpha: 0.55)
            }
            return canvas
        }
    }

    /// A tree. Two of them, keyed by size, so a row of them is not a row of
    /// one tree repeated.
    func tree(tall: Bool) -> SKTexture {
        cached("tree.\(tall)") { theme in
            let height = tall ? 26 : 19
            let crown = tall ? 16 : 12
            var canvas = PixelCanvas(width: 16, height: height)
            let left = (16 - crown) / 2
            let dark = theme.leaf.blended(withFraction: 0.35, of: theme.ink) ?? theme.leaf
            canvas.fill(left + 1, 0, crown - 2, 2, theme.leaf)
            canvas.fill(left, 2, crown, crown - 4, theme.leaf)
            canvas.fill(left + 1, crown - 2, crown - 2, 2, dark)
            canvas.fill(7, crown - 1, 2, height - crown + 1, theme.bark)
            canvas.fill(6, height - 1, 4, 1, dark)
            return canvas
        }
    }

    /// A hedge. The garden's punctuation.
    func bush() -> SKTexture {
        cached("bush") { theme in
            let dark = theme.leaf.blended(withFraction: 0.3, of: theme.ink) ?? theme.leaf
            var canvas = PixelCanvas(width: 12, height: 7)
            canvas.fill(1, 1, 10, 5, theme.leaf)
            canvas.fill(0, 3, 12, 3, theme.leaf)
            canvas.fill(1, 5, 10, 2, dark)
            return canvas
        }
    }

    /// The gate at the far end of the garden. A session that is over walks to
    /// it and off the map.
    func gate() -> SKTexture {
        cached("gate") { theme in
            let post = theme.bark
            let iron = theme.stone
            var canvas = PixelCanvas(width: 20, height: 22)
            canvas.fill(0, 2, 3, 20, post)
            canvas.fill(17, 2, 3, 20, post)
            canvas.fill(0, 0, 3, 2, post.blended(withFraction: 0.3, of: .white) ?? post)
            canvas.fill(17, 0, 3, 2, post.blended(withFraction: 0.3, of: .white) ?? post)
            // The gate itself, standing open: two leaves swung back against
            // the posts, which is what "somebody just walked out" looks like
            // without an animation.
            canvas.fill(3, 6, 2, 14, iron)
            canvas.fill(15, 6, 2, 14, iron)
            canvas.fill(3, 6, 14, 1, iron)
            return canvas
        }
    }

    // MARK: - Bubbles

    /// A speech bubble. Baked in its own colour rather than tinted, because
    /// there are four of them and they never change hue.
    func bubble(_ kind: BubbleKind) -> SKTexture {
        cached("bubble.\(kind.rawValue)") { theme in
            let fill: NSColor
            switch kind {
            case .alert: fill = theme.color(for: .waitingPermission(tool: nil))
            case .asleep: fill = NSColor(sceneRGB: theme.isDark ? 0xB39755 : 0x7C6420)
            case .note: fill = theme.color(for: .delegating(children: 1))
            // The board's own choice: `done unseen` borrows the writing green,
            // because it is the same fact one moment later.
            case .done: fill = theme.color(for: .writingFile(path: nil))
            }

            var canvas = PixelCanvas(width: 13, height: 14)
            canvas.fill(1, 0, 11, 10, fill)
            canvas.fill(0, 1, 13, 8, fill)
            canvas.fill(4, 10, 4, 2, fill)      // tail
            canvas.fill(5, 12, 2, 1, fill)

            switch kind {
            case .alert:
                canvas.fill(6, 2, 2, 4, theme.ink)
                canvas.fill(6, 7, 2, 2, theme.ink)
            case .asleep:
                // Three z's, largest first, because that is how a comic reads.
                Self.drawZ(&canvas, x: 2, y: 5, size: 3, color: theme.ink)
                Self.drawZ(&canvas, x: 6, y: 3, size: 3, color: theme.ink)
                Self.drawZ(&canvas, x: 9, y: 1, size: 2, color: theme.ink)
            case .note:
                canvas.fill(4, 3, 5, 5, theme.ink)
                canvas.fill(5, 4, 3, 1, fill)
                canvas.fill(5, 6, 3, 1, fill)
            case .done:
                // A page with a tick on it: written, and waiting to be read.
                canvas.fill(3, 2, 7, 7, theme.ink)
                canvas.fill(4, 5, 2, 2, fill)
                canvas.set(6, 7, fill)
                canvas.fill(7, 4, 2, 3, fill)
            }
            return canvas
        }
    }

    private static func drawZ(_ canvas: inout PixelCanvas, x: Int, y: Int, size: Int, color: NSColor) {
        canvas.fill(x, y, size, 1, color)
        canvas.fill(x, y + size - 1, size, 1, color)
        for step in 0..<size { canvas.set(x + size - 1 - step, y + step, color) }
    }

    // MARK: - Light

    /// The monitor's spill: a soft radial falloff, drawn white and tinted at
    /// use, added rather than blended.
    ///
    /// The one thing in the scene that is not pixel art. Light is what the
    /// board's state colours actually are here — a room read at a glance is
    /// read by its lighting — and a hard-edged pixel disc would read as an
    /// object instead.
    func glow() -> SKTexture {
        if let hit = cache["glow"] { return hit }
        let side = 96
        var canvas = PixelCanvas(width: side, height: side)
        let centre = CGFloat(side - 1) / 2
        for y in 0..<side {
            for x in 0..<side {
                let dx = (CGFloat(x) - centre) / centre
                let dy = (CGFloat(y) - centre) / centre
                let distance = min(1, sqrt(dx * dx + dy * dy))
                let falloff = pow(1 - distance, 2.6)
                canvas.set(x, y, .white, alpha: falloff)
            }
        }
        let texture = canvas.texture()
        texture.filteringMode = .linear
        cache["glow"] = texture
        return texture
    }

    /// The backdrop tile: the same measured grid the board draws, so switching
    /// between the two views does not feel like switching applications.
    func gridTile(spacing: Int = 26) -> SKTexture {
        cached("grid.\(spacing)") { theme in
            var canvas = PixelCanvas(width: spacing, height: spacing)
            canvas.fill(0, 0, spacing, spacing, theme.canvas)
            canvas.fill(0, 0, spacing, 1, theme.grid)
            canvas.fill(0, 0, 1, spacing, theme.grid)
            return canvas
        }
    }
}

extension NSColor {
    /// Builds a colour from `0xRRGGBB` in sRGB, matching ``AuspexPalette``'s
    /// own convention so a furniture tone and an accent are mixed in the same
    /// space.
    convenience init(sceneRGB rgb: Int) {
        self.init(
            srgbRed: CGFloat((rgb >> 16) & 0xFF) / 255,
            green: CGFloat((rgb >> 8) & 0xFF) / 255,
            blue: CGFloat(rgb & 0xFF) / 255,
            alpha: 1
        )
    }
}
