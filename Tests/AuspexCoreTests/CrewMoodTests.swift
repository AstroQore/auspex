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
            (.delegating(children: 2), .burst),
            (.waitingPermission(tool: "Bash"), .alert),
            (.ended(reason: .exited), .sleep)
        ]
        for (state, expected) in cases {
            #expect(CrewMoodMap.avatarState(for: state).state == expected)
        }
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
        for state: BloubStateID in [.alert, .play, .orbit, .burst, .comet] {
            let period = CrewMoodMap.replayPeriod(for: state)
            #expect(period != nil)
            // never shorter than the state's own entry morph, or the replay
            // would land inside the previous one
            #expect((period ?? 0) > BloubStates.state(state).morph)
        }
        for state: BloubStateID in [.idle, .thinking, .wink, .notify, .sleep] {
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

    /// Every state change goes through the engine, so the ones bloub measured a
    /// blink on get one here too.
    @Test("changing state through the driver still hides the change in a blink")
    func driverBlinks() {
        var driver = CrewAvatarDriver(harness: .claudeCode, state: .idle, at: 0)
        let open = driver.sample(11.5).eyes[0]
        driver.update(state: .idle, isStale: true, at: 11.5)
        // stale + idle is still idle, so nothing moved
        #expect(driver.mood.state == .idle)

        driver.update(state: .thinking, isStale: true, at: 11.5)
        #expect(driver.mood.state == .wink)
        let mid = driver.sample(11.6).eyes[0]
        #expect(abs(mid.d) < abs(open.d) * 0.2)
    }
}
