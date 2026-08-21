import AgentSessionKit
import AgentSessionLive
import AppKit
import AuspexCore
import SwiftUI

/// Renders the crew wall to a PNG, offscreen.
///
/// The same reason ``SceneSnapshotRenderer`` exists: a screenshot taken by
/// pointing a capture tool at a running window is a picture of whatever else
/// was on that screen, at whatever moment the finger came off the key. This
/// one is a pure function of a demo offset and an animation instant, it draws
/// fabricated sessions under `/Users/example`, and two runs of the same
/// arguments produce the same pixels.
///
/// It is also how the avatars get verified at all: a `Canvas` has no view
/// hierarchy to assert against, so the only honest check is to draw one and
/// look at it.
enum CrewSnapshotRenderer {
    /// Renders the crew wall for `board` and writes a PNG to `url`.
    ///
    /// - Parameters:
    ///   - avatarTime: where in the animation to freeze every avatar. Each one
    ///     still gets its own phase offset, so the wall does not blink in
    ///     unison in the picture either.
    ///   - columns: how many cards per row.
    @MainActor
    static func render(
        board: BoardSnapshot,
        to url: URL,
        avatarTime: TimeInterval = 1.4,
        columns: Int = 5,
        scale: CGFloat = 2,
        appearance: NSAppearance = NSAppearance(named: .darkAqua) ?? NSAppearance()
    ) throws {
        // Touching AppKit at all requires the shared application to exist; the
        // policy keeps it out of the Dock and off the menu bar while it does.
        NSApplication.shared.setActivationPolicy(.prohibited)

        guard !board.sessions.isEmpty else { throw RenderError.emptyBoard }

        let roster = CrewRoster()
        // The wall is stepped at its real rate up to `avatarTime` rather than
        // sampled once. Sampling once would create every engine and read it at
        // the same instant, so each avatar would be frozen on its own first
        // frame — and it would skip the montage entirely: the burst would never
        // hand over to the waiting pose, and a held state would never replay.
        // The picture has to be of the wall the app actually draws.
        var now = 0.0
        while now < avatarTime {
            for session in board.sessions {
                _ = roster.instant(for: session, at: now, frozen: false)
            }
            now += 1.0 / 30
        }
        let attention = SceneSnapshotRenderer.demoAttention(board)
        let cards = board.sessions.map { session -> CrewSnapshotCard in
            let instant = roster.instant(for: session, at: avatarTime, frozen: false)
            return CrewSnapshotCard(
                session: session,
                frame: instant.frame,
                descendants: board.tree.descendants(of: session.key).count,
                chrome: CrewCardChrome.of(session, attention: attention[session.key] ?? .none),
                isOver: instant.stance == .ended
            )
        }

        guard let image = wallImage(cards: cards, columns: columns, scale: scale) else {
            throw RenderError.renderFailed
        }
        try writePNG(image, to: url)
    }

    /// One wall, drawn. Shared with ``CrewMotionRenderer``, which needs dozens
    /// of these and must get them from the same drawing as the still — a
    /// filmstrip of a second, simpler renderer would prove nothing about this
    /// one.
    @MainActor
    static func wallImage(cards: [CrewSnapshotCard], columns: Int, scale: CGFloat) -> CGImage? {
        let renderer = ImageRenderer(content: CrewSnapshotSheet(cards: cards, columns: columns))
        renderer.scale = scale
        renderer.isOpaque = true
        return renderer.cgImage
    }

    /// PNG bytes on disk, atomically.
    static func writePNG(_ image: CGImage, to url: URL) throws {
        let rep = NSBitmapImageRep(cgImage: image)
        guard let data = rep.representation(using: .png, properties: [.compressionFactor: 1.0])
        else { throw RenderError.encodingFailed }
        try data.write(to: url, options: .atomic)
    }

    enum RenderError: Error, CustomStringConvertible {
        case emptyBoard
        case renderFailed
        case encodingFailed

        var description: String {
            switch self {
            case .emptyBoard: "the board has no sessions to draw"
            case .renderFailed: "SwiftUI could not render the crew wall offscreen"
            case .encodingFailed: "the rendered image could not be encoded as PNG"
            }
        }
    }
}

/// One card's worth of already-sampled input, so the sheet does nothing but lay
/// them out.
struct CrewSnapshotCard: Identifiable {
    let session: SessionSnapshot
    let frame: BloubFrame
    let descendants: Int
    /// What the card says over and above the avatar.
    var chrome: CrewCardChrome = .none
    /// Whether the avatar is asleep and grey.
    var isOver: Bool = false

    var id: SessionKey { session.key }
}

/// The wall, as a fixed grid.
///
/// A plain `LazyVGrid` in a fixed frame rather than the live view: the live one
/// carries a scroll view, a timeline and a model, none of which mean anything
/// to a renderer with no window and no clock.
struct CrewSnapshotSheet: View {
    let cards: [CrewSnapshotCard]
    let columns: Int

    var body: some View {
        let grid = Array(
            repeating: GridItem(.fixed(200), spacing: 16, alignment: .top),
            count: columns
        )
        return LazyVGrid(columns: grid, spacing: 16) {
            ForEach(cards) { card in
                CrewCard(
                    session: card.session,
                    isSelected: false,
                    descendantCount: card.descendants,
                    chrome: card.chrome
                ) {
                    CrewStillAvatar(
                        harness: card.session.key.harness,
                        frame: card.frame,
                        isOver: card.isOver
                    )
                }
            }
        }
        .padding(24)
        .frame(width: CGFloat(columns) * 216 + 32)
        .background(AuspexPalette.canvas)
        .environment(\.colorScheme, .dark)
    }
}
