import AgentSessionKit
import AgentSessionLive
import SpriteKit

/// One agent, as a little person.
///
/// ## Two rigs behind one interface
///
/// If this session's character package has a strip for the pose, the sprite is
/// one node playing it. If it does not — because nobody has drawn that pose
/// yet, or because no package claims the harness at all — the sprite is a
/// two-piece procedural rig: a head and a torso, drawn by ``PlaceholderArt`` in
/// the harness's own hue, animated by swapping the torso's pose texture and
/// moving the head. The choice is made per *pose*, so a package holding only
/// `blocked.png` gives exactly the sessions that need a person a person.
///
/// The rig matters because it decides what motion is available. A frame strip
/// can do anything the artist drew and nothing else; the procedural rig can
/// only swap between poses and move nodes, which is why the placeholder
/// vocabulary is small and rhythmic rather than detailed. Both are driven from
/// the same ``ScenePose``, so replacing one with the other changes how the
/// office looks and not how it behaves.
///
/// ## The rhythms
///
/// The board already teaches a state language in colour and motion — a slow
/// breath for thinking, a travelling segment while a tool is open, a hard
/// strobe when a person is needed. The office repeats it in bodies:
///
/// | State | What the body does |
/// | --- | --- |
/// | thinking | head bobs, slowly |
/// | tool call | hands alternate, fast |
/// | writing a file | hands alternate, half speed |
/// | delegating | stands, holds a note out sideways |
/// | waiting for permission | one hand up, insistent bounce |
/// | idle | slumped, still |
/// | stale | still, dimmed |
/// | ended | fades out and leaves the chair |
///
/// Every one of them collapses to a static pose under Reduce Motion, and the
/// two states that are *supposed* to be still — idle and ended — attach no
/// action at all in either mode. A room of forty finished agents costs the
/// render loop nothing.
@MainActor
final class AgentSprite: SKNode {
    /// The width of the procedural torso in points. The whole rig hangs off it.
    static let bodySize = CGSize(width: 36, height: 30)
    static let headSize = CGSize(width: 20, height: 16)

    private let harness: Harness
    private let key: SessionKey

    private let body = SKSpriteNode()
    private let head = SKSpriteNode()
    /// Used instead of ``body``/``head`` when real art exists for this pose.
    private let atlas = SKSpriteNode()

    private var currentPose: ScenePose?
    private var currentReduceMotion: Bool?

    init(harness: Harness, key: SessionKey) {
        self.harness = harness
        self.key = key
        super.init()

        body.anchorPoint = CGPoint(x: 0.5, y: 0)
        body.size = Self.bodySize
        body.zPosition = 0

        head.anchorPoint = CGPoint(x: 0.5, y: 0)
        head.size = Self.headSize
        head.position = CGPoint(x: 0, y: Self.bodySize.height - 2)
        head.zPosition = 1

        atlas.anchorPoint = CGPoint(x: 0.5, y: 0)
        atlas.isHidden = true
        atlas.zPosition = 1

        addChild(body)
        addChild(head)
        addChild(atlas)

        // Weakly held. A character package can be redrawn while the office is
        // on screen, and a desk only re-applies a pose when its *session*
        // changes — so the library repaints the sprites it knows about rather
        // than waiting for a board frame that may not arrive for minutes.
        SpriteLibrary.shared.register(self)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("AgentSprite is not archived") }

    /// Puts the agent into `pose`.
    ///
    /// Does nothing when the pose and the motion setting are both unchanged,
    /// which is the common case: a board frame arrives twenty times a second
    /// and almost none of them change what an agent is doing. Restarting a
    /// `repeatForever` on every frame would reset its phase, so the whole room
    /// would blink in lockstep with the ingest pipeline.
    func apply(pose: ScenePose, reduceMotion: Bool) {
        guard currentPose != pose || currentReduceMotion != reduceMotion else { return }
        currentPose = pose
        currentReduceMotion = reduceMotion

        removeAllActions()
        body.removeAllActions()
        head.removeAllActions()
        atlas.removeAllActions()
        position.y = 0
        head.position.y = Self.bodySize.height - 2
        alpha = 1

        if let strip = SpriteLibrary.shared.strip(for: key, pose: pose) {
            applyStrip(strip, reduceMotion: reduceMotion)
        } else {
            applyProcedural(pose, reduceMotion: reduceMotion)
        }
    }

    /// Redraws the current pose from whatever the library holds now.
    ///
    /// Called after a reload, when the art behind an unchanged pose may be
    /// different — a package appeared, was edited, or was deleted. The memo in
    /// ``apply(pose:reduceMotion:)`` exists to stop a board frame arriving
    /// twenty times a second from restarting every loop in the room, and it is
    /// exactly what has to be defeated here.
    func refreshArt() {
        guard let pose = currentPose, let reduceMotion = currentReduceMotion else { return }
        currentPose = nil
        apply(pose: pose, reduceMotion: reduceMotion)
    }

    // MARK: Drawn art

    private func applyStrip(_ strip: SpriteLibrary.Strip, reduceMotion: Bool) {
        guard let first = strip.frames.first else { return }
        body.isHidden = true
        head.isHidden = true
        atlas.isHidden = false
        // `pointsPerPixel` and not `PlaceholderArt.pixelScale`: a 48-pixel cell
        // is a more detailed character, not a taller one, so both legal cell
        // sizes land the same height on screen.
        let pixels = first.size()
        atlas.size = CGSize(
            width: pixels.width * strip.pointsPerPixel,
            height: pixels.height * strip.pointsPerPixel
        )
        atlas.texture = first
        guard !reduceMotion, strip.frames.count > 1 else { return }
        atlas.run(
            .repeatForever(.animate(with: strip.frames, timePerFrame: strip.timePerFrame)),
            withKey: "pose"
        )
    }

    // MARK: The placeholder rig

    private func applyProcedural(_ pose: ScenePose, reduceMotion: Bool) {
        atlas.isHidden = true
        body.isHidden = false
        head.isHidden = false
        let art = PlaceholderArt.shared
        head.texture = art.head(harness: harness)

        switch pose {
        case .ended:
            body.texture = art.body(harness: harness, pose: .slump)
            // The one animation that is not a loop: the agent leaves, the desk
            // stays. Under Reduce Motion it is simply gone.
            if reduceMotion {
                alpha = 0
            } else {
                run(.sequence([.wait(forDuration: 0.35), .fadeOut(withDuration: 0.5)]), withKey: "pose")
            }

        case .idle:
            body.texture = art.body(harness: harness, pose: .slump)
            alpha = 0.85

        case .stale:
            body.texture = art.body(harness: harness, pose: .rest)
            alpha = 0.55

        case .thinking:
            body.texture = art.body(harness: harness, pose: .rest)
            guard !reduceMotion else { return }
            head.run(
                .repeatForever(
                    .sequence([
                        .moveBy(x: 0, y: -2, duration: 0.62, timing: .easeInEaseOut),
                        .moveBy(x: 0, y: 2, duration: 0.62, timing: .easeInEaseOut)
                    ])
                ),
                withKey: "bob"
            )

        case .typing, .writing:
            let frames = [
                art.body(harness: harness, pose: .rest),
                art.body(harness: harness, pose: .type)
            ]
            body.texture = frames[0]
            guard !reduceMotion else { return }
            // A file write is the slower of the two activities and reads that
            // way on the board's pulse line as well.
            let tempo: TimeInterval = pose == .writing ? 0.2 : 0.1
            body.run(.repeatForever(.animate(with: frames, timePerFrame: tempo)), withKey: "pose")

        case .delegating:
            body.texture = art.body(harness: harness, pose: .offer)
            // Standing up: the one pose that changes the agent's height, so a
            // delegating desk is picked out by silhouette before colour.
            position.y = 3
            guard !reduceMotion else { return }
            run(
                .repeatForever(
                    .sequence([
                        .moveBy(x: 2, y: 0, duration: 0.7, timing: .easeInEaseOut),
                        .moveBy(x: -2, y: 0, duration: 0.7, timing: .easeInEaseOut)
                    ])
                ),
                withKey: "pose"
            )

        case .blocked:
            body.texture = art.body(harness: harness, pose: .raise)
            guard !reduceMotion else { return }
            run(
                .repeatForever(
                    .sequence([
                        .moveBy(x: 0, y: 2.5, duration: 0.22, timing: .easeOut),
                        .moveBy(x: 0, y: -2.5, duration: 0.28, timing: .easeIn),
                        .wait(forDuration: 0.34)
                    ])
                ),
                withKey: "pose"
            )
        }
    }
}

private extension SKAction {
    /// `SKAction.moveBy` with a timing mode, in one expression.
    ///
    /// The two-line form — build the action, then set `timingMode` — is what
    /// turns a readable sequence into a page of temporaries.
    static func moveBy(
        x: CGFloat,
        y: CGFloat,
        duration: TimeInterval,
        timing: SKActionTimingMode
    ) -> SKAction {
        let action = SKAction.moveBy(x: x, y: y, duration: duration)
        action.timingMode = timing
        return action
    }
}
