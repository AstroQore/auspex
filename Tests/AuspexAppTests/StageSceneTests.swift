import AgentSessionKit
import AgentSessionLive
import AppKit
import AuspexCore
import Foundation
import QuartzCore
import SpriteKit
import Testing

@testable import AuspexApp

/// Now's stage as the scene draws it, and what a pause does to anybody who
/// was between two places.
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

    // MARK: - The stage

    /// A canvas the size of the design's stage, drawing `board` as the stage.
    private static func stage(_ board: BoardSnapshot) -> (SceneCanvasView, OfficeScene) {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let scene = OfficeScene(theme: theme)
        scene.composesStage = true
        let view = SceneCanvasView(scene: scene, frame: CGRect(x: 0, y: 0, width: 1_020, height: 380))
        view.fitPadding = scene.fitPadding
        view.layoutSubtreeIfNeeded()
        update(scene, board)
        view.layoutSubtreeIfNeeded()
        scene.frameStage()
        scene.update(CACurrentMediaTime())
        return (view, scene)
    }

    @Test("The stage draws people, one desk each, with the subagents folded into their parent")
    func stageDrawsOnlyPeople() {
        let parent = Self.key("parent")
        let board = Self.board([
            Self.session("parent", state: .delegating(children: 1)),
            Self.session("child", parent: parent, state: .toolCalling(name: "Grep")),
            Self.session("resting", state: .idle),
            Self.session("finished", state: .ended(reason: .exited)),
            Self.session("elsewhere", project: "/Users/example/Code/harbor", state: .ended(reason: .exited)),
        ])
        let (_, scene) = Self.stage(board)
        #expect(Set(scene.map.slots.compactMap(\.session)) == [parent, Self.key("resting")])
        #expect(scene.map.slots.allSatisfy { $0.isOccupied })
        #expect(scene.map.floors.map(\.title) == ["atlas"])
        #expect(scene.map.seats.isEmpty)
        #expect(scene.map.slots.first { $0.session == parent }?.childCount == 1)

        // The child's balloon hangs over the parent it is folded into.
        scene.setCaptions([Self.key("child"): SceneCaption(tone: .working, lead: nil, body: "Grep", since: nil)])
        #expect(scene.showsCaption(over: parent))
    }

    @Test("The stage is framed to its composition, and the composition fills the strip")
    func stageIsFramed() {
        let board = Self.board((0..<5).map { Self.session("s\($0)", state: .thinking) })
        let (_, scene) = Self.stage(board)
        #expect(scene.composition.zoom == 1)
        #expect(abs(scene.zoom - scene.composition.zoom) < 0.001)
        #expect(scene.viewport.showsAll(of: scene.contentBounds))
    }
}
