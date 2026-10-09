import AgentSessionKit
import AgentSessionLive
import AppKit
import AuspexCore
import Foundation
import QuartzCore
import SpriteKit
import Testing

@testable import AuspexApp

/// When the office draws, and when it stops.
///
/// The view stops its clock after any frame with nothing moving in it, and
/// starts it again for the next change — see `OfficeSKView`. What can be held
/// headless is everything either side of the display link: whether the scene
/// is right about what is moving, whether idle motion waits for the room to
/// stir, how fast each surface draws, and that a view nobody can see stays
/// asleep whatever is changed under it.
@MainActor
@Suite("Scene clock")
struct SceneClockTests {
    private static let theme = SceneTheme.resolved(
        for: NSAppearance(named: .darkAqua) ?? NSAppearance()
    )

    /// The demo office on a canvas, with the camera's cull applied.
    private static func canvas(reduceMotion: Bool) -> (SceneCanvasView, OfficeScene) {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let scene = OfficeScene(theme: theme)
        let view = SceneCanvasView(scene: scene, frame: CGRect(x: 0, y: 0, width: 900, height: 640))
        view.layoutSubtreeIfNeeded()
        scene.update(
            board: SceneSnapshotRenderer.demoBoard(elapsed: 16),
            selected: nil,
            focusedProject: nil,
            reduceMotion: reduceMotion,
            theme: theme
        )
        view.layoutSubtreeIfNeeded()
        scene.fitAll()
        scene.update(CACurrentMediaTime())
        return (view, scene)
    }

    /// Whether anything visible in a subtree has an action — the question
    /// the director answers from its own tables, asked the slow way.
    private static func anythingMoves(_ node: SKNode) -> Bool {
        if node.isHidden || node.isPaused { return false }
        if node.hasActions() { return true }
        return node.children.contains(where: anythingMoves)
    }

    private static func session(
        _ id: String,
        state: SessionState,
        isStale: Bool = false
    ) -> SessionSnapshot {
        SessionSnapshot(
            identity: SessionIdentity(
                key: SessionKey(harness: .claudeCode, sessionID: id),
                sourcePath: "/Users/example/.claude/projects/demo/\(id).jsonl",
                cwd: "/Users/example/Code/demo",
                gitRoot: "/Users/example/Code/demo",
                title: "Demo \(id)"
            ),
            state: state,
            isStale: isStale
        )
    }

    // MARK: - What is moving

    @Test("A working office is moving; the same office under Reduce Motion is still")
    func workingOfficeMoves() {
        let (_, moving) = Self.canvas(reduceMotion: false)
        #expect(moving.hasVisibleMotion)

        let (_, still) = Self.canvas(reduceMotion: true)
        #expect(!still.hasVisibleMotion)
        // And nothing in it will stir on its own: Reduce Motion has no idle
        // motion to wake up for.
        #expect(still.nextIdleBeat == nil)
    }

    @Test("The scene's answer agrees with a walk of the whole scene graph")
    func motionCheckMatchesTheGraph() {
        for reduceMotion in [false, true] {
            let (_, scene) = Self.canvas(reduceMotion: reduceMotion)
            // Headless, the view has paused the scene, which is a statement
            // about the clock rather than about what is moving in the
            // picture; a running office is what the question is about.
            scene.isPaused = false
            let walked = Self.anythingMoves(scene)
            #expect(scene.hasVisibleMotion == walked)
            #expect(walked == !reduceMotion)
        }
    }

    @Test("Idle motion waits for the room to stir, plays once, and stops")
    func idleMotionIsABeat() throws {
        let desk = DeskNode(slotID: "desk.4", theme: Self.theme)
        // Working, but silent for too long: drawn dozing, with a `z` over them.
        desk.apply(
            session: Self.session("dozing", state: .thinking, isStale: true),
            scale: 1,
            theme: Self.theme,
            reduceMotion: false
        )
        #expect(desk.hasIdleMotion)
        #expect(!desk.isAnimating)

        // The first stir this desk takes part in.
        let round = try #require((UInt64(1)...20).first { SceneIdleBeat.joins("desk.4", round: $0) })
        desk.beat(round: round)
        #expect(desk.isAnimating)

        // A stir it sits out leaves it alone.
        let other = DeskNode(slotID: "desk.4", theme: Self.theme)
        other.apply(
            session: Self.session("dozing", state: .thinking, isStale: true),
            scale: 1,
            theme: Self.theme,
            reduceMotion: false
        )
        let skipped = try #require((UInt64(1)...20).first { !SceneIdleBeat.joins("desk.4", round: $0) })
        other.beat(round: skipped)
        #expect(!other.isAnimating)
    }

    @Test("Working motion is a loop, not a beat")
    func workingMotionLoops() {
        let desk = DeskNode(slotID: "desk.1", theme: Self.theme)
        desk.apply(
            session: Self.session("typing", state: .toolCalling(name: "shell")),
            scale: 1,
            theme: Self.theme,
            reduceMotion: false
        )
        #expect(desk.isAnimating)
        #expect(!desk.hasIdleMotion)

        // And under Reduce Motion there is neither.
        let still = DeskNode(slotID: "desk.2", theme: Self.theme)
        still.apply(
            session: Self.session("dozing", state: .thinking, isStale: true),
            scale: 1,
            theme: Self.theme,
            reduceMotion: true
        )
        #expect(!still.isAnimating)
        #expect(!still.hasIdleMotion)
    }

    // MARK: - Rates, and staying asleep

    @Test("Now's stage draws at half the aviary's rate, gesture or not")
    func stageRates() {
        #expect(OfficeSKView.Rates.aviary == .init(resting: 30, gesture: 60))
        #expect(OfficeSKView.Rates.stage == .init(resting: 15, gesture: 30))

        let (view, _) = Self.canvas(reduceMotion: true)
        view.skView.rates = .stage
        // Headless there is no window, so the view put itself to sleep; a
        // running one is what the rate is about.
        view.skView.isPaused = false
        view.noteInteraction()
        #expect(view.skView.preferredFramesPerSecond == 30)
        view.advance(to: CACurrentMediaTime() + 10)
        #expect(view.skView.preferredFramesPerSecond == 15)
    }

    @Test("A view nobody can see stays asleep whatever changes under it")
    func offscreenViewStaysAsleep() {
        let (view, scene) = Self.canvas(reduceMotion: false)
        #expect(view.skView.isPaused)
        #expect(!view.skView.isOnScreen)

        scene.hover(atLayoutPoint: .zero)
        scene.requestFrame()
        view.skView.wake()
        view.skView.frameFinished(moving: false, nextWake: CACurrentMediaTime())
        #expect(view.skView.isPaused)
        #expect(!view.skView.isStill)
    }
}
