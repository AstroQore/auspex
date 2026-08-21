import AgentSessionKit
import AgentSessionLive
import AuspexCore
import Foundation
import Testing

/// The table that turns what Auspex knows into what the avatar draws.
///
/// Worth its own suite because it is the only place a new harness or a new
/// session state could pick up a silent default, and because the precedence
/// between "needs you", "stale" and a finished turn is a product decision
/// rather than something the engine knows about.
@Suite("Crew mood")
struct CrewMoodTests {
    // MARK: The tables

    /// The body is the *session* now, not the harness — see ``FlockShapes``
    /// for why, and `FlockShapesTests` for the family's own properties. What
    /// this asserts is the mapping the wall goes through.
    @Test("the body comes from the session and the harness is not in it")
    func shapeComesFromTheSession() {
        let key = SessionKey(harness: .cursor, sessionID: "a-session")
        #expect(CrewMoodMap.shape(for: key) == FlockShapes.shape(for: key))
        #expect(FlockShapes.family.contains(CrewMoodMap.shape(for: key)))
    }

    /// Nine harnesses no longer mean nine outlines — they mean nine accents.
    /// A wall of ninety sessions where forty were the same triangle was one
    /// bird drawn forty times.
    @Test("two sessions of one harness are two different bodies")
    func oneHarnessIsManyBodies() {
        let shapes = (0..<40).map {
            CrewMoodMap.shape(for: SessionKey(harness: .codex, sessionID: "s-\($0)"))
        }
        #expect(Set(shapes).count >= 8)
    }

    /// The body no longer says what a session is doing — it says which session
    /// it is, and nothing else. Everything else is the face.
    @Test("the silhouette is the session and never the state")
    func shapeIsStable() {
        let key = SessionKey(harness: .cursor, sessionID: "a")
        let body = FlockShapes.shape(for: key)
        var driver = CrewAvatarDriver(session: key, state: .idle, at: 0)
        let states: [SessionState] = [
            .thinking,
            .toolCalling(name: "shell"),
            .waitingPermission(tool: "bash"),
            .delegating(children: 3),
            .writingFile(path: "/Users/example/a.swift"),
            .ended(reason: .exited)
        ]
        for (index, state) in states.enumerated() {
            driver.update(state: state, isStale: false, at: Double(index) * 3)
            #expect(driver.mood.shape == body, "\(state) changed the silhouette")
        }
    }

    @Test("each session state maps to a stance")
    func stanceTable() {
        #expect(CrewMoodMap.stance(for: .idle) == .idle)
        #expect(CrewMoodMap.stance(for: .thinking) == .thinking)
        #expect(CrewMoodMap.stance(for: .toolCalling(name: "shell")) == .working)
        #expect(CrewMoodMap.stance(for: .writingFile(path: "/Users/example/a.swift")) == .working)
        #expect(CrewMoodMap.stance(for: .delegating(children: 2)) == .delegating)
        #expect(CrewMoodMap.stance(for: .waitingPermission(tool: nil)) == .blocked)
        #expect(CrewMoodMap.stance(for: .ended(reason: .exited)) == .ended)
    }

    /// From outside, a tool call and a file write are the same thing: the
    /// session is busy and is not asking anything of you. Two stances for that
    /// would be two faces for one fact.
    @Test("tool calls and file writes are one stance")
    func toolsAndWritesAgree() {
        #expect(
            CrewMoodMap.stance(for: .toolCalling(name: "shell"))
                == CrewMoodMap.stance(for: .writingFile(path: "/Users/example/a.swift"))
        )
    }

    /// Delegating is two beats: the act of spawning, then the watching.
    @Test("delegating spawns first and listens afterwards")
    func delegatingIsTwoBeats() {
        #expect(CrewMoodMap.stance(for: .delegating(children: 1), isSpawning: true) == .spawning)
        #expect(CrewMoodMap.stance(for: .delegating(children: 1), isSpawning: false) == .delegating)
    }

    @Test("a stale working session droops instead of showing its work")
    func staleWins() {
        for state: SessionState in [
            .thinking,
            .toolCalling(name: "shell"),
            .writingFile(path: "/Users/example/a.swift"),
            .delegating(children: 2)
        ] {
            #expect(CrewMoodMap.stance(for: state, isStale: true) == .stale, "\(state)")
        }
    }

    /// "Needs you" is the one state that will never resolve itself, so nothing
    /// softer is allowed to mask it — and a session that is over is over.
    @Test("needs-you and ended outrank stale and a finished turn")
    func precedence() {
        #expect(
            CrewMoodMap.stance(
                for: .waitingPermission(tool: "bash"),
                isStale: true,
                isNotifying: true
            ) == .blocked
        )
        #expect(
            CrewMoodMap.stance(
                for: .ended(reason: .killed),
                isStale: true,
                isNotifying: true
            ) == .ended
        )
    }

    @Test("a celebration only lands on an idle session")
    func notifyOnlyWhenIdle() {
        #expect(CrewMoodMap.stance(for: .idle, isNotifying: true) == .celebrating)
        #expect(CrewMoodMap.stance(for: .thinking, isNotifying: true) == .thinking)
    }

    // MARK: The driver

    @Test("a turn ending raises a celebration, and it expires")
    func softNotify() {
        var driver = CrewAvatarDriver(session: SessionKey(harness: .claudeCode, sessionID: "a"), state: .thinking, at: 0)
        #expect(driver.mood.stance == .thinking)

        driver.update(state: .idle, isStale: false, at: 4)
        #expect(driver.isCelebrating)
        #expect(driver.mood.stance == .celebrating)

        // Twenty seconds, not four: a celebration is the one piece of good news
        // on the wall and it has to still be there when somebody looks back.
        driver.update(state: .idle, isStale: false, at: 4 + CrewMoodMap.notifyHold - 1)
        #expect(driver.mood.stance == .celebrating)

        driver.update(state: .idle, isStale: false, at: 4 + CrewMoodMap.notifyHold + 0.1)
        #expect(!driver.isCelebrating)
        #expect(driver.mood.stance == .idle)
    }

    /// A session that was already idle when the board first saw it has nothing
    /// to announce — the celebration marks a turn *ending*, not idleness.
    @Test("a session that was idle all along raises nothing")
    func noNotifyWithoutATurn() {
        var driver = CrewAvatarDriver(session: SessionKey(harness: .codex, sessionID: "a"), state: .idle, at: 0)
        driver.update(state: .idle, isStale: false, at: 5)
        #expect(!driver.isCelebrating)
        #expect(driver.mood.stance == .idle)
    }

    /// The spawn fires on entering `delegating` and again when the session
    /// hands out more work — but not while a count merely holds, which is the
    /// same act still in progress.
    @Test("the spawn fires on the act, not on the condition")
    func spawningBurst() {
        var driver = CrewAvatarDriver(session: SessionKey(harness: .claudeCode, sessionID: "a"), state: .thinking, at: 0)
        driver.update(state: .delegating(children: 1), isStale: false, at: 1)
        #expect(driver.mood.stance == .spawning)

        driver.update(state: .delegating(children: 1), isStale: false, at: 1 + 2.5)
        #expect(driver.mood.stance == .delegating)

        // more work handed out: it fires again
        driver.update(state: .delegating(children: 3), isStale: false, at: 6)
        #expect(driver.mood.stance == .spawning)

        // and a child finishing does not restart it
        driver.update(state: .delegating(children: 2), isStale: false, at: 6 + 2.5)
        #expect(driver.mood.stance == .delegating)
    }

    /// A child finishing is news the stance cannot carry — the parent is still
    /// delegating — so the face says it instead.
    @Test("a child finishing is announced by the face")
    func childFinishedAccents() {
        var driver = CrewAvatarDriver(session: SessionKey(harness: .claudeCode, sessionID: "a"), state: .thinking, at: 0, seed: 0x31)
        driver.update(state: .delegating(children: 3), isStale: false, at: 1)
        driver.update(state: .delegating(children: 3), isStale: false, at: 5)
        driver.update(state: .delegating(children: 2), isStale: false, at: 6)
        #expect(driver.choreographer.isReacting(at: 6.2))
        #expect(driver.choreographer.sample(at: 6.8).sequence == .proud)
    }

    /// A long delegation never settles on something that reads as finished.
    @Test("a long delegation never looks asleep")
    func delegationDoesNotLookEnded() {
        var driver = CrewAvatarDriver(session: SessionKey(harness: .grokBuild, sessionID: "a"), state: .thinking, at: 0, seed: 7)
        driver.update(state: .delegating(children: 2), isStale: false, at: 1)
        for t in stride(from: 1.0, through: 120, by: 0.5) {
            driver.update(state: .delegating(children: 2), isStale: false, at: t)
            #expect(driver.mood.stance != .ended)
            #expect(driver.choreographer.sample(at: t).sequence != .sleeping)
        }
    }

    /// bloub hides a change of shape inside a blink; this port made the morph
    /// visible and moved the blink to its midpoint. That accent is the one
    /// piece of bloub's transition grammar that is about eyes rather than
    /// bodies, so it survives the state language moving onto the face.
    @Test("a change of stance is still punctuated by a blink")
    func driverBlinks() {
        var driver = CrewAvatarDriver(session: SessionKey(harness: .claudeCode, sessionID: "a"), state: .idle, at: 0, seed: 0x2B)
        driver.update(state: .thinking, isStale: false, at: 10)
        let lowest = stride(from: 10.0, through: 10.7, by: 0.005)
            .map { driver.choreographer.sample(at: $0).lid }
            .min() ?? 1
        #expect(lowest < 0.1, "the change was not punctuated: lowest lid \(lowest)")
    }

    /// An ended session is asleep. No blink is the load-bearing half of that:
    /// a blink is exactly what says "awake".
    @Test("an ended session does not blink")
    func endedDoesNotBlink() {
        var driver = CrewAvatarDriver(session: SessionKey(harness: .codex, sessionID: "a"), state: .thinking, at: 0, seed: 9)
        driver.update(state: .ended(reason: .exited), isStale: false, at: 2)
        for t in stride(from: 4.0, through: 200, by: 0.05) {
            #expect(driver.choreographer.sample(at: t).lid == 1, "blinked at \(t)")
            #expect(!driver.choreographer.isReacting(at: t))
        }
    }

    // MARK: The frame rate

    /// The first instant at or after `t` at which nothing but the stance itself
    /// is asking for frames: no blink under way or about to start, no reaction
    /// in flight, no step morph running.
    ///
    /// All three would otherwise answer for the stance rule, and a test that did
    /// not say which one it was reading would pass by accident.
    private static func quiet(_ driver: CrewAvatarDriver, from t: Double) -> Double {
        var now = t
        while now < t + 200 {
            let face = driver.choreographer.sample(at: now)
            if !face.isReacting, face.hasSettled,
               !driver.choreographer.blinkImminent(at: now, lead: CrewCadence.blinkLead) {
                return now
            }
            now += 0.05
        }
        return now
    }

    @Test("a change of stance buys a second at the full rate")
    func cadenceAfterAChange() {
        var driver = CrewAvatarDriver(session: SessionKey(harness: .claudeCode, sessionID: "a"), state: .idle, at: 0, seed: 0x51)
        driver.update(state: .idle, isStale: false, at: 10)
        // settled idle, away from a blink and a reaction: the low rate
        #expect(driver.frameInterval(at: Self.quiet(driver, from: 10)) == CrewCadence.low)

        driver.update(state: .thinking, isStale: false, at: 10)
        #expect(driver.mood.stance == .thinking)
        for offset in [0.0, 0.2, 0.5, 0.9] {
            #expect(driver.frameInterval(at: 10 + offset) == CrewCadence.full, "at +\(offset)")
        }
        // The change also fires an accent — the face says "starting work" — and
        // that is an event too, so the full rate runs through it as well.
        #expect(driver.frameInterval(at: 11.2) == CrewCadence.full)
        // and drops away once nothing at all is in flight
        let settled = driver.frameInterval(at: Self.quiet(driver, from: 12))
        #expect(settled == CrewCadence.low)
        #expect(CrewCadence.settle > BloubTransition.longest)
        #expect(CrewCadence.settle > CrewAvatarDriver.popDuration)
    }

    /// The body no longer animates, so the rate is decided entirely by the
    /// face: an event gets sixty, a step morph thirty, a held face fifteen, and
    /// a session that has ended nothing at all.
    @Test("the rate follows the face, not the state")
    func cadencePerStance() {
        func settled(_ state: SessionState, isStale: Bool = false) -> Double? {
            var driver = CrewAvatarDriver(session: SessionKey(harness: .codex, sessionID: "a"), state: .idle, at: 0, seed: 0x77)
            driver.update(state: state, isStale: isStale, at: 0)
            return driver.frameInterval(at: Self.quiet(driver, from: 30))
        }

        // A held face, whatever the session is doing: the low rate.
        #expect(settled(.toolCalling(name: "shell")) == CrewCadence.low)
        #expect(settled(.thinking) == CrewCadence.low)
        #expect(settled(.waitingPermission(tool: nil)) == CrewCadence.low)
        #expect(settled(.thinking, isStale: true) == CrewCadence.low)
        // and a session that is over is not drawn at all
        #expect(settled(.ended(reason: .exited)) == nil)
    }

    /// A step morph is a continuous movement of two capsules, not an event, so
    /// it sits at the middle tier — the same place the board already puts a
    /// motion that is smooth but slow.
    @Test("a step morph asks for the middle rate")
    func cadenceDuringAStepMorph() {
        var driver = CrewAvatarDriver(session: SessionKey(harness: .claudeCode, sessionID: "a"), state: .idle, at: 0, seed: 0x99)
        driver.update(state: .idle, isStale: false, at: 0)
        var sawHalf = false
        for t in stride(from: 5.0, through: 120, by: 0.02) {
            let face = driver.choreographer.sample(at: t)
            guard !face.isReacting, !face.hasSettled,
                  !driver.choreographer.blinkImminent(at: t, lead: CrewCadence.blinkLead)
            else { continue }
            #expect(driver.frameInterval(at: t) == CrewCadence.half)
            sawHalf = true
        }
        #expect(sawHalf, "the idle loop never morphed between steps")
    }

    /// A blink is 0.28 s. At fifteen frames a second it would get four of them,
    /// so a card goes back to sixty around each one — which it can only do
    /// because the schedule is pre-drawn and the next blink is a fact about the
    /// future.
    @Test("an avatar wakes up for its own blinks")
    func cadenceAroundABlink() {
        var driver = CrewAvatarDriver(session: SessionKey(harness: .claudeCode, sessionID: "a"), state: .idle, at: 0, seed: 0x1234)
        driver.update(state: .idle, isStale: false, at: 0)

        // Walk a minute at the rate the driver itself asks for, and collect
        // what it says. This is the loop the wall runs.
        var now = 2.0
        var sawLow = false
        var blinkFrames = 0
        while now < 60 {
            let interval = driver.frameInterval(at: now) ?? CrewCadence.low
            if interval == CrewCadence.low { sawLow = true }
            // The lid the driver actually draws: the *sequence's* rhythm, not
            // bloub's global schedule, which a choreographed face switches off.
            if driver.choreographer.sample(at: now).lid < 0.999 {
                blinkFrames += 1
                #expect(interval == CrewCadence.full, "blink frame at \(now)")
            }
            now += interval
        }
        #expect(sawLow, "an idle avatar should spend most of its time at the low rate")
        #expect(blinkFrames > 40, "only \(blinkFrames) frames landed inside a blink")
    }
}
