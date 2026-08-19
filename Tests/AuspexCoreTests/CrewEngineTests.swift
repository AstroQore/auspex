import AuspexCore
import Foundation
import Testing

/// What the ported avatar engine guarantees.
///
/// Two kinds of assertion live here and they are not the same thing. The
/// **golden** ones pin numbers that were measured off the reference video and
/// must never drift — if one of them fails, either the port broke or somebody
/// "tidied" a constant, and both are bugs. The **property** ones pin the rules
/// the whole design rests on: purity, linear morphing, a blink over every shape
/// change. Those survive a re-measurement; the goldens are the re-measurement.
@Suite("Crew engine")
struct CrewEngineTests {
    /// The reference radius everything is expressed in.
    private static let radius = BloubFrameOfReference.radius

    // MARK: Golden geometry

    /// bloub's `public/favicon.svg` is not a lookalike drawing: its circle and
    /// **both eye matrices** are what `engine.sample(1)` returns for `idle`,
    /// byte for byte. That makes it the one golden nobody can argue with, and
    /// reproducing it exercises the whole chain at once — the sphere model, the
    /// mulberry32 blink schedule, the drift noise and the tangent frame.
    @Test("the resting face reproduces bloub's favicon, digit for digit")
    func faviconGolden() {
        let engine = BloubEngine(state: .idle)
        let frame = engine.sample(1)
        #expect(frame.eyes.count == 2)

        func rounded(_ e: BloubEye) -> [Double] {
            [e.a, e.b, e.c, e.d, e.e, e.f].map { ($0 * 100).rounded() / 100 }
        }
        #expect(rounded(frame.eyes[0]) == [0.87, -0.33, 0.45, 0.84, 21.42, -43.32])
        #expect(rounded(frame.eyes[1]) == [0.64, -0.06, 0.45, 0.84, 62.98, -53.9])
    }

    /// The measured eye geometry of a resting circle, from
    /// `docs/measurements.md`: the capsule's own size, the far eye compressed
    /// to about 0.69 of the near one by the sphere's depth, and a lean of about
    /// 26° off vertical — in the `\` direction, not `/`.
    @Test("an idle circle carries the measured eye geometry")
    func idleEyeGeometry() {
        let engine = BloubEngine(state: .idle, shape: .circle, expression: .neutral)
        let frame = engine.sample(0)
        #expect(frame.eyes.count == 2)

        // The capsule itself is the same for both eyes; the depth compression
        // lives in the matrix, not in the size.
        for eye in frame.eyes {
            #expect(abs(eye.width - BloubFace.eyeWidth * Self.radius) < 1e-9)
            #expect(abs(eye.height - BloubFace.eyeHeight * Self.radius) < 1e-9)
        }

        // Apparent width = the length of the matrix's first column.
        let near = hypot(frame.eyes[0].a, frame.eyes[0].b)
        let far = hypot(frame.eyes[1].a, frame.eyes[1].b)
        #expect(far < near)
        // 0.69 in `face.ts`, 0.674 raw from the video, ~0.708 from the fitted
        // model: source against fit, and the drift moves it a little either
        // way. The band covers that spread and nothing more.
        #expect((0.66...0.72).contains(far / near))

        // The long axis is the matrix's second column. Both components
        // positive, in a frame where y points down, is a `\`.
        for eye in frame.eyes {
            #expect(eye.c > 0)
            #expect(eye.d > 0)
            let lean = atan2(eye.c, eye.d) * 180 / .pi
            #expect((24.0...30.0).contains(lean))
        }
    }

    /// The rings and the comet's swoosh are what sets the viewBox: nothing
    /// bounds them at runtime, it is the hand tuning of their tables that keeps
    /// them inside. bloub locks it with a test and so does this port, because
    /// the failure mode is an avatar clipped at the card's edge.
    @Test("no decor reaches beyond the viewBox")
    func decorStaysInside() {
        let limit = BloubFrameOfReference.halfViewBox
        for seed in BloubDecor.rings + BloubDecor.swoosh + BloubDecor.cometRibbons {
            let reach = (seed.a + seed.width / 2 + max(abs(seed.centerX), abs(seed.centerY)))
                * BloubFrameOfReference.radius
            #expect(reach < limit)
        }
    }

    /// A tilt is only visible on an elongated eye: an eye whose width/height
    /// ratio approaches 1 is a circle and looks the same at every angle. bloub
    /// enforces a two-tier rule, having got it wrong once.
    @Test("every tilted expression has eyes elongated enough to show it")
    func tiltsAreVisible() {
        for expression in BloubExpressions.all {
            for eye in [expression.eyes.0, expression.eyes.1] {
                let ratio = eye.width / eye.height
                if abs(eye.tilt) >= 20 {
                    #expect(ratio < 0.6 || ratio > 1.7, "\(expression.id) ratio \(ratio)")
                } else if abs(eye.tilt) > 0 {
                    #expect(ratio < 0.8 || ratio > 1.25, "\(expression.id) ratio \(ratio)")
                }
            }
        }
    }

    // MARK: Purity

    @Test("the same instant gives the same frame")
    func deterministic() {
        var engine = BloubEngine(state: .idle, shape: .droplet, expression: .neutral)
        engine.setState(.orbit, at: 1)
        let a = engine.sample(1.3)
        let b = engine.sample(1.3)
        #expect(a.body.start == b.body.start)
        #expect(a.body.curves == b.body.curves)
        #expect(a.eyes == b.eyes)
        #expect(a.arcs == b.arcs)
        #expect(a.dots == b.dots)
    }

    /// Re-reading a date from **before** the end of a fade must still find it.
    ///
    /// The tempting optimisation is to drop the previous state once the morph
    /// is over. It looks innocent and it makes the engine non-replayable, which
    /// is what pausing, scrubbing and the whole test suite depend on. bloub
    /// broke this once on the shape morph and keeps a dedicated test for it.
    @Test("sampling forwards does not change what an earlier instant returns")
    func replayable() {
        var engine = BloubEngine(state: .idle, shape: .circle, expression: .neutral)
        engine.setState(.wide, at: 5)
        let midFade = engine.sample(5.2)
        // walk well past the end of the morph
        for i in 0..<200 { _ = engine.sample(5 + Double(i) * 0.02) }
        let again = engine.sample(5.2)
        #expect(midFade.eyes == again.eyes)
        #expect(midFade.body.curves == again.body.curves)
    }

    /// A negative elapsed time — re-reading a date before the state change —
    /// must not extrapolate the ease-out. Unclamped it sends the silhouette
    /// thirty times too far.
    @Test("a date before the state change does not blow the silhouette up")
    func clampedRatio() {
        var engine = BloubEngine(state: .idle, shape: .circle, expression: .neutral)
        engine.setState(.wide, at: 5)
        let before = engine.sample(4.5)
        let reach = before.body.curves.map { hypot($0.end.x, $0.end.y) }.max() ?? 0
        #expect(reach < BloubFrameOfReference.halfViewBox)
    }

    // MARK: Morphing

    /// All silhouettes share one angular sampling, so a morph between any two
    /// is a linear interpolation of radii. That is the invariant the absence of
    /// a path-morphing library rests on.
    @Test("blending two profiles interpolates their radii linearly")
    func profilesInterpolateLinearly() {
        let a = BloubShape.circle(1)
        let b = BloubShape.silhouette(.triangle)
        for t in [0.0, 0.25, 0.5, 0.75, 1.0] {
            let mid = BloubShape.blend(a, b, t)
            #expect(mid.radii.count == BloubProfiles.sampleCount)
            for i in 0..<BloubProfiles.sampleCount {
                let expected = a.radii[i] + (b.radii[i] - a.radii[i]) * t
                #expect(abs(mid.radii[i] - expected) < 1e-12)
            }
        }
    }

    /// Every customiser shape goes through a radial profile at the shared
    /// sampling. A shape that did not would break morphing for every pair it
    /// belongs to, not just for itself.
    @Test("every shape is sampled at the shared angles")
    func everyShapeSharesTheSampling() {
        for shape in BloubSkins.all {
            #expect(shape.radii.count == BloubProfiles.sampleCount)
            #expect(shape.radii.allSatisfy { $0 > 0 && $0.isFinite })
        }
    }

    /// The body never overshoots: the transitions are exponential ease-outs,
    /// and the one spring in the engine is the notification pastille's pop.
    @Test("a morph towards a bigger body never overshoots it")
    func noOvershoot() {
        var engine = BloubEngine(state: .sleep)
        engine.setState(.idle, at: 3)
        let settled = engine.sample(9)
        let settledReach = settled.body.curves.map { hypot($0.end.x, $0.end.y) }.max() ?? 0
        for i in 0...60 {
            let frame = engine.sample(3 + Double(i) * 0.01)
            let reach = frame.body.curves.map { hypot($0.end.x, $0.end.y) }.max() ?? 0
            // a per-mille of slack for the 0.5 % breath, which is not overshoot
            #expect(reach <= settledReach * 1.01)
        }
    }

    // MARK: Easing

    /// The one property that separates this port's transitions from the ones
    /// that were called stiff: the body does not move at a constant rate.
    ///
    /// Measured the way an eye measures it — the distance between consecutive
    /// frames. A linear morph gives the same gap every frame; an ease-in-out
    /// gives a small gap, a big one, a small one. Taking the mean radius about
    /// the outline's own centroid rather than the reach from the origin is what
    /// makes the number mean "how much did the shape change" and not "where did
    /// it drift to".
    @Test("a morph accelerates through its middle and decelerates out of it")
    func morphIsNotLinear() {
        var engine = BloubEngine(state: .idle, shape: .circle, expression: .neutral)
        let change = 5.0
        engine.setState(.sleep, at: change)
        let duration = BloubTransition.duration(BloubStates.state(.sleep).morph)

        let step = 0.01
        let count = Int((duration / step).rounded())
        var deltas: [Double] = []
        var previous = Self.meanRadius(engine.sample(change))
        for i in 1...count {
            let radius = Self.meanRadius(engine.sample(change + Double(i) * step))
            deltas.append(abs(radius - previous))
            previous = radius
        }

        let third = deltas.count / 3
        func mean(_ slice: ArraySlice<Double>) -> Double {
            slice.reduce(0, +) / Double(slice.count)
        }
        let first = mean(deltas[..<third])
        let middle = mean(deltas[third..<(third * 2)])
        let last = mean(deltas[(third * 2)...])

        // accelerates in, decelerates out
        #expect(first < middle)
        #expect(last < middle)
        // and by a margin nobody could mistake for sampling noise: the cubic
        // puts about four and a half times as much travel in the middle third
        #expect(middle > first * 2)
        #expect(middle > last * 2)
        // never constant, which is what a linear ramp would give
        #expect((deltas.max() ?? 0) > (deltas.min() ?? 1) * 3)
    }

    /// The mean distance from the outline to its own centroid, in viewBox
    /// units: "how big is this shape", with the drift divided out.
    private static func meanRadius(_ frame: BloubFrame) -> Double {
        let points = frame.body.curves.map(\.end)
        guard !points.isEmpty else { return 0 }
        let n = Double(points.count)
        let cx = points.reduce(0) { $0 + $1.x } / n
        let cy = points.reduce(0) { $0 + $1.y } / n
        return points.reduce(0) { $0 + hypot($1.x - cx, $1.y - cy) } / n
    }

    /// A blink is not a triangle wave. The lid falls on an ease-in over 45 % of
    /// the blink and rises on an ease-out over the other 55 %, so shutting is
    /// both shorter and faster than opening.
    @Test("the blink curve is asymmetric — shut fast, open slow")
    func blinkIsAsymmetric() {
        // 1.4 s is the first scheduled blink, and nothing else is happening.
        let start = 1.4
        let span = BloubFace.blinkDuration
        func lid(_ k: Double) -> Double { BloubFace.liveliness(start + k * span).lid }

        // Shut somewhere in the middle, open at both ends.
        #expect(lid(0) > 0.99)
        #expect(lid(0.45) < 0.01)
        #expect(lid(1) > 0.99)

        // How far either side of the shut point the lid is half-way.
        func halfway(_ from: Double, _ to: Double) -> Double {
            var k = from
            let step = (to - from) / 4_000
            while abs(k - to) > abs(step) {
                if (from < to && lid(k) <= 0.5) || (from > to && lid(k) <= 0.5) { break }
                k += step
            }
            return k
        }
        let closing = 0.45 - halfway(0, 0.45)
        let opening = halfway(1, 0.45) - 0.45
        #expect(closing > 0)
        #expect(opening > closing * 1.15)

        // And the fastest part of shutting is faster than the fastest part of
        // opening — the "fast shut, slower reopen" the reference asks for.
        func speed(_ k: Double) -> Double { abs(lid(k + 0.001) - lid(k - 0.001)) }
        let shutting = stride(from: 0.02, to: 0.44, by: 0.005).map(speed).max() ?? 0
        let reopening = stride(from: 0.46, to: 0.98, by: 0.005).map(speed).max() ?? 0
        #expect(shutting > reopening)
    }

    /// The face trails the body by ``BloubTransition/eyeLag``, so the head
    /// follows the shape rather than moving with it.
    @Test("the eyes are still arriving when the body has settled")
    func eyesTrailTheBody() {
        var engine = BloubEngine(state: .idle, shape: .circle, expression: .neutral)
        engine.setState(.wide, at: 5)
        let duration = BloubTransition.duration(BloubStates.state(.wide).morph)
        let settled = engine.sample(9).eyes[0].width

        // The body's morph is over here; the eyes are not.
        #expect(engine.sample(5 + duration).eyes[0].width < settled)
        // One eye-lag later they are.
        let arrived = engine.sample(5 + duration + BloubTransition.eyeLag + 0.001).eyes[0].width
        #expect(abs(arrived - settled) < 1e-9)
    }

    /// Spinning something up by multiplying its *angle* by a ramp overshoots
    /// cruise and falls back to it; integrating the ramp does not. This is the
    /// mechanism the orbit's rotation rests on.
    @Test("an eased spin-up leaves from rest and never overshoots cruise")
    func easedSpinUp() {
        let span = 0.5
        func speed(_ t: Double) -> Double {
            (BloubMath.easedTravel(t + 1e-6, span: span)
                - BloubMath.easedTravel(t - 1e-6, span: span)) / 2e-6
        }
        #expect(speed(0.002) < 0.02)
        #expect(abs(speed(span) - 1) < 0.01)
        #expect(abs(speed(span * 3) - 1) < 1e-6)
        for i in 0...200 {
            #expect(speed(Double(i) * span / 100) <= 1.0001)
        }
    }

    /// The thinking dots used to be a half-cosine doubled and clamped, which
    /// dropped a dot from full brightness to nothing between two frames. A
    /// pulse may be sharp; it may not have an edge in it.
    @Test("the thinking dots pulse without an on/off edge")
    func thinkingPulseHasNoEdge() {
        let pose = BloubStates.state(.thinking).pose
        var previous: [Double]?
        var biggestStep = 0.0
        for i in 0...4_000 {
            let opacities = pose(Double(i) * 0.001).dots.map(\.opacity)
            if let previous, previous.count == opacities.count {
                for (a, b) in zip(previous, opacities) {
                    biggestStep = max(biggestStep, abs(a - b))
                }
            }
            previous = opacities
        }
        // A millisecond apart. The clamped version stepped by 0.45 here.
        #expect(biggestStep < 0.01)
    }

    /// A blanket guard over the catalogue: nothing any state draws may change
    /// size or place in a jump, whatever else it does.
    @Test("no state's silhouette moves in a jump")
    func silhouettesAreContinuous() {
        for def in BloubStates.all {
            var previousRadius: Double?
            var previousCentre: Double?
            for i in 0...Int(def.duration * 1_000) {
                let s = def.pose(Double(i) / 1_000).silhouette
                let radius = s.radii.reduce(0, +) / Double(s.radii.count)
                let centre = hypot(s.centerX, s.centerY)
                if let previousRadius {
                    #expect(abs(radius - previousRadius) < 0.01, "\(def.id) radius at \(i) ms")
                }
                if let previousCentre {
                    #expect(abs(centre - previousCentre) < 0.01, "\(def.id) centre at \(i) ms")
                }
                previousRadius = radius
                previousCentre = centre
            }
        }
    }

    // MARK: The resting walk

    /// The wall's drift model: continuous, inside bloub's own amplitudes, and
    /// genuinely different from one avatar to the next.
    @Test("each seed gives its own continuous resting drift")
    func wanderIsPerAvatar() {
        for seed in [UInt32(1), 7, 4_242, 99_991] {
            var previous: BloubLiveliness?
            var biggestStep = 0.0
            var reach = 0.0
            for i in 0...6_000 {
                let life = BloubFace.liveliness(Double(i) * 0.01, drift: .wander(seed: seed))
                if let previous {
                    biggestStep = max(biggestStep, abs(life.deltaYaw - previous.deltaYaw))
                    biggestStep = max(biggestStep, abs(life.deltaPitch - previous.deltaPitch))
                }
                reach = max(reach, max(abs(life.deltaYaw), abs(life.deltaPitch)))
                previous = life
            }
            // 10 ms apart: a walk, not a set of teleports.
            #expect(biggestStep < 0.5, "seed \(seed) stepped \(biggestStep)°")
            // and it stays inside the range bloub's own noise covers
            #expect(reach < 9, "seed \(seed) reached \(reach)°")
            #expect(reach > 3, "seed \(seed) only reached \(reach)°")
        }
        // Two avatars are not looking the same way at the same moment.
        let apart = (0...40).map { i -> Double in
            let t = Double(i) * 0.25
            return abs(
                BloubFace.liveliness(t, drift: .wander(seed: 1)).deltaYaw
                    - BloubFace.liveliness(t, drift: .wander(seed: 2)).deltaYaw
            )
        }
        #expect((apart.reduce(0, +) / Double(apart.count)) > 1)
    }

    // MARK: The forced blink

    /// A state change into a `blinkIn` state still blinks — but the blink is
    /// centred on the **morph's** midpoint, not fired at its start.
    ///
    /// bloub uses the blink to hide the shape change; Auspex wants the change
    /// seen, so the blink lands in the middle of it as punctuation and the
    /// morph runs on either side with the eyes open. ``BloubTransition``
    /// carries the reasoning.
    @Test("a state change into a blinking state shuts the eyes at the morph's midpoint")
    func forcedBlink() {
        // 11.5 s sits between two scheduled blinks, so what is measured here is
        // the forced one and nothing else.
        var engine = BloubEngine(state: .idle, shape: .circle, expression: .neutral)
        let open = engine.sample(11.5).eyes[0]
        engine.setState(.wide, at: 11.5)

        let midpoint = 11.5 + BloubTransition.duration(BloubStates.state(.wide).morph) / 2
        let shut = engine.sample(midpoint).eyes[0]
        let opening = engine.sample(midpoint + 0.09).eyes[0]

        // The blink is a vertical squash: only the y outputs shrink.
        #expect(abs(shut.d) < abs(open.d) * 0.2)
        #expect(abs(opening.d) > abs(shut.d) * 3)
        // and the morph starts and ends with the eyes open, which is the point
        #expect(abs(engine.sample(11.53).eyes[0].d) > abs(open.d) * 0.7)
    }

    @Test("a state change into a non-blinking state does not force one")
    func noForcedBlink() {
        var engine = BloubEngine(state: .idle, shape: .circle, expression: .neutral)
        let open = engine.sample(11.5).eyes[0]
        engine.setState(.orbit, at: 11.5)
        let midpoint = 11.5 + BloubTransition.duration(BloubStates.state(.orbit).morph) / 2
        #expect(abs(engine.sample(midpoint).eyes[0].d) > abs(open.d) * 0.5)
    }

    /// Which states carry the blink is measured, not chosen: it is the list of
    /// shape changes the video hides.
    @Test("the states that blink in are the measured ones")
    func blinkingStates() {
        let blinking = Set(BloubStates.all.filter(\.blinkIn).map(\.id))
        #expect(blinking == [.thinking, .wink, .wide, .notify, .egg, .hexagon, .play, .swirl])
    }

    // MARK: Resting life

    /// At rest the avatar does **not** float: the video measures the centre
    /// stable to ±0.003. What is kept is a drift of a few thousandths of the
    /// radius and a 0.5 % breath, purely so the image is not frozen. All the
    /// visible life is the gaze and the blinking.
    @Test("an idle body does not float")
    func noFloat() {
        let engine = BloubEngine(state: .idle, shape: .circle, expression: .neutral)
        var minX = Double.infinity
        var maxX = -Double.infinity
        var minY = Double.infinity
        var maxY = -Double.infinity
        for i in 0..<600 {
            let life = BloubFace.liveliness(Double(i) * 0.05)
            minX = min(minX, life.driftX)
            maxX = max(maxX, life.driftX)
            minY = min(minY, life.driftY)
            maxY = max(maxY, life.driftY)
            #expect(abs(life.breath - 1) <= 0.005 + 1e-12)
        }
        #expect(maxX - minX < 0.02)
        #expect(maxY - minY < 0.02)
        // and the eyes are alive over the same window
        let lids = (0..<600).map { BloubFace.liveliness(Double($0) * 0.05).lid }
        #expect(lids.contains { $0 < 0.5 })
        _ = engine
    }

    /// Every state names the instant it reads most clearly at. That is the
    /// pose bloub's own frozen state board shows, and the one this port holds
    /// when Reduce Motion is on — so a missing entry would be an avatar stuck
    /// on an arbitrary frame.
    @Test("every state names its most legible instant")
    func poseTimes() {
        for state in BloubStateID.allCases {
            let time = BloubStates.poseTime[state]
            #expect(time != nil, "\(state) has no pose time")
            #expect((time ?? 0) > 0)
            #expect((time ?? 0) <= BloubStates.state(state).duration)
        }
    }

    // MARK: Auspex's own addition

    /// A replay blends out of the pose that was on screen, so the seam is
    /// continuous rather than a cut — which is the only reason a held state may
    /// be replayed at all.
    @Test("replaying a held state is continuous")
    func replayIsContinuous() {
        var engine = BloubEngine(state: .orbit)
        let before = engine.sample(2.5)
        engine.replay(at: 2.5)
        let after = engine.sample(2.5)
        let moved = zip(before.body.curves, after.body.curves)
            .map { hypot($0.end.x - $1.end.x, $0.end.y - $1.end.y) }
            .max() ?? 0
        #expect(moved < 0.001)
        // and the rings do not blink out: both sets are on screen mid-fade
        #expect(engine.sample(2.8).arcs.count >= before.arcs.count)
    }
}
