import AgentSessionKit
import AgentSessionLive
import AppKit
import AuspexCore
import Foundation
import SwiftUI
import Testing

@testable import AuspexApp

/// What keeps Now's lists alive: stopwatches that tick on their own leaf,
/// a dot that breathes in Core Animation, and neither while nobody looks.
@MainActor
@Suite("Now liveness", .serialized)
struct NowLivenessTests {
    private static let since = Date(timeIntervalSince1970: 1_767_225_600)

    @Test("A live stopwatch ticks while its reading has seconds in it, and then leaves it to the board clock")
    func ticksOnlyWhileSecondsShow() {
        #expect(NowLiveElapsed.ticksEverySecond(elapsed: 0))
        #expect(NowLiveElapsed.ticksEverySecond(elapsed: 599))
        #expect(!NowLiveElapsed.ticksEverySecond(elapsed: 600))
        // Exactly where the reading stops showing seconds.
        #expect(NowFrame.compactDuration(599) == "9m59s")
        #expect(NowFrame.compactDuration(600) == "10m")
    }

    @Test("One timer for every live stopwatch, and none when no label wants it")
    func oneSharedTimer() {
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 200, height: 40),
            styleMask: [.borderless], backing: .buffered, defer: true
        )
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let labels = (0..<3).map { _ in NowLiveLabel() }
        for label in labels { window.contentView?.addSubview(label) }
        #expect(!NowSecondTicker.shared.isRunning)
        for label in labels {
            label.configure(since: Date().addingTimeInterval(-30), suffix: "", color: .white, now: Date(), ticks: true)
        }
        #expect(NowSecondTicker.shared.isRunning)
        // A label past ten minutes, or one asked not to tick, does not hold
        // the timer.
        labels[0].configure(since: Date().addingTimeInterval(-3_600), suffix: "", color: .white, now: Date(), ticks: true)
        labels[1].configure(since: Date().addingTimeInterval(-30), suffix: "", color: .white, now: Date(), ticks: false)
        #expect(NowSecondTicker.shared.isRunning)
        labels[2].configure(since: Date().addingTimeInterval(-30), suffix: "", color: .white, now: Date(), ticks: false)
        #expect(!NowSecondTicker.shared.isRunning)
    }

    @Test("A working row's dot breathes only while the window can be seen")
    func dotBreathesWhileVisible() {
        let dot = NowBreathingDot.DotView()
        dot.configure(color: .white, breathes: true)
        #expect(dot.isBreathing)
        dot.configure(color: .white, breathes: false)
        #expect(!dot.isBreathing)
    }

    @Test("The stopwatch's tick sets the stopwatch's words and does not re-evaluate the row")
    func tickStaysInTheLeaf() async throws {
        let (ticks, rows) = try await Self.evaluations(visible: true, seconds: 3.5)
        #expect(ticks >= 2, "the stopwatch should have ticked; it was evaluated \(ticks) more times")
        #expect(rows == 0, "the row was evaluated \(rows) more times while only its stopwatch moved")
    }

    @Test("Nothing ticks while the window cannot be seen")
    func nothingTicksUnseen() async throws {
        let (ticks, rows) = try await Self.evaluations(visible: false, seconds: 1.6)
        #expect(ticks == 0)
        #expect(rows == 0)
    }

    /// Hosts one working row and counts how often it, and its stopwatch, are
    /// evaluated after the first draw over `seconds` of the run loop.
    private static func evaluations(visible: Bool, seconds: TimeInterval) async throws -> (ticks: Int, rows: Int) {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let session = SessionSnapshot(
            identity: SessionIdentity(
                key: SessionKey(harness: .claudeCode, sessionID: "ticking"),
                sourcePath: "/Users/example/.claude/projects/demo/ticking.jsonl",
                cwd: "/Users/example/Code/atlas",
                gitRoot: "/Users/example/Code/atlas"
            ),
            state: .thinking,
            isAlive: true
        )
        let board = BoardSnapshot(generatedAt: Date(), sessions: [session])
        let row = BoardRowBuilder(board: board, now: board.generatedAt).row(for: session)
        let item = NowFrame.Item(
            id: "working:ticking",
            tone: .working,
            reason: .working,
            row: row,
            activity: NowFrame.Activity(row: row),
            since: Date().addingTimeInterval(-30),
            unitID: "implicit:ticking",
            unitTitle: "Ticking"
        )
        let view = NowWorkingRow(item: item, isSelected: false, columns: NowColumns(width: 1_200))
            .environment(\.nowIsVisible, visible)
            .environment(BoardClock())
            .frame(width: 1_000, height: 48)
        NowBodyCounter.reset()
        NowBodyCounter.isEnabled = true
        let host = NSHostingView(rootView: view)
        host.frame = CGRect(x: 0, y: 0, width: 1_000, height: 48)
        let window = NSWindow(
            contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.contentView = host
        window.isReleasedWhenClosed = false
        defer {
            NowBodyCounter.isEnabled = false
            window.close()
        }
        host.layoutSubtreeIfNeeded()
        host.display()
        let rowsAtFirstDraw = NowBodyCounter.counts[.row, default: 0]
        let ticksAtFirstDraw = NowBodyCounter.counts[.stopwatch, default: 0]
        #expect(rowsAtFirstDraw >= 1)

        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            try await Task.sleep(for: .milliseconds(50))
            host.layoutSubtreeIfNeeded()
        }
        let ticks = NowBodyCounter.counts[.stopwatch, default: 0] - ticksAtFirstDraw
        let rows = NowBodyCounter.counts[.row, default: 0] - rowsAtFirstDraw
        return (ticks, rows)
    }
}
