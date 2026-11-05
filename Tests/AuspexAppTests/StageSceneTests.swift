import AgentSessionKit
import AgentSessionLive
import AppKit
import AuspexCore
import Foundation
import QuartzCore
import SpriteKit
import Testing

@testable import AuspexApp

/// What a pause does to anybody who was between two places.
@MainActor
@Suite("Stage scene")
struct StageSceneTests {
    private static let theme = SceneTheme.resolved(
        for: NSAppearance(named: .darkAqua) ?? NSAppearance()
    )
    private static let epoch = Date(timeIntervalSince1970: 1_767_225_600)

    private static func key(_ id: String) -> SessionKey {
        SessionKey(harness: .claudeCode, sessionID: id)
    }

    private static func session(
        _ id: String,
        project: String = "/Users/example/Code/atlas",
        parent: SessionKey? = nil,
        state: SessionState
    ) -> SessionSnapshot {
        SessionSnapshot(
            identity: SessionIdentity(
                key: key(id),
                sourcePath: "/Users/example/.claude/projects/demo/\(id).jsonl",
                parent: parent,
                cwd: project,
                gitRoot: project,
                title: "Demo \(id)"
            ),
            state: state,
            isAlive: !state.isEnded
        )
    }

    private static func board(_ sessions: [SessionSnapshot], after seconds: TimeInterval = 0) -> BoardSnapshot {
        BoardSnapshot(generatedAt: epoch.addingTimeInterval(seconds), sessions: sessions)
    }

    private static func update(_ scene: OfficeScene, _ board: BoardSnapshot, reduceMotion: Bool = false) {
        scene.update(
            board: board, selected: nil, focusedProject: nil,
            reduceMotion: reduceMotion, theme: theme
        )
    }

    /// Four people at their desks, then one of them gone idle and on their
    /// way to the break room.
    private static func sceneWithWalker(_ walker: SessionState) -> OfficeScene {
        let scene = OfficeScene(theme: theme)
        let others = ["b", "c", "d"].map { session($0, state: .thinking) }
        update(scene, board([session("walker", state: .thinking)] + others))
        update(scene, board([session("walker", state: walker)] + others, after: 1))
        return scene
    }

    // MARK: - Walking

    @Test("Somebody mid-walk keeps the clock running")
    func walkerIsMotion() {
        let scene = Self.sceneWithWalker(.idle)
        #expect(scene.walkerCount == 1)
        #expect(!scene.isSeated(Self.key("walker")))
        #expect(scene.hasVisibleMotion)
    }

    @Test("A pause lands everybody mid-walk in their seat")
    func pauseLandsWalkers() {
        let scene = Self.sceneWithWalker(.idle)
        scene.settleMotion()
        #expect(scene.walkerCount == 0)
        #expect(scene.isSeated(Self.key("walker")))
    }

    @Test("A view that stops its clock settles the scene first")
    func suspendSettles() {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let scene = OfficeScene(theme: Self.theme)
        let view = SceneCanvasView(scene: scene, frame: CGRect(x: 0, y: 0, width: 900, height: 640))
        let others = ["b", "c", "d"].map { Self.session($0, state: .thinking) }
        Self.update(scene, Self.board([Self.session("walker", state: .thinking)] + others))
        Self.update(scene, Self.board([Self.session("walker", state: .idle)] + others, after: 1))
        #expect(scene.walkerCount == 1)

        view.skView.suspend()
        #expect(scene.walkerCount == 0)
        #expect(scene.isSeated(Self.key("walker")))
    }

    @Test("Somebody settled on their way out leaves, rather than standing at the door")
    func settledLeaverLeaves() {
        let scene = Self.sceneWithWalker(.ended(reason: .exited))
        #expect(scene.walkerCount == 1)
        #expect(!scene.hasDeparted(Self.key("walker")))
        scene.settleMotion()
        #expect(scene.walkerCount == 0)
        #expect(scene.hasDeparted(Self.key("walker")))
        // And nobody is left in the queue for a door.
        #expect(!scene.map.seats.contains { $0.kind == .gate && $0.session != nil })
    }
}
