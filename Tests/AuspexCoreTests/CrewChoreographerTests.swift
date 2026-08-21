import AuspexCore
import Foundation
import Testing

/// What the choreographer guarantees.
///
/// The complaint it answers is "the wall looks stiff", and the two halves of
/// that are: every avatar of a state does the same thing (fixed by the pools),
/// and it does it at the same time as every other one (fixed by the seeds). So
/// the assertions come in those two families, plus the usual purity.
@Suite("Crew choreographer")
struct CrewChoreographerTests {
    /// A dozen seeds, the way a wall of twelve sessions gets them: a hash of
    /// the session id, not an index.
    private static let seeds: [UInt32] = (0..<12).map { UInt32($0) &* 2_654_435_761 &+ 17 }

    /// What counts as a cut, in the ``distance(_:_:)`` metric below.
    ///
    /// The two faces furthest apart in the whole vocabulary are 184 units
    /// apart, so a genuine cut between them shows up as ~184 in a single 60th
    /// of a second. A legitimate morph across that distance takes 0.3 to 0.7 s
    /// and peaks around 26. A fifth of the widest pair sits between the two
    /// with room on both sides, and it is the number a missing hand-over
    /// breaks: the state change without one measured 136.
    private static let cut = 184.0 / 5

    private func chorus(
        _ state: BloubStateID,
        seed: UInt32,
        liveliness: CrewLiveliness = .normal
    ) -> CrewChoreographer {
        CrewChoreographer(seed: seed, state: state, liveliness: liveliness, at: 0)
    }

    // MARK: Purity

    @Test("the same instant gives the same face")
    func deterministic() {
        let one = chorus(.idle, seed: 0xC0FFEE)
        for t in stride(from: 0.0, through: 120, by: 0.41) {
            #expect(one.sample(at: t) == one.sample(at: t))
        }
    }

    @Test("two choreographers with one seed are the same choreographer")
    func seedIsTheSchedule() {
        let one = chorus(.idle, seed: 0x1234)
        let two = chorus(.idle, seed: 0x1234)
        for t in stride(from: 0.0, through: 200, by: 0.23) {
            #expect(one.sample(at: t) == two.sample(at: t))
        }
    }

    @Test("sampling forwards does not change what an earlier instant returns")
    func replayable() {
        let one = chorus(.thinking, seed: 0x99)
        let early = one.sample(at: 7.3)
        for t in stride(from: 0.0, through: 300, by: 0.13) { _ = one.sample(at: t) }
        #expect(one.sample(at: 7.3) == early)
    }

    // MARK: Nobody is in lockstep

    @Test("the wall never reacts as one")
    func reactionsDoNotLineUp() {
        let wall = Self.seeds.map { chorus(.idle, seed: $0) }
        var most = 0
        var total = 0
        var samples = 0
        for t in stride(from: 0.0, through: 400, by: 0.25) {
            let reacting = wall.count { $0.isReacting(at: t) }
            most = max(most, reacting)
            total += reacting
            samples += 1
        }
        // Reactions are common by design — a quarter of an avatar's time — so
        // several being in flight at once is normal and wanted. What must never
        // happen is the *whole wall* moving together, which is what a schedule
        // that ignored the seed would produce.
        #expect(most < wall.count, "all \(wall.count) reacted at once")
        #expect(Double(total) / Double(samples) < Double(wall.count) / 2)
    }

    @Test("a wall of idle avatars is not a wall of one drawing")
    func facesDiffer() {
        let wall = Self.seeds.map { chorus(.idle, seed: $0) }
        var fewest = wall.count
        var varied = 0
        var samples = 0
        for t in stride(from: 0.0, through: 400, by: 0.25) {
            let faces = Set(wall.map { $0.sample(at: t).face }).count
            fewest = min(fewest, faces)
            samples += 1
            if faces >= 3 { varied += 1 }
        }
        // The floor is two, and it is a floor of the *data*: avatar-lab's idle
        // pool holds two expressions, so a wall where nobody is mid-morph and
        // nobody is reacting shows two faces. What matters is that it is never
        // one — and that most of the time it is more, which is what the phases,
        // the tempos and the reaction pools buy.
        #expect(fewest >= 2)
        #expect(Double(varied) / Double(samples) > 0.8, "\(varied)/\(samples)")
    }

    @Test("each avatar's schedule is its own")
    func schedulesDiffer() {
        // The starts of the first four reactions, per seed. Two seeds sharing
        // even one of them would be a coincidence; sharing the list would mean
        // the seed is not reaching the schedule.
        var schedules: [[Double]] = []
        for seed in Self.seeds {
            let one = chorus(.idle, seed: seed)
            var starts: [Double] = []
            var wasReacting = false
            for t in stride(from: 0.0, through: 200, by: 0.05) {
                let reacting = one.isReacting(at: t)
                if reacting, !wasReacting { starts.append((t * 20).rounded() / 20) }
                wasReacting = reacting
            }
            schedules.append(Array(starts.prefix(4)))
        }
        #expect(Set(schedules.map(\.description)).count == schedules.count)
    }

    // MARK: The pools

    @Test("every state plays only what its own beat allows")
    func poolsAreRespected() {
        for state in BloubStateID.allCases {
            let beat = CrewChoreography.beat(for: state)
            let allowed = Set([beat.base] + beat.reactions)
            for seed in Self.seeds.prefix(4) {
                let one = chorus(state, seed: seed)
                let played = Set(
                    stride(from: 0.0, through: 300, by: 0.25).map { one.sample(at: $0).sequence }
                )
                #expect(played.isSubset(of: allowed), "\(state) played \(played)")
                // And the pool is actually used, not merely permitted.
                if !beat.reactions.isEmpty {
                    #expect(played.count > 1, "\(state) never left its base loop")
                }
            }
        }
    }

    @Test("a session waiting on you never looks idle")
    func blockedIsNeverIdle() {
        // `alert` is the one state that will not resolve itself, so the face
        // has to keep asking. A single frame of the idle loop here would read
        // as a session that had given up.
        let beat = CrewChoreography.beat(for: .alert)
        #expect(!([beat.base] + beat.reactions).contains(.idle))
        #expect(!([beat.base] + beat.reactions).contains(.sleeping))
        #expect(!([beat.base] + beat.reactions).contains(.drowsy))
        // And it asks often: the gap is the shortest on the board.
        for state in BloubStateID.allCases where state != .alert {
            #expect(beat.minGap <= CrewChoreography.beat(for: state).minGap)
        }
    }

    @Test("a session that has ended sleeps and stays asleep")
    func endedSleeps() {
        let one = chorus(.sleep, seed: 0x42)
        for t in stride(from: 0.0, through: 400, by: 1.0) {
            #expect(one.sample(at: t).sequence == .sleeping)
            #expect(!one.isReacting(at: t))
        }
    }

    @Test("a stale session's pool has given up on it")
    func staleDroops() {
        let beat = CrewChoreography.beat(for: .wink)
        #expect(Set(beat.reactions) == Set([.drowsy, .sleeping, .bored]))
        #expect(beat.base == .idle)
    }

    // MARK: The rhythm

    @Test("the gaps between reactions land inside the declared window")
    func gapsAreInBand() {
        for state in [BloubStateID.idle, .thinking, .alert, .wide, .notify] {
            let beat = CrewChoreography.beat(for: state)
            for liveliness in CrewLiveliness.allCases {
                let one = chorus(state, seed: 0xBEEF, liveliness: liveliness)
                let starts = reactionStarts(one, through: 600)
                #expect(starts.count > 4, "\(state)/\(liveliness) barely reacts")
                for gap in zip(starts, starts.dropFirst()).map({ $0.1 - $0.0 }) {
                    #expect(gap > beat.minGap * liveliness.gapScale - 0.3, "\(state) \(gap)")
                    #expect(gap < beat.maxGap * liveliness.gapScale + 0.3, "\(state) \(gap)")
                }
            }
        }
    }

    @Test("liveliness scales how often things happen, not how fast they happen")
    func livelinessScales() {
        for state in [BloubStateID.idle, .thinking, .wide] {
            let counts = CrewLiveliness.allCases.map { liveliness -> Int in
                reactionStarts(chorus(state, seed: 0x5EED, liveliness: liveliness), through: 900)
                    .count
            }
            let calm = counts[CrewLiveliness.allCases.firstIndex(of: .calm)!]
            let normal = counts[CrewLiveliness.allCases.firstIndex(of: .normal)!]
            let lively = counts[CrewLiveliness.allCases.firstIndex(of: .lively)!]
            #expect(calm < normal, "\(state): \(counts)")
            #expect(normal < lively, "\(state): \(counts)")
        }
    }

    @Test("a reaction always hands the base loop back before the next one")
    func reactionsLeaveRoom() {
        // The failure this catches is an avatar in a permanent fit: at the
        // lively setting the gaps come down to five seconds, and a reaction cap
        // that ignored that would fill them.
        for state in BloubStateID.allCases {
            guard !CrewChoreography.beat(for: state).reactions.isEmpty else { continue }
            for liveliness in CrewLiveliness.allCases {
                let one = chorus(state, seed: 0xA5A5, liveliness: liveliness)
                var resting = 0
                var samples = 0
                for t in stride(from: 0.0, through: 400, by: 0.1) {
                    samples += 1
                    if !one.isReacting(at: t) { resting += 1 }
                }
                // Most of the time an avatar is living in its loop, whatever
                // the setting.
                #expect(
                    Double(resting) / Double(samples) > 0.55,
                    "\(state)/\(liveliness) reacts \(samples - resting)/\(samples)"
                )
            }
        }
    }

    // MARK: Accents

    @Test("a change of state is announced by the face, not only by the body")
    func stateChangesAccent() {
        var one = chorus(.thinking, seed: 0x77)
        one.setState(.alert, at: 40)
        // In flight immediately — the hand-over starts on the frame of the
        // change — and speaking by the time it has crossed.
        #expect(one.isReacting(at: 40.01))
        #expect(one.sample(at: 40.8).sequence == .surprised)
        #expect(!one.isReacting(at: 40 + CrewChoreography.accentCap + 0.1))
        // And it hands back to the beat the new state asked for.
        let beat = CrewChoreography.beat(for: .alert)
        #expect(one.sample(at: 40 + CrewChoreography.accentCap + 0.1).sequence == beat.base)
    }

    @Test("the accents cover the changes that mean something")
    func accentTable() {
        #expect(CrewChoreography.accent(from: .idle, to: .alert) == .surprised)
        #expect(CrewChoreography.accent(from: .orbit, to: .alert) == .surprised)
        #expect(CrewChoreography.accent(from: .alert, to: .orbit) == .happy)
        #expect(CrewChoreography.accent(from: .wide, to: .burst) == .excited)
        #expect(CrewChoreography.accent(from: .thinking, to: .orbit) == .excited)
        #expect(CrewChoreography.accent(from: .idle, to: .notify) == .celebrate)
        #expect(CrewChoreography.accent(from: .orbit, to: .sleep) == .drowsy)
        // And a change that is already its own announcement gets nothing extra.
        #expect(CrewChoreography.accent(from: .orbit, to: .play) == nil)
    }

    @Test("an explicit accent outranks whatever the schedule had planned")
    func accentsWin() {
        var one = chorus(.wide, seed: 0x31)
        // Find an instant where the schedule wanted a reaction, and interrupt
        // it: a child finishing is news, an avatar's own thought is not.
        let scheduled = reactionStarts(one, through: 300).first ?? 30
        one.accent(.proud, at: scheduled + 0.2)
        #expect(one.sample(at: scheduled + 0.5).sequence == .proud)
    }

    // MARK: Continuity

    @Test("nothing cuts — not a reaction arriving, not one leaving")
    func handoversAreSmooth() {
        // A sequence's first step has nothing before it to morph from, so
        // without the hand-over a reaction would appear in one frame. The
        // symptom on the wall is a face that flickers rather than one that
        // changes its mind.
        for state in [BloubStateID.idle, .thinking, .alert, .notify, .wide] {
            for seed in Self.seeds.prefix(3) {
                let one = chorus(state, seed: seed)
                var previous: BloubExpression?
                var worst = 0.0
                for t in stride(from: 0.0, through: 200, by: 1.0 / 60) {
                    let face = one.sample(at: t).face
                    if let previous { worst = max(worst, distance(previous, face)) }
                    previous = face
                }
                #expect(worst < Self.cut, "\(state) jumps by \(worst)")
            }
        }
    }

    @Test("a state change does not cut either")
    func stateChangesAreSmooth() {
        var one = chorus(.idle, seed: 0x1D1E)
        one.setState(.orbit, at: 30)
        var previous: BloubExpression?
        var worst = 0.0
        for t in stride(from: 25.0, through: 45, by: 1.0 / 60) {
            let face = one.sample(at: t).face
            if let previous { worst = max(worst, distance(previous, face)) }
            previous = face
        }
        #expect(worst < Self.cut, "the change jumps by \(worst)")
    }

    // MARK: Helpers

    private func reactionStarts(
        _ one: CrewChoreographer,
        through end: Double
    ) -> [Double] {
        var starts: [Double] = []
        var wasReacting = false
        for t in stride(from: 0.0, through: end, by: 0.05) {
            let reacting = one.isReacting(at: t)
            if reacting, !wasReacting { starts.append(t) }
            wasReacting = reacting
        }
        return starts
    }

    private func distance(_ a: BloubExpression, _ b: BloubExpression) -> Double {
        abs(a.gaze.yaw - b.gaze.yaw) + abs(a.gaze.pitch - b.gaze.pitch)
            + abs(a.gaze.roll - b.gaze.roll) + abs(a.split - b.split)
            + 100 * (abs(a.eyes.0.width - b.eyes.0.width) + abs(a.eyes.0.height - b.eyes.0.height))
            + 100 * (abs(a.eyes.1.width - b.eyes.1.width) + abs(a.eyes.1.height - b.eyes.1.height))
    }
}
