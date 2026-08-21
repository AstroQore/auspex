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
        _ stance: CrewStance,
        seed: UInt32,
        liveliness: CrewLiveliness = .normal
    ) -> CrewChoreographer {
        CrewChoreographer(seed: seed, stance: stance, liveliness: liveliness, at: 0)
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

    @Test("every stance plays only what its own beat allows")
    func poolsAreRespected() {
        for stance in CrewStance.allCases {
            let beat = CrewChoreography.beat(for: stance)
            for seed in Self.seeds.prefix(4) {
                let one = chorus(stance, seed: seed)
                let played = Set(
                    stride(from: 0.0, through: 300, by: 0.25).map { one.sample(at: $0).sequence }
                )
                #expect(played.isSubset(of: beat.vocabulary), "\(stance) played \(played)")
                // And the pool is actually used, not merely permitted.
                if !beat.reactions.isEmpty {
                    #expect(played.count > 1, "\(stance) never left its base loop")
                }
            }
        }
    }

    /// Every stance is a *pool*, never one animation. A stance that named a
    /// single sequence would put every session in it on the same loop, and
    /// twelve working sessions would be twelve copies of one drawing again —
    /// only a busier one. The two exceptions each earn it: a spawn is 2.4
    /// seconds and already an event, and a session that has ended is asleep.
    @Test("every stance a session lives in is a pool, not one animation")
    func stancesArePools() {
        for stance in CrewStance.allCases where stance != .spawning && stance != .ended {
            let beat = CrewChoreography.beat(for: stance)
            #expect(beat.reactions.count >= 2, "\(stance) has \(beat.reactions.count) reactions")
            #expect(beat.vocabulary.count >= 3, "\(stance) can only show \(beat.vocabulary)")
        }
    }

    /// The pools the user asked for, spelled out. Not a tautology: this is the
    /// product decision, and it is the thing a refactor would quietly drift.
    @Test("the pools say what the crew was asked to say")
    func poolTable() {
        func pool(_ stance: CrewStance) -> Set<AvatarSequenceID> {
            Set(CrewChoreography.beat(for: stance).reactions.map(\.id))
        }
        #expect(CrewChoreography.beat(for: .thinking).base == .thinking)
        #expect(pool(.thinking) == [.searching, .curious, .confused])
        #expect(CrewChoreography.beat(for: .working).base == .working)
        #expect(pool(.working) == [.searching, .thinking, .proud])
        #expect(CrewChoreography.beat(for: .delegating).base == .listening)
        #expect(pool(.delegating) == [.working, .curious])
        #expect(CrewChoreography.beat(for: .blocked).base == .listening)
        #expect(pool(.blocked) == [.surprised, .suspicious, .confused, .scared])
        #expect(pool(.celebrating) == [.proud, .laughing, .celebrate])
        #expect(pool(.idle) == [.bored, .drowsy, .playful, .shy, .curious])
        #expect(pool(.stale) == [.drowsy, .sleeping, .bored, .waking])
        #expect(CrewChoreography.beat(for: .ended).base == .sleeping)
        #expect(pool(.ended).isEmpty)
    }

    /// "Rare" is part of the choreography. A session that looked *confused*
    /// every third thought would be one nobody trusts; one that never did
    /// would be a metronome.
    @Test("the rare reactions really are rare, and really do happen")
    func weightsAreHonoured() {
        for (stance, rare) in [(CrewStance.thinking, AvatarSequenceID.confused),
                               (.working, .proud),
                               (.blocked, .scared)] {
            var seen: [AvatarSequenceID: Int] = [:]
            for seed in Self.seeds {
                let one = chorus(stance, seed: seed)
                var wasReacting = false
                for t in stride(from: 0.0, through: 900, by: 0.1) {
                    let reacting = one.isReacting(at: t)
                    if reacting, !wasReacting {
                        seen[one.sample(at: t + 0.6).sequence, default: 0] += 1
                    }
                    wasReacting = reacting
                }
            }
            let total = seen.values.reduce(0, +)
            let rareCount = seen[rare] ?? 0
            #expect(rareCount > 0, "\(stance) never showed \(rare)")
            #expect(
                Double(rareCount) / Double(total) < 0.2,
                "\(stance) showed \(rare) \(rareCount)/\(total) times"
            )
        }
    }

    @Test("a session waiting on you never looks idle")
    func blockedIsNeverIdle() {
        // `blocked` is the one stance that will not resolve itself, so the face
        // has to keep asking. A single frame of the idle loop here would read
        // as a session that had given up.
        let beat = CrewChoreography.beat(for: .blocked)
        #expect(beat.vocabulary.isDisjoint(with: [.idle, .sleeping, .drowsy, .bored]))
        // And it asks often: the gap is the shortest on the board.
        for stance in CrewStance.allCases where stance != .blocked {
            let other = CrewChoreography.beat(for: stance)
            #expect(beat.minGap <= other.minGap || other.reactions.isEmpty)
        }
    }

    @Test("a session that has ended sleeps, does not blink, and stays asleep")
    func endedSleeps() {
        let one = chorus(.ended, seed: 0x42)
        for t in stride(from: 0.0, through: 400, by: 0.5) {
            let face = one.sample(at: t)
            #expect(face.sequence == .sleeping)
            #expect(face.lid == 1, "an ended session blinked at \(t)")
            #expect(!one.isReacting(at: t))
            #expect(!one.blinkImminent(at: t, lead: 0.25))
        }
    }

    /// Idle is awake and ended is asleep, and that difference has to be
    /// visible without reading a word. Awake means open eyes, a blink and the
    /// occasional reaction; asleep means none of the three.
    @Test("idle is awake where ended is asleep")
    func idleIsNotEnded() {
        let awake = chorus(.idle, seed: 0x5150)
        let asleep = chorus(.ended, seed: 0x5150)
        var awakeBlinks = 0
        var asleepBlinks = 0
        var awakeReactions = 0
        for t in stride(from: 0.0, through: 300, by: 0.05) {
            if awake.sample(at: t).lid < 0.9 { awakeBlinks += 1 }
            if asleep.sample(at: t).lid < 0.9 { asleepBlinks += 1 }
            if awake.isReacting(at: t) { awakeReactions += 1 }
        }
        #expect(awakeBlinks > 0)
        #expect(asleepBlinks == 0)
        #expect(awakeReactions > 0)
        // And the eyes really are more closed: `sleeping` walks the three
        // flattest expressions in the vocabulary.
        let open = awake.sample(at: 30).face
        let shut = asleep.sample(at: 30).face
        #expect(shut.eyes.0.height < open.eyes.0.height)
    }

    /// Stale is drooping but not dead: it may still come back, so `waking` is
    /// in the pool.
    @Test("a stale session's pool has given up on it, but not entirely")
    func staleDroops() {
        let beat = CrewChoreography.beat(for: .stale)
        #expect(Set(beat.reactions.map(\.id)) == Set([.drowsy, .sleeping, .bored, .waking]))
        #expect(beat.base == .idle)
        #expect(beat.blinks)
    }

    // MARK: The rhythm

    @Test("the gaps between reactions land inside the declared window")
    func gapsAreInBand() {
        for state in [CrewStance.idle, .thinking, .blocked, .delegating, .celebrating] {
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
        for state in [CrewStance.idle, .thinking, .delegating] {
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
        for state in CrewStance.allCases {
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

    @Test("a change of stance is announced by the face")
    func stateChangesAccent() {
        var one = chorus(.thinking, seed: 0x77)
        one.setStance(.blocked, at: 40)
        // In flight immediately — the hand-over starts on the frame of the
        // change — and speaking by the time it has crossed.
        #expect(one.isReacting(at: 40.01))
        #expect(one.sample(at: 40.8).sequence == .surprised)
        #expect(!one.isReacting(at: 40 + CrewChoreography.accentCap + 0.1))
        // And it hands back to the beat the new stance asked for.
        let beat = CrewChoreography.beat(for: .blocked)
        #expect(one.sample(at: 40 + CrewChoreography.accentCap + 0.1).sequence == beat.base)
    }

    @Test("the accents cover the changes that mean something")
    func accentTable() {
        #expect(CrewChoreography.accent(from: .idle, to: .blocked) == .surprised)
        #expect(CrewChoreography.accent(from: .working, to: .blocked) == .surprised)
        #expect(CrewChoreography.accent(from: .blocked, to: .working) == .happy)
        #expect(CrewChoreography.accent(from: .thinking, to: .working) == .excited)
        #expect(CrewChoreography.accent(from: .idle, to: .thinking) == .excited)
        #expect(CrewChoreography.accent(from: .working, to: .idle) == .bored)
        #expect(CrewChoreography.accent(from: .working, to: .stale) == .drowsy)
        // Falling asleep, rather than merely looking drowsy: the eyes close on
        // the way in and stay closed.
        #expect(CrewChoreography.accent(from: .working, to: .ended) == .sleeping)
        // A change that is already its own announcement gets nothing extra.
        #expect(CrewChoreography.accent(from: .delegating, to: .spawning) == nil)
        #expect(CrewChoreography.accent(from: .idle, to: .celebrating) == nil)
    }

    /// An avatar whose eyes snapped shut would read as a crash rather than as a
    /// session finishing, so falling asleep gets the long end of the band.
    @Test("falling asleep takes longer than any other change")
    func endedMorphsSlowly() {
        for stance in CrewStance.allCases where stance != .ended {
            #expect(CrewChoreography.morph(into: .ended) > CrewChoreography.morph(into: stance))
        }
    }

    @Test("an explicit accent outranks whatever the schedule had planned")
    func accentsWin() {
        var one = chorus(.delegating, seed: 0x31)
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
        for state in [CrewStance.idle, .thinking, .blocked, .celebrating, .delegating] {
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

    @Test("a change of stance does not cut either")
    func stateChangesAreSmooth() {
        var one = chorus(.idle, seed: 0x1D1E)
        one.setStance(.working, at: 30)
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
