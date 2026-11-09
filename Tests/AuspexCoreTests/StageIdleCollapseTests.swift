import Testing

@testable import AuspexCore

@Suite("StageIdleCollapse")
struct StageIdleCollapseTests {
    /// An arbitrary origin. Nothing here waits: every event says when it
    /// happened.
    private let t0 = ContinuousClock.now

    private func at(_ seconds: Int) -> ContinuousClock.Instant {
        t0.advanced(by: .seconds(seconds))
    }

    /// `handle(_:at:)` is mutating, which `#expect` cannot evaluate inline.
    private func changed(
        _ stage: inout StageIdleCollapse,
        _ event: StageIdleCollapse.Event,
        at instant: ContinuousClock.Instant
    ) -> Bool {
        stage.handle(event, at: instant)
    }

    @Test("the stage opens expanded, counting down two and a half minutes")
    func opensExpanded() {
        #expect(StageIdleCollapse.delay == .seconds(150))
        let stage = StageIdleCollapse(now: t0)
        #expect(stage.presentation == .expanded)
        #expect(!stage.isCollapsed)
        #expect(!stage.isManual)
        #expect(stage.deadline == at(150))
    }

    @Test("with no input, the timer folds the stage at the deadline and not before")
    func foldsWhenIdle() {
        var stage = StageIdleCollapse(now: t0)
        // Early — a timer that woke ahead of its tolerance — is not idle yet.
        #expect(!changed(&stage, .timerFired, at: at(149)))
        #expect(stage.presentation == .expanded)

        #expect(changed(&stage, .timerFired, at: at(150)))
        #expect(stage.presentation == .collapsed)
        #expect(!stage.isManual)
        // Folded: no countdown, so the app holds no timer.
        #expect(stage.deadline == nil)
    }

    @Test("every input moves the deadline, and a timer armed before it is stale")
    func inputRestartsTheCountdown() {
        var stage = StageIdleCollapse(now: t0)
        stage.handle(.userActivity, at: at(100))
        #expect(stage.deadline == at(250))

        // The timer the app armed for the old deadline goes off: nothing
        // folds, and the deadline it should re-arm for is the new one.
        #expect(!changed(&stage, .timerFired, at: at(150)))
        #expect(stage.presentation == .expanded)
        #expect(stage.deadline == at(250))

        #expect(changed(&stage, .timerFired, at: at(250)))
        #expect(stage.isCollapsed)
    }

    @Test("only input resets the countdown — board frames and stray wakes do not")
    func dataDoesNotResetTheCountdown() {
        // A busy board wakes the app constantly. None of those wakes is an
        // event here; the only thing a wake can deliver is a timer firing,
        // and a timer that fires early must leave the deadline where it was.
        var stage = StageIdleCollapse(now: t0)
        for second in stride(from: 5, to: 150, by: 5) {
            stage.handle(.timerFired, at: at(second))
            #expect(stage.deadline == at(150))
        }
        #expect(changed(&stage, .timerFired, at: at(150)))
        #expect(stage.isCollapsed)
    }

    @Test("the chevron folds by hand, and nothing but the strip opens it again")
    func manualCollapseHoldsUntilTheStrip() {
        var stage = StageIdleCollapse(now: t0)
        #expect(changed(&stage, .manualToggle, at: at(10)))
        #expect(stage.presentation == .collapsed)
        #expect(stage.isManual)
        #expect(stage.deadline == nil)

        // Input, a late timer and the window coming and going all leave it
        // folded.
        stage.handle(.userActivity, at: at(20))
        stage.handle(.timerFired, at: at(400))
        stage.handle(.visibility(false), at: at(500))
        stage.handle(.visibility(true), at: at(600))
        #expect(stage.presentation == .collapsed)
        #expect(stage.isManual)

        #expect(changed(&stage, .tapStrip, at: at(700)))
        #expect(stage.presentation == .expanded)
        #expect(!stage.isManual)
        #expect(stage.deadline == at(850))
    }

    @Test("folded by the timer, one click on the strip opens it — and idling folds it again")
    func automaticCollapseReopensAndRefolds() {
        var stage = StageIdleCollapse(now: t0)
        stage.handle(.timerFired, at: at(150))
        #expect(stage.isCollapsed && !stage.isManual)

        // Scrolling the lists is not a request for the office.
        stage.handle(.userActivity, at: at(160))
        #expect(stage.isCollapsed)

        #expect(changed(&stage, .tapStrip, at: at(200)))
        #expect(stage.presentation == .expanded)
        #expect(stage.deadline == at(350))

        #expect(changed(&stage, .timerFired, at: at(350)))
        #expect(stage.isCollapsed)
        #expect(!stage.isManual)
    }

    @Test("opened by hand, the stage counts down like any other open stage")
    func manualExpandStartsTheCountdown() {
        var stage = StageIdleCollapse(now: t0)
        stage.handle(.manualToggle, at: at(5))
        #expect(changed(&stage, .manualToggle, at: at(30)))
        #expect(stage.presentation == .expanded)
        #expect(!stage.isManual)
        #expect(stage.deadline == at(180))

        #expect(changed(&stage, .timerFired, at: at(180)))
        #expect(stage.isCollapsed)
        #expect(!stage.isManual)
    }

    @Test("a click on the open stage is input, not a toggle")
    func tapOnAnOpenStageIsInput() {
        var stage = StageIdleCollapse(now: t0)
        #expect(!changed(&stage, .tapStrip, at: at(40)))
        #expect(stage.presentation == .expanded)
        #expect(stage.deadline == at(190))
    }

    @Test("nothing counts while the stage cannot be seen, and it starts over when it can")
    func visibilityPausesTheCountdown() {
        var stage = StageIdleCollapse(now: t0, isWatched: false)
        #expect(stage.deadline == nil)
        // A timer from before the window was covered finds nobody watching.
        #expect(!changed(&stage, .timerFired, at: at(1_000)))
        #expect(stage.presentation == .expanded)

        stage.handle(.visibility(true), at: at(1_000))
        #expect(stage.deadline == at(1_150))

        stage.handle(.visibility(false), at: at(1_100))
        #expect(stage.deadline == nil)
        #expect(!changed(&stage, .timerFired, at: at(1_150)))

        // Back on screen: the full delay, not the fifty seconds that were left.
        stage.handle(.visibility(true), at: at(2_000))
        #expect(stage.deadline == at(2_150))
        // A repeat of the same answer is not a fresh start.
        stage.handle(.visibility(true), at: at(2_100))
        #expect(stage.deadline == at(2_150))
    }

    @Test("input never moves the deadline backwards")
    func lateInputDoesNotRewind() {
        var stage = StageIdleCollapse(now: t0)
        stage.handle(.userActivity, at: at(100))
        // Delivered out of order — an event timestamped before the last one.
        stage.handle(.userActivity, at: at(50))
        #expect(stage.deadline == at(250))
    }

    @Test("a demo's delay is read in seconds, within a floor and a ceiling")
    func delayOverride() {
        #expect(StageIdleCollapse.delay(seconds: "5") == .seconds(5))
        #expect(StageIdleCollapse.delay(seconds: " 2.5 ") == .milliseconds(2_500))
        #expect(StageIdleCollapse.delay(seconds: "0.1") == .seconds(1))
        #expect(StageIdleCollapse.delay(seconds: "100000") == .seconds(3_600))
        #expect(StageIdleCollapse.delay(seconds: "0") == nil)
        #expect(StageIdleCollapse.delay(seconds: "-3") == nil)
        #expect(StageIdleCollapse.delay(seconds: "soon") == nil)
        #expect(StageIdleCollapse.delay(seconds: "inf") == nil)
        #expect(StageIdleCollapse.delay(seconds: nil) == nil)

        var stage = StageIdleCollapse(delay: .seconds(5), now: t0)
        #expect(stage.deadline == at(5))
        #expect(changed(&stage, .timerFired, at: at(5)))
    }
}
