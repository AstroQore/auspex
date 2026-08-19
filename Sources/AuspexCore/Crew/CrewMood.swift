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
        isNotifying: Bool = false
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
            return (.burst, .excited)
        }
    }

    /// The whole mood for a session.
    public static func mood(
        harness: Harness,
        state: SessionState,
        isStale: Bool = false,
        isNotifying: Bool = false
    ) -> CrewMood {
        let resolved = avatarState(for: state, isStale: isStale, isNotifying: isNotifying)
        return CrewMood(
            shape: shape(for: harness),
            state: resolved.state,
            expression: resolved.expression
        )
    }

    /// How often a held state replays itself, or `nil` when it needs no help.
    ///
    /// bloub's states are montage blocks of a couple of seconds. Five of them
    /// tell a story that finishes — the "!" travels and comes back, the rings
    /// fade in and out, the body bursts and recomposes — and then have nothing
    /// left to show. Auspex holds a state for as long as the work takes, so
    /// those five are replayed.
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
        case .alert, .play, .orbit, .burst, .comet:
            let def = BloubStates.state(state)
            return def.minDuration ?? def.duration
        case .idle, .thinking, .wink, .wide, .notify, .exclaim, .sleep, .egg, .hexagon, .swirl:
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
    /// The last session state seen, to spot the edge a turn ending makes.
    private var lastSessionState: SessionState?

    public init(
        harness: Harness,
        state: SessionState,
        isStale: Bool = false,
        at now: Double,
        scale: Double = BloubFrameOfReference.radius
    ) {
        let mood = CrewMoodMap.mood(harness: harness, state: state, isStale: isStale)
        self.harness = harness
        self.mood = mood
        lastSessionState = state
        var engine = BloubEngine(
            scale: scale,
            state: mood.state,
            shape: mood.shape,
            expression: mood.expression
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
    /// turn ends, ends it four seconds later, and replays a held state. Idempotent
    /// for a given `now`, so calling it twice in one frame changes nothing.
    public mutating func update(state: SessionState, isStale: Bool, at now: Double) {
        // A turn that just ended: the session was doing something and is now
        // idle. Not `ended` — a finished session is not news, it is history.
        if case .idle = state, let last = lastSessionState, last.isActive {
            notifyUntil = now + CrewMoodMap.notifyHold
        }
        lastSessionState = state

        if let until = notifyUntil, now >= until { notifyUntil = nil }

        let next = CrewMoodMap.mood(
            harness: harness,
            state: state,
            isStale: isStale,
            isNotifying: notifyUntil != nil
        )
        if next.state != mood.state {
            // Every state change is hidden by a blink — the engine does that
            // for the states bloub measured a blink on.
            engine.setState(next.state, at: now)
            mood.state = next.state
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

    /// Whether a soft notification is showing.
    public var isNotifying: Bool { notifyUntil != nil }
}
