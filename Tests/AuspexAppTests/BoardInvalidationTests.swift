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
    private func invalidates(
        reading read: @escaping () -> Void,
        during body: () -> Void
    ) -> Bool {
        let flag = Flag()
        withObservationTracking(read) { flag.fired = true }
        body()
        return flag.fired
    }

    @Test("A frame that changes nothing leaves the wall alone")
    func idempotentFrameDoesNotTouchTheWall() {
        let model = LiveBoardModel()
        let sessions = sessions
        model.apply(frame(sessions))

        // Same sessions, new snapshot value: exactly what the registry
        // publishes when one session gained an event and the others did not.
        #expect(
            !invalidates(reading: { _ = model.rowGroups }, during: { model.apply(frame(sessions)) })
        )
        #expect(
            !invalidates(reading: { _ = model.summary }, during: { model.apply(frame(sessions)) })
        )
        #expect(
            !invalidates(
                reading: { _ = model.endedRows },
                during: { model.apply(frame(sessions)) }
            )
        )
        #expect(
            !invalidates(
                reading: { _ = model.sessionCount },
                during: { model.apply(frame(sessions)) }
            )
        )
    }

    @Test("A frame that changes a session does re-lay its section out")
    func changedSessionTouchesTheWall() {
        let model = LiveBoardModel()
        var sessions = sessions
        model.apply(frame(sessions))

        sessions[0].toolCallCount = 7
        #expect(
            invalidates(reading: { _ = model.rowGroups }, during: { model.apply(frame(sessions)) })
        )
    }

    @Test("A session arriving moves the counts the header and the sidebar read")
    func newSessionMovesTheCount() {
        let model = LiveBoardModel()
        var sessions = sessions
        model.apply(frame(sessions))

        sessions.append(session("4", cwd: "/Users/example/Code/auspex", title: "Ledger"))
        #expect(
            invalidates(
                reading: { _ = model.sessionCount },
                during: { model.apply(frame(sessions)) }
            )
        )
        #expect(model.sessionCount == 4)
    }

    @Test("A frame that does not move the selected session leaves the trace pane alone")
    func idempotentFrameDoesNotTouchTheTracePane() {
        let model = LiveBoardModel()
        let sessions = sessions
        model.apply(frame(sessions))
        model.selectedKey = sessions[0].key
        #expect(model.selectedSession?.key == sessions[0].key)
        #expect(model.selectedProjectName != nil)

        #expect(
            !invalidates(
                reading: { _ = model.selectedSession },
                during: { model.apply(frame(sessions)) }
            )
        )
        #expect(
            !invalidates(
                reading: { _ = model.selectedChildren },
                during: { model.apply(frame(sessions)) }
            )
        )
        #expect(
            !invalidates(
                reading: { _ = model.selectedProjectName },
                during: { model.apply(frame(sessions)) }
            )
        )
    }

    @Test("The selected session's own changes still reach the trace pane")
    func changedSelectionReachesTheTracePane() {
        let model = LiveBoardModel()
        var sessions = sessions
        model.apply(frame(sessions))
        model.selectedKey = sessions[0].key

        sessions[0].turnCount = 9
        #expect(
            invalidates(
                reading: { _ = model.selectedSession },
                during: { model.apply(frame(sessions)) }
            )
        )
        #expect(model.selectedSession?.turnCount == 9)
    }

    @Test("A frame that changes nothing leaves the sidebar's tree alone")
    func idempotentFrameDoesNotTouchTheTree() {
        let projects = ProjectsModel()
        let sessions = sessions
        projects.rebuild(board: frame(sessions))
        #expect(projects.tree.projects.count == 2)

        #expect(
            !invalidates(
                reading: { _ = projects.tree },
                during: { projects.rebuild(board: frame(sessions)) }
            )
        )
    }

    @Test("A project gaining a session does reach the sidebar's tree")
    func newProjectReachesTheTree() {
        let projects = ProjectsModel()
        var sessions = sessions
        projects.rebuild(board: frame(sessions))

        sessions.append(session("4", cwd: "/Users/example/Code/kit", title: "Kit"))
        #expect(
            invalidates(
                reading: { _ = projects.tree },
                during: { projects.rebuild(board: frame(sessions)) }
            )
        )
        #expect(projects.tree.projects.count == 3)
    }
}
