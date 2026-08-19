// Ported from bloub — https://github.com/jeremy-prt/bloub
// MIT License, © 2026 Jérémy Perret. See THIRD_PARTY_NOTICES.md.
//
// Deviation, on purpose: the *timing* of the transitions in this file is
// Auspex's, not bloub's — a visible eased morph rather than a change hidden in
// a blink, and no straight lines left in the catalogue. Every pose, silhouette,
// amplitude and gaze angle is still the measurement. See BloubTransition.swift
// and THIRD_PARTY_NOTICES.md.

import Foundation

/// The render frame everything the engine emits is expressed in.
///
/// These two numbers **are** the definition of the engine's output: without
/// them a frame means nothing.
public enum BloubFrameOfReference {
    /// Radius of the resting ball, in viewBox units. Chosen, not measured:
    /// it is the working unit, and everything else in the port is expressed as
    /// a fraction of it, which is what makes the measurements independent of
    /// the display size.
    public static let radius = 100.0

    /// Half-side of the displayed viewBox. The margin beyond the radius houses
    /// the rings.
    ///
    /// Not a free value: the orbit's rings and the comet's swoosh reach 1.4
    /// times the radius, i.e. 140. Nothing bounds them at runtime — it is the
    /// hand tuning of ``BloubDecor/rings`` and ``BloubDecor/swoosh`` that keeps
    /// them under 158, and a test locks it.
    public static let halfViewBox = 158.0
}

/// One eye, ready to draw: a capsule of `width` × `height` centred on the
/// origin, put in place by an affine transform.
///
/// The eyes are **holes**, not white shapes laid on top. That is what makes
/// them clip themselves against the silhouette when they slide towards the
/// edge, with no cropping code — and it is why the renderer must punch them out
/// of the body rather than paint them over it.
public struct BloubEye: Sendable, Hashable {
    public var width: Double
    public var height: Double
    /// `matrix(a, b, c, d, e, f)`: columns (a, b) and (c, d), translation (e, f).
    public var a: Double
    public var b: Double
    public var c: Double
    public var d: Double
    public var e: Double
    public var f: Double
    public var alpha: Double
}

/// Everything one instant of the avatar needs, in viewBox units.
public struct BloubFrame: Sendable {
    /// The ball's radius in viewBox units — the unit `dots[].polygon` and any
    /// other ball-radius geometry is expressed in.
    public var scale: Double
    public var body: BloubOutline
    public var bodyAlpha: Double
    public var eyes: [BloubEye]
    public var dots: [BloubDot]
    /// true = the dots pass behind the body (the burst's particles).
    public var dotsBehind: Bool
    public var arcs: [BloubArc]
    public var notify: (x: Double, y: Double, radius: Double)?
    /// The notch subtracted from the body around the pastille.
    public var notch: (x: Double, y: Double, radius: Double)?
}

/// Where the avatar looks when something outside drives it.
///
/// `yaw` and `pitch` are **absolute** directions, replacing the pose's own as
/// `mix` rises. Two reasons, each a trap already fallen into:
///
/// - the **engine** must do the mixing, not the caller, because only it knows
///   the pose at that instant. A caller compensating for the expression's
///   orientation would read its arrival value while the morph was still
///   running, and the eyes would jump on every mood change;
/// - it has to be absolute on **both** axes. In relative terms the eye height
///   followed each expression's own, and "neutral" looks about 30° higher than
///   the others, so the eyes dropped all at once on the first mood change.
///   What distinguishes a mood during tracking is the **shape** of its eyes,
///   not where it looks.
///
/// `mix` and `wander` are **not** the same thing. `mix` says how much the
/// outside world commands the direction; `wander` is what remains of automatic
/// drift. When the pointer moves the drift must die out — added together, the
/// avatar would look like it was hunting for the cursor without ever holding
/// it. But with no pointer at all the head must stay turned *and* keep living,
/// so drift is added **after** the mix.
///
/// `spin` is a turn taken on the way, in degrees. Since the eyes live on a
/// sphere a turn takes them behind the ball and back — and -360° being the same
/// angle as 0, it does not change where they land.
public struct BloubLook: Sendable, Hashable {
    public var yaw: Double
    public var pitch: Double
    public var mix: Double
    public var spin: Double
    public var wander: Double

    public init(yaw: Double, pitch: Double, mix: Double, spin: Double = 0, wander: Double = 0) {
        self.yaw = yaw
        self.pitch = pitch
        self.mix = mix
        self.spin = spin
        self.wander = wander
    }

    public static let none = BloubLook(yaw: 0, pitch: 0, mix: 0, spin: 0, wander: 1)
}

/// A clockless engine: ``sample(_:)`` is a pure function of time.
///
/// The practical consequence is that pausing, resuming, slowing down and
/// jumping to an arbitrary date all give exactly the same image, and the render
/// is testable with no window.
///
/// So this type must not gain internal state that depends on real time, nor a
/// `Date()`, nor a SwiftUI import. Everything from outside enters through a
/// **dated setter** — `setState(_:at:)`, `setShape(_:at:)` — never through a
/// value read during sampling. It is a `struct` for the same reason: `sample`
/// is `nonmutating`, and the compiler is what enforces it.
public struct BloubEngine: Sendable {
    /// Radius of the resting ball, in viewBox units.
    public let scale: Double

    /// Which model the resting gaze drifts on. Fixed for the life of the
    /// engine: it is an identity, not a state, and a drift that changed model
    /// mid-flight would move the head without anything having happened.
    public let drift: BloubGazeDrift

    private var current: BloubStateID
    private var previous: BloubStateID?
    /// A **frozen** start pose, set only when a state change arrives while a
    /// fade is already running. See ``setState(_:at:)``.
    private var frozenStart: BloubPose?
    private var currentAt: Double = 0
    private var previousAt: Double = 0
    private var blinkAt: Double = -10

    private var shape: BloubShapeID?
    private var shapePrevious: BloubShapeID?
    private var shapeAt: Double = -10

    private var expression: BloubExpressionID?
    private var expressionPrevious: BloubExpressionID?
    private var expressionAt: Double = -10

    private var look: BloubLook = .none
    private var lookPrevious: BloubLook = .none
    private var lookAt: Double = -10
    private var lookMorph: Double = BloubEngine.lookMorphDefault

    /// How long a change of body shape takes to morph.
    public static let shapeMorph = 0.45

    /// The shape and expression axes ride the same curve as a state change, so
    /// a mood that moves both at once moves as one thing.
    private static func morphCurve(_ k: Double) -> Double { BloubTransition.curve(k) }

    /// How long the gaze takes to catch up with a target. Shorter than
    /// ``shapeMorph``: a following gaze should look attentive, not viscous.
    public static let lookMorphDefault = 0.24

    public init(
        scale: Double = BloubFrameOfReference.radius,
        state: BloubStateID = .idle,
        shape: BloubShapeID? = nil,
        expression: BloubExpressionID? = nil,
        drift: BloubGazeDrift = .measured
    ) {
        self.scale = scale
        current = state
        self.shape = shape
        self.expression = expression
        self.drift = drift
    }

    /// The state currently being played.
    public var state: BloubStateID { current }

    /// The body shape currently chosen, if any.
    public var bodyShape: BloubShapeID? { shape }

    // MARK: Dated setters

    /// The resting expression. Like the shape, it slides towards the new value
    /// instead of jumping.
    public mutating func setExpression(_ id: BloubExpressionID?, at now: Double) {
        if id == expression { return }
        expressionPrevious = expression
        expression = id
        expressionAt = now
    }

    /// The chosen body shape. It only replaces the body on resting states
    /// (``BloubStateDef/usesBaseBody``): on the others the silhouette **is**
    /// the animation and must not be overwritten.
    ///
    /// The change morphs rather than cutting: since every shape is sampled at
    /// the same angles, interpolating the radii is enough.
    ///
    /// Narrower than bloub's, which takes an arbitrary radii array: here only a
    /// catalogue shape can be chosen, which is what makes the eye-offset lookup
    /// total instead of silently returning zero for an unknown profile.
    public mutating func setShape(_ id: BloubShapeID?, at now: Double) {
        if id == shape { return }
        shapePrevious = shape
        shape = id
        shapeAt = now
    }

    /// A new gaze target, `nil` to go back to the state's own.
    ///
    /// It restarts from the **current** value rather than from the previous
    /// target, unlike ``setShape(_:at:)``: this is called on every pointer
    /// move, and restarting from the old target would step the gaze backwards
    /// before each catch-up — the tracking would judder instead of gliding.
    ///
    /// A non-finite target is refused. The engine **keeps** the last one: a
    /// `NaN` set even once would propagate to every frame and the avatar would
    /// never rest again.
    public mutating func setLook(
        _ target: BloubLook?,
        at now: Double,
        morph: Double = BloubEngine.lookMorphDefault
    ) {
        if let target,
           !(target.yaw + target.pitch + target.mix + target.spin + target.wander).isFinite {
            return
        }
        lookPrevious = lookAtTime(now)
        look = target ?? .none
        lookAt = now
        lookMorph = morph
    }

    /// Restarts on `id` with **no** previous state, like a fresh engine placed
    /// on it.
    ///
    /// This is what "rewind" means for this engine. ``setState(_:at:)`` alone
    /// cannot do it: it keeps the state being left so it can fade from it,
    /// which is exactly its job during playback and exactly the wrong thing
    /// when returning to the start of a sequence.
    public mutating func reset(to id: BloubStateID, at now: Double) {
        current = id
        previous = nil
        frozenStart = nil
        currentAt = now
        previousAt = now
        blinkAt = -10
    }

    /// A dated state change.
    ///
    /// The engine keeps only ONE slot of history, so a change arriving during a
    /// fade used to replace the blend's origin with the **full** pose of the
    /// state being left, rather than the partly-blended frame that was actually
    /// on screen — measured on `idle → wide → idle` at 100 ms: 35.9 px of jump
    /// against 8.0 px of normal movement.
    ///
    /// So the composite pose is frozen and the blend starts from it. Continuous
    /// by construction, however many changes are chained.
    ///
    /// And **only** in that case. Freezing on every change would stop the
    /// outgoing state's own animation dead for the whole fade — `alert`'s
    /// travelling "!" would halt mid-course — while there is nothing to fix
    /// outside a fade, where the state being left is already exactly the
    /// displayed frame.
    public mutating func setState(_ id: BloubStateID, at now: Double) {
        if id == current { return }
        let span = BloubTransition.span(BloubStates.state(current).morph)
        let midFade = previous != nil && now - currentAt < span
        frozenStart = midFade ? composedPose(now) : nil
        previous = current
        previousAt = currentAt
        current = id
        currentAt = now
        scheduleBlink(for: id, at: now)
    }

    /// The blink that goes with a morph, on the states bloub measured one on.
    ///
    /// It is **centred on the morph's midpoint** rather than fired at its
    /// start. In the video the blink is the damping mechanism: the eye is shut
    /// over the fastest part of the change, and the change is never really
    /// seen. On a wall of cards that reads as a snap, so here the blink is a
    /// punctuation mark inside a morph the viewer is meant to watch — 0.2 s of
    /// it out of 0.42 to 0.60. See ``BloubTransition``.
    private mutating func scheduleBlink(for id: BloubStateID, at now: Double) {
        guard BloubStates.state(id).blinkIn else { return }
        blinkAt = now + BloubTransition.blinkStart(
            BloubStates.state(id).morph,
            blinkDuration: BloubFace.forcedBlinkDuration
        )
    }

    /// Restarts the **current** state at `now`, morphing out of whatever is on
    /// screen — an addition of this port, not something bloub has.
    ///
    /// bloub's states are montage blocks: they are held for a measured couple
    /// of seconds and then cut to the next one, so several of them let their
    /// decor decay on the way out (`orbit`'s rings are gone by 3.6 s). Auspex
    /// has no montage — a session stays in one state for as long as the work
    /// takes — so a state whose animation is a one-shot has to be played
    /// again.
    ///
    /// It reuses the frozen-start mechanism ``setState(_:at:)`` already has, so
    /// the replay blends out of the composite pose that was actually on screen:
    /// continuous by construction, and the arcs cross-fade from the old set to
    /// the new one rather than blinking out. What it deliberately does not do
    /// is scale time — bloub's montage "holds or cuts, it never scales time",
    /// and every measured duration would break at once if this did.
    public mutating func replay(at now: Double) {
        frozenStart = composedPose(now)
        previous = current
        previousAt = currentAt
        currentAt = now
        scheduleBlink(for: current, at: now)
    }

    /// How long the current state has been running at `now`.
    public func elapsed(at now: Double) -> Double { now - currentAt }

    // MARK: Time-resolved inputs

    /// The effective expression at `now`, morph included.
    private func expressionAtTime(_ now: Double) -> BloubExpression? {
        guard let to = expression else { return nil }
        guard let from = expressionPrevious else { return BloubExpressions.expression(to) }
        let k = (now - expressionAt) / BloubEngine.shapeMorph
        if k >= 1 { return BloubExpressions.expression(to) }
        return BloubExpressions.blend(
            BloubExpressions.expression(from),
            BloubExpressions.expression(to),
            Self.morphCurve(k)
        )
    }

    /// The effective profile at `now`, morph included.
    ///
    /// Does **not** clear `shapePrevious` when the morph ends: `sample` has to
    /// stay a pure function of time, so re-reading a past date must give the
    /// intermediate image back. That is the optimisation that looks innocent
    /// and breaks everything.
    private func shapeAtTime(_ now: Double) -> [Double]? {
        guard let to = shape else { return nil }
        guard let from = shapePrevious else { return BloubSkins.radii(to) }
        let k = (now - shapeAt) / BloubEngine.shapeMorph
        let target = BloubSkins.radii(to)
        if k >= 1 { return target }
        let source = BloubSkins.radii(from)
        let t = Self.morphCurve(k)
        return target.enumerated().map { i, r in BloubMath.lerp(i < source.count ? source[i] : r, r, t) }
    }

    /// The effective gaze target at `now`, catch-up included.
    private func lookAtTime(_ now: Double) -> BloubLook {
        let k = (now - lookAt) / lookMorph
        if k >= 1 { return look }
        let t = BloubMath.easeOutQuint(BloubMath.clamp(k))
        return BloubLook(
            yaw: BloubMath.lerp(lookPrevious.yaw, look.yaw, t),
            pitch: BloubMath.lerp(lookPrevious.pitch, look.pitch, t),
            mix: BloubMath.lerp(lookPrevious.mix, look.mix, t),
            spin: BloubMath.lerp(lookPrevious.spin, look.spin, t),
            wander: BloubMath.lerp(lookPrevious.wander, look.wander, t)
        )
    }

    // MARK: Poses

    private func posed(
        _ def: BloubStateDef,
        _ t: Double,
        _ radii: [Double]?,
        _ expression: BloubExpression?
    ) -> BloubPose {
        var pose = def.pose(t)
        if def.usesBaseBody, let radii {
            // keep the pose (rotation, offset, squash) and swap only the profile
            pose.silhouette.radii = radii
        }
        if def.usesBaseFace, let expression {
            pose.gaze = expression.gaze
            pose.split = expression.split
            pose.eyes = expression.eyes
        }
        return pose
    }

    /// Interpolates two poses. The decor cross-fades in opacity, not in
    /// geometry.
    ///
    /// `t` drives the body and everything anchored to it; `face` drives the
    /// gaze and the eyes, and runs ``BloubTransition/eyeLag`` behind. Keeping
    /// them as two ratios rather than two calls matters: the eyes are placed on
    /// the silhouette at render time, so a face blended in a second pass would
    /// have to be re-seated against a body it never saw.
    private func blendPose(
        _ a: BloubPose,
        _ b: BloubPose,
        _ t: Double,
        face: Double
    ) -> BloubPose {
        let out = 1 - t
        func lerpEye(_ x: BloubEyeConfig, _ y: BloubEyeConfig) -> BloubEyeConfig {
            BloubEyeConfig(
                width: BloubMath.lerp(x.width, y.width, face),
                height: BloubMath.lerp(x.height, y.height, face),
                open: BloubMath.lerp(x.open, y.open, face),
                tilt: BloubMath.lerp(x.tilt, y.tilt, face)
            )
        }
        return BloubPose(
            silhouette: BloubShape.blend(a.silhouette, b.silhouette, t),
            offsetX: BloubMath.lerp(a.offsetX, b.offsetX, t),
            offsetY: BloubMath.lerp(a.offsetY, b.offsetY, t),
            gaze: BloubGaze(
                yaw: BloubMath.lerp(a.gaze.yaw, b.gaze.yaw, face),
                pitch: BloubMath.lerp(a.gaze.pitch, b.gaze.pitch, face),
                roll: BloubMath.lerp(a.gaze.roll, b.gaze.roll, face)
            ),
            split: BloubMath.lerp(a.split, b.split, face),
            eyes: (lerpEye(a.eyes.0, b.eyes.0), lerpEye(a.eyes.1, b.eyes.1)),
            eyeAlpha: BloubMath.lerp(a.eyeAlpha, b.eyeAlpha, face),
            bodyAlpha: BloubMath.lerp(a.bodyAlpha, b.bodyAlpha, t),
            dots: a.dots.map { var d = $0; d.opacity *= out; return d }
                + b.dots.map { var d = $0; d.opacity *= t; return d },
            arcs: a.arcs.map { var s = $0; s.id = "a" + s.id; s.opacity *= out; return s }
                + b.arcs.map { var s = $0; s.id = "b" + s.id; s.opacity *= t; return s },
            // the pastille belongs to one of the two states; it does not blend
            notify: t < 0.5 ? a.notify : b.notify,
            dotsBehind: t < 0.5 ? a.dotsBehind : b.dotsBehind
        )
    }

    /// The fade's origin: the frozen pose if there is one, otherwise the state
    /// being left evaluated at its own elapsed time — so still animating, which
    /// is intended.
    private func origin(
        _ now: Double,
        _ radii: [Double]?,
        _ expression: BloubExpression?
    ) -> BloubPose? {
        if let frozenStart { return frozenStart }
        guard let previous else { return nil }
        return posed(
            BloubStates.state(previous),
            max(0, now - previousAt),
            radii,
            expression
        )
    }

    /// The composite pose at `now`, fade included: exactly what ``sample(_:)``
    /// blends, before the resting-life and gaze layers.
    private func composedPose(_ now: Double) -> BloubPose {
        let def = BloubStates.state(current)
        let radii = shapeAtTime(now)
        let expression = expressionAtTime(now)
        let pose = posed(def, max(0, now - currentAt), radii, expression)
        let since = now - currentAt
        if since >= BloubTransition.span(def.morph) { return pose }
        guard let start = origin(now, radii, expression) else { return pose }
        let duration = BloubTransition.duration(def.morph)
        return blendPose(
            start,
            pose,
            BloubTransition.body(since, duration),
            face: BloubTransition.face(since, duration)
        )
    }

    /// The eye offset at `now` for a given state, in ball-radius units.
    ///
    /// It is **read from a table** and interpolated, never recomputed —
    /// ``BloubEyeFit`` explains why that distinction is the whole fix. What is
    /// left here is to interpolate it along the shape axis, with exactly the
    /// curve and duration of the silhouette's morph: same cause, so it must be
    /// the same movement.
    ///
    /// The table is queried on the morph's **boundaries** and never on the
    /// interpolated profile, which is a fresh array with no identity and exists
    /// in no table. Feeding that to the solver is exactly what made the eyes
    /// tremble.
    private func eyeOffsetAtTime(_ now: Double, _ state: BloubStateID) -> (x: Double, y: Double) {
        /// One morph axis: read the table on both **bounds** and interpolate
        /// with that morph's curve.
        func onAxis(
            _ start: Double,
            _ duration: Double,
            _ a: (x: Double, y: Double),
            _ b: (x: Double, y: Double)
        ) -> (x: Double, y: Double) {
            if a == b { return b }
            let k = (now - start) / duration
            if k >= 1 { return b }
            let t = Self.morphCurve(k)
            return (BloubMath.lerp(a.x, b.x, t), BloubMath.lerp(a.y, b.y, t))
        }

        // expression axis, for each of the two shapes in play
        func perShape(_ id: BloubShapeID?) -> (x: Double, y: Double) {
            onAxis(
                expressionAt,
                BloubEngine.shapeMorph,
                BloubEyeFit.eyeOffset(shape: id, state: state, expression: expressionPrevious),
                BloubEyeFit.eyeOffset(shape: id, state: state, expression: expression)
            )
        }

        // then the shape axis
        return onAxis(
            shapeAt,
            BloubEngine.shapeMorph,
            perShape(shapePrevious),
            perShape(shape)
        )
    }

    // MARK: Sampling

    /// The frame at `now`. A pure function of time: calling it twice with the
    /// same argument gives the same answer, and it mutates nothing.
    public func sample(_ now: Double) -> BloubFrame {
        let radius = scale
        let def = BloubStates.state(current)
        let radii = shapeAtTime(now)
        let expression = expressionAtTime(now)
        var pose = posed(def, max(0, now - currentAt), radii, expression)
        var offset = eyeOffsetAtTime(now, current)

        // --- transition ---------------------------------------------------
        let since = now - currentAt
        // The previous state is never purged: comparing against the span is
        // enough to ignore it once the fade is over, and forgetting it would
        // make the engine non-replayable — re-reading a date from before the
        // end of the fade would no longer find it. The span, not the duration:
        // the eyes are still arriving after the body has settled.
        let span = BloubTransition.span(def.morph)
        let start = since < span ? origin(now, radii, expression) : nil
        if let start {
            // An ease-in-out over a chosen 420–600 ms, not bloub's measured
            // exponential ease-out — ``BloubTransition`` says why. Both ratios
            // are clamped inside `curve`: re-reading a date BEFORE the state
            // change would give a negative one, and an unclamped cubic
            // extrapolates it into a silhouette thirty times too far.
            let duration = BloubTransition.duration(def.morph)
            let ratio = BloubTransition.body(since, duration)
            let faceRatio = BloubTransition.face(since, duration)
            pose = blendPose(start, pose, ratio, face: faceRatio)
            if let left = previous {
                let before = eyeOffsetAtTime(now, left)
                offset = (
                    BloubMath.lerp(before.x, offset.x, faceRatio),
                    BloubMath.lerp(before.y, offset.y, faceRatio)
                )
            }
        }

        // --- resting life -------------------------------------------------
        let alive = pose.eyeAlpha > 0.01
        let target = lookAtTime(now)
        let life = BloubFace.liveliness(
            now,
            wander: alive ? target.wander : 0,
            blink: alive,
            drift: drift
        )

        let gaze = BloubGaze(
            // The two aims REPLACE the pose's instead of adding to them, and
            // the spin is subtracted on the way. The drift is added AFTER the
            // mix, otherwise the target would cancel it along with the pose —
            // and it has to survive a head turned with no pointer.
            yaw: BloubMath.lerp(pose.gaze.yaw, target.yaw, target.mix) + life.deltaYaw
                - target.spin,
            pitch: BloubMath.lerp(pose.gaze.pitch, target.pitch, target.mix) + life.deltaPitch,
            // the roll follows nothing: the head is tilted -13° in the video,
            // and rolling it with the cursor breaks that signature
            roll: pose.gaze.roll + life.deltaRoll
        )

        // the blink triggered by the state change, on top of the schedule
        let forced = (now - blinkAt) / BloubFace.forcedBlinkDuration
        let lid = min(life.lid, BloubFace.forcedLid(forced))

        let offX = pose.offsetX + life.driftX
        let offY = pose.offsetY + life.driftY

        // --- body -----------------------------------------------------------
        var silhouette = pose.silhouette
        silhouette.centerX += offX
        silhouette.centerY += offY
        silhouette.scaleY *= life.breath
        let body = BloubShape.closedOutline(BloubShape.points(silhouette, scale: radius))

        // --- eyes -----------------------------------------------------------
        // The eyes live on a sphere of radius 1; as soon as the silhouette
        // stops being a circle they are brought back pro rata the real radius
        // in their direction, otherwise they overflow and the mask cuts them.
        func bodyRadius(_ x: Double, _ y: Double) -> Double {
            BloubShape.radius(pose.silhouette.radii, atAngle: atan2(y, x) - pose.silhouette.rotation)
        }

        var eyes: [BloubEye] = []
        if pose.eyeAlpha > 0.01 {
            let poses = BloubFace.eyePoses(gaze: gaze, scale: radius, split: pose.split)
            for i in 0..<2 {
                let e = i == 0 ? poses.0 : poses.1
                if e.depth <= 0.02 { continue }
                let cfg = i == 0 ? pose.eyes.0 : pose.eyes.1
                let fit = bodyRadius(e.x, e.y)
                // The eye's own tilt: the tangent frame composed with a
                // rotation in the eye's plane (Basis × Rot). That is what
                // allows mirrored tilts between the two eyes.
                let phi = cfg.tilt * .pi / 180
                let cp = cos(phi)
                let sp = sin(phi)
                let ax = e.a * cp + e.c * sp
                let ay = e.b * cp + e.d * sp
                let cx = -e.a * sp + e.c * cp
                let cy = -e.b * sp + e.d * cp
                // The blink applies AFTER all of that: a vertical squash on
                // screen, not along the capsule's axis.
                let k = BloubFace.blinkScale(min(lid, cfg.open))
                eyes.append(
                    BloubEye(
                        width: cfg.width * radius,
                        height: cfg.height * radius,
                        a: ax,
                        b: ay * k,
                        c: cx,
                        d: cy * k,
                        e: e.x * fit + (offX + offset.x) * radius,
                        f: e.y * fit + (offY + offset.y) * radius,
                        alpha: pose.eyeAlpha * BloubMath.clamp(e.depth / 0.12)
                    )
                )
            }
        }

        // --- decor ----------------------------------------------------------
        let dots = pose.dots
            .filter { $0.opacity > 0.01 && $0.radius > 0.0005 }
            .map { dot -> BloubDot in
                var out = dot
                out.x = (dot.x + offX) * radius
                out.y = (dot.y + offY) * radius
                out.radius = dot.radius * radius
                return out
            }

        // the pastille sits on the outline, so it follows the shape too
        var notify: (x: Double, y: Double, radius: Double)?
        var notch: (x: Double, y: Double, radius: Double)?
        if let spec = pose.notify {
            let fit = bodyRadius(spec.x, spec.y)
            let nx = (spec.x * fit + offX) * radius
            let ny = (spec.y * fit + offY) * radius
            notify = (nx, ny, spec.radius * radius)
            notch = (nx, ny, spec.notch * radius)
        }

        return BloubFrame(
            scale: radius,
            body: body,
            bodyAlpha: pose.bodyAlpha,
            eyes: eyes,
            dots: dots,
            dotsBehind: pose.dotsBehind,
            // States declare arcs in ball-radius units; the engine is the only
            // one that knows the viewBox scale, so it does the tracing.
            arcs: pose.arcs
                .filter { $0.opacity > 0.01 }
                .map {
                    BloubDecor.render(
                        $0.seed,
                        time: $0.time,
                        scale: radius,
                        id: $0.id,
                        opacity: $0.opacity
                    )
                },
            notify: notify,
            notch: notch
        )
    }
}
