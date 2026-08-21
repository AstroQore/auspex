import AgentSessionKit
import AgentSessionLive
import Foundation

/// What a session's face is doing — and the crew's **whole** state language.
///
/// ## Why the body stopped saying it
///
/// bloub's catalogue says "thinking" by turning the body into three pulsing
/// dots, "waiting" by turning it into a travelling "!", "tool call" by hanging
/// six rings around it. Each of those is a lovely piece of animation and each of
/// them costs the avatar its **identity**: the silhouette that says which
/// harness this is disappears for as long as the state lasts, so a wall of
/// twelve working sessions is a wall of twelve identical ring bouquets.
///
/// So the division of labour is now clean. The **body** is the harness — one
/// silhouette per vendor, always visible, never replaced. The **face** is the
/// state, and it is avatar-lab's vocabulary: 25 expressions and 23 animations,
/// played from pools. And anything that has to *shout* — a session waiting on
/// you, a turn that finished while you were elsewhere — is **card chrome**: a
/// ring and a corner badge, where a person's eye already goes looking for
/// status, and where it does not have to be decoded out of a shape.
public enum CrewStance: String, Sendable, Hashable, CaseIterable {
    /// Awake, nothing to do. Open eyes, blinks, gaze drift, reactions.
    case idle
    /// Claims to be working and has said nothing for a while.
    case stale
    case thinking
    /// Tool calls and file writes. One stance: from the outside they are the
    /// same thing — the session is busy and not asking anything of you.
    case working
    case delegating
    /// A child has just appeared.
    case spawning
    /// Waiting on a person: a permission prompt, a question, a review.
    case blocked
    /// A turn just finished, and nobody has looked yet.
    case celebrating
    /// Over. Asleep, grey, and on its way off the wall.
    case ended
}

/// What one session looks like as a crew avatar: a body shape and a stance.
///
/// Identity and activity travel in separate channels, the same split the board
/// uses. The **shape** says which harness this is and never changes for the
/// life of a session; the **stance** says what it is doing right now and is
/// carried entirely by the face. So a person learns eight silhouettes once and
/// reads activity off the eyes afterwards.
public struct CrewMood: Sendable, Hashable {
    public var shape: BloubShapeID
    public var stance: CrewStance

    public init(shape: BloubShapeID, stance: CrewStance) {
        self.shape = shape
        self.stance = stance
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

    /// How long a finished turn is celebrated for.
    ///
    /// Twenty seconds, not four. A celebration is the one thing on the wall
    /// that is *good news*, and the point of it is to still be visible when
    /// somebody looks back at the screen — long enough to catch, short enough
    /// that a board of finished turns is not a permanent party. The green tick
    /// on the card stays until it is dismissed; the dance does not.
    public static let notifyHold: TimeInterval = 20

    /// How long the burst of a spawn runs before the parent settles back into
    /// delegating.
    public static let spawnBurst: TimeInterval = 2.4

    /// How long a finished session stays on the wall before folding away.
    ///
    /// A minute. Long enough that somebody who was watching sees it fall
    /// asleep where it was working, short enough that a machine which has run
    /// two hundred sessions today is not a wall of grey.
    public static let endedFold: TimeInterval = 60

    /// The stance for one session state.
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
    public static func stance(
        for state: SessionState,
        isStale: Bool = false,
        isNotifying: Bool = false,
        isSpawning: Bool = false
    ) -> CrewStance {
        switch state {
        case .ended:
            return .ended
        case .waitingPermission:
            return .blocked
        case .idle:
            return isNotifying ? .celebrating : .idle
        case .thinking:
            return isStale ? .stale : .thinking
        case .toolCalling, .writingFile:
            return isStale ? .stale : .working
        case .delegating:
            if isStale { return .stale }
            return isSpawning ? .spawning : .delegating
        }
    }

    /// The whole mood for a session.
    public static func mood(
        harness: Harness,
        state: SessionState,
        isStale: Bool = false,
        isNotifying: Bool = false,
        isSpawning: Bool = false
    ) -> CrewMood {
        CrewMood(
            shape: shape(for: harness),
            stance: stance(
                for: state,
                isStale: isStale,
                isNotifying: isNotifying,
                isSpawning: isSpawning
            )
        )
    }
}

/// One avatar's engine plus the bookkeeping Auspex adds around it: which mood
/// is showing, when a celebration expires, and when a spawn settles.
///
/// A value type, and clockless like the engine underneath: every entry point
/// takes the time. The view owns one of these per session and feeds it the
/// shared clock, which is what lets sixty avatars animate off one timeline.
public struct CrewAvatarDriver: Sendable {
    /// The engine. `sample(_:)` on it is still a pure function of time.
    ///
    /// It is parked on ``BloubStateID/idle`` for the whole life of the avatar
    /// and never leaves it. That is not a limitation, it is the point: `idle`
    /// is the one catalogue state that wears **the chosen body** and **a face
    /// handed in from outside**, which is exactly the division this view is
    /// built on. What the engine still does, and what nothing else could, is
    /// seat two eye capsules on a sphere inside an arbitrary silhouette, ease
    /// between shapes, and keep the gaze drifting.
    public private(set) var engine: BloubEngine
    /// What the face is doing.
    ///
    /// The two channels are deliberately separate all the way down: the body
    /// is bloub's — a silhouette per harness — and the face is avatar-lab's,
    /// sequenced from this session's own seed. That is what makes twelve idle
    /// sessions twelve different things to look at rather than twelve copies of
    /// one drawing.
    public private(set) var choreographer: CrewChoreographer
    /// Which harness this avatar is. Fixed for the life of the session, and
    /// the only thing the mood cannot be re-derived without.
    public let harness: Harness
    /// The mood currently being played.
    public private(set) var mood: CrewMood
    /// When the celebration stops, on the same clock.
    private var notifyUntil: Double?
    /// When a spawn settles back into delegating.
    private var spawnUntil: Double?
    /// How many children the session had last time, so a *new* one can be seen.
    private var lastChildren: Int?
    /// The last session state seen, to spot the edge a turn ending makes.
    private var lastSessionState: SessionState?
    /// When the avatar last changed stance, so the card can pop on it.
    private var changedAt: Double?

    /// How long the pop that greets a change of stance lasts.
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
        seed: UInt32 = 0,
        liveliness: CrewLiveliness = .default
    ) {
        // A session first seen already delegating has, from the wall's point of
        // view, just done it: it gets the spawn like any other.
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
            state: .idle,
            shape: mood.shape,
            expression: .neutral,
            // Every session gets its own resting drift. Sixty avatars reading
            // one clock and one drift function would all look the same way at
            // the same moment, which is the difference between a crew and a
            // screensaver.
            drift: .wander(seed: seed)
        )
        // The engine starts its clock at zero, and this driver is handed a
        // clock that has been running since the wall opened.
        engine.reset(to: .idle, at: now)
        self.engine = engine
        choreographer = CrewChoreographer(
            seed: seed,
            stance: mood.stance,
            liveliness: liveliness,
            at: now
        )
    }

    /// How often this avatar reacts. Changing it does not disturb whatever is
    /// playing — the setting is about the *next* reaction, not this one.
    public mutating func setLiveliness(_ value: CrewLiveliness) {
        choreographer.setLiveliness(value)
    }

    /// Feeds the driver the session's current state and the clock.
    ///
    /// Call it on every frame: it is what starts a celebration when a turn
    /// ends, ends it twenty seconds later, fires the spawn, and accents a child
    /// finishing. Idempotent for a given `now`, so calling it twice in one
    /// frame changes nothing.
    public mutating func update(state: SessionState, isStale: Bool, at now: Double) {
        // A turn that just ended: the session was doing something and is now
        // idle. Not `ended` — a finished session is not news, it is history.
        if case .idle = state, let last = lastSessionState, last.isActive {
            notifyUntil = now + CrewMoodMap.notifyHold
        }
        lastSessionState = state

        if let until = notifyUntil, now >= until { notifyUntil = nil }

        // The spawn is an event, not a condition: it fires when the session
        // starts delegating and again whenever it hands out *more* work. A
        // count that stays put is the same act still in progress.
        if case .delegating(let children) = state, !isStale {
            if lastChildren == nil || children > (lastChildren ?? 0) {
                spawnUntil = now + CrewMoodMap.spawnBurst
            } else if let last = lastChildren, children < last {
                // A child finished. The stance has nothing to say about it —
                // the parent is still delegating — so the face says it instead.
                choreographer.accent(.proud, at: now)
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
        if next.stance != mood.stance {
            // The eased morph, the accent that announces the change and the
            // blink at the morph's midpoint all belong to the choreographer;
            // what the driver adds is the date, so the card knows when to pop.
            choreographer.setStance(next.stance, at: now)
            mood.stance = next.stance
            changedAt = now
        }
    }

    /// The frame at `now`: the harness's body wearing avatar-lab's face.
    public func sample(_ now: Double) -> BloubFrame {
        let face = choreographer.sample(at: now)
        return engine.sample(
            now,
            face: BloubFaceOverride(expression: face.face, lid: face.lid)
        )
    }

    /// The avatar's own scale at `now`: a 4 % pop on each change of stance.
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

    /// How long the wall may wait before drawing this avatar again at `now`,
    /// or `nil` when it need not draw it at all.
    ///
    /// One clock per card is what makes this possible, and this is what pays
    /// for it: on a real board most sessions are idle or ended most of the
    /// time, and it is only ever the few that are working that need sixty
    /// frames a second.
    ///
    /// Now that the body no longer animates — it is a silhouette that only
    /// moves when the shape morphs — the rate is decided entirely by the face:
    ///
    /// - **full** for a reaction, which is an event and the one thing on an
    ///   otherwise still card a person's eye is meant to be caught by; for the
    ///   first second after a change of stance, which covers the morph, the
    ///   blink inside it and the card's pop; and around a blink, which at
    ///   fifteen frames a second would get two frames and read as a glitch;
    /// - **half** for a step morph inside the base loop — a continuous
    ///   movement of two capsules, not an event;
    /// - **low** for a face that is simply held, with the gaze drifting under
    ///   it. A 2–5 s random walk and a 3.4 s breath cannot use more;
    /// - **nothing at all** for a session that has ended, which is asleep and
    ///   does not even blink.
    public func frameInterval(at now: Double) -> Double? {
        if mood.stance == .ended, now - (changedAt ?? -1000) > CrewCadence.settle {
            // Asleep. The eyes are shut, there is no blink schedule and no
            // pool, so there is nothing left to draw. Pausing a timeline leaves
            // the last frame standing, so there is no jump either.
            return nil
        }
        if engine.elapsed(at: now) < CrewCadence.settle { return CrewCadence.full }
        if let changedAt, now - changedAt < CrewCadence.settle { return CrewCadence.full }

        let face = choreographer.sample(at: now)
        if face.isReacting { return CrewCadence.full }
        if choreographer.blinkImminent(at: now, lead: CrewCadence.blinkLead) {
            return CrewCadence.full
        }
        return face.hasSettled ? CrewCadence.low : CrewCadence.half
    }

    /// Whether a celebration is showing.
    public var isCelebrating: Bool { notifyUntil != nil }

    /// Whether a spawn is still playing.
    public var isSpawning: Bool { spawnUntil != nil }
}

/// How often each kind of avatar has to be redrawn.
///
/// The wall holds a clock per card, so the rate can follow what the card is
/// actually doing rather than what the busiest card on the wall is doing. That
/// is the whole saving: a session that has been idle for ten minutes is
/// drifting its gaze and breathing, and neither of those needs sixty frames a
/// second — while the half-second when it changes stance needs every one of
/// them.
///
/// The tiers are decided by *how fast the fastest thing on screen moves*, never
/// by how important the state is:
///
/// - **full** — anything in flight: a stance morph, a reaction, the pop, a
///   blink. Also the whole second after a change, which is longer than any of
///   them and saves splitting hairs about which is still running.
/// - **half** — a step morph inside the base loop: continuous but slow.
/// - **low** — a held face plus resting life. Gaze drift is a 2–5 s random walk
///   and the breath a 3.4 s sine; fifteen frames a second is more than either
///   can use.
/// - **paused** — a session that has ended. Nothing moves at all.
public enum CrewCadence {
    public static let full = 1.0 / 60
    public static let half = 1.0 / 30
    public static let low = 1.0 / 15

    /// How long after a change of stance an avatar keeps the full rate.
    ///
    /// Longer than the longest morph (0.6 s) and than the pop (0.32 s), so "is
    /// anything still moving" is one comparison rather than three.
    public static let settle = 1.0

    /// How far ahead of a scheduled blink to go back to the full rate.
    ///
    /// Must exceed ``low`` — a card sampling every 67 ms has to be *told* about
    /// the blink before it arrives, or it steps over the warning entirely. 0.25
    /// gives it three chances to notice.
    public static let blinkLead = 0.25
}
