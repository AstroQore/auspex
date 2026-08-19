import AgentSessionKit
import AgentSessionLive
import Foundation

/// What one session looks like as a crew avatar: a body shape, an animation
/// state, and a resting expression.
///
/// Identity and activity travel in separate channels, the same split the board
/// uses. The **shape** says which harness this is and never changes for the
/// life of a session; the **state** says what it is doing right now. So a
/// person learns eight silhouettes once and reads activity off the movement
/// afterwards, rather than decoding a colour-and-shape pair every time.
public struct CrewMood: Sendable, Hashable {
    public var shape: BloubShapeID
    public var state: BloubStateID
    public var expression: BloubExpressionID

    public init(shape: BloubShapeID, state: BloubStateID, expression: BloubExpressionID) {
        self.shape = shape
        self.state = state
        self.expression = expression
    }
}

/// The mapping between what Auspex knows and what the avatar engine draws.
///
/// Pure functions over pure data, so the whole table is testable without a
/// window — which matters, because this is the only place where a new harness
/// or a new session state would silently get a default.
public enum CrewMoodMap {
    /// One silhouette per harness.
    ///
    /// Total over `Harness` on purpose: adding a harness to the kit fails this
    /// switch rather than quietly drawing it as a circle, exactly as
    /// `HarnessStyle` does for the accent. The two harnesses that share a
    /// vendor also share a shape — Claude Code and Claude Cowork are both
    /// circles, Codex and ChatGPT Work both squircles — because they are one
    /// vendor's two products, and the accent is what tells them apart.
    public static func shape(for harness: Harness) -> BloubShapeID {
        switch harness {
        case .claudeCode, .claudeCowork: .circle
        case .codex, .chatgptWork: .squircle
        case .cursor: .triangle
        case .grokBuild: .pebble
        case .grokBot: .droplet
        case .antigravity: .cloud
        case .geminiCLI: .capsule
        }
    }

    /// How long a soft notification holds after a turn ends.
    ///
    /// A turn finishing is worth a glance and nothing more, so it is a
    /// four-second pastille rather than a state: long enough to catch on a wall
    /// being watched, short enough that a board of finished turns is not a wall
    /// of blue dots.
    public static let notifyHold: TimeInterval = 4

    /// The avatar state and expression for one session state.
    ///
    /// Precedence, and why:
    ///
    /// 1. **ended** wins over everything. A session that is over is over; a
    ///    stale flag or a pending notification on it would be noise.
    /// 2. **waitingPermission** comes next. It is the one state that will never
    ///    resolve itself, so it must not be masked by a softer signal.
    /// 3. **a soft notify** applies only to an idle session — a turn that just
    ///    ended. On a working session the work is the news.
    /// 4. **stale** applies only to an active session: staleness means
    ///    "claims to be working and has said nothing", which is meaningless for
    ///    an idle one.
    /// 5. otherwise the state itself.
    ///
    /// The expressions are the ones the reference renders use. They only reach
    /// the screen on a state that wears the resting face — `idle` — but they
    /// are carried for every entry so this table stays comparable with the
    /// design sheet it was drawn from.
    public static func avatarState(
        for state: SessionState,
        isStale: Bool = false,
        isNotifying: Bool = false,
        isSpawning: Bool = false
    ) -> (state: BloubStateID, expression: BloubExpressionID) {
        switch state {
        case .ended:
            return (.sleep, .sleepy)
        case .waitingPermission:
            return (.alert, .surprised)
        case .idle:
            if isNotifying { return (.notify, .attentive) }
            return (.idle, .neutral)
        case .thinking:
            if isStale { return (.wink, .sleepy) }
            return (.thinking, .curious)
        case .toolCalling:
            if isStale { return (.wink, .sleepy) }
            return (.orbit, .attentive)
        case .writingFile:
            if isStale { return (.wink, .sleepy) }
            return (.play, .attentive)
        case .delegating:
            if isStale { return (.wink, .sleepy) }
            // Delegating is two beats, not one. The burst is the *act* of
            // spawning — the body flies apart and the children come out of the
            // particles — and it resolves in 2.4 s. Holding it after that
            // leaves the avatar as a lone dot, which is what `sleep` looks
            // like, so a card that had just handed work out read as one that
            // had finished. Once the body has re-formed the session goes to
            // `wide`: eyes open on a body that is the harness's own shape
            // again, watching. Both halves are bloub's; only the cut is ours.
            if isSpawning { return (.burst, .excited) }
            return (.wide, .attentive)
        }
    }

    /// How long the burst runs before the body re-forms.
    ///
    /// Read off the state, not chosen: `minDuration` is "the date at which the
    /// animation resolves", and `burst` puts it at 1.7 + 0.7 — the moment the
    /// body has finished growing back and the eyes are open again. Cutting
    /// earlier would leave the body in pieces; later is padding.
    public static let spawnBurst: TimeInterval =
        BloubStates.state(.burst).minDuration ?? BloubStates.state(.burst).duration

    /// The whole mood for a session.
    public static func mood(
        harness: Harness,
        state: SessionState,
        isStale: Bool = false,
        isNotifying: Bool = false,
        isSpawning: Bool = false
    ) -> CrewMood {
        let resolved = avatarState(
            for: state,
            isStale: isStale,
            isNotifying: isNotifying,
            isSpawning: isSpawning
        )
        return CrewMood(
            shape: shape(for: harness),
            state: resolved.state,
            expression: resolved.expression
        )
    }

    /// How often a held state replays itself, or `nil` when it needs no help.
    ///
    /// bloub's states are montage blocks of a couple of seconds. Several tell a
    /// story that finishes — the "!" travels and comes back, the rings fade in
    /// and out — and then have nothing left to show. Auspex holds a state for as
    /// long as the work takes, so those are replayed.
    ///
    /// `burst` is deliberately **not** among them: it is played once per act of
    /// spawning and then handed to `wide`, so looping it would turn one event
    /// into a nervous tic.
    ///
    /// The period is the state's own **resolve** time (`minDuration`, "the date
    /// at which the animation resolves", read off its constants), falling back
    /// to its measured hold. Replaying there means nothing is cut and nothing
    /// is padded.
    ///
    /// The others are left alone because they already sustain themselves: the
    /// thinking dots pulse on a 1.5 s wave, `sleep` bounces on a 0.6 s one,
    /// and `idle`, `wink` and `notify` are static poses that the resting life
    /// keeps alive on its own. Replaying a periodic state would put a seam in a
    /// loop that does not have one.
    public static func replayPeriod(for state: BloubStateID) -> Double? {
        switch state {
        case .alert, .play, .orbit, .comet:
            let def = BloubStates.state(state)
            return def.minDuration ?? def.duration
        case .idle, .thinking, .wink, .wide, .notify, .exclaim, .sleep, .egg, .hexagon,
             .swirl, .burst:
            return nil
        }
    }
}

/// One avatar's engine plus the bookkeeping Auspex adds around it: which mood
/// is showing, when a soft notification expires, and when a held state has to
/// be replayed.
///
/// A value type, and clockless like the engine underneath: every entry point
/// takes the time. The view owns one of these per session and feeds it the
/// shared clock, which is what lets sixty avatars animate off one timeline.
public struct CrewAvatarDriver: Sendable {
    /// The engine. `sample(_:)` on it is still a pure function of time.
    public private(set) var engine: BloubEngine
    /// Which harness this avatar is. Fixed for the life of the session, and
    /// the only thing the mood cannot be re-derived without.
    public let harness: Harness
    /// The mood currently being played.
    public private(set) var mood: CrewMood
    /// When the soft notification stops, on the same clock.
    private var notifyUntil: Double?
    /// When the spawning burst stops and the body re-forms.
    private var spawnUntil: Double?
    /// How many children the session had last time, so a *new* one can be seen.
    private var lastChildren: Int?
    /// The last session state seen, to spot the edge a turn ending makes.
    private var lastSessionState: SessionState?
    /// When the avatar last changed state, so the card can pop on it.
    private var changedAt: Double?

    /// How long the pop that greets a state change lasts.
    public static let popDuration = 0.32
    /// How far it goes. Four per cent: enough to catch the eye on a 120-point
    /// avatar, small enough that a wall of them changing at once does not look
    /// like a wave.
    public static let popScale = 0.04

    public init(
        harness: Harness,
        state: SessionState,
        isStale: Bool = false,
        at now: Double,
        scale: Double = BloubFrameOfReference.radius,
        seed: UInt32 = 0
    ) {
        // A session first seen already delegating has, from the wall's point of
        // view, just done it: it gets the burst like any other.
        var spawning = false
        if case .delegating(let children) = state, !isStale {
            spawnUntil = now + CrewMoodMap.spawnBurst
            lastChildren = children
            spawning = true
        }
        let mood = CrewMoodMap.mood(
            harness: harness,
            state: state,
            isStale: isStale,
            isSpawning: spawning
        )
        self.harness = harness
        self.mood = mood
        lastSessionState = state
        var engine = BloubEngine(
            scale: scale,
            state: mood.state,
            shape: mood.shape,
            expression: mood.expression,
            // Every session gets its own resting drift. Sixty avatars reading
            // one clock and one drift function would all look the same way at
            // the same moment, which is the difference between a crew and a
            // screensaver.
            drift: .wander(seed: seed)
        )
        // The engine starts its clock at zero, and this driver is handed a
        // clock that has been running since the wall opened. Without this the
        // avatar would be born several seconds into its own animation — an
        // orbit whose rings had already faded out, a burst already recomposed —
        // which is exactly what a session that has just appeared has not done.
        engine.reset(to: mood.state, at: now)
        self.engine = engine
    }

    /// Feeds the driver the session's current state and the clock.
    ///
    /// Call it on every frame: it is what starts a soft notification when a
    /// turn ends, ends it four seconds later, fires the spawning burst, and
    /// replays a held state. Idempotent for a given `now`, so calling it twice
    /// in one frame changes nothing.
    public mutating func update(state: SessionState, isStale: Bool, at now: Double) {
        // A turn that just ended: the session was doing something and is now
        // idle. Not `ended` — a finished session is not news, it is history.
        if case .idle = state, let last = lastSessionState, last.isActive {
            notifyUntil = now + CrewMoodMap.notifyHold
        }
        lastSessionState = state

        if let until = notifyUntil, now >= until { notifyUntil = nil }

        // The burst is an event, not a condition: it fires when the session
        // starts delegating and again whenever it hands out *more* work. A
        // count that stays put, or drops as children finish, is the same act
        // still in progress and must not restart it.
        if case .delegating(let children) = state, !isStale {
            if lastChildren == nil || children > (lastChildren ?? 0) {
                spawnUntil = now + CrewMoodMap.spawnBurst
            }
            lastChildren = children
        } else {
            lastChildren = nil
            spawnUntil = nil
        }
        if let until = spawnUntil, now >= until { spawnUntil = nil }

        let next = CrewMoodMap.mood(
            harness: harness,
            state: state,
            isStale: isStale,
            isNotifying: notifyUntil != nil,
            isSpawning: spawnUntil != nil
        )
        if next.state != mood.state {
            // The morph, the blink at its midpoint and the eyes' 60 ms lag all
            // belong to the engine; what the driver adds is the date, so the
            // card knows when to pop.
            engine.setState(next.state, at: now)
            mood.state = next.state
            changedAt = now
        }
        if next.expression != mood.expression {
            engine.setExpression(next.expression, at: now)
            mood.expression = next.expression
        }

        if let period = CrewMoodMap.replayPeriod(for: mood.state),
           engine.elapsed(at: now) >= period {
            engine.replay(at: now)
        }
    }

    /// The frame at `now`.
    public func sample(_ now: Double) -> BloubFrame { engine.sample(now) }

    /// The avatar's own scale at `now`: a 4 % pop on each state change.
    ///
    /// A pure function of time like everything else here, and deliberately not
    /// a SwiftUI animation. The wall already has a clock ticking every frame;
    /// asking SwiftUI to run sixty more interpolations alongside it would buy
    /// nothing and cost a transaction per card. It also means the pop replays
    /// identically from a screenshot renderer with no window.
    ///
    /// Up on an ease-out over the first 40 %, back down on an ease-in-out over
    /// the rest: it leaves 1 and rejoins 1 at rest, and never overshoots — the
    /// body's own rule, kept.
    public func pop(at now: Double) -> Double {
        guard let changedAt else { return 1 }
        let k = (now - changedAt) / CrewAvatarDriver.popDuration
        if k <= 0 || k >= 1 { return 1 }
        let shape = k < 0.4
            ? BloubMath.easeOutCubic(k / 0.4)
            : 1 - BloubMath.easeInOutCubic((k - 0.4) / 0.6)
        return 1 + CrewAvatarDriver.popScale * shape
    }

    /// Whether a soft notification is showing.
    public var isNotifying: Bool { notifyUntil != nil }

    /// Whether the spawning burst is still playing.
    public var isSpawning: Bool { spawnUntil != nil }
}
