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
        var seat: SceneSeatKind
        var isAlarming: Bool
        var isEnded: Bool
        var isVacant: Bool
        /// Whether whoever this place belongs to is somewhere else on the map.
        var isAway: Bool
        var scale: CGFloat
        var reduceMotion: Bool
        /// How many sessions this one delegated to.
        var childCount: Int
    }

    /// What a place is made of.
    ///
    /// Decided once, at construction, from the kind of seat the layout said
    /// this is. A desk never becomes a bench: the layout gives a workstation
    /// and a garden seat different ids, and a node's id is what the director
    /// diffs on. So the furniture is built once and the per-frame work stays
    /// what it was — one small value compared, and usually nothing done.
    enum Furniture {
        /// A desk, a chair, and a monitor.
        case workstation
        /// A chair at a long table, with a laptop on it.
        case tableSeat
        /// A bench or a blanket in the garden.
        case gardenSeat
        /// Nothing. Somebody on their way out through the gate.
        case bare

        init(_ kind: SceneSeatKind) {
            switch kind {
            case .desk: self = .workstation
            case .tableHead, .tableNorth, .tableSouth: self = .tableSeat
            case .call, .note, .bench, .doze: self = .gardenSeat
            case .gate: self = .bare
            }
        }
    }

    /// The desk itself, which outlives whoever is sitting at it.
    let slotID: String
    /// What this place is made of.
    let furniture: Furniture
    /// Which seat it is, which decides where the laptop goes and which way the
    /// light spills.
    private let seatKind: SceneSeatKind
    /// Who is sitting here now.
    private(set) var sessionKey: SessionKey?
    private(set) var look: Look?

    // MARK: Geometry

    /// The clickable area, in node space. Wider than the furniture so a click
    /// near a desk selects it rather than falling through to the floor.
    ///
    /// It is not a node: the pointer is placed by ``SceneHitIndex``, against
    /// the floor plan, so this is a *number the layout knows* rather than an
    /// invisible sprite in every desk for the scene graph to walk past.
    static let hitSize = CGSize(width: 104, height: 78)

    /// How far that area reaches below the point on the floor line the desk
    /// stands on — the rest of its height is above.
    static let hitBaseline: CGFloat = 8

    /// The vendor mark on the desk front, in points. Small enough that the
    /// monitor's light stays the loudest thing on the desk.
    static let markSize: CGFloat = 11

    private let chair = SKSpriteNode()
    private let desk = SKSpriteNode()
    private let monitor = SKSpriteNode()
    private let screen = SKSpriteNode()
    private let glow = SKSpriteNode()
    /// What the glow hangs from. SpriteKit multiplies a node's alpha by its
    /// parent's, so one value here scales every pose's glow — and every fade
    /// action already in flight — without touching a dozen literals that are
    /// each about a *pose* rather than about an appearance.
    private let glowHolder = SKNode()
    private let paper = SKSpriteNode()
    private let bubble = SKSpriteNode()
    /// `↳ N`: how many sessions this one handed work to.
    ///
    /// The arcs stopped being drawn all at once (see
    /// ``SceneFrame/arcs(focus:limit:)``) and this is half of what replaced
    /// them — the count a reader was going to make by following lines, written
    /// down. The other half is that the children are sitting round this
    /// session's table.
    private let delegation = SKLabelNode()
    /// The bench or the blanket a garden seat is, and the laptop a table seat
    /// has. `nil` for a place that needs neither.
    private var seatProp: SKSpriteNode?
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

    init(slotID: String, kind: SceneSeatKind = .desk, theme: SceneTheme) {
        self.slotID = slotID
        self.seatKind = kind
        self.furniture = Furniture(kind)
        self.theme = theme
        super.init()

        let art = PlaceholderArt.shared

        glow.texture = art.glow()
        glow.size = CGSize(width: 132, height: 132)
        glow.position = CGPoint(x: 22, y: 40)
        glow.colorBlendFactor = 1
        glow.alpha = 0
        glowHolder.zPosition = 0
        glowHolder.addChild(glow)
        applyGlowGround()

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

        // The delegation badge sits on the far corner of the desk, away from
        // the bubble over the agent's head, because the two say different
        // things and a session that is delegating *and* blocked shows both.
        delegation.horizontalAlignmentMode = .right
        delegation.verticalAlignmentMode = .center
        delegation.position = CGPoint(x: 46, y: 58)
        delegation.zPosition = 9
        delegation.isHidden = true

        ring.strokeColor = theme.textSecondary
        ring.lineWidth = 1.5
        ring.fillColor = .clear
        ring.zPosition = 8
        ring.isHidden = true

        buildNameplate()

        addChild(glowHolder)
        addChild(chair)
        addChild(screen)
        addChild(desk)
        addChild(paper)
        addChild(monitor)
        addChild(mark)
        addChild(bubble)
        addChild(delegation)
        addChild(ring)
        addChild(nameplate)

        furnish(art)
    }

    /// Puts out whatever this place is made of, and takes away what it is not.
    ///
    /// The office's own sprites are built by the initialiser above and then
    /// switched off here rather than being built conditionally, because they
    /// are stored properties: a `let` that only sometimes has a texture is a
    /// worse trade than four hidden nodes on the seats that are not desks.
    private func furnish(_ art: PlaceholderArt) {
        switch furniture {
        case .workstation:
            return

        case .tableSeat:
            desk.isHidden = true
            monitor.isHidden = true
            chair.isHidden = true
            paper.isHidden = true
            let laptop = SKSpriteNode(texture: art.laptop())
            laptop.anchorPoint = CGPoint(x: 0.5, y: 0)
            laptop.size = CGSize(width: 20, height: 16)
            // A laptop belongs between its owner and the middle of the table.
            // Which way that is depends on which side of it they are sitting,
            // and so does whether it is drawn in front of them or behind: on
            // the near side you see their back and the lid past their head.
            switch seatKind {
            case .tableSouth:
                laptop.position = CGPoint(x: 0, y: 34)
                laptop.zPosition = 1
                screen.position = CGPoint(x: 0, y: 42)
            case .tableHead:
                laptop.position = CGPoint(x: 16, y: 8)
                laptop.zPosition = 6
                screen.position = CGPoint(x: 16, y: 16)
            default:
                laptop.position = CGPoint(x: 0, y: -14)
                laptop.zPosition = 6
                screen.position = CGPoint(x: 0, y: -6)
            }
            screen.size = CGSize(width: 12, height: 8)
            screen.zPosition = laptop.zPosition - 0.1
            glow.size = CGSize(width: 96, height: 96)
            glow.position = screen.position
            mark.position = CGPoint(x: -18, y: 6)
            addChild(laptop)
            seatProp = laptop

        case .gardenSeat:
            desk.isHidden = true
            monitor.isHidden = true
            chair.isHidden = true
            paper.isHidden = true
            screen.isHidden = true
            // Half the garden sits on benches and half on blankets, decided
            // from the seat's own id so that a bench does not become a blanket
            // when the person on it goes from resting to waiting to be read.
            let onBlanket = Self.prefersBlanket(slotID)
            let prop = SKSpriteNode(
                texture: onBlanket ? art.picnicBlanket() : art.bench()
            )
            prop.anchorPoint = CGPoint(x: 0.5, y: 0)
            prop.size = onBlanket
                ? CGSize(width: 46, height: 26)
                : CGSize(width: 52, height: 24)
            prop.position = CGPoint(x: 0, y: onBlanket ? -8 : -4)
            prop.zPosition = onBlanket ? 0.5 : 1
            glow.size = CGSize(width: 88, height: 88)
            glow.position = CGPoint(x: 0, y: 26)
            mark.position = CGPoint(x: 20, y: 6)
            bubble.position = CGPoint(x: 6, y: 46)
            addChild(prop)
            seatProp = prop

        case .bare:
            desk.isHidden = true
            monitor.isHidden = true
            chair.isHidden = true
            paper.isHidden = true
            screen.isHidden = true
            mark.isHidden = true
            glow.size = CGSize(width: 72, height: 72)
            glow.position = CGPoint(x: 0, y: 26)
        }
    }

    /// Whether this garden seat is a blanket rather than a bench.
    ///
    /// Two in five, spread by the seat's index rather than at random: a
    /// picture that reshuffled its furniture between two renders of the same
    /// board would not be a picture of the board.
    private static func prefersBlanket(_ id: String) -> Bool {
        guard let digits = id.split(separator: ".").last,
              let index = Int(digits.drop(while: { !$0.isNumber }))
        else { return false }
        return index % 5 >= 3
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("DeskNode is not archived") }

    // MARK: Content

    /// Draws `session` at this desk, or empties it when `session` is `nil`.
    ///
    /// Returns without touching anything when nothing that matters changed.
    func apply(
        session: SessionSnapshot?,
        seat: SceneSeatKind = .desk,
        isAway: Bool = false,
        childCount: Int = 0,
        scale: CGFloat,
        theme: SceneTheme,
        reduceMotion: Bool
    ) {
        let next = Look(
            harness: session?.key.harness,
            stateKey: session.map { SceneTheme.stateKey($0.state) } ?? "vacant",
            pose: session.map { ScenePose.pose(for: $0.state, isStale: $0.isStale) } ?? .ended,
            seat: seat,
            isAlarming: session?.state.style.isAlarming ?? false,
            isEnded: session?.state.isEnded ?? false,
            isVacant: session == nil,
            isAway: isAway,
            scale: scale,
            reduceMotion: reduceMotion,
            childCount: childCount
        )
        sessionKey = session?.key
        guard look != next || self.theme.id != theme.id else { return }
        let appearanceChanged = self.theme.isDark != theme.isDark
        self.theme = theme
        if appearanceChanged { applyGlowGround() }
        look = next

        setScale(scale)
        applyAgent(session: session, look: next)
        applyDesk(look: next)
        applyScreen(session: session, look: next)
        applyBubble(look: next)
        applyDelegationBadge(look: next)
    }

    /// Writes `↳ N` on the desk of a session that delegated, or takes it off.
    ///
    /// Only where the person actually is: a badge on a desk somebody has
    /// walked away from would be counting a family that is sitting in the next
    /// room, which the table already shows.
    private func applyDelegationBadge(look: Look) {
        guard look.childCount > 0, !look.isVacant, !look.isAway, !look.isEnded else {
            delegation.isHidden = true
            return
        }
        delegation.isHidden = false
        delegation.attributedText = SceneText.mono(
            "↳\(look.childCount)",
            size: 10,
            color: theme.color(for: .delegating(children: look.childCount))
        )
    }

    private func applyAgent(session: SessionSnapshot?, look: Look) {
        // A desk whose owner has walked to a table or a bench is drawn empty,
        // the same as one nobody has taken. The difference is not something a
        // picture of a desk can carry — it is carried by the person being
        // visibly somewhere else.
        guard let session, let harness = look.harness, !look.isAway else {
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
            created.position = Self.agentPosition(for: furniture)
            created.zPosition = 2
            addChild(created)
            agent = created
            sprite = created
        }
        switch look.seat {
        // Somebody in the queue for the gate is *leaving*, not gone. The
        // `ended` pose fades them out where they sit, which is right at a desk
        // — the chair is what is left — and wrong here, where the whole point
        // of the walk is that you can watch them go.
        case .gate:
            sprite.walk(.right, reduceMotion: look.reduceMotion)
        // Somebody waiting to be read is *sitting there*, whether or not the
        // process behind them has exited. Half the sessions on this bench are
        // `ended`, and the ended pose fades them out — which would leave the
        // garden holding a note with nobody under it, and lose the one thing
        // the annex was built to show.
        case .note:
            sprite.apply(pose: .idle, reduceMotion: look.reduceMotion)
        // And somebody waiting on a person has their hand up, wherever the
        // state machine thinks they are. The pose is what the front row is
        // *for*: a raised hand reads from the far side of the map, and the
        // whole point of moving them out of the office was that a hand up
        // among forty desks does not.
        case .call:
            sprite.apply(pose: .blocked, reduceMotion: look.reduceMotion)
        default:
            sprite.apply(pose: look.pose, reduceMotion: look.reduceMotion)
        }
    }

    /// Where the person stands inside their place.
    ///
    /// The office offsets them to the left so the monitor has the middle of
    /// the desk; everywhere else the seat *is* the anchor, because a chair at
    /// a table and a bench in the garden were laid out around the person
    /// rather than around the furniture.
    private static func agentPosition(for furniture: Furniture) -> CGPoint {
        switch furniture {
        case .workstation: CGPoint(x: -20, y: 4)
        case .tableSeat, .gardenSeat, .bare: CGPoint(x: 0, y: 0)
        }
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
        if let harness = look.harness, let texture = Self.markTexture(for: harness),
           furniture != .bare, !look.isAway {
            mark.texture = texture
            mark.color = theme.accent(harness)
            mark.isHidden = false
        } else {
            mark.isHidden = true
        }
        mark.alpha = look.isEnded ? 0.4 : 1
        seatProp?.alpha = look.isVacant ? 0.55 : 1
        guard furniture == .workstation else { return }
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

    /// How the spill meets the floor, which is the one thing about a glow that
    /// is about the room rather than about the session.
    private func applyGlowGround() {
        glow.blendMode = theme.glowBlend
        glowHolder.alpha = theme.glowScale
    }

    /// The monitor: colour says which state, rhythm says which state, and the
    /// spill is what makes both readable at the far end of a second display.
    private func applyScreen(session: SessionSnapshot?, look: Look) {
        screen.removeAllActions()
        glow.removeAllActions()

        let isDark = look.isAway || (look.isEnded && look.seat != .note)
        guard let session, !isDark else {
            screen.color = theme.screenOff
            screen.alpha = 1
            glow.alpha = 0
            return
        }

        let color = theme.color(for: session.state)
        screen.color = color
        glow.color = color
        screen.alpha = 1

        // Nothing in the garden has a screen in it. The light is still there,
        // low, because a bench with somebody on it and a bench without one
        // should not be the same shape in the dark — but the state itself is
        // said by the bubble over their head, which is the whole reason they
        // are out here.
        guard furniture != .gardenSeat, furniture != .bare else {
            glow.alpha = look.reduceMotion || look.pose != .stale ? 0.14 : 0.1
            return
        }

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
        switch look.seat {
        // The whole point of the garden: a session that finished while you
        // were elsewhere sits there holding the note that says so, and that
        // is readable from further away than any monitor colour.
        case .note: kind = .done
        // The loudest thing on the map, and the only one allowed to be.
        case .call: kind = .alert
        case .doze: kind = .asleep
        case .bench, .gate: kind = nil
        // Nothing over anybody's head at a table. The projector at the end of
        // it already carries the parent's state, and a note bubble on top of
        // that would be the same fact said twice — once by the room and once
        // by the person, which is how a reader learns to trust neither.
        case .tableHead, .tableNorth, .tableSouth:
            kind = look.pose == .blocked ? .alert : nil
        default:
            switch look.pose {
            case .blocked: kind = .alert
            case .stale: kind = .asleep
            case .delegating: kind = .note
            default: kind = nil
            }
        }
        guard let kind, !look.isAway, !look.isVacant else {
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
        case .done:
            // A slow lift and settle rather than a pulse: it is waiting, not
            // asking. The only thing in this scene allowed to ask is red.
            bubble.run(
                .repeatForever(
                    .sequence([
                        .moveBy(x: 0, y: 3, duration: 1.1),
                        .moveBy(x: 0, y: -3, duration: 1.1),
                        .wait(forDuration: 0.5)
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
