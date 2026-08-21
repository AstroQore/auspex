import AgentSessionKit
import AgentSessionLive
import AppKit
import AuspexCore
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

/// Renders the crew's *motion* offscreen, which a still cannot show.
///
/// ``CrewSnapshotRenderer`` answers "does the wall draw correctly". These three
/// answer "does it move correctly", which is a different question and the one
/// this branch exists for:
///
/// - a **filmstrip** of a single transition, sixteen frames laid out in reading
///   order with the per-frame travel drawn under each one. An eased morph and a
///   linear one look identical in any one frame and completely different as a
///   row of bars, so the bars are the evidence, not decoration;
/// - a **contact sheet** of the whole wall over a couple of seconds, for the
///   things a single avatar cannot show — sixty gazes that do not drift in
///   unison, a halo breathing;
/// - the same frames as an **animated GIF**, which is the only one of the three
///   that shows the motion as motion.
///
/// All three are pure functions of the demo board and an instant, they draw
/// fabricated sessions under `/Users/example`, and two runs of the same
/// arguments produce the same pixels. The GIF is assembled with ImageIO rather
/// than by shelling out to `ffmpeg`, so nothing outside the toolchain has to be
/// installed for the evidence to be reproducible.
enum CrewMotionRenderer {
    // MARK: Filmstrip

    /// Frames per filmstrip. Sixteen across a 420–600 ms morph puts a sample
    /// every 35–45 ms, which is fine enough to see the curve bend and coarse
    /// enough that consecutive tiles differ visibly.
    static let stripFrames = 16

    /// Renders one reaction as a filmstrip.
    ///
    /// - Parameters:
    ///   - stance: the loop the avatar is living in, so the strip shows the
    ///     reaction arriving out of something and going back into it.
    ///   - reaction: the one-shot to play.
    ///   - cadence: seconds between frames. `nil` spreads the sixteen frames
    ///     across the whole reaction, hand-overs included, which is what shows
    ///     the easing. Given a value it instead samples the **settled** base
    ///     loop at exactly that interval, which is how a frame rate is judged:
    ///     the question "does a step morph step at 30 fps" is answered by
    ///     looking at consecutive 33 ms frames of one, and by nothing else.
    @MainActor
    static func renderStrip(
        stance: CrewStance,
        reaction: AvatarSequenceID,
        to url: URL,
        cadence: Double? = nil,
        scale: CGFloat = 2
    ) throws {
        NSApplication.shared.setActivationPolicy(.prohibited)

        // A settled loop, so the strip shows a reaction and not an avatar being
        // born. Twelve seconds is past every hand-over and several blinks.
        let seed: UInt32 = 0x51E4
        let change = 12.0
        var engine = BloubEngine(
            scale: BloubFrameOfReference.radius,
            state: .idle,
            shape: .circle,
            expression: .neutral,
            drift: .wander(seed: seed)
        )
        engine.reset(to: .idle, at: 0)
        var chorus = CrewChoreographer(seed: seed, stance: stance, at: 0)
        chorus.accent(reaction, at: change)

        let length = CrewChoreography.accentCap
        let first: Double
        let step: Double
        if let cadence {
            first = change + length + 1.5
            step = cadence
        } else {
            first = change - 0.1
            step = (length + 0.35) / Double(stripFrames - 1)
        }

        var tiles: [CrewFilmstripTile] = []
        var previousReach: Double?
        for index in 0..<stripFrames {
            let at = first + Double(index) * step
            let face = chorus.sample(at: at)
            let frame = engine.sample(
                at,
                face: BloubFaceOverride(expression: face.face, lid: face.lid)
            )
            let reach = faceReach(of: frame)
            tiles.append(
                CrewFilmstripTile(
                    index: index,
                    time: at - change,
                    frame: frame,
                    travel: previousReach.map { abs(reach - $0) } ?? 0
                )
            )
            previousReach = reach
        }

        let renderer = ImageRenderer(
            content: CrewFilmstripSheet(
                stance: stance,
                reaction: reaction,
                handover: CrewChoreography.handover(for: length),
                cadence: cadence,
                tiles: tiles
            )
        )
        renderer.scale = scale
        renderer.isOpaque = true
        guard let image = renderer.cgImage else { throw RenderError.renderFailed }
        try CrewSnapshotRenderer.writePNG(image, to: url)
    }

    /// How far the face has travelled, as one number per frame.
    ///
    /// Where the silhouette used to be measured, because the silhouette used to
    /// be what moved. It no longer does — the body is the harness and holds
    /// still — so what a strip has to show is the eyes: where they sit, how big
    /// they are, and how far open. Its frame-to-frame difference is the speed
    /// the face is morphing at, which is the whole thing under test: a linear
    /// morph gives a flat row of bars, an eased one gives a hump.
    static func faceReach(of frame: BloubFrame) -> Double {
        frame.eyes.reduce(0.0) { total, eye in
            total + hypot(eye.e, eye.f) + eye.width + eye.height
                + hypot(eye.b, eye.d) * 40
        }
    }

    // MARK: The wall, over time

    /// Renders the demo wall over `seconds` as a 4 × 4 contact sheet.
    @MainActor
    static func renderContactSheet(
        board: BoardSnapshot,
        to url: URL,
        seconds: TimeInterval = 2,
        columns: Int = 4,
        scale: CGFloat = 1
    ) throws {
        let images = try wallFrames(
            board: board,
            seconds: seconds,
            count: 16,
            columns: columns,
            scale: scale
        )
        guard let sheet = compose(images, across: 4) else { throw RenderError.renderFailed }
        try CrewSnapshotRenderer.writePNG(sheet, to: url)
    }

    /// Renders the demo wall over `seconds` as an animated GIF.
    @MainActor
    static func renderGIF(
        board: BoardSnapshot,
        to url: URL,
        seconds: TimeInterval = 2,
        fps: Double = 20,
        columns: Int = 4,
        scale: CGFloat = 1
    ) throws {
        let count = max(2, Int((seconds * fps).rounded()))
        let images = try wallFrames(
            board: board,
            seconds: seconds,
            count: count,
            columns: columns,
            scale: scale
        )
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL,
            UTType.gif.identifier as CFString,
            images.count,
            nil
        ) else { throw RenderError.encodingFailed }

        CGImageDestinationSetProperties(
            destination,
            [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary
        )
        let delay = [
            kCGImagePropertyGIFDictionary: [
                kCGImagePropertyGIFUnclampedDelayTime: 1 / fps,
                kCGImagePropertyGIFDelayTime: 1 / fps
            ]
        ] as CFDictionary
        for image in images {
            CGImageDestinationAddImage(destination, image, delay)
        }
        guard CGImageDestinationFinalize(destination) else { throw RenderError.encodingFailed }
    }

    /// `count` evenly spaced frames of the wall over `seconds`.
    ///
    /// The roster is stepped at the wall's own rate and only *sampled* at the
    /// wanted instants, for the reason ``CrewSnapshotRenderer`` gives: reading
    /// it straight at each instant would create every engine there and freeze
    /// each avatar on its own first frame.
    @MainActor
    private static func wallFrames(
        board: BoardSnapshot,
        seconds: TimeInterval,
        count: Int,
        columns: Int,
        scale: CGFloat
    ) throws -> [CGImage] {
        NSApplication.shared.setActivationPolicy(.prohibited)
        guard !board.sessions.isEmpty else { throw RenderError.emptyBoard }

        let roster = CrewRoster()
        let unseen = SceneSnapshotRenderer.demoUnseenDone(board)
        let tick = 1.0 / 60.0
        // Two seconds of run-up, so the wall is past its own opening morphs.
        let lead = 2.0
        var wanted = (0..<count).map { lead + Double($0) * seconds / Double(count) }
        var images: [CGImage] = []

        var now = 0.0
        while now <= lead + seconds + tick, !wanted.isEmpty {
            var instants: [SessionKey: CrewInstant] = [:]
            for session in board.sessions {
                instants[session.key] = roster.instant(for: session, at: now, frozen: false)
            }
            if let next = wanted.first, now >= next {
                wanted.removeFirst()
                let cards = board.sessions.map { session -> CrewSnapshotCard in
                    let instant = instants[session.key]
                    return CrewSnapshotCard(
                        session: session,
                        frame: instant?.frame ?? BloubEngine().sample(0),
                        descendants: board.tree.descendants(of: session.key).count,
                        chrome: CrewCardChrome.of(
                            session,
                            isUnseenDone: unseen.contains(session.key)
                        ),
                        isOver: instant?.stance == .ended
                    )
                }
                guard let image = CrewSnapshotRenderer.wallImage(
                    cards: cards,
                    columns: columns,
                    scale: scale
                ) else { throw RenderError.renderFailed }
                images.append(image)
            }
            now += tick
        }
        guard !images.isEmpty else { throw RenderError.renderFailed }
        return images
    }

    /// Lays images out in a grid, left to right then top to bottom.
    private static func compose(_ images: [CGImage], across: Int) -> CGImage? {
        guard let first = images.first else { return nil }
        let gutter = 12
        let rows = (images.count + across - 1) / across
        let width = first.width * across + gutter * (across + 1)
        let height = first.height * rows + gutter * (rows + 1)
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        context.setFillColor(CGColor(red: 0.043, green: 0.043, blue: 0.051, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        for (index, image) in images.enumerated() {
            let column = index % across
            let row = index / across
            context.draw(
                image,
                in: CGRect(
                    x: gutter + column * (first.width + gutter),
                    // CoreGraphics counts from the bottom; the sheet reads from
                    // the top, so the rows are laid out backwards.
                    y: height - (gutter + (row + 1) * (first.height + gutter)) + gutter,
                    width: first.width,
                    height: first.height
                )
            )
        }
        return context.makeImage()
    }

    enum RenderError: Error, CustomStringConvertible {
        case emptyBoard
        case renderFailed
        case encodingFailed

        var description: String {
            switch self {
            case .emptyBoard: "the board has no sessions to draw"
            case .renderFailed: "SwiftUI could not render the crew's motion offscreen"
            case .encodingFailed: "the rendered frames could not be encoded"
            }
        }
    }
}

/// One cell of a filmstrip.
struct CrewFilmstripTile: Identifiable {
    let index: Int
    /// Seconds from the state change. Negative before it.
    let time: Double
    let frame: BloubFrame
    /// How far the silhouette travelled since the previous tile, viewBox units.
    let travel: Double

    var id: Int { index }
}

/// The filmstrip, as a sheet: two rows of eight, each tile carrying its own
/// instant and a bar for how far the body moved to get there.
///
/// The bars are the point. Sixteen avatars in a row prove nothing on their own —
/// any morph looks smooth frozen — but a row of bars that rises and falls is a
/// morph that accelerates and decelerates, and a row of equal bars is the
/// straight line this branch was asked to remove.
private struct CrewFilmstripSheet: View {
    let stance: CrewStance
    let reaction: AvatarSequenceID
    let handover: Double
    /// Set when the strip is a steady state sampled at a fixed rate rather than
    /// a morph spread across its own length.
    let cadence: Double?
    let tiles: [CrewFilmstripTile]

    private static let tile: CGFloat = 132
    private static let columns = 8

    var body: some View {
        let peak = tiles.dropFirst().map(\.travel).max() ?? 1
        return VStack(alignment: .leading, spacing: 18) {
            header
            VStack(spacing: 16) {
                ForEach(0..<((tiles.count + Self.columns - 1) / Self.columns), id: \.self) { row in
                    HStack(spacing: 10) {
                        ForEach(
                            tiles[
                                (row * Self.columns)..<min((row + 1) * Self.columns, tiles.count)
                            ]
                        ) { tile in
                            cell(tile, peak: peak)
                        }
                    }
                }
            }
        }
        .padding(24)
        .background(AuspexPalette.canvas)
        .environment(\.colorScheme, .dark)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(
                cadence == nil
                    ? "\(stance.rawValue)  →  \(reaction.rawValue)  →  \(stance.rawValue)"
                    : stance.rawValue
            )
                .font(.system(size: 17, weight: .semibold, design: .monospaced))
                .foregroundStyle(AuspexPalette.textPrimary)
            Text(subtitle)
                .font(.system(size: 11.5))
                .foregroundStyle(AuspexPalette.textSecondary)
        }
    }

    private var subtitle: String {
        if let cadence {
            return String(
                format: "the base loop, settled, sampled every %.1f ms — %.0f fps · "
                    + "bars = how far the face moved since the previous frame",
                cadence * 1000,
                1 / cadence
            )
        }
        return String(
            format: "one reaction · %.0f ms · handed over on a %.0f ms smoothstep at "
                + "each end · bars = how far the face moved since the previous frame",
            CrewChoreography.accentCap * 1000,
            handover * 1000
        )
    }

    private func cell(_ tile: CrewFilmstripTile, peak: Double) -> some View {
        VStack(spacing: 6) {
            CrewAvatarView(
                frame: tile.frame,
                ink: Harness.claudeCode.style.accent,
                paper: AuspexPalette.panel
            )
            .frame(width: Self.tile, height: Self.tile)

            Text(String(format: "%+.0f ms", tile.time * 1000))
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(
                    tile.time < 0 ? AuspexPalette.textTertiary : AuspexPalette.textSecondary
                )

            // The travel bar, on a shared scale across the whole strip.
            ZStack(alignment: .bottom) {
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(AuspexPalette.hairline)
                    .frame(width: 8, height: 46)
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(Harness.claudeCode.style.accent)
                    .frame(
                        width: 8,
                        height: max(1, 46 * CGFloat(tile.travel / max(peak, 1e-9)))
                    )
            }
        }
        .frame(width: Self.tile)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous).fill(AuspexPalette.panel)
        )
    }
}
