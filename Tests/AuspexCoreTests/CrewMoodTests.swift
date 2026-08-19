import AgentSessionKit
import AgentSessionLive
import AuspexCore
import Foundation
import Testing

/// The table that turns what Auspex knows into what the avatar draws.
///
/// Worth its own suite because it is the only place a new harness or a new
/// session state could pick up a silent default, and because the precedence
/// between "needs you", "stale" and a soft notification is a product decision
/// rather than something the engine knows about.
@Suite("Crew mood")
struct CrewMoodTests {
    // MARK: The shape table

    @Test("every harness has a silhouette, and vendors share one")
    func shapeTable() {
        let expected: [Harness: BloubShapeID] = [
            .claudeCode: .circle,
            .claudeCowork: .circle,
            .codex: .squircle,
            .chatgptWork: .squircle,
            .cursor: .triangle,
            .grokBuild: .pebble,
            .grokBot: .droplet,
            .antigravity: .cloud,
            .geminiCLI: .capsule
        ]
        for harness in Harness.allCases {
            #expect(CrewMoodMap.shape(for: harness) == expected[harness])
        }
    }

    /// Seven silhouettes over nine harnesses: the two pairs that share a vendor
    /// share a shape, and everything else is distinct. A board where two
    /// unrelated harnesses had the same outline would defeat the point of
    /// having outlines at all.
    @Test("only the two vendor pairs share a silhouette")
    func shapesAreDistinctAcrossVendors() {
        let shapes = Harness.allCases.map(CrewMoodMap.shape(for:))
        #expect(Set(shapes).count == 7)
        #expect(CrewMoodMap.shape(for: .claudeCode) == CrewMoodMap.shape(for: .claudeCowork))
        #expect(CrewMoodMap.shape(for: .codex) == CrewMoodMap.shape(for: .chatgptWork))
        #expect(CrewMoodMap.shape(for: .grokBuild) != CrewMoodMap.shape(for: .grokBot))
    }

    // MARK: The state table

    @Test("each session state maps to its measured animation")
    func stateTable() {
        let cases: [(SessionState, BloubStateID)] = [
            (.idle, .idle),
            (.thinking, .thinking),
            (.toolCalling(name: "Bash"), .orbit),
            (.writingFile(path: "/tmp/x.swift"), .play),
            (.delegating(children: 2), .wide),
            (.waitingPermission(tool: "Bash"), .alert),
            (.ended(reason: .exited), .sleep)
        ]
        for (state, expected) in cases {
            #expect(CrewMoodMap.avatarState(for: state).state == expected)
        }
    }

    /// Delegating is two beats: the act of spawning, then the waiting. Holding
    /// the burst instead would leave the avatar as a lone dot, which is what an
    /// ended session looks like.
    @Test("delegating bursts while it spawns and opens its eyes afterwards")
    func delegatingIsTwoBeats() {
        let spawning = CrewMoodMap.avatarState(for: .delegating(children: 1), isSpawning: true)
        #expect(spawning.state == .burst)
        let waiting = CrewMoodMap.avatarState(for: .delegating(children: 1), isSpawning: false)
        #expect(waiting.state == .wide)
        // and the second beat wears the harness's own body again
        #expect(BloubStates.state(.wide).usesBaseBody)
        #expect(!BloubStates.state(.burst).usesBaseBody)
    }

    @Test("a stale working session winks instead of showing its work")
    func staleWins() {
        for state: SessionState in [
            .thinking,
            .toolCalling(name: "Bash"),
            .writingFile(path: nil),
            .delegating(children: 1)
        ] {
            #expect(CrewMoodMap.avatarState(for: state, isStale: true).state == .wink)
        }
    }

    /// "Needs you" is the one state that will never resolve itself, so nothing
    /// softer is allowed to mask it — and a session that is over is over.
    @Test("needs-you and ended outrank stale and a pending notification")
    func precedence() {
        let blocked = CrewMoodMap.avatarState(
            for: .waitingPermission(tool: "Bash"),
            isStale: true,
            isNotifying: true
        )
        #expect(blocked.state == .alert)

        let over = CrewMoodMap.avatarState(
            for: .ended(reason: .exited),
            isStale: true,
            isNotifying: true
        )
        #expect(over.state == .sleep)
    }

    @Test("a soft notification only lands on an idle session")
    func notifyOnlyWhenIdle() {
        #expect(CrewMoodMap.avatarState(for: .idle, isNotifying: true).state == .notify)
        #expect(CrewMoodMap.avatarState(for: .thinking, isNotifying: true).state == .thinking)
    }

    /// Only the states whose animation is a one-shot are replayed. Replaying a
    /// state that already loops would put a seam in a loop that has none.
    @Test("only the one-shot states are replayed")
    func replayPolicy() {
        for state: BloubStateID in [.alert, .play, .orbit, .comet] {
            let period = CrewMoodMap.replayPeriod(for: state)
            #expect(period != nil)
            // never shorter than the state's own entry morph, or the replay
            // would land inside the previous one
            #expect((period ?? 0) > BloubStates.state(state).morph)
        }
        // `burst` is played once per act of spawning and then handed to `wide`,
        // so looping it would turn one event into a tic.
        for state: BloubStateID in [.idle, .thinking, .wink, .wide, .notify, .sleep, .burst] {
            #expect(CrewMoodMap.replayPeriod(for: state) == nil)
        }
    }

    // MARK: The driver

    @Test("a turn ending raises a soft notification, and it expires")
    func softNotify() {
        var driver = CrewAvatarDriver(harness: .claudeCode, state: .thinking, at: 0)
        #expect(driver.mood.state == .thinking)

        driver.update(state: .idle, isStale: false, at: 10)
        #expect(driver.isNotifying)
        #expect(driver.mood.state == .notify)

        driver.update(state: .idle, isStale: false, at: 10 + CrewMoodMap.notifyHold - 0.1)
        #expect(driver.mood.state == .notify)

        driver.update(state: .idle, isStale: false, at: 10 + CrewMoodMap.notifyHold)
        #expect(!driver.isNotifying)
        #expect(driver.mood.state == .idle)
    }

    /// A session that was already idle when the board first saw it has nothing
    /// to announce — the notification marks a turn *ending*, not idleness.
    @Test("a session that was idle all along raises nothing")
    func noNotifyWithoutATurn() {
        var driver = CrewAvatarDriver(harness: .codex, state: .idle, at: 0)
        driver.update(state: .idle, isStale: false, at: 1)
        #expect(!driver.isNotifying)
        #expect(driver.mood.state == .idle)
    }

    @Test("the driver keeps the harness's silhouette through every state")
    func shapeIsStable() {
        var driver = CrewAvatarDriver(harness: .cursor, state: .idle, at: 0)
        #expect(driver.mood.shape == .triangle)
        driver.update(state: .toolCalling(name: "Bash"), isStale: false, at: 1)
        #expect(driver.mood.shape == .triangle)
        driver.update(state: .ended(reason: .exited), isStale: false, at: 2)
        #expect(driver.mood.shape == .triangle)
        #expect(driver.engine.bodyShape == .triangle)
    }

    @Test("a held one-shot state is replayed rather than left to decay")
    func heldStateIsReplayed() {
        var driver = CrewAvatarDriver(harness: .claudeCode, state: .toolCalling(name: "Bash"), at: 0)
        #expect(driver.mood.state == .orbit)
        // Well past the point where the rings would have faded out on their own.
        var now = 0.0
        while now < 12 {
            now += 1.0 / 60
            driver.update(state: .toolCalling(name: "Bash"), isStale: false, at: now)
        }
        #expect(!driver.sample(now).arcs.isEmpty)
    }

    /// The burst fires on entering `delegating` and again when the session
    /// hands out more work — but not while a count merely holds or falls as
    /// children finish, which is the same act still in progress.
    @Test("the spawning burst fires on the act, not on the condition")
    func spawningBurst() {
        var driver = CrewAvatarDriver(harness: .claudeCode, state: .thinking, at: 0)
        driver.update(state: .delegating(children: 1), isStale: false, at: 10)
        #expect(driver.isSpawning)
        #expect(driver.mood.state == .burst)

        // it resolves, and the body comes back as the harness's own shape
        driver.update(state: .delegating(children: 1), isStale: false, at: 10 + CrewMoodMap.spawnBurst)
        #expect(!driver.isSpawning)
        #expect(driver.mood.state == .wide)
        #expect(driver.engine.bodyShape == .circle)

        // holding at one child does not restart it
        driver.update(state: .delegating(children: 1), isStale: false, at: 20)
        #expect(driver.mood.state == .wide)
        // nor does a child finishing
        driver.update(state: .delegating(children: 1), isStale: false, at: 21)
        #expect(driver.mood.state == .wide)

        // a new child does
        driver.update(state: .delegating(children: 3), isStale: false, at: 22)
        #expect(driver.isSpawning)
        #expect(driver.mood.state == .burst)
    }

    /// And it never rests as a lone dot, which is what `sleep` is.
    @Test("a long delegation never settles on the ended pose")
    func delegationDoesNotLookEnded() {
        var driver = CrewAvatarDriver(harness: .codex, state: .delegating(children: 2), at: 0)
        var now = 0.0
        var sawWide = false
        while now < 30 {
            now += 1.0 / 30
            driver.update(state: .delegating(children: 2), isStale: false, at: now)
            #expect(driver.mood.state != .sleep)
            if driver.mood.state == .wide { sawWide = true }
        }
        #expect(sawWide)
        // the body is the harness's silhouette at full size, not a collapsed core
        let reach = driver.sample(now).body.curves
            .map { hypot($0.end.x, $0.end.y) }.max() ?? 0
        #expect(reach > BloubFrameOfReference.radius * 0.8)
    }

    /// Every state change goes through the engine, so the ones bloub measured a
    /// blink on get one here too — at the midpoint of the morph, which is where
    /// this port puts it.
    @Test("changing state through the driver still punctuates it with a blink")
    func driverBlinks() {
        var driver = CrewAvatarDriver(harness: .claudeCode, state: .idle, at: 0)
        let open = driver.sample(11.5).eyes[0]
        driver.update(state: .idle, isStale: true, at: 11.5)
        // stale + idle is still idle, so nothing moved
        #expect(driver.mood.state == .idle)

        driver.update(state: .thinking, isStale: true, at: 11.5)
        #expect(driver.mood.state == .wink)
        let midpoint = 11.5 + BloubTransition.duration(BloubStates.state(.wink).morph) / 2
        #expect(abs(driver.sample(midpoint).eyes[0].d) < abs(open.d) * 0.2)
    }

    // MARK: How often each avatar has to be drawn

    /// The whole second after a state change runs at the full rate, whatever
    /// the state settles into — that window has to cover the morph, the blink
    /// inside it and the card's pop.
    /// The first instant at or after `t` with no blink under way or about to
    /// start. The blink rule would otherwise answer for the state rule, and a
    /// test that did not say which one it was reading would pass by accident.
    private static func quiet(from t: Double) -> Double {
        var now = t
        while BloubFace.blinkImminent(at: now, lead: CrewCadence.blinkLead) { now += 0.05 }
        return now
    }

    @Test("a state change buys a second at the full rate")
    func cadenceAfterAChange() {
        var driver = CrewAvatarDriver(harness: .claudeCode, state: .idle, at: 0)
        driver.update(state: .idle, isStale: false, at: 10)
        // settled idle, away from a blink: the low rate
        #expect(driver.frameInterval(at: Self.quiet(from: 10)) == CrewCadence.low)

        driver.update(state: .thinking, isStale: false, at: 10)
        #expect(driver.mood.state == .thinking)
        for offset in [0.0, 0.2, 0.5, 0.9] {
            #expect(driver.frameInterval(at: 10 + offset) == CrewCadence.full, "at +\(offset)")
        }
        // and drops to the state's own rate once nothing is in flight
        #expect(driver.frameInterval(at: 11.2) == CrewCadence.half)
        // the window is longer than the morph and the pop, which is why it can
        // be one comparison rather than three
        #expect(CrewCadence.settle > BloubTransition.span(BloubStates.state(.thinking).morph))
        #expect(CrewCadence.settle > CrewAvatarDriver.popDuration)
    }

    /// The orbit is the one continuous state that keeps 60: its rings turn at 3
    /// to 3.7 turns a second, so 30 fps would move each one 36–44° between
    /// frames and the bouquet would strobe. Checked on a filmstrip sampled at
    /// both rates, not assumed.
    @Test("each state asks for the rate its fastest motion needs")
    func cadencePerState() {
        // A driver parked well past any change, so only the state decides.
        func settled(_ state: SessionState, isStale: Bool = false) -> Double? {
            var driver = CrewAvatarDriver(harness: .codex, state: .idle, at: 0)
            driver.update(state: state, isStale: isStale, at: 0)
            return driver.frameInterval(at: Self.quiet(from: 30))
        }

        #expect(settled(.toolCalling(name: "shell")) == CrewCadence.full)   // orbit
        #expect(settled(.thinking) == CrewCadence.half)
        #expect(settled(.writingFile(path: "/Users/example/a.swift")) == CrewCadence.half)
        #expect(settled(.waitingPermission(tool: nil)) == CrewCadence.half)          // alert
        // stale work is a wink: a still pose, so the low rate
        #expect(settled(.thinking, isStale: true) == CrewCadence.low)
        // and a session that is over is not drawn at all
        #expect(settled(.ended(reason: .exited)) == nil)
    }

    /// A blink is 0.18 s. At fifteen frames a second it would get two of them,
    /// so an idle card goes back to sixty around each one — which it can only
    /// do because the schedule is pre-drawn and the next blink is a fact about
    /// the future.
    @Test("an idle avatar wakes up for its own blinks")
    func cadenceAroundABlink() {
        var driver = CrewAvatarDriver(harness: .claudeCode, state: .idle, at: 0)
        driver.update(state: .idle, isStale: false, at: 0)

        // Walk a minute at the rate the driver itself asks for, and collect
        // what it says. This is the loop the wall runs.
        var now = 2.0
        var sawLow = false
        var blinkFrames = 0
        var lidsSeen: [Double] = []
        while now < 40 {
            let interval = driver.frameInterval(at: now) ?? CrewCadence.low
            if interval == CrewCadence.low { sawLow = true }
            let lid = BloubFace.liveliness(now).lid
            if lid < 0.999 {
                blinkFrames += 1
                lidsSeen.append(lid)
                // every frame drawn during a blink was drawn at the full rate
                #expect(interval == CrewCadence.full, "blink frame at \(now)")
            }
            now += interval
        }
        #expect(sawLow, "an idle avatar should spend most of its time at the low rate")
        // Roughly a dozen blinks in 38 s, each getting ten or more frames
        // instead of the two the low rate would have given it.
        #expect(blinkFrames > 100, "only \(blinkFrames) frames landed inside a blink")
        // and the eye really does shut on some of them
        #expect(lidsSeen.contains { $0 < 0.05 })
    }

    /// The warning has to arrive before the blink does, or a card sampling every
    /// 67 ms steps straight over it.
    @Test("the blink warning is longer than the slowest rate")
    func blinkLeadCoversTheLowRate() {
        #expect(CrewCadence.blinkLead > CrewCadence.low)
        // three chances to notice
        #expect(CrewCadence.blinkLead > CrewCadence.low * 3)
    }

    /// What the tiers are actually worth, measured on the demo script rather
    /// than argued from the table.
    ///
    /// The wall's cost is the number of avatar-frames it asks for, so that is
    /// what is counted: replay the demo for a minute, step every 1/60 s, and
    /// sum 1/interval over every session on the board. At the time of writing
    /// that is 396 frames a second against 705 for sixty-everywhere — 56 %,
    /// with the avatar-ticks falling 42 % at 60, 16 % at 30, 25 % at 15 and
    /// 17 % not drawn at all.
    ///
    /// The demo board is deliberately busy; a real one, where most sessions are
    /// idle or finished, sits further down. The bound below is loose enough to
    /// survive a change to the script and tight enough to fail if somebody
    /// quietly puts a tier back to 60.
    @Test("the tiers cut the demo wall's frames by a third or better")
    func cadenceCutsTheDemoWall() {
        let start = Date(timeIntervalSince1970: 1_767_225_600)
        let steps = DemoScript.make(seed: DemoScript.defaultSeed, startedAt: start).steps
        let reducer = SessionStateReducer()

        var snapshots: [SessionKey: SessionSnapshot] = [:]
        var drivers: [SessionKey: CrewAvatarDriver] = [:]
        var index = 0
        var asked = 0.0
        var flat = 0.0
        var now = 0.0

        while now < 60 {
            while index < steps.count, steps[index].offset <= now {
                let event = steps[index].event
                var current = snapshots[event.session]
                if current == nil, case .sessionStarted(let identity) = event.kind {
                    current = SessionStateReducer.initialSnapshot(identity: identity)
                }
                if let current {
                    snapshots[event.session] = reducer.reduce(current, event: event)
                }
                index += 1
            }
            for session in snapshots.values {
                var driver = drivers[session.key] ?? CrewAvatarDriver(
                    harness: session.key.harness,
                    state: session.state,
                    isStale: session.isStale,
                    at: now
                )
                driver.update(state: session.state, isStale: session.isStale, at: now)
                drivers[session.key] = driver
                flat += 1 / CrewCadence.full
                asked += driver.frameInterval(at: now).map { 1 / $0 } ?? 0
            }
            now += CrewCadence.full
        }

        #expect(flat > 0)
        #expect(asked < flat * 0.7, "the wall asked for \(asked / flat) of a flat 60 fps")
        // and it is still drawing: a policy that answered `nil` everywhere
        // would pass the line above and show a wall of frozen avatars
        #expect(asked > flat * 0.25)
    }
}
