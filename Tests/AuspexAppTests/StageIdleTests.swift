import AgentSessionKit
import AgentSessionLive
import AuspexCore
import Foundation
import Testing

@testable import AuspexApp

/// Now's stage folding: what the board model does when it folds, what the
/// countdown listens to, and the words the strip prints.
///
/// The rules themselves are ``StageIdleCollapse``'s and are tested in Core;
/// this is the clock and the wiring around them.
@MainActor
@Suite("Stage idle collapse")
struct StageIdleTests {
    init() { pinEnglishInterface() }

    private func model() async -> LiveBoardModel {
        let model = LiveBoardModel()
        model.apply(frame(sessions(["1", "2", "3"])))
        await model.settle()
        await model.settle()
        return model
    }

    private func sessions(_ ids: [String], at seconds: TimeInterval = 0) -> [SessionSnapshot] {
        ids.map { id in
            var snapshot = SessionStateReducer.initialSnapshot(
                identity: SessionIdentity(
                    key: SessionKey(harness: .claudeCode, sessionID: id),
                    sourcePath: "/Users/example/store/\(id).jsonl",
                    cwd: "/Users/example/Code/auspex",
                    gitRoot: "/Users/example/Code/auspex",
                    title: "Session \(id)"
                )
            )
            snapshot.state = .thinking
            snapshot.isAlive = true
            snapshot.lastEventAt = Date(timeIntervalSince1970: 1_767_225_600 + seconds)
            return snapshot
        }
    }

    private func frame(_ sessions: [SessionSnapshot], at seconds: TimeInterval = 0) -> BoardSnapshot {
        BoardSnapshot(
            generatedAt: Date(timeIntervalSince1970: 1_767_225_600 + seconds), sessions: sessions
        )
    }

    /// Stands in for a probe in a visible window.
    private let window = ObjectIdentifier(NSObject())

    @Test("folded, the office leaves the frames but its last board is kept for the open")
    func foldingDropsTheOfficeFromTheFrames() async {
        let model = await model()
        #expect(model.isStageOpen)
        #expect(!model.sceneBoard.sessions.isEmpty)

        model.collapseStage()
        #expect(model.isStageCollapsed)
        #expect(model.stageIdle.isManual)
        #expect(!model.isStageOpen)
        await model.settle()
        // A new session arrives while folded: the lists see it, the office's
        // board is neither rebuilt nor emptied.
        model.apply(frame(sessions(["1", "2", "3", "4"]), at: 5))
        await model.settle()
        #expect(model.nowFrame.working.count == 4)
        #expect(model.sceneBoard.sessions.count == 3)

        model.openStage()
        #expect(!model.isStageCollapsed)
        await model.settle()
        #expect(model.sceneBoard.sessions.count == 4)
    }

    @Test("switching the office back on opens a stage that was folded when it went off")
    func listsOnlyAndBackOpensTheStage() async {
        let model = await model()
        model.collapseStage()
        model.showsStage = false
        #expect(model.sceneBoard.sessions.isEmpty)
        // Two clicks, so two frames: one for the lists alone, one for the
        // office back.
        await model.settle()
        model.showsStage = true
        #expect(!model.isStageCollapsed)
        await model.settle()
        #expect(!model.sceneBoard.sessions.isEmpty)
    }

    @Test("board frames do not move the countdown; input does")
    func dataUpdatesDoNotResetTheCountdown() async {
        let model = await model()
        let idle = model.stageIdle
        // Nobody is looking yet, so there is nothing to count down.
        #expect(idle.deadline == nil)
        #expect(!idle.isArmed)

        idle.report(window, isWatching: true)
        let deadline = idle.deadline
        #expect(deadline != nil)
        #expect(idle.isArmed)

        for step in 1...4 {
            let ids = (1...(3 + step)).map(String.init)
            model.apply(frame(sessions(ids, at: Double(step)), at: Double(step)))
            await model.settle()
        }
        #expect(model.nowFrame.working.count == 7)
        #expect(idle.deadline == deadline)

        try? await Task.sleep(for: .milliseconds(5))
        idle.noteActivity()
        #expect(idle.deadline.map { $0 > deadline! } == true)

        idle.report(window, isWatching: false)
        #expect(idle.deadline == nil)
        #expect(!idle.isArmed)
    }

    @Test("the armed timer folds a watched stage on its own")
    func theTimerFolds() async {
        let model = await model()
        model.stageIdle.delay = .milliseconds(100)
        model.stageIdle.report(window, isWatching: true)
        #expect(model.stageIdle.isArmed)

        // The timer has a second of tolerance; give it three.
        let until = ContinuousClock.now.advanced(by: .seconds(3))
        while !model.isStageCollapsed, ContinuousClock.now < until {
            try? await Task.sleep(for: .milliseconds(20))
        }
        #expect(model.isStageCollapsed)
        #expect(!model.stageIdle.isManual)
        // Folded: no timer left behind.
        #expect(!model.stageIdle.isArmed)

        model.openStage()
        #expect(!model.isStageCollapsed)
        #expect(model.stageIdle.isArmed)
        model.stageIdle.report(window, isWatching: false)
    }

    @Test("folded, input in the window does not open the stage")
    func inputDoesNotOpenAFoldedStage() async {
        let model = await model()
        model.stageIdle.report(window, isWatching: true)
        model.collapseStage()
        model.stageIdle.noteActivity()
        #expect(model.isStageCollapsed)
        #expect(!model.stageIdle.isArmed)
        model.stageIdle.report(window, isWatching: false)
    }

    @Test("the strip says how many are working, and how many need you only when any do")
    func stripCopy() {
        #expect(NowCopy.collapsedSummary(working: 3, needsYou: 0) == "Office · 3 working ▸")
        #expect(NowCopy.collapsedSummary(working: 1, needsYou: 1) == "Office · 1 working · 1 needs you ▸")
        #expect(NowCopy.collapsedSummary(working: 0, needsYou: 2) == "Office · 0 working · 2 need you ▸")
        #expect(NowCopy.collapsedA11y(working: 2, needsYou: 0) == "Office, folded: 2 sessions working, 0 need you")
        #expect(NowCopy.expandStage == "Show the office")
    }
}

/// The demo's shortened countdown.
@Suite("Stage idle launch option")
struct StageIdleLaunchOptionTests {
    @Test("a demo reads AUSPEX_STAGE_IDLE_DELAY, in seconds")
    func demoReadsTheDelay() {
        let options = AppLaunchOptions.current(
            arguments: ["Auspex"],
            environment: ["AUSPEX_DEMO": "1", "AUSPEX_STAGE_IDLE_DELAY": "5"]
        )
        #expect(options.stageIdleDelay == .seconds(5))
        #expect(AppLaunchOptions.current(
            arguments: ["Auspex", "--demo"], environment: ["AUSPEX_STAGE_IDLE_DELAY": "later"]
        ).stageIdleDelay == nil)
    }

    @Test("a live launch ignores it")
    func liveIgnoresTheDelay() {
        let options = AppLaunchOptions.current(
            arguments: ["Auspex"], environment: ["AUSPEX_STAGE_IDLE_DELAY": "5"]
        )
        #expect(!options.isDemo)
        #expect(options.stageIdleDelay == nil)
    }
}
