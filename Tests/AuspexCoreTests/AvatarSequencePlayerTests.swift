import AuspexCore
import Foundation
import Testing

/// What the sequence player guarantees.
///
/// The player is the piece that had to be rewritten rather than ported:
/// avatar-lab drives one avatar off a browser timer with a mutable cursor and
/// an integrated spring, and Auspex needs a wall of sixty sampled off one
/// clock, stoppable, resumable and reproducible from a screenshot renderer with
/// no window. So the assertions here are mostly about that: purity, ordering,
/// and curves that arrive exactly where they said they would.
@Suite("Avatar sequence player")
struct AvatarSequencePlayerTests {
    private static let seed: UInt32 = 0xA11C

    private func sequence(_ id: AvatarSequenceID) -> AvatarSequence {
        AvatarLabPresets.sequence(id)
    }

    // MARK: Purity

    @Test("the same instant gives the same frame")
    func deterministic() {
        let idle = sequence(.idle)
        for t in stride(from: 0.0, through: 40, by: 0.37) {
            let first = AvatarSequencePlayer.sample(idle, from: 0, at: t, seed: Self.seed)
            let second = AvatarSequencePlayer.sample(idle, from: 0, at: t, seed: Self.seed)
            #expect(first == second)
        }
    }

    @Test("sampling forwards does not change what an earlier instant returns")
    func replayable() {
        let working = sequence(.working)
        let early = AvatarSequencePlayer.sample(working, from: 0, at: 3.1, seed: Self.seed)
        for t in stride(from: 0.0, through: 60, by: 0.11) {
            _ = AvatarSequencePlayer.sample(working, from: 0, at: t, seed: Self.seed)
        }
        #expect(AvatarSequencePlayer.sample(working, from: 0, at: 3.1, seed: Self.seed) == early)
    }

    @Test("an instant before the start is the first step, not an extrapolation")
    func beforeTheStart() {
        // Without jitter there is no phase, so `t0` really is step 0 — and an
        // earlier date must give that back rather than running the schedule
        // backwards into steps the sequence never played.
        let thinking = sequence(.thinking)
        let atStart = AvatarSequencePlayer.sample(
            thinking, from: 10, at: 10, seed: Self.seed, jitter: 0
        )
        let before = AvatarSequencePlayer.sample(
            thinking, from: 10, at: 4, seed: Self.seed, jitter: 0
        )
        #expect(atStart.stepIndex == 0)
        #expect(before.stepIndex == 0)
        #expect(before.face == atStart.face)
    }

    @Test("with jitter, an avatar starts somewhere inside its own cycle")
    func phaseSpreadsTheWall() {
        // The one thing the per-segment slack cannot fix: sixty avatars that
        // all entered `idle` at step 0 would change face together for the
        // whole first cycle however different their tempos are afterwards.
        let idle = sequence(.idle)
        let firstSteps = Set((0..<60).map { seed in
            AvatarSequencePlayer.sample(idle, from: 0, at: 0, seed: UInt32(seed) &* 2_654_435_761)
                .stepIndex
        })
        #expect(firstSteps.count == idle.steps.count)
    }

    // MARK: Curves

    @Test("every curve leaves 0, arrives at exactly 1, and never overshoots")
    func curveEndpoints() {
        for style in AvatarSequenceCurve.allCases {
            #expect(AvatarSequencePlayer.curve(style, 0) == 0)
            #expect(abs(AvatarSequencePlayer.curve(style, 1) - 1) < 1e-12)
            var previous = 0.0
            for step in 0...200 {
                let value = AvatarSequencePlayer.curve(style, Double(step) / 200)
                // Monotone and inside the unit interval: a spring that
                // overshot would wobble a wall of sixty faces at once, which
                // is bloub's own rule for the body kept for the face.
                #expect(value >= previous - 1e-12, "\(style) went backwards")
                #expect(value <= 1 + 1e-12, "\(style) overshot")
                previous = value
            }
            // Clamped outside 0…1, so re-reading a date from before a step
            // change cannot extrapolate the face into nonsense.
            #expect(AvatarSequencePlayer.curve(style, -3) == 0)
            #expect(abs(AvatarSequencePlayer.curve(style, 4) - 1) < 1e-12)
        }
    }

    @Test("snappy is ahead of smooth, and the spring leaves from rest")
    func curveCharacters() {
        // Half-way through, a snappy morph is nearly there and a smooth one is
        // exactly half-way. That difference is the whole reason a step names a
        // curve at all.
        #expect(AvatarSequencePlayer.curve(.snappy, 0.5) > 0.9)
        #expect(abs(AvatarSequencePlayer.curve(.smooth, 0.5) - 0.5) < 1e-9)
        #expect(AvatarSequencePlayer.curve(.snappy, 0.6) >= 1 - 1e-12)

        // A critically damped spring starts with zero velocity — that is what
        // distinguishes it from an ease-out, which departs at full speed.
        let earlySpring = AvatarSequencePlayer.curve(.spring, 0.02)
        let earlySnappy = AvatarSequencePlayer.curve(.snappy, 0.02)
        #expect(earlySpring < earlySnappy)
        #expect(earlySpring < 0.01)
    }

    // MARK: Playback modes

    @Test("loop walks the pool and comes back round")
    func loopWalks() {
        // `idle` holds each of its two expressions for 5.2 s.
        let idle = sequence(.idle)
        let seen = stride(from: 0.0, through: 40, by: 0.25).map {
            AvatarSequencePlayer.sample(idle, from: 0, at: $0, seed: Self.seed, jitter: 0).stepIndex
        }
        #expect(Set(seen) == Set(0..<idle.steps.count))
        // And it never claims to be finished: a loop has no end.
        #expect(
            !stride(from: 0.0, through: 40, by: 0.25).contains {
                AvatarSequencePlayer.sample(idle, from: 0, at: $0, seed: Self.seed).isFinished
            }
        )
    }

    @Test("once stops on its last step and says so")
    func onceStops() {
        var celebrate = sequence(.celebrate)
        celebrate = AvatarSequence(
            id: celebrate.id,
            group: celebrate.group,
            playback: .once,
            steps: celebrate.steps,
            blink: celebrate.blink
        )
        let last = celebrate.steps.count - 1
        let length = AvatarSequencePlayer.duration(of: celebrate, seed: Self.seed, jitter: 0)
        let end = AvatarSequencePlayer.sample(
            celebrate, from: 0, at: length + 30, seed: Self.seed, jitter: 0
        )
        #expect(end.stepIndex == last)
        #expect(end.isFinished)
        // And it is not finished half-way through.
        let middle = AvatarSequencePlayer.sample(
            celebrate, from: 0, at: length / 2, seed: Self.seed, jitter: 0
        )
        #expect(!middle.isFinished)
    }

    @Test("pingPong reflects off both ends instead of jumping back")
    func pingPongReflects() {
        let source = sequence(.searching)
        let pinged = AvatarSequence(
            id: source.id,
            group: source.group,
            playback: .pingPong,
            steps: source.steps,
            blink: source.blink
        )
        let hold = source.steps[0].hold
        var walk: [Int] = []
        for segment in 0..<(4 * source.steps.count) {
            let at = (Double(segment) + 0.95) * hold
            let index = AvatarSequencePlayer.sample(
                pinged, from: 0, at: at, seed: Self.seed, jitter: 0
            ).stepIndex
            if walk.last != index { walk.append(index) }
        }
        // Consecutive steps only ever differ by one: that is what "reflects"
        // means, and a modulo would show a fall from the last index to 0.
        for pair in zip(walk, walk.dropFirst()) {
            #expect(abs(pair.0 - pair.1) == 1, "\(walk)")
        }
        #expect(walk.contains(source.steps.count - 1))
        #expect(walk.dropFirst().contains(0))
    }

    // MARK: Jitter

    @Test("the boundaries stay in order however hard they are jittered")
    func boundariesStayOrdered() {
        // The whole trick is that jitter is on the boundary, not the interval.
        // It only survives while the slack stays under half the shortest hold,
        // and the symptom of getting that wrong is a segment that is skipped or
        // replayed — visible as an avatar that twitches once and settles wrong.
        for id in AvatarSequenceID.allCases {
            let sequence = AvatarLabPresets.sequence(id)
            for seed in [UInt32(1), 7, 0xBEEF, 0xFFFF_FF00] {
                // From wherever the phase put it, not from zero: an avatar
                // enters a loop somewhere inside its own cycle on purpose.
                var previous = AvatarSequencePlayer.sample(
                    sequence, from: 0, at: 0, seed: seed
                ).segment
                var seen: Set<Int> = []
                for t in stride(from: 0.0, through: 90, by: 0.05) {
                    let segment = AvatarSequencePlayer.sample(
                        sequence, from: 0, at: t, seed: seed
                    ).segment
                    #expect(segment >= previous, "\(id) went backwards in time")
                    #expect(segment <= previous + 1, "\(id) skipped a segment")
                    seen.insert(segment)
                    previous = segment
                }
                #expect(seen.count > 1, "\(id) never advanced")
            }
        }
    }

    @Test("two seeds fall out of step within one cycle")
    func seedsDiverge() {
        let idle = sequence(.idle)
        let a = UInt32(0x1111)
        let b = UInt32(0x2222)
        var disagreements = 0
        var samples = 0
        for t in stride(from: 0.0, through: 60, by: 0.1) {
            let left = AvatarSequencePlayer.sample(idle, from: 0, at: t, seed: a)
            let right = AvatarSequencePlayer.sample(idle, from: 0, at: t, seed: b)
            samples += 1
            if left.face != right.face { disagreements += 1 }
        }
        // Not "they are different somewhere" — "they are different most of the
        // time", which is what stops a wall reading as one animation.
        #expect(Double(disagreements) / Double(samples) > 0.5)
    }

    @Test("jitter moves the timing without changing the sequence")
    func jitterStaysInBand() {
        let working = sequence(.working)
        let plain = AvatarSequencePlayer.duration(of: working, seed: Self.seed, jitter: 0)
        for seed in [UInt32(3), 0x5555, 0xC0DE, 0x9999] {
            let jittered = AvatarSequencePlayer.duration(of: working, seed: seed)
            // One pass is still one pass: the jitter is on the boundaries
            // inside it, so the pass length moves by at most the slack.
            #expect(abs(jittered - plain) < plain * 0.25)
            // And every step is still visited.
            let seen = Set(
                stride(from: 0.0, through: plain * 2, by: 0.1).map {
                    AvatarSequencePlayer.sample(working, from: 0, at: $0, seed: seed).stepIndex
                }
            )
            #expect(seen == Set(0..<working.steps.count))
        }
    }

    // MARK: Blinks

    @Test("a sequence blinks on its own rhythm, inside its own window")
    func blinkRhythm() {
        for id in AvatarSequenceID.allCases {
            let blink = AvatarLabPresets.sequence(id).blink
            var starts: [Double] = []
            var wasShut = false
            for t in stride(from: 0.0, through: 120, by: 0.01) {
                let lid = AvatarSequencePlayer.lid(blink, from: 0, at: t, seed: Self.seed)
                #expect(lid >= 0 && lid <= 1)
                let shut = lid < 1
                if shut, !wasShut { starts.append(t) }
                wasShut = shut
            }
            #expect(starts.count > 5, "\(id) barely blinks in two minutes")
            #expect(starts[0] >= blink.initialDelay - blink.maxInterval)
            for gap in zip(starts, starts.dropFirst()).map({ $0.1 - $0.0 }) {
                // The realised gaps land inside the declared window, which is
                // the point of putting the slack at a quarter of it.
                #expect(gap > blink.minInterval - 0.05, "\(id) blinked after \(gap)s")
                #expect(gap < blink.maxInterval + 0.05, "\(id) blinked after \(gap)s")
            }
        }
    }

    @Test("a blink actually shuts the eye")
    func blinkShuts() {
        let blink = AvatarLabPresets.sequence(.idle).blink
        let lowest = stride(from: 0.0, through: 60, by: 0.005)
            .map { AvatarSequencePlayer.lid(blink, from: 0, at: $0, seed: Self.seed) }
            .min() ?? 1
        // `BloubFace.lidCurve` is shut at 45 % of the blink; a schedule that
        // never lands near that point would give a wall of avatars that flutter
        // without ever closing.
        #expect(lowest < 0.05)
    }

    @Test("a blink is announced before it arrives")
    func blinkImminent() {
        // What lets a card sampling fifteen times a second go back to sixty in
        // time to draw a 0.28 s blink — the same bargain `BloubFace` makes.
        let blink = AvatarLabPresets.sequence(.idle).blink
        var announced = 0
        var arrived = 0
        for t in stride(from: 0.0, through: 90, by: 1.0 / 15) {
            let warned = AvatarSequencePlayer.blinkImminent(
                blink, from: 0, at: t, lead: 0.25, seed: Self.seed
            )
            let shut = AvatarSequencePlayer.lid(blink, from: 0, at: t + 0.25, seed: Self.seed) < 1
            if warned { announced += 1 }
            if shut {
                arrived += 1
                #expect(warned, "a blink at \(t + 0.25)s was not announced")
            }
        }
        #expect(arrived > 5)
        #expect(announced >= arrived)
    }

    @Test("two seeds do not blink together")
    func blinksDiverge() {
        let blink = AvatarLabPresets.sequence(.idle).blink
        var together = 0
        var either = 0
        for t in stride(from: 0.0, through: 120, by: 0.02) {
            let left = AvatarSequencePlayer.lid(blink, from: 0, at: t, seed: 0x1234) < 1
            let right = AvatarSequencePlayer.lid(blink, from: 0, at: t, seed: 0x8765) < 1
            if left || right { either += 1 }
            if left, right { together += 1 }
        }
        #expect(either > 0)
        #expect(Double(together) / Double(either) < 0.3)
    }

    // MARK: Continuity

    @Test("no step change moves the face in a jump")
    func facesAreContinuous() {
        // A sequence is a wall's worth of small movements; one that stepped
        // would read as a glitch rather than as a face changing its mind.
        for id in AvatarSequenceID.allCases {
            let sequence = AvatarLabPresets.sequence(id)
            var previous: BloubExpression?
            var worst = 0.0
            for t in stride(from: 0.0, through: 45, by: 1.0 / 60) {
                let face = AvatarSequencePlayer.sample(
                    sequence, from: 0, at: t, seed: Self.seed
                ).face
                if let previous { worst = max(worst, distance(previous, face)) }
                previous = face
            }
            // Measured against the sequence's own biggest step, not against an
            // absolute number: a cut would move the whole distance in one
            // frame. An eased 0.5 s morph at 60 fps moves at most about 7 % of
            // it per frame, so a quarter is a wide margin around "no cuts" and
            // still catches one.
            let widest = widestStep(sequence)
            // `waking` names a single expression, so it has nothing to move
            // between and must not move at all.
            if widest > 0 {
                #expect(worst < 0.25 * widest, "\(id) jumps \(worst) of \(widest)")
            } else {
                #expect(worst == 0, "\(id) moves without a second face to move to")
            }
        }
    }

    /// The biggest distance between any two faces the sequence names.
    private func widestStep(_ sequence: AvatarSequence) -> Double {
        let faces = sequence.steps.map { AvatarLabFace.face(id: $0.expressionID) }
        var widest = 0.0
        for left in faces {
            for right in faces { widest = max(widest, distance(left, right)) }
        }
        return widest
    }

    private func distance(_ a: BloubExpression, _ b: BloubExpression) -> Double {
        abs(a.gaze.yaw - b.gaze.yaw) + abs(a.gaze.pitch - b.gaze.pitch)
            + abs(a.gaze.roll - b.gaze.roll) + abs(a.split - b.split)
            + 100 * (abs(a.eyes.0.width - b.eyes.0.width) + abs(a.eyes.0.height - b.eyes.0.height))
            + 100 * (abs(a.eyes.1.width - b.eyes.1.width) + abs(a.eyes.1.height - b.eyes.1.height))
    }
}
