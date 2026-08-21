import Foundation

/// How often the crew reacts.
///
/// One knob, three stops, and it scales **the gaps between reactions** rather
/// than the reactions themselves: a lively wall is one where things happen more
/// often, not one where every avatar moves faster. Speeding the movements up
/// instead would make a calm setting read as a slow-motion wall, which is not
/// what anybody who turns it down is asking for.
public enum CrewLiveliness: String, Codable, Sendable, Hashable, CaseIterable {
    /// A reaction every 14 to 51 seconds. For a board that is being worked
    /// beside rather than watched.
    case calm
    /// Every 8 to 30 seconds.
    case normal
    /// Every 5 to 18 seconds.
    case lively

    /// What the declared gap is multiplied by.
    public var gapScale: Double {
        switch self {
        case .calm: 1.7
        case .normal: 1
        case .lively: 0.6
        }
    }

    public static let `default` = CrewLiveliness.normal
}

/// What one avatar state asks the face to do: a loop to live in, a pool to
/// break it with, and how often.
public struct CrewBeat: Sendable, Hashable {
    /// The sequence that plays when nothing else is happening.
    public var base: AvatarSequenceID
    /// What may interrupt it. Empty means the base plays forever, which is
    /// what a session that has ended should do.
    public var reactions: [AvatarSequenceID]
    /// Seconds between one reaction starting and the next, before liveliness
    /// scales it.
    public var minGap: Double
    public var maxGap: Double

    public init(
        base: AvatarSequenceID,
        reactions: [AvatarSequenceID] = [],
        minGap: Double = 8,
        maxGap: Double = 30
    ) {
        self.base = base
        self.reactions = reactions
        self.minGap = minGap
        self.maxGap = maxGap
    }
}

/// Which beat each avatar state gets, and what a change of state is worth.
///
/// A total switch over ``BloubStateID``, like ``CrewMoodMap/shape(for:)`` and
/// for the same reason: a state added to the catalogue should fail this switch
/// rather than quietly get the idle pool.
public enum CrewChoreography {
    /// The beat for an avatar state.
    ///
    /// The states map onto Auspex's own through ``CrewMoodMap/avatarState(for:isStale:isNotifying:isSpawning:)``,
    /// so this table reads as the session states it came from:
    ///
    /// | avatar state | session state | why this pool |
    /// | --- | --- | --- |
    /// | `idle` | idle | the whole range — an idle session is the one thing on the wall that has *time* |
    /// | `wink` | stale | drowsy and asleep: something that claims to be working and has said nothing |
    /// | `thinking` | thinking | searching and confused, on a long gap: thinking is not a performance |
    /// | `orbit`, `play` | tool calls, writing | `working`, occasionally `searching` |
    /// | `wide` | delegating | `listening`, and the parent is proud or curious about its children |
    /// | `burst` | delegating, spawning | `excited` — 2.4 s of body, and the face should agree |
    /// | `alert` | waiting on you | suspicious and confused over a `listening` base, on a short gap. Never idle-looking: this is the one state that will not resolve itself |
    /// | `notify` | a turn just ended | proud, with celebration on the way in |
    /// | `sleep` | ended | asleep, and nothing interrupts it |
    public static func beat(for state: BloubStateID) -> CrewBeat {
        switch state {
        case .idle:
            CrewBeat(
                base: .idle,
                reactions: [.bored, .drowsy, .curious, .playful, .shy, .sleeping],
                minGap: 8,
                maxGap: 30
            )
        case .wink:
            // Stale. Same idle loop, a pool that has given up on it, and a
            // shorter gap, so a session that has gone quiet visibly droops
            // rather than merely stopping.
            CrewBeat(
                base: .idle,
                reactions: [.drowsy, .sleeping, .bored],
                minGap: 9,
                maxGap: 24
            )
        case .thinking:
            CrewBeat(base: .thinking, reactions: [.searching, .confused], minGap: 12, maxGap: 40)
        case .orbit, .play:
            CrewBeat(base: .working, reactions: [.searching], minGap: 12, maxGap: 40)
        case .wide:
            CrewBeat(base: .listening, reactions: [.curious, .proud], minGap: 10, maxGap: 30)
        case .burst:
            CrewBeat(base: .excited, reactions: [], minGap: 12, maxGap: 30)
        case .alert:
            // The one that must never look idle. `listening` underneath so the
            // avatar reads as *waiting on you* rather than as stuck, and a gap
            // short enough that it is always about to ask again.
            CrewBeat(
                base: .listening,
                reactions: [.suspicious, .confused],
                minGap: 5,
                maxGap: 14
            )
        case .notify:
            CrewBeat(base: .proud, reactions: [.happy, .celebrate], minGap: 6, maxGap: 16)
        case .sleep:
            // Over is over. A pool here would be a finished session miming.
            CrewBeat(base: .sleeping, reactions: [])
        case .exclaim:
            CrewBeat(base: .surprised, reactions: [.scared, .confused], minGap: 6, maxGap: 18)
        case .comet:
            CrewBeat(base: .searching, reactions: [.curious], minGap: 10, maxGap: 30)
        case .egg, .hexagon, .swirl:
            // Interface states with no session behind them. They keep the idle
            // loop so an avatar caught in one is still alive, and a narrow
            // pool so it is not putting on a show.
            CrewBeat(base: .idle, reactions: [.curious], minGap: 12, maxGap: 34)
        }
    }

    /// The one-shot that greets a change of state, if it is worth one.
    ///
    /// Not every change is. A state that is already an event — the burst, the
    /// notification — carries its own accent through the beat it lands on, and
    /// doubling it would be two announcements of one thing. What gets an accent
    /// is a change whose *meaning* is not in either pose: work starting, work
    /// stopping, a session being blocked.
    public static func accent(from: BloubStateID, to: BloubStateID) -> AvatarSequenceID? {
        switch (from, to) {
        // Blocked. The loudest thing that can happen to a session, and the one
        // the person watching has to act on.
        case (_, .alert): .surprised
        // Released: whatever it was waiting for, it got it.
        case (.alert, _): .happy
        // Handing work out.
        case (_, .burst): .excited
        // Starting to work, from anywhere that was not working.
        case (.idle, .thinking), (.idle, .orbit), (.idle, .play), (.wink, _): .excited
        case (.thinking, .orbit), (.thinking, .play): .excited
        // Finishing: the turn ended, and `notify` holds `proud` afterwards.
        case (_, .notify): .celebrate
        // Going quiet or going away.
        case (_, .sleep): .drowsy
        case (_, .wink): .drowsy
        // A session that has stopped working and has nothing to announce.
        case (.orbit, .idle), (.play, .idle), (.thinking, .idle): .bored
        default: nil
        }
    }

    /// The longest a scheduled reaction may run.
    ///
    /// avatar-lab's holds are tuned for a state that plays for as long as the
    /// avatar is in it — `bored` holds each face 3.6 s and has three of them.
    /// A *reaction* is a beat inside another animation, so it is cut at the
    /// cap. Cutting during a hold is invisible, because a hold is a still
    /// pose; the cross-fade back to the base is what makes the exit smooth.
    public static let reactionCap = 4.5

    /// The longest an accent may run. Shorter, because an accent answers an
    /// event that has already happened: it is punctuation, not a paragraph.
    public static let accentCap = 1.6

    /// How long the face takes to hand over between the base loop and a
    /// reaction, in either direction.
    ///
    /// A sequence's first step has no incoming transition — there is nothing
    /// before it to come from — so without this a reaction would *cut* in.
    ///
    /// A third of the reaction, capped: it has to be long enough that the
    /// hand-over is not itself the fastest thing on screen — the widest pair of
    /// faces in the vocabulary is about eighty degrees of gaze apart, and
    /// crossing that in a fifth of a second reads as a flicker — and short
    /// enough that a 1.5-second reaction still gets to be itself in the middle.
    public static func handover(for length: Double) -> Double {
        min(0.7, max(length / 3, 0.1))
    }
}

/// One avatar's face at one instant: which sequence is speaking and what it
/// is saying.
public struct CrewChoreographedFace: Sendable, Hashable {
    public var face: BloubExpression
    /// 1 open, 0 shut.
    public var lid: Double
    /// Which sequence the face is nearest right now.
    public var sequence: AvatarSequenceID
    /// `true` while a reaction or an accent is playing, hand-over included.
    /// The wall reads this as "in flight" and pays for the frames.
    public var isReacting: Bool
    /// `false` while any morph — a step, a hand-over — is still running.
    public var hasSettled: Bool
}

/// One session's choreography: which loop it lives in, and when it is
/// interrupted.
///
/// ## What it is for
///
/// The complaint this answers is that the wall is stiff, and the reason it was
/// stiff is that a state used to be a *pose*: every idle avatar wore the same
/// resting face for as long as it was idle, so twelve idle sessions were twelve
/// copies of one drawing. A state is a **pool and a rhythm** here — a loop to
/// live in and a schedule of one-shots to break it with — and both are drawn
/// from the session's own seed, so no two sessions are ever on the same beat.
///
/// ## Clockless, like everything under it
///
/// Every entry point takes the date; nothing is remembered except *when* each
/// thing started. So the whole schedule can be regenerated at any instant, a
/// card whose clock stopped resumes exactly where it was, and the offscreen
/// renderer reproduces a wall frame for frame. `sample(at:)` is `nonmutating`
/// and the compiler is what keeps it that way, exactly as in ``BloubEngine``.
public struct CrewChoreographer: Sendable {
    /// The session's own seed. Fixed for its life: it is an identity.
    public let seed: UInt32
    /// How often reactions come.
    public var liveliness: CrewLiveliness

    /// The beat currently being lived in, and when it started.
    public private(set) var state: BloubStateID
    private var beat: CrewBeat
    private var beatAt: Double
    /// The beat being left, kept for exactly as long as the body's own morph
    /// into the new state takes.
    ///
    /// Without it a change of state restarts the base loop at its first step,
    /// and the face **cuts** to it while the body is still easing across —
    /// measured at 13 units of face travel in one 60th of a second against 4
    /// for a normal morph. The engine keeps one slot of state history for the
    /// same reason and over the same window, so the face and the body arrive
    /// together.
    private var leaving: (beat: CrewBeat, at: Double)?
    private var leftAt: Double = -1000
    private var morph: Double = BloubTransition.shortest

    /// An explicit one-shot: a state change, a child spawning, a child
    /// finishing. Outranks whatever the schedule had planned.
    private var accentID: AvatarSequenceID?
    private var accentAt: Double = -1000

    // Salts, distinct from the player's so a reaction's schedule and its
    // contents are two independent draws.
    private static let slotSalt: UInt32 = 211
    private static let pickSalt: UInt32 = 223

    public init(
        seed: UInt32,
        state: BloubStateID,
        liveliness: CrewLiveliness = .default,
        at now: Double
    ) {
        self.seed = seed
        self.liveliness = liveliness
        self.state = state
        beat = CrewChoreography.beat(for: state)
        beatAt = now
    }

    // MARK: Dated setters

    /// A change of avatar state: a new beat, and the accent that announces it.
    public mutating func setState(_ next: BloubStateID, at now: Double) {
        guard next != state else { return }
        if let accent = CrewChoreography.accent(from: state, to: next) {
            accentID = accent
            accentAt = now
        }
        leaving = (beat, beatAt)
        leftAt = now
        morph = BloubTransition.duration(BloubStates.state(next).morph)
        state = next
        beat = CrewChoreography.beat(for: next)
        beatAt = now
    }

    /// An explicit one-shot, for something that happened *to* the session and
    /// is not a change of state — a child spawning, a child finishing.
    public mutating func accent(_ id: AvatarSequenceID, at now: Double) {
        accentID = id
        accentAt = now
    }

    /// Changes how often reactions come, without disturbing the one playing.
    public mutating func setLiveliness(_ value: CrewLiveliness) {
        liveliness = value
    }

    // MARK: Sampling

    /// The face at `now`.
    public func sample(at now: Double) -> CrewChoreographedFace {
        let base = baseFace(at: now)

        guard let interruption = interruption(at: now) else {
            return CrewChoreographedFace(
                face: base.face,
                lid: base.lid,
                sequence: beat.base,
                isReacting: false,
                hasSettled: base.hasArrived
            )
        }

        let sequence = AvatarLabPresets.sequence(interruption.id).played(.once)
        let over = AvatarSequencePlayer.sample(
            sequence,
            from: interruption.start,
            at: now,
            // A different seed for the reaction than for the base, or an
            // avatar whose tempo ran slow would react slowly too, which is one
            // personality trait too many.
            seed: seed &+ Self.pickSalt
        )

        // In and out on the same curve. Both are needed: a sequence's first
        // step has nothing before it to morph from, so it would cut in, and
        // the base has moved on underneath while the reaction played, so it
        // would cut out.
        let since = now - interruption.start
        let handover = CrewChoreography.handover(for: interruption.length)
        let left = BloubMath.smoothstep(since / handover)
        let right = BloubMath.smoothstep((interruption.length - since) / handover)
        let mix = min(left, right)

        return CrewChoreographedFace(
            face: BloubExpressions.blend(base.face, over.face, mix),
            // The lid takes whichever eye is more shut. A blink that was going
            // to happen anyway should not be cancelled by a reaction starting,
            // and a reaction's own rhythm should not be masked by the base's.
            lid: min(base.lid, over.lid),
            sequence: mix > 0.5 ? interruption.id : beat.base,
            isReacting: true,
            hasSettled: false
        )
    }

    /// The base loop at `now`, the morph out of the state being left included.
    private func baseFace(at now: Double) -> AvatarSequenceFrame {
        var frame = AvatarSequencePlayer.sample(
            AvatarLabPresets.sequence(beat.base),
            from: beatAt,
            at: now,
            seed: seed
        )
        let since = now - leftAt
        // No lower bound on `since`: `BloubTransition.curve` clamps, so a date
        // read from *before* the change gives the beat that was actually
        // playing then. Without that the choreographer would answer a past
        // instant with the state it has since moved to, and a renderer that
        // walks time backwards — or a card resuming from a stopped clock —
        // would see a cut where the live wall saw a morph. The engine makes
        // the same promise about its own state history.
        guard let leaving, since < morph else { return frame }
        let previous = AvatarSequencePlayer.sample(
            AvatarLabPresets.sequence(leaving.beat.base),
            from: leaving.at,
            at: now,
            seed: seed
        )
        frame.face = BloubExpressions.blend(
            previous.face,
            frame.face,
            BloubTransition.curve(since / morph)
        )
        frame.lid = min(previous.lid, frame.lid)
        frame.hasArrived = false
        return frame
    }

    /// Whether a reaction or an accent is playing at `now`.
    public func isReacting(at now: Double) -> Bool {
        interruption(at: now) != nil
    }

    /// Whether a blink is running at `now` or starts within `lead` of it.
    ///
    /// What lets a card that is only drifting drop to fifteen frames a second
    /// and still catch a 0.28 s blink — the same bargain
    /// ``BloubFace/blinkImminent(at:lead:)`` makes, asked of the sequence's own
    /// rhythm instead of bloub's global one.
    public func blinkImminent(at now: Double, lead: Double) -> Bool {
        AvatarSequencePlayer.blinkImminent(
            AvatarLabPresets.sequence(beat.base).blink,
            from: beatAt,
            at: now,
            lead: lead,
            seed: seed
        )
    }

    /// When the current beat began — what the driver compares against to know
    /// whether a change is still settling.
    public var startedAt: Double { beatAt }

    // MARK: The schedule

    /// A reaction or an accent, and when it started.
    private struct Interruption {
        let id: AvatarSequenceID
        let start: Double
        let length: Double
    }

    /// What is interrupting the base loop at `now`, if anything.
    ///
    /// An accent outranks the schedule: it answers something that actually
    /// happened, where a scheduled reaction is only the avatar having a
    /// thought.
    private func interruption(at now: Double) -> Interruption? {
        if let accentID {
            let length = min(
                AvatarSequencePlayer.duration(
                    of: AvatarLabPresets.sequence(accentID).played(.once),
                    seed: seed &+ Self.pickSalt
                ),
                CrewChoreography.accentCap
            )
            if now >= accentAt, now < accentAt + length {
                return Interruption(id: accentID, start: accentAt, length: length)
            }
        }
        guard !beat.reactions.isEmpty else { return nil }
        let slot = slot(at: now)
        let id = pick(slot)
        let start = slotStart(slot)
        let length = min(
            AvatarSequencePlayer.duration(
                of: AvatarLabPresets.sequence(id).played(.once),
                seed: seed &+ Self.pickSalt
            ),
            cap
        )
        guard now >= start, now < start + length else { return nil }
        return Interruption(id: id, start: start, length: length)
    }

    /// The mean gap between two reactions starting.
    private var cadence: Double {
        (beat.minGap + beat.maxGap) / 2 * liveliness.gapScale
    }

    /// How far a reaction may slide either way. A quarter of the declared
    /// window, so the realised gaps span exactly `[minGap, maxGap]` scaled —
    /// and, being under half the cadence, the slots stay in order.
    private var slack: Double {
        (beat.maxGap - beat.minGap) / 4 * liveliness.gapScale
    }

    /// The longest reaction this beat allows.
    ///
    /// Bounded by half the *shortest* gap, not by the cap alone: at the lively
    /// setting the gaps come down to five seconds, and a 4.5-second reaction
    /// inside one of those would leave no base loop between two reactions at
    /// all — the avatar would look like it was in a permanent fit.
    private var cap: Double {
        min(CrewChoreography.reactionCap, beat.minGap * liveliness.gapScale * 0.5)
    }

    /// Where reaction `index` starts.
    private func slotStart(_ index: Int) -> Double {
        let nominal = beatAt + Double(index + 1) * cadence
        guard slack > 0 else { return nominal }
        let draw = BloubRNG.value(index: index, salt: Self.slotSalt, seed: seed)
        return nominal + (draw * 2 - 1) * slack
    }

    /// Which slot `now` falls in. Negative before the first one.
    private func slot(at now: Double) -> Int {
        var index = Int(((now - beatAt) / max(cadence, 0.1)).rounded(.down)) - 1
        // At most one either way, by construction of the slack.
        while index > -1, slotStart(index) > now { index -= 1 }
        while slotStart(index + 1) <= now { index += 1 }
        return max(index, 0)
    }

    /// Which reaction slot `index` plays.
    ///
    /// A hash rather than a shuffle, so slot 412 can be asked about without
    /// having drawn the 411 before it — the same reason ``BloubRNG/value(index:salt:seed:)``
    /// exists at all.
    private func pick(_ index: Int) -> AvatarSequenceID {
        let draw = BloubRNG.value(index: index, salt: Self.pickSalt, seed: seed)
        let position = min(Int(draw * Double(beat.reactions.count)), beat.reactions.count - 1)
        return beat.reactions[position]
    }
}
