import AgentSessionKit
import AgentSessionLive
import AuspexCore
import Foundation
import Observation
import Testing

@testable import AuspexApp

/// What a frame is allowed to invalidate.
///
/// The board's whole performance story is that a frame arrives whenever *any*
/// session changed and that almost none of those changes reach most of the
/// window. `@Observable` invalidates on every write, including a write of the
/// value the property already held, so "the model wrote it" and "a view has to
/// be laid out again" are the same event — which makes the guards these tests
/// pin the difference between a window that re-lays out eight times a second
/// and one that does so when something moved.
///
/// The assertions are about *observation*, not about values, because a value
/// test cannot tell a republished value from a kept one. `withObservationTracking`
/// can: its `onChange` fires on the write, whatever the value was.
@MainActor
@Suite("Board invalidation")
struct BoardInvalidationTests {
    /// A flag the `@Sendable` `onChange` closure may set.
    private final class Flag: @unchecked Sendable {
        var fired = false
    }

    private let instant = Date(timeIntervalSince1970: 1_767_225_600)

    private func session(
        _ id: String,
        harness: Harness = .claudeCode,
        cwd: String,
        title: String,
        tools: Int = 0,
        turns: Int = 1
    ) -> SessionSnapshot {
        var snapshot = SessionStateReducer.initialSnapshot(
            identity: SessionIdentity(
                key: SessionKey(harness: harness, sessionID: id),
                sourcePath: "/Users/example/store/\(id).jsonl",
                cwd: cwd,
                gitRoot: cwd,
                title: title
            )
        )
        snapshot.state = .thinking
        snapshot.isAlive = true
        snapshot.lastEventAt = instant
        snapshot.toolCallCount = tools
        snapshot.turnCount = turns
        return snapshot
    }

    private func frame(_ sessions: [SessionSnapshot]) -> BoardSnapshot {
        BoardSnapshot(generatedAt: instant, sessions: sessions)
    }

    private var sessions: [SessionSnapshot] {
        [
            session("1", cwd: "/Users/example/Code/auspex", title: "Build the board"),
            session("2", harness: .codex, cwd: "/Users/example/Code/auspex", title: "Adapters"),
            session("3", cwd: "/Users/example/Code/vendor", title: "Sync the vendor tree"),
        ]
    }

    /// Runs `body` while watching `read`, and says whether the property was
    /// written during it.
    ///
    /// Async because the write happens when the assembled frame comes back
    /// rather than when the frame was applied: `body` is expected to settle the
    /// model before it returns.
    private func invalidates(
        reading read: @escaping () -> Void,
        during body: () async -> Void
    ) async -> Bool {
        let flag = Flag()
        withObservationTracking(read) { flag.fired = true }
        await body()
        return flag.fired
    }

    /// Applies a frame and waits for the board to take it.
    private func applying(
        _ frame: BoardSnapshot,
        to model: LiveBoardModel
    ) -> () async -> Void {
        { model.apply(frame); await model.settle() }
    }

    @Test("A frame that changes nothing leaves the wall alone")
    func idempotentFrameDoesNotTouchTheWall() async {
        let model = LiveBoardModel()
        let sessions = sessions
        model.apply(frame(sessions))
        await model.settle()

        // Same sessions, new snapshot value: exactly what the registry
        // publishes when one session gained an event and the others did not.
        let again = applying(frame(sessions), to: model)
        #expect(await !invalidates(reading: { _ = model.rowGroups }, during: again))
        #expect(await !invalidates(reading: { _ = model.summary }, during: again))
        #expect(await !invalidates(reading: { _ = model.endedRows }, during: again))
        #expect(await !invalidates(reading: { _ = model.sessionCount }, during: again))
    }

    @Test("A frame carrying only a fresh instant leaves the board value alone")
    func idempotentFrameDoesNotRepublishTheBoard() async {
        let model = LiveBoardModel()
        let sessions = sessions
        model.apply(frame(sessions))
        await model.settle()

        // A new `BoardSnapshot` with a later `generatedAt` and the same
        // sessions: `==` can never be true between two of these, so the scene,
        // the crew wall, the Harnesses page and the menu bar's panel were all
        // invalidated by the instant alone, eight times a second.
        let later = BoardSnapshot(
            generatedAt: instant.addingTimeInterval(5),
            sessions: sessions
        )
        #expect(
            await !invalidates(
                reading: { _ = model.board },
                during: { model.apply(later); await model.settle() }
            )
        )
    }

    @Test("A fresh frame instant does not republish semantic catch-up state")
    func idempotentFrameDoesNotTouchCatchUp() async {
        let model = LiveBoardModel()
        let sessions = sessions
        model.apply(frame(sessions))
        await model.settle()

        let later = BoardSnapshot(
            generatedAt: instant.addingTimeInterval(5),
            sessions: sessions
        )
        #expect(
            await !invalidates(
                reading: {
                    _ = model.catchUp
                    _ = model.humanWorkQueue
                    _ = model.watchSignals
                },
                during: { model.apply(later); await model.settle() }
            )
        )
    }

    @Test("A frame that changes a session does re-lay its section out")
    func changedSessionTouchesTheWall() async {
        let model = LiveBoardModel()
        var sessions = sessions
        model.apply(frame(sessions))
        await model.settle()

        sessions[0].toolCallCount = 7
        #expect(
            await invalidates(
                reading: { _ = model.rowGroups },
                during: applying(frame(sessions), to: model)
            )
        )
    }

    @Test("A session arriving moves the counts the header and the sidebar read")
    func newSessionMovesTheCount() async {
        let model = LiveBoardModel()
        var sessions = sessions
        model.apply(frame(sessions))
        await model.settle()

        sessions.append(session("4", cwd: "/Users/example/Code/auspex", title: "Ledger"))
        #expect(
            await invalidates(
                reading: { _ = model.sessionCount },
                during: applying(frame(sessions), to: model)
            )
        )
        #expect(model.sessionCount == 4)
    }

    @Test("A frame that does not move the selected session leaves the trace pane alone")
    func idempotentFrameDoesNotTouchTheTracePane() async {
        let model = LiveBoardModel()
        let sessions = sessions
        model.apply(frame(sessions))
        await model.settle()
        model.selectedKey = sessions[0].key
        #expect(model.selectedSession?.key == sessions[0].key)
        #expect(model.selectedProjectName != nil)

        let again = applying(frame(sessions), to: model)
        #expect(await !invalidates(reading: { _ = model.selectedSession }, during: again))
        #expect(await !invalidates(reading: { _ = model.selectedChildren }, during: again))
        #expect(await !invalidates(reading: { _ = model.selectedProjectName }, during: again))
    }

    @Test("The selected session's own changes still reach the trace pane")
    func changedSelectionReachesTheTracePane() async {
        let model = LiveBoardModel()
        var sessions = sessions
        model.apply(frame(sessions))
        await model.settle()
        model.selectedKey = sessions[0].key

        sessions[0].turnCount = 9
        #expect(
            await invalidates(
                reading: { _ = model.selectedSession },
                during: applying(frame(sessions), to: model)
            )
        )
        #expect(model.selectedSession?.turnCount == 9)
    }

    @Test("Another session changing leaves the selected detail values alone")
    func unrelatedSessionDoesNotTouchTheTracePane() async {
        let model = LiveBoardModel()
        var sessions = sessions
        model.apply(frame(sessions))
        await model.settle()
        model.selectedKey = sessions[0].key

        sessions[1].toolCallCount = 9
        #expect(
            await !invalidates(
                reading: {
                    _ = model.selectedSession
                    _ = model.selectedParent
                    _ = model.selectedChildren
                    _ = model.selectedProjectName
                    _ = model.selectedProjectKey
                    _ = model.selectedUnit
                    _ = model.selectedAttention
                },
                during: applying(frame(sessions), to: model)
            )
        )
    }

    @Test("A frame that changes nothing leaves the sidebar's tree alone")
    func idempotentFrameDoesNotTouchTheTree() async {
        let projects = ProjectsModel()
        let sessions = sessions
        projects.adopt(tree: ProjectTree.build(board: frame(sessions)))
        #expect(projects.tree.projects.count == 2)

        #expect(
            await !invalidates(
                reading: { _ = projects.tree },
                during: { projects.adopt(tree: ProjectTree.build(board: self.frame(sessions))) }
            )
        )
    }

    @Test("A project gaining a session does reach the sidebar's tree")
    func newProjectReachesTheTree() async {
        let projects = ProjectsModel()
        var sessions = sessions
        projects.adopt(tree: ProjectTree.build(board: frame(sessions)))

        sessions.append(session("4", cwd: "/Users/example/Code/kit", title: "Kit"))
        let grown = sessions
        #expect(
            await invalidates(
                reading: { _ = projects.tree },
                during: { projects.adopt(tree: ProjectTree.build(board: self.frame(grown))) }
            )
        )
        #expect(projects.tree.projects.count == 3)
    }

    @Test("The tree the sidebar takes is the one the frame was assembled with")
    func treeArrivesWithTheFrame() async {
        let model = LiveBoardModel()
        let projects = ProjectsModel()
        model.onTree = { tree in projects.adopt(tree: tree) }
        model.apply(frame(sessions))
        await model.settle()

        #expect(projects.tree.projects.count == 2)
        #expect(projects.tree == ProjectTree.build(board: model.board))
    }
}
