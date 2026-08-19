import AgentSessionKit
import AgentSessionLive
import AppKit
import AuspexCore
import SpriteKit

/// The name of one animation on disk.
///
/// Deliberately not ``SessionState``. A state carries a payload the art does
/// not care about — which tool, which file — and there are more states than
/// there are things worth drawing: `toolCalling` and `writingFile` are both
/// "typing", they just differ in tempo and screen colour. So the atlas has its
/// own small vocabulary, and one place maps states onto it.
enum ScenePose: String, CaseIterable, Sendable {
    /// Nothing outstanding. The slumped, still pose.
    case idle
    /// Reasoning. A slow head bob and a breathing screen.
    case thinking
    /// A tool is open. Hands moving.
    case typing
    /// The working tree is being changed.
    case writing
    /// Handing work to a subagent.
    case delegating
    /// Blocked on a person. One hand up.
    case blocked
    /// Working, but silent for longer than it should be.
    case stale
    /// Over. The chair is all that is left.
    case ended

    /// The pose a session in this state is drawn in.
    static func pose(for state: SessionState, isStale: Bool) -> ScenePose {
        // Staleness is a modifier on the board and a *pose* here, but only for
        // a session that claims to be working. A stale idle session is just an
        // idle session, and drawing it asleep would say something the board
        // does not.
        if isStale, state.isActive { return .stale }
        switch state {
        case .idle: return .idle
        case .thinking: return .thinking
        case .toolCalling: return .typing
        case .writingFile: return .writing
        case .delegating: return .delegating
        case .waitingPermission: return .blocked
        case .ended: return .ended
        }
    }
}

/// Where the office gets its art.
///
/// ## The contract
///
/// A frame strip lives at
/// `<root>/<harness>/<variant>/<pose>.png` — for example
/// `claudeCode/default/typing.png` — and is one horizontal row of square
/// frames on a transparent background. `docs/SPRITES.md` is the full
/// specification and the thing to hand to whoever is drawing.
///
/// Two roots are searched, nearest first:
///
/// 1. `~/.auspex/sprites/`, so a person can drop a folder of PNGs in and see
///    them without rebuilding the app. Read only; nothing here ever writes to
///    it.
/// 2. `Sprites/` inside the app bundle, which is where shipped art will live.
///
/// ## Why a fallback rather than a requirement
///
/// There will always be a harness nobody has drawn yet, and a board that
/// silently dropped its sessions because their PNG was missing would be worse
/// than one drawn with rectangles. So every lookup that fails resolves to
/// ``PlaceholderArt``'s procedural rig, and a half-finished sprite set produces
/// a half-pixel-art office rather than a broken one.
///
/// Misses are cached as hard as hits. A lookup happens when a sprite is created
/// and when its pose changes, which on a busy board is often enough that
/// hitting the filesystem each time would be a real cost for an answer that
/// does not change while the app is running.
@MainActor
final class SpriteLibrary {
    static let shared = SpriteLibrary()

    /// One loaded animation.
    struct Strip {
        /// The frames, left to right.
        let frames: [SKTexture]
        /// How fast to play them.
        let fps: Double

        /// How long one frame is on screen.
        var timePerFrame: TimeInterval { fps > 0 ? 1 / fps : 0.12 }
    }

    /// The default frame rate, when a strip carries no manifest.
    static let defaultFPS: Double = 8

    /// The variant folder used when a session does not name one, or names one
    /// nobody has drawn.
    static let defaultVariant = "default"

    private var cache: [String: Strip?] = [:]
    private let roots: [URL]

    private init() {
        var roots: [URL] = [
            AuspexPaths.default.baseDirectory.appendingPathComponent("sprites", isDirectory: true)
        ]
        if let bundled = Bundle.main.resourceURL?
            .appendingPathComponent("Sprites", isDirectory: true) {
            roots.append(bundled)
        }
        self.roots = roots
    }

    /// The strip for one harness, variant, and pose, or `nil` when nobody has
    /// drawn it and the caller should fall back to the procedural rig.
    ///
    /// A session's own variant is tried first and `default` second, so a
    /// harness can ship one look and override it for the entrypoints that
    /// deserve their own — `cursor/ide` beside `cursor/default`.
    func strip(harness: Harness, variant: String?, pose: ScenePose) -> Strip? {
        for candidate in variants(for: variant) {
            let key = "\(harness.rawValue)/\(candidate)/\(pose.rawValue)"
            if let cached = cache[key] {
                if let cached { return cached }
                continue
            }
            let loaded = load(key: key)
            cache[key] = loaded
            if let loaded { return loaded }
        }
        return nil
    }

    /// `true` when at least one file has ever been found. Lets the scene say
    /// "placeholder art" in the legend without probing the disk itself.
    private(set) var hasLoadedArt = false

    private func variants(for variant: String?) -> [String] {
        guard let variant, !variant.isEmpty, variant != Self.defaultVariant else {
            return [Self.defaultVariant]
        }
        return [variant, Self.defaultVariant]
    }

    private func load(key: String) -> Strip? {
        for root in roots {
            let url = root.appendingPathComponent("\(key).png")
            guard FileManager.default.fileExists(atPath: url.path),
                  let image = NSImage(contentsOf: url),
                  let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
            else { continue }

            let manifest = Manifest.beside(url)
            let height = cgImage.height
            let frameWidth = manifest?.frameWidth ?? height
            guard frameWidth > 0, cgImage.width >= frameWidth else { continue }

            let columns = cgImage.width / frameWidth
            let sheet = SKTexture(cgImage: cgImage)
            sheet.filteringMode = .nearest

            var frames: [SKTexture] = []
            frames.reserveCapacity(columns)
            for column in 0..<columns {
                // SKTexture's sub-rectangle is in normalised coordinates with
                // the origin at the bottom left, which for a single-row strip
                // means only `x` varies.
                let rect = CGRect(
                    x: CGFloat(column * frameWidth) / CGFloat(cgImage.width),
                    y: 0,
                    width: CGFloat(frameWidth) / CGFloat(cgImage.width),
                    height: 1
                )
                let frame = SKTexture(rect: rect, in: sheet)
                frame.filteringMode = .nearest
                frames.append(frame)
            }
            guard !frames.isEmpty else { continue }
            hasLoadedArt = true
            return Strip(frames: frames, fps: manifest?.fps ?? Self.defaultFPS)
        }
        return nil
    }

    /// The optional sidecar beside a strip: `typing.json` next to `typing.png`.
    ///
    /// Optional on purpose. The zero-configuration rule — square frames, eight
    /// a second — covers everything a first pass at the art needs, and a
    /// manifest is only reached for when a pose wants a different tempo or a
    /// non-square frame.
    private struct Manifest: Decodable {
        var frameWidth: Int?
        var fps: Double?

        static func beside(_ png: URL) -> Manifest? {
            let json = png.deletingPathExtension().appendingPathExtension("json")
            guard let data = try? Data(contentsOf: json) else { return nil }
            return try? JSONDecoder().decode(Manifest.self, from: data)
        }
    }
}
