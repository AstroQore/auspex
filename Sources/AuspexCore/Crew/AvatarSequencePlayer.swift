import Foundation

/// One instant of a sequence: the face to draw and the lid to draw it behind.
public struct AvatarSequenceFrame: Sendable, Hashable {
    /// The blended face at this instant.
    public var face: BloubExpression
    /// 1 open, 0 shut — the sequence's **own** blink rhythm, which replaces
    /// bloub's global schedule while a sequence is playing.
    public var lid: Double
    /// Which step is being played, as an index into the sequence's steps.
    public var stepIndex: Int
    /// How many step boundaries have gone by since the sequence started. Rises
    /// forever on a loop; stops at the last step on a `once`. Exposed because
    /// it is the only way to check from outside that the jittered schedule
    /// never skips a beat or runs backwards.
    public var segment: Int
    /// `false` while the morph into `stepIndex` is still running.
    public var hasArrived: Bool
    /// `true` for a `once` sequence that has reached and held its last step.
    public var isFinished: Bool
}

/// Plays one of avatar-lab's sequences as a **seeded pure function of time**.
///
/// ## Why this is not avatar-lab's player
///
/// avatar-lab drives a single avatar in a browser: `playback.ts` keeps a
/// mutable cursor, schedules the next step on a timer, and springs between
/// expressions with a physics animation that is integrated frame by frame.
/// Auspex draws up to sixty avatars off one clock, has to be able to render a
/// reproducible screenshot with no window, and must be able to *stop* an
/// avatar's clock entirely when its card is off screen and resume it later on
/// the same frame it left. None of that survives a mutable cursor or an
/// integrated spring — the same rule ``BloubEngine`` is built on, and for the
/// same reasons.
///
/// So the whole schedule is **regenerated from the seed on every sample**:
/// `sample(_:from:at:seed:)` reads no state, mutates nothing, and answering the
/// same instant twice gives the same face back.
///
/// ## Where the randomness is
///
/// Jitter is applied to the **boundaries**, never to the intervals, exactly as
/// ``BloubFace`` does for the resting gaze's random walk. Jittering intervals
/// would mean summing them from zero to know which step `t` falls in, which is
/// a walk — O(t) and not a function. Jittering boundaries keeps the segment
/// holding `t` a division give or take one step, and the boundaries stay in
/// order as long as the jitter stays under half the shortest hold, which
/// ``jitterFraction`` guarantees.
///
/// The seed is mixed with the sequence's id, so one avatar playing `idle` and
/// then `bored` does not replay the same jitter pattern under a different
/// name.
public enum AvatarSequencePlayer {
    /// How far a duration may stray, either way. The brief's ±25 %: enough
    /// that two avatars on the same sequence visibly fall out of step within
    /// one cycle, little enough that a sequence still reads as the sequence it
    /// is.
    public static let jitterFraction = 0.25

    // Salts. Distinct so that the hold schedule, the transition lengths and
    // the blink rhythm are three independent draws rather than one shifted
    // three ways — a single salt gives avatars whose blinks land on their
    // step changes, which reads as a tic.
    private static let holdSalt: UInt32 = 101
    private static let transitionSalt: UInt32 = 103
    private static let blinkSalt: UInt32 = 107
    private static let phaseSalt: UInt32 = 109
    private static let rateSalt: UInt32 = 113

    // MARK: Curves

    /// How far along a morph is, for a step's declared curve.
    ///
    /// All three leave 0 at `u = 0`, reach exactly 1 at `u = 1`, rise
    /// monotonically and **never overshoot**. That last one is bloub's rule for
    /// the body and it is kept for the face: the engine's only spring is the
    /// notification pastille's local pop, and a face that sprang past its
    /// target would wobble a wall of sixty avatars at once.
    @inlinable
    public static func curve(_ style: AvatarSequenceCurve, _ u: Double) -> Double {
        let k = BloubMath.clamp(u)
        switch style {
        case .smooth:
            // The classic S. Leaves rest, arrives at rest.
            return BloubMath.easeInOutCubic(k)
        case .snappy:
            // Short and front-loaded: the morph is over in 60 % of the step's
            // nominal transition and the rest of it is hold. Used where a face
            // should *snap* to attention rather than glide there.
            return BloubMath.easeOutQuint(BloubMath.clamp(k / 0.6))
        case .spring:
            // A **critically damped** spring, sampled in closed form rather
            // than integrated: x(t) = 1 - (1 + ωt)·e^(−ωt), which is the exact
            // step response of ẍ + 2ωẋ + ω²x = ω². ω is chosen so the spring
            // is 98.3 % settled at u = 1, and the whole curve is then
            // normalised so it arrives at exactly 1 — a spring that stopped at
            // 0.983 would leave a permanent 1.7 % error in the face.
            //
            // Critically damped, so no overshoot and no oscillation. An
            // underdamped spring would look livelier for one avatar and like a
            // shiver across a wall of them.
            let decay = 6.0
            let raw = 1 - (1 + decay * k) * exp(-decay * k)
            let settled = 1 - (1 + decay) * exp(-decay)
            return raw / settled
        }
    }

    // MARK: Sampling

    /// The sequence's frame at `t`, having started at `t0`.
    ///
    /// - Parameters:
    ///   - jitter: 0 plays the sequence at its declared timings, which is what
    ///     a golden test wants. The wall uses ``jitterFraction``.
    public static func sample(
        _ sequence: AvatarSequence,
        from t0: Double,
        at t: Double,
        seed: UInt32,
        jitter: Double = jitterFraction
    ) -> AvatarSequenceFrame {
        let plan = Plan(sequence, seed: seed, jitter: jitter)
        // A `once` sequence really does stop: its segments are clamped to the
        // last step, so `since` goes on growing and the step stays arrived.
        // Letting the counter run instead would re-enter the last step over
        // and over — the face would not move, but nothing would ever report
        // itself finished and the choreographer would never hand back.
        let segment = plan.clamped(plan.segment(containing: t, from: t0))
        let index = plan.step(at: segment)
        let previous = plan.step(at: segment - 1)
        let step = sequence.steps[index]

        let since = t - plan.boundary(segment, from: t0)
        let span = plan.transition(segment, of: step)
        let progress = span > 0 ? BloubMath.clamp(since / span) : 1
        let face = index == previous
            ? AvatarLabFace.face(id: step.expressionID)
            : BloubExpressions.blend(
                AvatarLabFace.face(id: sequence.steps[previous].expressionID),
                AvatarLabFace.face(id: step.expressionID),
                curve(step.curve, progress)
            )

        return AvatarSequenceFrame(
            face: face,
            lid: lid(sequence.blink, from: t0, at: t, seed: seed, jitter: jitter),
            stepIndex: index,
            segment: segment,
            hasArrived: progress >= 1,
            isFinished: sequence.playback == .once
                && segment >= sequence.steps.count - 1
                && progress >= 1
        )
    }

    /// How long one full pass of a sequence takes, jitter included — every
    /// step reached *and* held.
    ///
    /// What the choreographer schedules a one-shot reaction against: a reaction
    /// that handed back before its last step had been held would read as an
    /// interruption rather than as a beat.
    public static func duration(
        of sequence: AvatarSequence,
        seed: UInt32,
        jitter: Double = jitterFraction
    ) -> Double {
        // The pass itself, not the last boundary: the phase says where in the
        // cycle this avatar happens to be, and how long a pass takes is not a
        // fact about where it started.
        AvatarSequencePlayer.Plan(sequence, seed: seed, jitter: jitter).pass
    }

    // MARK: Blinks

    /// The lid at `t` for a sequence's own blink rhythm.
    ///
    /// Pre-drawn from the seed like everything else here, and for the reason
    /// ``BloubFace/blinkImminent(at:lead:)`` gives: a wall that samples a
    /// resting avatar fifteen times a second has to be able to ask when the
    /// *next* blink is, which is only a question you can answer about a
    /// schedule that already exists.
    public static func lid(
        _ blink: AvatarBlinkRhythm,
        from t0: Double,
        at t: Double,
        seed: UInt32,
        jitter: Double = jitterFraction
    ) -> Double {
        guard blink.isEnabled, blink.duration > 0 else { return 1 }
        let schedule = BlinkSchedule(blink, seed: seed, jitter: jitter)
        guard let start = schedule.startCovering(t, from: t0) else { return 1 }
        return BloubFace.lidCurve((t - start) / blink.duration)
    }

    /// Whether a blink is running at `t` or starts within `lead` of it.
    public static func blinkImminent(
        _ blink: AvatarBlinkRhythm,
        from t0: Double,
        at t: Double,
        lead: Double,
        seed: UInt32,
        jitter: Double = jitterFraction
    ) -> Bool {
        guard blink.isEnabled, blink.duration > 0 else { return false }
        let schedule = BlinkSchedule(blink, seed: seed, jitter: jitter)
        return schedule.startCovering(t, from: t0, lead: lead) != nil
    }

    // MARK: The schedules

    /// A sequence's step schedule, regenerated from the seed.
    fileprivate struct Plan {
        let sequence: AvatarSequence
        let seed: UInt32
        let jitter: Double
        /// Cumulative nominal holds. `prefix[i]` is where step `i` starts
        /// inside one pass; `prefix[count]` is the pass's length.
        let prefix: [Double]
        /// How far a boundary may slide. Strictly under half the shortest
        /// hold, which is what keeps the boundaries in order.
        let slack: Double
        /// This avatar's own tempo, 0.75 to 1.25 of the declared one.
        ///
        /// The per-segment slack alone is **not** enough to break lockstep, and
        /// that was measured rather than assumed: two avatars on `idle`, whose
        /// steps are held 5.2 s, agreed on the face 84 % of the time, because a
        /// boundary that may slide 0.65 s either way still lands within a
        /// second of the other avatar's. A tempo is a *rate* difference: two
        /// avatars drift a whole step apart within a couple of cycles and never
        /// come back.
        let rate: Double
        /// Where in its own cycle this avatar starts.
        ///
        /// A loop that every avatar entered at step 0 would still have a wall
        /// changing face together for the first cycle, however different the
        /// tempos are afterwards. A `once` sequence gets no phase: a reaction
        /// that started half-way through would be a beat with its head cut off.
        let phase: Double

        init(_ sequence: AvatarSequence, seed: UInt32, jitter: Double) {
            self.sequence = sequence
            // The sequence's own id mixed in, so an avatar that switches
            // sequences gets a fresh schedule rather than the same one
            // relabelled.
            let seed = seed &+ AvatarSequencePlayer.salt(of: sequence.id)
            self.seed = seed
            self.jitter = jitter
            let rate = jitter > 0
                ? 1 + (BloubRNG.value(index: 0, salt: AvatarSequencePlayer.rateSalt, seed: seed)
                    * 2 - 1) * jitter
                : 1
            self.rate = rate
            var running = [0.0]
            for step in sequence.steps {
                running.append(running[running.count - 1] + step.hold * rate)
            }
            prefix = running
            let shortest = (sequence.steps.map(\.hold).min() ?? 1) * rate
            slack = jitter * 0.5 * shortest
            phase = jitter > 0 && sequence.playback != .once
                ? BloubRNG.value(index: 0, salt: AvatarSequencePlayer.phaseSalt, seed: seed)
                    * running[running.count - 1]
                : 0
        }

        var count: Int { sequence.steps.count }
        var pass: Double { max(prefix[count], 1e-6) }

        /// Where segment `index` starts. Segments run past the end of one pass
        /// and keep counting, which is what makes `loop` and `pingPong` a
        /// matter of *reading* the index rather than of resetting anything.
        func boundary(_ index: Int, from t0: Double) -> Double {
            let passes = Int((Double(index) / Double(count)).rounded(.down))
            let within = index - passes * count
            let nominal = t0 - phase + Double(passes) * pass + prefix[within]
            guard slack > 0 else { return nominal }
            let draw = BloubRNG.value(
                index: index,
                salt: AvatarSequencePlayer.holdSalt,
                seed: seed
            )
            return nominal + (draw * 2 - 1) * slack
        }

        /// The segment holding `t`. Never below 0: a sequence asked about an
        /// instant before it began answers with its first step rather than
        /// extrapolating backwards into one it never played.
        func segment(containing t: Double, from t0: Double) -> Int {
            let elapsed = t - t0 + phase
            guard elapsed > 0 else { return 0 }
            let passes = Int((elapsed / pass).rounded(.down))
            let within = elapsed - Double(passes) * pass
            var index = passes * count
            // `prefix` is short — no sequence has more than six steps — so a
            // scan is cheaper than a search and has no boundary cases.
            for step in 0..<count where prefix[step] <= within { index = passes * count + step }
            // At most one step either way, by construction of the slack.
            while index > 0, boundary(index, from: t0) > t { index -= 1 }
            while boundary(index + 1, from: t0) <= t { index += 1 }
            return max(index, 0)
        }

        /// A `once` sequence's segments stop at its last step.
        func clamped(_ segment: Int) -> Int {
            sequence.playback == .once ? min(segment, count - 1) : segment
        }

        /// Which step a segment plays. This is the whole of `playbackMode`.
        func step(at segment: Int) -> Int {
            guard count > 1 else { return 0 }
            switch sequence.playback {
            case .loop:
                return ((segment % count) + count) % count
            case .once:
                return min(max(segment, 0), count - 1)
            case .pingPong:
                let period = 2 * count - 2
                let position = ((segment % period) + period) % period
                return position < count ? position : period - position
            }
        }

        /// How long the morph into a segment takes.
        func transition(_ index: Int, of step: AvatarSequenceStep) -> Double {
            guard jitter > 0 else { return step.transition }
            let draw = BloubRNG.value(
                index: index,
                salt: AvatarSequencePlayer.transitionSalt,
                seed: seed
            )
            let scaled = step.transition * rate * (1 + (draw * 2 - 1) * jitter)
            // A transition longer than the hold would mean a step that is left
            // before it is ever reached.
            return min(max(scaled, 0.02), step.hold * rate * 0.9)
        }
    }

    /// A blink rhythm, regenerated from the seed.
    private struct BlinkSchedule {
        let blink: AvatarBlinkRhythm
        let seed: UInt32
        /// Mean gap between two blinks.
        let cadence: Double
        /// How far a blink may slide. A quarter of the window either way, so
        /// the realised gaps span exactly `[minInterval, maxInterval]` and the
        /// boundaries stay ordered.
        let slack: Double
        /// How far into its own rhythm this avatar starts. Without it a wall
        /// of avatars that all began at the same instant would blink together
        /// for the first minute, however different their cadences are after
        /// that.
        let phase: Double

        init(_ blink: AvatarBlinkRhythm, seed: UInt32, jitter: Double) {
            self.blink = blink
            let seed = seed &+ AvatarSequencePlayer.blinkSalt
            self.seed = seed
            cadence = max((blink.minInterval + blink.maxInterval) / 2, 0.1)
            slack = (blink.maxInterval - blink.minInterval) / 4 * (jitter > 0 ? 1 : 0)
            phase = jitter > 0
                ? BloubRNG.value(index: 0, salt: AvatarSequencePlayer.phaseSalt, seed: seed)
                    * cadence
                : 0
        }

        func start(_ index: Int) -> Double {
            let nominal = blink.initialDelay - phase + Double(index) * cadence
            guard slack > 0 else { return nominal }
            let draw = BloubRNG.value(
                index: index,
                salt: AvatarSequencePlayer.blinkSalt,
                seed: seed
            )
            return nominal + (draw * 2 - 1) * slack
        }

        /// The start of the blink covering `t`, if there is one.
        ///
        /// - Parameter lead: how far *ahead* of `t` to look. Zero asks "is a
        ///   blink running right now", which is what the lid needs; a lead asks
        ///   "is one running or about to start", which is what a card sampling
        ///   fifteen times a second needs in order to go back to sixty in time
        ///   to draw it.
        ///
        ///   The two windows have to be one function and they have to overlap.
        ///   Asking the question about `t + lead` with a window of `lead`
        ///   instead — which is what this did first — leaves a hole: a blink
        ///   that started more than `lead - duration` ago is still shutting the
        ///   eye and is no longer announced, so the card drops to fifteen
        ///   frames in the middle of it and the blink reads as a glitch.
        func startCovering(_ t: Double, from t0: Double, lead: Double = 0) -> Double? {
            let elapsed = t - t0
            let guess = Int(((elapsed - blink.initialDelay + phase) / cadence).rounded())
            for index in max(0, guess - 1)...(max(0, guess) + 2) {
                let at = start(index)
                if at <= elapsed + lead, elapsed < at + blink.duration {
                    return t0 + at
                }
            }
            return nil
        }
    }

    /// A stable salt per sequence, so two sequences never share a schedule.
    ///
    /// FNV-1a over the raw value rather than `hashValue`: Swift seeds its
    /// hasher per process, and a schedule that changed on every launch would
    /// be a wall that moves differently every morning for no reason — the same
    /// trap ``CrewRoster`` names.
    static func salt(of id: AvatarSequenceID) -> UInt32 {
        var hash: UInt32 = 0x811c_9dc5
        for byte in id.rawValue.utf8 {
            hash ^= UInt32(byte)
            hash = hash &* 0x0100_0193
        }
        return hash
    }
}
