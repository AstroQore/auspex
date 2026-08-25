import AgentSessionKit
import AgentSessionLive
import AuspexCore
import Foundation
import Testing

@testable import AuspexApp

/// What the window is allowed to cost when the machine is busy.
///
/// The bug these pin is one bug with three faces: a window whose main thread
/// never gets back to `mach_msg`. Every rule here is a bound on *how much* the
/// window can be asked to do per frame, and each one is a number somebody could
/// otherwise raise by accident — the sidebar's cap, the trace's window, the
/// spacing between applied frames. A test that only checked they were correct
/// would pass with all three set to infinity.
@MainActor
@Suite("Window cost")
struct WindowCostTests {
    // MARK: - The scroll viewport

    @Test("Roost scrolling has no custom placement or lazy-prefetch feedback path")
    func roostScrollHasNoFeedbackLayout() throws {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let gate = try String(
            contentsOf: repository.appendingPathComponent(
                "Sources/AuspexApp/Window/ScrollSizeGate.swift"
            ),
            encoding: .utf8
        )
        let roost = try String(
            contentsOf: repository.appendingPathComponent(
                "Sources/AuspexApp/Tasks/TasksPageView.swift"
            ),
            encoding: .utf8
        )

        // The first real freeze included this path:
        // custom Layout.placeSubviews -> ScrollView sizing -> lazy prefetch ->
        // NSHostingView.requestUpdate -> another transaction. Replacing only
        // the custom layout proved insufficient: two real Roost scrolls still
        // reproduced the cycle inside LazyLayoutViewCache. Both links stay
        // absent, because either one makes the window capable of self-exciting.
        #expect(gate.contains("GeometryReader"))
        #expect(!gate.contains("struct ProposalOnlyLayout"))
        #expect(!gate.contains("func placeSubviews("))
        #expect(!roost.contains("LazyVStack("))
    }

    // MARK: - The sidebar's fold

    @Test("a short branch is drawn whole and says nothing")
    func shortBranchIsWhole() {
        let fold = SidebarFold.make(rows: 3, finished: 0, isOpen: false)
        #expect(fold.shown == 3)
        #expect(fold.capped == 0)
        #expect(!fold.needsRow)
    }

    @Test("a long branch is cut at the limit and offers the rest")
    func longBranchIsCut() {
        let fold = SidebarFold.make(rows: 19, finished: 0, isOpen: false)
        #expect(fold.shown == ProjectTree.listLimit)
        #expect(fold.capped == 19 - ProjectTree.listLimit)
        #expect(fold.needsRow)
        #expect(MoreRow.title(fold) == "+\(19 - ProjectTree.listLimit) more")
    }

    @Test("opening a branch draws all of it, and offers the way back")
    func openBranchIsWhole() {
        let fold = SidebarFold.make(rows: 19, finished: 0, isOpen: true)
        #expect(fold.shown == 19)
        #expect(fold.capped == 0)
        #expect(fold.isOpen)
        // The row is still drawn, and that is the point: nothing is missing
        // from an opened branch, but the way back has to be somewhere.
        #expect(fold.needsRow)
        #expect(MoreRow.title(fold) == "Show fewer")
    }

    @Test("finished sessions are reported and never listed, however many there are")
    func finishedSessionsAreOnlyReported() {
        let fold = SidebarFold.make(rows: 2, finished: 40, isOpen: false)
        #expect(fold.shown == 2)
        #expect(fold.capped == 0)
        #expect(fold.needsRow)
        #expect(MoreRow.title(fold) == "40 finished")
        #expect(MoreRow.help(fold).contains("Ended section"))

        // Opening the branch does not bring them back: they are on the board.
        let opened = SidebarFold.make(rows: 2, finished: 40, isOpen: true)
        #expect(opened.shown == 2)
    }

    @Test("both at once read as one row")
    func cappedAndFinishedShareARow() {
        let fold = SidebarFold.make(rows: 20, finished: 5, isOpen: false)
        #expect(MoreRow.title(fold) == "+\(20 - ProjectTree.listLimit) more · 5 finished")
    }

    // MARK: - The trace's window

    @Test("a long trace draws its newest rows and says how many are above")
    func traceIsBoundedToItsTail() throws {
        let model = LiveBoardModel()
        let entries = try trace(rows: 1_500)
        model.adoptTrace(entries)

        #expect(entries.count == 1_500)
        #expect(model.traceItems.count == LiveBoardModel.traceVisibleWindow)
        #expect(model.traceHiddenCount == 1_500 - LiveBoardModel.traceVisibleWindow)
        // The tail, not the head: a trace is read from the bottom.
        #expect(model.traceItems.last == .row(entries[1_499]))
    }

    @Test("a trace shorter than the window is drawn whole")
    func shortTraceIsWhole() throws {
        let model = LiveBoardModel()
        model.adoptTrace(try trace(rows: 40))

        #expect(model.traceItems.count == 40)
        #expect(model.traceHiddenCount == 0)
    }

    @Test("asking for the whole of a long trace draws all of it")
    func theWholeTraceCanBeAskedFor() throws {
        let model = LiveBoardModel()
        model.adoptTrace(try trace(rows: 1_500))
        model.showsWholeTrace = true

        #expect(model.traceItems.count == 1_500)
        #expect(model.traceHiddenCount == 0)
    }

    @Test("selecting another session puts the fold back")
    func theFoldResetsWithTheSelection() throws {
        let model = LiveBoardModel()
        model.adoptTrace(try trace(rows: 1_500))
        model.showsWholeTrace = true
        #expect(model.traceItems.count == 1_500)

        // A decision about one transcript. Carrying it would put the next
        // session's four thousand rows on screen without anybody asking.
        model.selectedKey = SessionKey(harness: .codex, sessionID: "next")
        #expect(!model.showsWholeTrace)
    }

    // MARK: - How often a frame is applied

    @Test("small boards coalesce bursts at the half-second freshness budget")
    func smallBoardsCoalesceBursts() {
        #expect(LiveBoardModel.frameInterval(forSessions: 0) == .milliseconds(500))
        #expect(LiveBoardModel.frameInterval(forSessions: 12) == .milliseconds(500))
        #expect(LiveBoardModel.frameInterval(forSessions: 40) == .milliseconds(500))
    }

    @Test("a big board is paced, and never slower than half a second")
    func bigBoardsArePaced() {
        // The size the report was made at.
        #expect(LiveBoardModel.frameInterval(forSessions: 81) == .milliseconds(500))
        #expect(LiveBoardModel.frameInterval(forSessions: 170) == .milliseconds(500))
        // `AGENTS.md` 4.1: the board updates within half a second during a
        // burst. Whatever the size, the pacing may not break that.
        #expect(LiveBoardModel.frameInterval(forSessions: 10_000) == .milliseconds(500))
    }

    @Test("the curve never goes backwards")
    func pacingIsMonotonic() {
        var previous = LiveBoardModel.frameInterval(forSessions: 0)
        for sessions in stride(from: 0, through: 400, by: 7) {
            let interval = LiveBoardModel.frameInterval(forSessions: sessions)
            #expect(interval >= previous)
            previous = interval
        }
    }

    // MARK: - Fixtures

    /// `rows` trace rows, through the store the pane actually reads.
    ///
    /// `StoredEvent` is only constructible from a database row — the trace
    /// renders what was persisted rather than what was emitted — so a fixture
    /// that hand-built rows would be a fixture that could drift from the
    /// schema.
    private func trace(rows: Int) throws -> [TraceEntry] {
        let key = SessionKey(harness: .claudeCode, sessionID: "trace")
        let store = try AuspexStore(inMemory: true)
        let repository = SessionRepository(store: store)
        try repository.upsert(snapshot: SessionStateReducer.initialSnapshot(
            identity: SessionIdentity(
                key: key,
                sourcePath: "/Users/example/store/trace.jsonl"
            )
        ))
        let instant = Date(timeIntervalSince1970: 1_767_225_600)
        // One row each: a tool call that starts and finishes in the same event
        // would collapse two events into one row and make the count a guess.
        let events = (0..<rows).map { index in
            AgentEvent(
                session: key,
                timestamp: instant.addingTimeInterval(Double(index)),
                sequence: Int64(index),
                kind: .assistantText(preview: "line \(index)")
            )
        }
        _ = try repository.insertEvents(events)
        return TraceEntry.entries(
            from: try repository.recentEvents(key: key, limit: rows + 10)
        )
    }
}
