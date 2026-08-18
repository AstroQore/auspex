import AgentSessionKit
import AgentSessionLive
import Foundation
import Testing

@testable import AuspexCore

@Suite("TraceEntry")
struct TraceEntryTests {
    /// Writes a script through the store and reads it back as trace rows.
    ///
    /// `StoredEvent` is only constructible from a database row, which is the
    /// right constraint — the trace renders what was persisted, not what was
    /// emitted — so the summariser is exercised over the real round trip
    /// rather than over hand-built rows that could drift from the schema.
    private func entries(
        _ events: [AgentEvent],
        key: SessionKey = Fixtures.key()
    ) throws -> [TraceEntry] {
        let store = try AuspexStore(inMemory: true)
        let repository = SessionRepository(store: store)
        try repository.upsert(snapshot: SessionStateReducer.initialSnapshot(
            identity: Fixtures.identity(key: key)
        ))
        try repository.insertEvents(events)
        return TraceEntry.entries(from: try repository.recentEvents(key: key, limit: 500))
    }

    // MARK: - Tool calls

    @Test("a start and its finish collapse into one row carrying the duration")
    func toolCallPairCollapsesWithDuration() throws {
        let key = Fixtures.key()
        let rows = try entries([
            Fixtures.event(
                .toolCallStarted(id: "c1", name: "Bash", kind: .shell, target: "swift build"),
                key: key, at: 10
            ),
            Fixtures.event(.toolCallFinished(id: "c1", isError: false), key: key, at: 13.5)
        ], key: key)

        #expect(rows.count == 1)
        #expect(rows[0].title == "Bash")
        #expect(rows[0].detail == "swift build")
        #expect(rows[0].glyph == .shell)
        #expect(rows[0].category == .tools)
        #expect(rows[0].duration == 3.5)
        #expect(rows[0].isError == false)
    }

    @Test("a failed call keeps its duration and is marked")
    func failedCallIsMarked() throws {
        let key = Fixtures.key()
        let rows = try entries([
            Fixtures.event(
                .toolCallStarted(id: "c1", name: "shell", kind: .shell, target: "swift test"),
                key: key, at: 0
            ),
            Fixtures.event(.toolCallFinished(id: "c1", isError: true), key: key, at: 2)
        ], key: key)

        #expect(rows.count == 1)
        #expect(rows[0].isError)
        #expect(rows[0].duration == 2)
    }

    @Test("an open call has no duration yet")
    func openCallHasNoDuration() throws {
        let key = Fixtures.key()
        let rows = try entries([
            Fixtures.event(
                .toolCallStarted(id: "c1", name: "Read", kind: .fileRead, target: "a.swift"),
                key: key, at: 0
            )
        ], key: key)

        #expect(rows.count == 1)
        #expect(rows[0].duration == nil)
    }

    @Test("a finish whose start fell outside the window still gets a row")
    func orphanedFinishKeepsItsRow() throws {
        let key = Fixtures.key()
        let rows = try entries([
            Fixtures.event(.toolCallFinished(id: "gone", isError: true), key: key, at: 4)
        ], key: key)

        #expect(rows.count == 1)
        #expect(rows[0].isError)
        #expect(rows[0].category == .tools)
    }

    @Test("interleaved calls pair by id, not by position")
    func interleavedCallsPairByID() throws {
        let key = Fixtures.key()
        let rows = try entries([
            Fixtures.event(.toolCallStarted(id: "outer", name: "Task", kind: .subagent, target: nil), key: key, at: 0),
            Fixtures.event(.toolCallStarted(id: "inner", name: "Grep", kind: .search, target: "x"), key: key, at: 1),
            Fixtures.event(.toolCallFinished(id: "inner", isError: false), key: key, at: 2),
            Fixtures.event(.toolCallFinished(id: "outer", isError: false), key: key, at: 9)
        ], key: key)

        #expect(rows.count == 2)
        #expect(rows[0].title == "Task")
        #expect(rows[0].duration == 9)
        #expect(rows[1].title == "Grep")
        #expect(rows[1].duration == 1)
    }

    // MARK: - Text folding

    @Test("a body that restates the preview above it becomes that row's full text")
    func adjacentBodyFoldsIntoItsPreview() throws {
        let key = Fixtures.key()
        let full = "Make the resizer stop snapping back when the window is narrow."
        let rows = try entries([
            Fixtures.event(.userPrompt(preview: "Make the resizer stop snapping back"), key: key, at: 0),
            Fixtures.event(.textBody(role: .user, text: full, toolCallID: nil), key: key, at: 0)
        ], key: key)

        #expect(rows.count == 1)
        #expect(rows[0].category == .prompts)
        #expect(rows[0].body == full)
        #expect(rows[0].isExpandable)
    }

    @Test("a body that belongs to nothing above it keeps its own row")
    func unmatchedBodyKeepsItsRow() throws {
        let key = Fixtures.key()
        let rows = try entries([
            Fixtures.event(.userPrompt(preview: "Something else entirely"), key: key, at: 0),
            Fixtures.event(.textBody(role: .assistant, text: "A separate answer.", toolCallID: nil), key: key, at: 1)
        ], key: key)

        #expect(rows.count == 2)
        #expect(rows[1].category == .text)
        #expect(rows[1].detail == "A separate answer.")
    }

    @Test("a tool result body is never folded into a prompt")
    func toolResultBodyIsNeverFolded() throws {
        let key = Fixtures.key()
        let rows = try entries([
            Fixtures.event(.userPrompt(preview: "run it"), key: key, at: 0),
            Fixtures.event(.textBody(role: .toolResult, text: "run it and here is the output", toolCallID: "c1"), key: key, at: 1)
        ], key: key)

        #expect(rows.count == 2)
        #expect(rows[1].category == .tools)
    }

    // MARK: - Turns

    @Test("turnStarted opens a turn and every row after it carries the number")
    func turnStartedNumbersFollowingRows() throws {
        let key = Fixtures.key()
        let rows = try entries([
            Fixtures.event(.sessionStarted(identity: Fixtures.identity(key: key)), key: key, at: 0),
            Fixtures.event(.turnStarted, key: key, at: 1),
            Fixtures.event(.thinking, key: key, at: 2),
            Fixtures.event(.turnEnded(reason: .complete), key: key, at: 3),
            Fixtures.event(.turnStarted, key: key, at: 4),
            Fixtures.event(.thinking, key: key, at: 5)
        ], key: key)

        #expect(rows.map(\.turnIndex) == [0, 1, 1, 1, 2, 2])
    }

    @Test("a prompt with no turn open opens one, for harnesses that record no boundary")
    func promptOpensATurnWhenNoneIsOpen() throws {
        let key = Fixtures.key()
        let rows = try entries([
            Fixtures.event(.userPrompt(preview: "first"), key: key, at: 0),
            Fixtures.event(.turnEnded(reason: .complete), key: key, at: 1),
            Fixtures.event(.userPrompt(preview: "second"), key: key, at: 2)
        ], key: key)

        #expect(rows.map(\.turnIndex) == [1, 1, 2])
    }

    // MARK: - Categories

    @Test("every event kind lands in a category, and the important ones land where expected")
    func categoriesAreAssignedAsExpected() throws {
        let key = Fixtures.key()
        let child = SessionKey(harness: .claudeCode, sessionID: "child")
        let rows = try entries([
            Fixtures.event(.sessionStarted(identity: Fixtures.identity(key: key)), key: key, at: 0),
            Fixtures.event(.userPrompt(preview: "go"), key: key, at: 1),
            Fixtures.event(.assistantText(preview: "sure"), key: key, at: 2),
            Fixtures.event(.permissionRequested(id: "p1", tool: "Bash"), key: key, at: 3),
            Fixtures.event(.permissionResolved(id: "p1", allowed: false), key: key, at: 4),
            Fixtures.event(.subagentStarted(child: child, agentType: "explore", toolUseID: "t1"), key: key, at: 5),
            Fixtures.event(.usage(model: "m", inputTokens: 10, outputTokens: 2, cachedTokens: 0), key: key, at: 6),
            Fixtures.event(.sessionEnded(reason: .exited), key: key, at: 7)
        ], key: key)

        #expect(rows.map(\.category) == [
            .lifecycle, .prompts, .text, .tools, .tools, .lifecycle, .usage, .lifecycle
        ])
        // A denied permission is an error even though nothing crashed: the
        // agent asked and was told no, which is what the row has to convey.
        #expect(rows[4].isError)
        #expect(rows[4].title == "Permission denied")
        #expect(rows[5].title == "Subagent · explore")
    }

    @Test("every row has a payload to expand and a non-empty title")
    func everyRowIsWellFormed() throws {
        let key = Fixtures.key()
        let rows = try entries(Fixtures.oneTurnScript(key: key), key: key)

        #expect(!rows.isEmpty)
        for row in rows {
            #expect(!row.title.isEmpty)
            #expect(row.detailJSON != nil)
        }
    }

    @Test("a whole scripted turn reads as the sequence a person would expect")
    func oneTurnScriptReadsInOrder() throws {
        let key = Fixtures.key()
        let rows = try entries(Fixtures.oneTurnScript(key: key), key: key)

        #expect(rows.map(\.title) == [
            "Session started", "Prompt", "Bash", "Turn ended", "Session ended"
        ])
        // The prompt's body folded in; the tool call paired.
        #expect(rows[1].body == "Make the resizer stop snapping back")
        #expect(rows[2].duration == 1)
    }
}

@Suite("Formatting")
struct FormattingTests {
    @Test("token counts stay short at every magnitude")
    func tokenCountsAreCompact() {
        #expect(TokenFormat.compact(0) == "0")
        #expect(TokenFormat.compact(843) == "843")
        #expect(TokenFormat.compact(1_200) == "1.2k")
        #expect(TokenFormat.compact(12_400) == "12k")
        #expect(TokenFormat.compact(1_260_000) == "1.3M")
        #expect(TokenFormat.compact(24_000_000) == "24M")
        for value in [0, 1, 999, 1_000, 99_999, 1_000_000, 12_345_678] {
            #expect(TokenFormat.compact(value).count <= 5, "\(value) formatted too wide")
        }
    }

    @Test("short durations gain precision as they get shorter")
    func shortDurationsScale() {
        #expect(DurationFormat.short(0.42) == "0.4s")
        #expect(DurationFormat.short(12.1) == "12s")
        #expect(DurationFormat.short(187) == "3m 07s")
        #expect(DurationFormat.short(3_845) == "1h 04m")
        #expect(DurationFormat.short(-5) == "0.0s")
    }

    @Test("the stopwatch keeps a fixed width until it needs hours")
    func clockIsFixedWidth() {
        #expect(DurationFormat.clock(0) == "00:00")
        #expect(DurationFormat.clock(42) == "00:42")
        #expect(DurationFormat.clock(433) == "07:13")
        #expect(DurationFormat.clock(3_862) == "1:04:22")
    }
}
