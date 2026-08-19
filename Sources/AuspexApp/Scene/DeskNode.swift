import AgentSessionKit
import AgentSessionLive
import AppKit
import AuspexCore
import SpriteKit

/// Text, set the way the rest of the app sets it.
///
/// `SKLabelNode(fontNamed:)` takes a PostScript name, and the faces Auspex
/// actually uses — the system's condensed and monospaced variants — do not have
/// stable ones. Attributed text takes an `NSFont` instead, which is the same
/// object `AuspexType` would resolve, so the scene's labels and the board's
/// cannot drift apart.
enum SceneText {
    /// A condensed uppercase label: floor names, counts, the legend.
    static func label(
        _ string: String,
        size: CGFloat,
        weight: NSFont.Weight = .semibold,
        color: NSColor,
        tracking: CGFloat = 0.9
    ) -> NSAttributedString {
        let descriptor = NSFont.systemFont(ofSize: size, weight: weight)
            .fontDescriptor.withDesign(.default)?
            .withSymbolicTraits(.condensed)
        let font = descriptor.map { NSFont(descriptor: $0, size: size) ?? NSFont.systemFont(ofSize: size, weight: weight) }
            ?? NSFont.systemFont(ofSize: size, weight: weight)
        return NSAttributedString(
            string: string.uppercased(),
            attributes: [
                .font: font as Any,
                .foregroundColor: color,
                .kern: tracking
            ]
        )
    }

    /// Monospaced text: paths, ids, anything whose characters matter.
    static func mono(
        _ string: String,
        size: CGFloat,
        weight: NSFont.Weight = .medium,
        color: NSColor
    ) -> NSAttributedString {
        NSAttributedString(
            string: string,
            attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: size, weight: weight),
                .foregroundColor: color
            ]
        )
    }
}

/// One workstation: a desk, a chair, a monitor, and whoever is at it.
///
/// ## What the node is for
///
/// Everything a person can read about one session at a glance, arranged so the
/// three distances the board's cards were designed for still work:
///
/// - **Across the room** — the monitor's light. Its colour is the session's
///   state and its rhythm is the state's motion, and because it is *light* it
///   spills onto the desk and the agent, so a room of forty desks is read by
///   its lighting before anything is read as a shape.
/// - **At a glance** — the body. Typing, standing, hand up, slumped.
/// - **On purpose** — the harness's vendor mark on the desk front, and the
///   nameplate that appears under the pointer, which carries the harness's
///   full name.
///
/// ## Why the look is a value
///
/// A board frame arrives twenty times a second, and on a normal wall one
/// session changes and thirty-nine do not. ``Look`` is everything about a
/// session this node draws, so ``apply(session:scale:theme:reduceMotion:)`` can
/// compare one small value and return without touching the scene graph. That is
/// what keeps forty animated desks off the CPU: the actions run in SpriteKit's
/// own loop, and nothing re-attaches them.
@MainActor
final class DeskNode: SKNode {
    /// Everything about a session that changes what this node draws.
    struct Look: Equatable {
        var harness: Harness?
        var stateKey: String
        var pose: ScenePose
        var isAlarming: Bool
        var isEnded: Bool
        var isVacant: Bool
        var scale: CGFloat
        var reduceMotion: Bool
    }

    /// The desk itself, which outlives whoever is sitting at it.
    let slotID: String
    /// Who is sitting here now.
    private(set) var sessionKey: SessionKey?
    private(set) var look: Look?

    // MARK: Geometry

    /// The clickable area, in node space. Wider than the furniture so a click
    /// near a desk selects it rather than falling through to the floor.
    static let hitSize = CGSize(width: 104, height: 78)

    /// The vendor mark on the desk front, in points. Small enough that the
    /// monitor's light stays the loudest thing on the desk.
    static let markSize: CGFloat = 11

    private let hitArea = SKSpriteNode(color: .clear, size: DeskNode.hitSize)
    private let chair = SKSpriteNode()
    private let desk = SKSpriteNode()
    private let monitor = SKSpriteNode()
    private let screen = SKSpriteNode()
    private let glow = SKSpriteNode()
    private let paper = SKSpriteNode()
    private let bubble = SKSpriteNode()
    /// The harness's vendor mark, on the front of the desk.
    private let mark = SKSpriteNode()
    private let ring = SKShapeNode(
        rect: CGRect(x: -52, y: -8, width: 104, height: 70), cornerRadius: 3
    )
    private let nameplate = SKNode()
    private let nameplateBack = SKShapeNode()
    private let nameplateTitle = SKLabelNode()
    private let nameplateDetail = SKLabelNode()

    private var agent: AgentSprite?
    private var theme: SceneTheme

    init(slotID: String, theme: SceneTheme) {
        self.slotID = slotID
        self.theme = theme
        super.init()

        let art = PlaceholderArt.shared

        hitArea.anchorPoint = CGPoint(x: 0.5, y: 0)
        hitArea.position = CGPoint(x: 0, y: -8)
        hitArea.zPosition = -1
        hitArea.name = DeskNode.hitName

        glow.texture = art.glow()
        glow.size = CGSize(width: 132, height: 132)
        glow.position = CGPoint(x: 22, y: 40)
        glow.blendMode = .add
        glow.colorBlendFactor = 1
        glow.alpha = 0
        glow.zPosition = 0

        chair.texture = art.chair()
        chair.anchorPoint = CGPoint(x: 0.5, y: 0)
        chair.size = CGSize(width: 24, height: 26)
        chair.position = CGPoint(x: -26, y: 1)
        chair.zPosition = 1

        desk.texture = art.desk()
        desk.anchorPoint = CGPoint(x: 0.5, y: 0)
        desk.size = CGSize(width: 88, height: 22)
        desk.zPosition = 5

        paper.texture = art.paper()
        paper.anchorPoint = CGPoint(x: 0.5, y: 0)
        paper.size = CGSize(width: 14, height: 18)
        paper.position = CGPoint(x: -6, y: 22)
        paper.zPosition = 5.5
        paper.isHidden = true

        // The lit rectangle sits *behind* the shell, showing through the window
        // cut out of it — one texture for every state instead of seven.
        screen.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        screen.size = CGSize(width: 28, height: 16)
        screen.position = CGPoint(x: 22, y: 40)
        screen.color = theme.screenOff
        screen.colorBlendFactor = 1
        screen.zPosition = 5.6

        monitor.texture = art.monitor()
        monitor.anchorPoint = CGPoint(x: 0.5, y: 0)
        monitor.size = CGSize(width: 36, height: 30)
        monitor.position = CGPoint(x: 22, y: 22)
        monitor.zPosition = 6

        mark.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        mark.size = CGSize(width: Self.markSize, height: Self.markSize)
        mark.position = CGPoint(x: -2, y: 9)
        mark.colorBlendFactor = 1
        mark.zPosition = 7
        mark.isHidden = true

        bubble.anchorPoint = CGPoint(x: 0.5, y: 0)
        bubble.size = CGSize(width: 26, height: 28)
        bubble.position = CGPoint(x: -8, y: 50)
        bubble.zPosition = 9
        bubble.isHidden = true

        ring.strokeColor = theme.textSecondary
        ring.lineWidth = 1.5
        ring.fillColor = .clear
        ring.zPosition = 8
        ring.isHidden = true

        buildNameplate()

        addChild(hitArea)
        addChild(glow)
        addChild(chair)
        addChild(screen)
        addChild(desk)
        addChild(paper)
        addChild(monitor)
        addChild(mark)
        addChild(bubble)
        addChild(ring)
        addChild(nameplate)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("DeskNode is not archived") }

    /// The name every desk's hit area carries, so the scene can find one from
    /// a click without reaching into the node hierarchy.
    static let hitName = "auspex.desk.hit"

    // MARK: Content

    /// Draws `session` at this desk, or empties it when `session` is `nil`.
    ///
    /// Returns without touching anything when nothing that matters changed.
    func apply(
        session: SessionSnapshot?,
        scale: CGFloat,
        theme: SceneTheme,
        reduceMotion: Bool
    ) {
        let next = Look(
            harness: session?.key.harness,
            stateKey: session.map { SceneTheme.stateKey($0.state) } ?? "vacant",
            pose: session.map { ScenePose.pose(for: $0.state, isStale: $0.isStale) } ?? .ended,
            isAlarming: session?.state.style.isAlarming ?? false,
            isEnded: session?.state.isEnded ?? false,
            isVacant: session == nil,
            scale: scale,
            reduceMotion: reduceMotion
        )
        sessionKey = session?.key
        guard look != next || self.theme.id != theme.id else { return }
        self.theme = theme
        look = next

        setScale(scale)
        applyAgent(session: session, look: next)
        applyDesk(look: next)
        applyScreen(session: session, look: next)
        applyBubble(look: next)
    }

    private func applyAgent(session: SessionSnapshot?, look: Look) {
        guard let session, let harness = look.harness else {
            agent?.removeFromParent()
            agent = nil
            // An empty desk has its chair pushed in. It is the difference
            // between a workstation nobody is using and one that is broken.
            chair.position.x = -14
            return
        }
        chair.position.x = -26
        let sprite: AgentSprite
        if let existing = agent, existing.name == harness.rawValue {
            sprite = existing
        } else {
            agent?.removeFromParent()
            let created = AgentSprite(harness: harness, key: session.key)
            created.name = harness.rawValue
            created.position = CGPoint(x: -20, y: 4)
            created.zPosition = 2
            addChild(created)
            agent = created
            sprite = created
        }
        sprite.apply(pose: look.pose, reduceMotion: look.reduceMotion)
    }

    /// One texture per harness, for the whole app.
    ///
    /// `SKTexture(cgImage:)` mints a new texture — and a new GPU upload —
    /// every time it is called, and this is called whenever a desk's look
    /// changes, which on a live board is several times a second per session.
    /// The raster underneath was already cached; the texture was not, and an
    /// afternoon of watching the office was an afternoon of uploading the same
    /// nine logos. The mark is a mask coloured by the sprite, so one texture
    /// serves every theme.
    private static var markTextures: [Harness: SKTexture] = [:]

    private static func markTexture(for harness: Harness) -> SKTexture? {
        if let cached = markTextures[harness] { return cached }
        // Rasterised at four times its drawn size so the mark stays clean when
        // the camera zooms in on one desk.
        guard let raster = HarnessLogo.cgImage(
            for: harness, pixelSize: Int(markSize) * 4
        ) else { return nil }
        let texture = SKTexture(cgImage: raster)
        markTextures[harness] = texture
        return texture
    }

    private func applyDesk(look: Look) {
        if let harness = look.harness, let texture = Self.markTexture(for: harness) {
            mark.texture = texture
            mark.color = theme.accent(harness)
            mark.isHidden = false
        } else {
            mark.isHidden = true
        }
        mark.alpha = look.isEnded ? 0.4 : 1
        paper.isHidden = look.pose != .writing
        paper.removeAllActions()
        if look.pose == .writing, !look.reduceMotion {
            paper.run(
                .repeatForever(
                    .sequence([
                        .moveBy(x: 0, y: 1.5, duration: 0.2),
                        .moveBy(x: 0, y: -1.5, duration: 0.2)
                    ])
                ),
                withKey: "tick"
            )
        }
    }

    /// The monitor: colour says which state, rhythm says which state, and the
    /// spill is what makes both readable at the far end of a second display.
    private func applyScreen(session: SessionSnapshot?, look: Look) {
        screen.removeAllActions()
        glow.removeAllActions()

        guard let session, !look.isEnded else {
            screen.color = theme.screenOff
            screen.alpha = 1
            glow.alpha = 0
            return
        }

        let color = theme.color(for: session.state)
        screen.color = color
        glow.color = color
        screen.alpha = 1

        guard !look.reduceMotion else {
            // Static, but not uniform: a still room still has to say which
            // desk needs a person.
            glow.alpha = look.isAlarming ? 0.7 : (look.pose == .idle ? 0.12 : 0.42)
            return
        }

        switch look.pose {
        case .thinking:
            glow.alpha = 0.24
            glow.run(
                .repeatForever(
                    .sequence([
                        .fadeAlpha(to: 0.52, duration: 1.05),
                        .fadeAlpha(to: 0.24, duration: 1.05)
                    ])
                ),
                withKey: "light"
            )
        case .typing:
            glow.alpha = 0.46
            screen.run(
                .repeatForever(
                    .sequence([
                        .fadeAlpha(to: 0.72, duration: 0.08),
                        .fadeAlpha(to: 1, duration: 0.12),
                        .wait(forDuration: 0.1)
                    ])
                ),
                withKey: "flicker"
            )
        case .writing:
            glow.alpha = 0.5
            glow.run(
                .repeatForever(
                    .sequence([
                        .fadeAlpha(to: 0.62, duration: 0.52),
                        .fadeAlpha(to: 0.42, duration: 0.52)
                    ])
                ),
                withKey: "light"
            )
        case .delegating:
            glow.alpha = 0.48
        case .blocked:
            // The loudest thing in the room, and the only thing allowed to be.
            glow.alpha = 0.8
            glow.run(
                .repeatForever(
                    .sequence([
                        .fadeAlpha(to: 0.18, duration: 0.3),
                        .fadeAlpha(to: 0.85, duration: 0.22),
                        .wait(forDuration: 0.24)
                    ])
                ),
                withKey: "light"
            )
        case .stale:
            glow.alpha = 0.12
        case .idle:
            glow.alpha = 0.1
        case .ended:
            glow.alpha = 0
        }
    }

    private func applyBubble(look: Look) {
        bubble.removeAllActions()
        let kind: BubbleKind?
        switch look.pose {
        case .blocked: kind = .alert
        case .stale: kind = .asleep
        case .delegating: kind = .note
        default: kind = nil
        }
        guard let kind else {
            bubble.isHidden = true
            return
        }
        bubble.isHidden = false
        bubble.texture = PlaceholderArt.shared.bubble(kind)
        bubble.alpha = 1
        bubble.setScale(1)
        guard !look.reduceMotion else { return }

        switch kind {
        case .alert:
            bubble.run(
                .repeatForever(
                    .sequence([
                        .scale(to: 1.22, duration: 0.24),
                        .scale(to: 1, duration: 0.3),
                        .wait(forDuration: 0.2)
                    ])
                ),
                withKey: "bubble"
            )
        case .asleep:
            bubble.run(
                .repeatForever(
                    .sequence([
                        .group([.fadeAlpha(to: 0.15, duration: 1.6), .moveBy(x: 0, y: 8, duration: 1.6)]),
                        .group([.fadeAlpha(to: 1, duration: 0), .moveBy(x: 0, y: -8, duration: 0)]),
                        .wait(forDuration: 0.4)
                    ])
                ),
                withKey: "bubble"
            )
        case .note:
            bubble.run(
                .repeatForever(
                    .sequence([
                        .fadeAlpha(to: 0.45, duration: 0.6),
                        .fadeAlpha(to: 1, duration: 0.6)
                    ])
                ),
                withKey: "bubble"
            )
        }
    }

    // MARK: Selection and hover

    /// Rings the desk. The scene keeps this in step with `model.selectedKey`,
    /// so clicking a card on the board lights the desk here and the other way
    /// round.
    func setSelected(_ selected: Bool) {
        ring.isHidden = !selected
        ring.strokeColor = selected ? theme.textPrimary : theme.textSecondary
    }

    /// Shows or hides the nameplate over the desk.
    func setHovered(_ hovered: Bool, title: String = "", detail: String = "") {
        guard hovered, !title.isEmpty else {
            nameplate.isHidden = true
            return
        }
        nameplateTitle.attributedText = SceneText.mono(title, size: 10, color: theme.textPrimary)
        nameplateDetail.attributedText = SceneText.label(
            detail, size: 8, color: theme.textTertiary
        )
        let width = max(
            nameplateTitle.frame.width, nameplateDetail.frame.width
        ) + 14
        nameplateBack.path = CGPath(
            roundedRect: CGRect(x: -width / 2, y: -4, width: width, height: 30),
            cornerWidth: 3,
            cornerHeight: 3,
            transform: nil
        )
        nameplate.isHidden = false
    }

    /// Keeps the nameplate the same size on screen however far the camera has
    /// zoomed out — a tooltip that shrinks with the room is a tooltip nobody
    /// can read.
    func setCameraScale(_ scale: CGFloat) {
        nameplate.setScale(max(0.4, min(2.5, scale)))
    }

    private func buildNameplate() {
        nameplateBack.fillColor = theme.panel
        nameplateBack.strokeColor = theme.hairlineStrong
        nameplateBack.lineWidth = 1

        nameplateTitle.horizontalAlignmentMode = .center
        nameplateTitle.verticalAlignmentMode = .baseline
        nameplateTitle.position = CGPoint(x: 0, y: 14)
        nameplateDetail.horizontalAlignmentMode = .center
        nameplateDetail.verticalAlignmentMode = .baseline
        nameplateDetail.position = CGPoint(x: 0, y: 2)

        nameplate.addChild(nameplateBack)
        nameplate.addChild(nameplateTitle)
        nameplate.addChild(nameplateDetail)
        nameplate.position = CGPoint(x: 0, y: 62)
        nameplate.zPosition = 20
        nameplate.isHidden = true
    }
}
