// Ported from bloub — https://github.com/jeremy-prt/bloub
// MIT License, © 2026 Jérémy Perret. See THIRD_PARTY_NOTICES.md.

import Foundation

/// Where to place the face on a customiser shape.
///
/// The eyes live on a sphere, and ``BloubShape/radius(_:atAngle:)`` re-seats
/// them on the real outline pro rata the local radius. That pro rata places
/// their **centre** correctly, and the eye has a size: the margin left in front
/// of the edge is multiplied by the same factor, so a silhouette that is narrow
/// in the eye's direction pushes it against the edge until the mask opens it
/// outwards. The capsule, the triangle, the cloud and the droplet all did it.
///
/// This module solves the problem **once**, at first use, and yields a table of
/// offsets. That choice is the whole fix, far more than the geometry it
/// contains:
///
/// Solved inside the render loop, the correction reacts to everything that
/// moves at sixty frames a second — the resting gaze drift, the pointer, the
/// expression mid-morph, which edge is nearest, which eye is tightest. bloub
/// wrote seven such versions and every one produced a visible motion artefact:
/// permanent trembling, a 26-unit direction jump when the reference edge
/// switched, an abrupt growth when size entered the calculation. The defect was
/// in none of their geometries; it was in solving per frame.
///
/// The rest of the engine does not work that way: poses are **declared** and it
/// only interpolates them along known curves. A tabulated offset fits that
/// mould. The engine reads the table on the **boundaries** of each morph and
/// interpolates with that morph's own curve — never on the interpolated value,
/// which has no identity and exists in no table.
///
/// The same approach has a name in character rigging: **pose space
/// deformation** (Lewis, Cordner & Fong, SIGGRAPH 2000) — a corrective authored
/// per pose, resolved at setup and merely looked up at runtime.
///
/// ## What not to try again
///
/// Each of these was written and measured by bloub, and each broke something
/// visible: bounding each eye separately (the pair spreads); retreating
/// radially towards the centre (both eyes merge into one blob); scaling the
/// face (the eyes visibly shrink on a flat body); taking the worst eye (the
/// binding eye changes mid-morph and the push direction flips); one entry per
/// shape with a worst case over expressions (no single translation satisfies
/// both a high-eyed and a low-eyed expression); and giving up when nothing
/// fits (the rule is to aim for the least bad, never to leave a real overflow
/// unimproved).
public enum BloubEyeFit {
    /// The solver's reference radius. The offset it returns is in units of it.
    private static let referenceRadius = 100.0

    /// Maximum amplitudes of the resting life, read off
    /// ``BloubFace/liveliness(_:wander:blink:float:)``. `loopNoise` is bounded
    /// to 1 in absolute value, so these sums are exact bounds, not estimates.
    ///
    /// They have to be covered, otherwise the correction is right on the
    /// nominal pose and wrong a second later: 7 degrees of yaw move the eye a
    /// dozen units on a ball of radius 100. That is exactly what made
    /// capsule + frightened overflow while a single-instant measurement
    /// declared it fine.
    private static let driftYaw = 5.5 + 1.6
    private static let driftPitch = 4.2 + 1.3
    /// Float of the centre, in ball-radius units.
    private static let driftX = 0.006
    private static let driftY = 0.007

    /// The centre's float, in viewBox units. It is added to the capsule's
    /// radius: under one unit, so absorbing it this way costs less than
    /// multiplying the trials by its four corners.
    private static let float = hypot(driftX, driftY) * referenceRadius

    /// Directions probed and dichotomy steps. Their product is the cost of
    /// building the table, the only figure worth watching here.
    private static let directions = 12
    private static let bisections = 8

    // MARK: Geometry

    /// A capsule ready to be measured: its axis segment, and what is needed to
    /// compute the radius to clear **in a given direction**.
    ///
    /// A capsule is exactly a segment thickened by a disc of radius `r`. Its
    /// image through the tangent matrix is therefore a segment thickened by an
    /// **ellipse**, and the radius to clear depends on the direction: it is
    /// that ellipse's support function, `r · |Aᵀu|`. Taking its largest
    /// singular value instead would be conservative but wrong in the only
    /// direction that matters, and that costs dearly: the reference margin on
    /// the circle came out NEGATIVE, so the requirement lost its teeth and 34
    /// combinations kept overflowing.
    private struct Footprint {
        /// Centre, in viewBox units.
        var x: Double
        var y: Double
        /// Half-vector of the axis.
        var ax: Double
        var ay: Double
        /// Radius of the local disc, before the transform.
        var r: Double
        /// Columns of the tangent matrix, for the support function.
        var m: (Double, Double, Double, Double)
    }

    /// The face a pose asks for: the expression's if the state accepts one,
    /// its own otherwise.
    private struct FaceSpec {
        var gaze: BloubGaze
        var split: Double
        var eyes: (BloubEyeConfig, BloubEyeConfig)
    }

    /// Both eyes' footprints for a face, laid on a profile.
    ///
    /// The blink is not in it: a shut eye does not need room made for it.
    private static func footprints(
        _ face: FaceSpec,
        _ silhouette: BloubSilhouette,
        _ radii: [Double]
    ) -> [Footprint] {
        var out: [Footprint] = []
        let poses = BloubFace.eyePoses(
            gaze: face.gaze,
            scale: referenceRadius,
            split: face.split
        )
        for i in 0..<2 {
            let e = i == 0 ? poses.0 : poses.1
            if e.depth <= 0.02 { continue }
            let cfg = i == 0 ? face.eyes.0 : face.eyes.1
            let phi = cfg.tilt * .pi / 180
            let cp = cos(phi)
            let sp = sin(phi)
            let ax = e.a * cp + e.c * sp
            let ay = e.b * cp + e.d * sp
            let cx = -e.a * sp + e.c * cp
            let cy = -e.b * sp + e.d * cp

            let hw = max(cfg.width * referenceRadius, 0.01) / 2
            let hh = max(cfg.height * referenceRadius, 0.01) / 2
            let r = min(hw, hh)
            // the axis is the longer dimension's
            let long = hh > hw
            let half = long ? hh - r : hw - r
            // the local radius pro rata, exactly as the engine does it
            let fit = BloubShape.radius(
                radii,
                atAngle: atan2(e.y, e.x) - silhouette.rotation
            )
            out.append(
                Footprint(
                    x: e.x * fit,
                    y: e.y * fit,
                    ax: (long ? cx : ax) * half,
                    ay: (long ? cy : ay) * half,
                    r: r,
                    m: (ax, ay, cx, cy)
                )
            )
        }
        return out
    }

    /// Closest approach between an outline and a segment: the distance, and the
    /// vector pointing from the outline towards the segment — the direction
    /// that clears. Both come out of the **same** pass; computing them
    /// separately doubled the only real cost of this module.
    private static func approach(
        _ pts: [BloubPoint],
        _ x0: Double,
        _ y0: Double,
        _ x1: Double,
        _ y1: Double
    ) -> (d: Double, ux: Double, uy: Double) {
        let sx = x1 - x0
        let sy = y1 - y0
        let len2 = sx * sx + sy * sy
        var best = Double.infinity
        var vx = 0.0
        var vy = 0.0
        for p in pts {
            var t = len2 > 0 ? ((p.x - x0) * sx + (p.y - y0) * sy) / len2 : 0
            t = t < 0 ? 0 : (t > 1 ? 1 : t)
            let ex = x0 + t * sx - p.x
            let ey = y0 + t * sy - p.y
            let d2 = ex * ex + ey * ey
            if d2 < best {
                best = d2
                vx = ex
                vy = ey
            }
        }
        let d = best.squareRoot()
        return (d, d > 1e-9 ? vx / d : 0, d > 1e-9 ? vy / d : 0)
    }

    /// Capsules to fit inside an outline, and the reference outline.
    private struct Trial {
        var footprints: [Footprint]
        var reference: [Footprint]
        var contour: [BloubPoint]
        var referenceContour: [BloubPoint]
    }

    /// The tightest capsule's margin, and the direction that clears it.
    private static func worst(
        _ pts: [BloubPoint],
        _ prints: [Footprint],
        _ tx: Double,
        _ ty: Double
    ) -> Double {
        var margin = Double.infinity
        for e in prints {
            let x = e.x + tx
            let y = e.y + ty
            let a = approach(pts, x - e.ax, y - e.ay, x + e.ax, y + e.ay)
            // support function of the ellipse in the approach's direction
            let radius = e.r * hypot(
                e.m.0 * a.ux + e.m.1 * a.uy,
                e.m.2 * a.ux + e.m.3 * a.uy
            ) + float
            margin = min(margin, a.d - radius)
        }
        return margin
    }

    /// The offset to apply to both eyes for this shape, state and expression.
    ///
    /// A **translation** common to both eyes, hence an isometry: spacing, sizes
    /// and tilts are preserved to the pixel. The face simply sits a little
    /// lower on a body that has no room up there — the gesture you would make
    /// by hand.
    ///
    /// The margin aimed for is the **original** profile's, not clearance: on
    /// the circle the outer eye already grazes the edge, deliberately, and that
    /// is what gives the volume. It is capped by what the shape can offer at
    /// its centre, otherwise the requirement is unmeetable on a flat body.
    ///
    /// A **directional search**, not a descent: we look for the smallest-norm
    /// translation that fits, so we probe a ring of directions and bisect the
    /// distance along each. A gradient descent was written first and does not
    /// converge — clearing the pair from one edge brings it closer to another,
    /// so it gropes and only keeps its best try.
    private static func solve(_ trials: [Trial]) -> (x: Double, y: Double) {
        guard let first = trials.first else { return (0, 0) }

        /// The tightest margin over every trial, for a given translation.
        func margin(_ tx: Double, _ ty: Double) -> Double {
            var m = Double.infinity
            for trial in trials {
                m = min(m, worst(trial.contour, trial.footprints, tx, ty))
            }
            return m
        }

        // Required margin: the tightest the original profile tolerates, over
        // every trial. Then capped by the most clearance the shape can offer
        // the pair — its centre.
        var required = Double.infinity
        for trial in trials {
            required = min(required, worst(trial.referenceContour, trial.reference, 0, 0))
        }

        // The travel must be able to reach the body's centre: `wide` has
        // 87-unit capsules, and on a triangle they only fit towards the middle,
        // some fifty units from their nominal place. A fixed travel left them
        // outside.
        var mx = 0.0
        var my = 0.0
        let prints = first.footprints
        for e in prints {
            mx -= e.x / Double(prints.count)
            my -= e.y / Double(prints.count)
        }
        let travel = max(0.35 * referenceRadius, hypot(mx, my) * 1.25)

        required = min(required, margin(mx, my))

        // Already fine: the circle's case, and any shape wide enough. The
        // capsule must FIT as well as being no tighter than on the original
        // profile — without that second condition, a shape where nothing fits
        // satisfies the first degenerately and we would give up.
        let start = margin(0, 0)
        if start >= required, start >= 0 { return (0, 0) }
        let target = max(required, 0)

        var bestX = 0.0
        var bestY = 0.0
        var bestNorm = Double.infinity
        // fallback when nothing fits: the translation that clears the most,
        // probed along the way
        var fallbackX = 0.0
        var fallbackY = 0.0
        var fallback = start

        for d in 0..<directions {
            let a = Double(d) / Double(directions) * .pi * 2
            let ux = cos(a)
            let uy = sin(a)
            if margin(ux * travel, uy * travel) < target {
                // no solution that way, but perhaps a better clearance
                for k in [0.3, 0.6, 1.0] {
                    let m = margin(ux * travel * k, uy * travel * k)
                    if m > fallback {
                        fallback = m
                        fallbackX = ux * travel * k
                        fallbackY = uy * travel * k
                    }
                }
                continue
            }
            // the shortest distance that fits, along this direction
            var low = 0.0
            var high = travel
            for _ in 0..<bisections {
                let mid = (low + high) / 2
                if margin(ux * mid, uy * mid) >= target { high = mid } else { low = mid }
            }
            if high < bestNorm {
                bestNorm = high
                bestX = ux * high
                bestY = uy * high
            }
        }

        let x = bestNorm == .infinity ? fallbackX : bestX
        let y = bestNorm == .infinity ? fallbackY : bestY
        // returned in BALL-RADIUS units: the engine puts it back to its scale
        return (
            (x / referenceRadius * 1_000_000).rounded() / 1_000_000,
            (y / referenceRadius * 1_000_000).rounded() / 1_000_000
        )
    }

    // MARK: The table

    /// The dates to sample in a state: one only if its pose does not move.
    private static func dates(_ def: BloubStateDef) -> [Double] {
        func signature(_ p: BloubPose) -> String {
            "\(p.gaze) \(p.split) \(p.eyes.0) \(p.eyes.1) "
                + "\(p.silhouette.rotation) \(p.silhouette.centerX) \(p.silhouette.centerY) "
                + "\(p.silhouette.scaleX) \(p.silhouette.scaleY)"
        }
        if signature(def.pose(0)) == signature(def.pose(def.duration)) { return [0] }
        let n = 3
        return (0..<n).map { Double($0) / Double(n - 1) * def.duration }
    }

    private static func face(
        _ def: BloubStateDef,
        _ pose: BloubPose,
        _ expression: BloubExpression?
    ) -> FaceSpec {
        if def.usesBaseFace, let expression {
            return FaceSpec(gaze: expression.gaze, split: expression.split, eyes: expression.eyes)
        }
        return FaceSpec(gaze: pose.gaze, split: pose.split, eyes: pose.eyes)
    }

    /// One shape's offset on one state and one expression, drift included.
    private static func offset(
        _ def: BloubStateDef,
        _ radii: [Double],
        _ expression: BloubExpression?
    ) -> (x: Double, y: Double) {
        var trials: [Trial] = []
        for t in dates(def) {
            let pose = def.pose(t)
            var swapped = pose.silhouette
            swapped.radii = radii
            let contour = BloubShape.points(swapped, scale: referenceRadius)
            let referenceContour = BloubShape.points(pose.silhouette, scale: referenceRadius)
            let spec = face(def, pose, expression)
            // The drift's four corners bound the nominal pose, which is their
            // centre: testing it as well would change no margin and cost one
            // trial in five.
            for dy in [-driftYaw, driftYaw] {
                for dp in [-driftPitch, driftPitch] {
                    let corner = FaceSpec(
                        gaze: BloubGaze(
                            yaw: spec.gaze.yaw + dy,
                            pitch: spec.gaze.pitch + dp,
                            roll: spec.gaze.roll
                        ),
                        split: spec.split,
                        eyes: spec.eyes
                    )
                    trials.append(
                        Trial(
                            footprints: footprints(corner, pose.silhouette, radii),
                            reference: footprints(
                                corner,
                                pose.silhouette,
                                pose.silhouette.radii
                            ),
                            contour: contour,
                            referenceContour: referenceContour
                        )
                    )
                }
            }
        }
        return solve(trials)
    }

    private struct Key: Hashable {
        var shape: BloubShapeID
        var state: BloubStateID
        var expression: BloubExpressionID?
    }

    /// The offsets table, built on first use: one entry per (shape, base-body
    /// state, expression).
    ///
    /// Only `idle` and `swirl` wear the resting face, so only they vary by
    /// expression — the other three base-body states have a face measured off
    /// the video and get a single entry.
    ///
    /// A Swift `static let` is a lazy, `swift_once`-guarded constant built from
    /// pure data: the same nature as ``BloubFace/blinks``, deterministic and
    /// stateless, so ``BloubEngine/sample(_:)`` stays a pure function of time.
    private static let table: [Key: (x: Double, y: Double)] = {
        var out: [Key: (x: Double, y: Double)] = [:]
        for shape in BloubSkins.all {
            for def in BloubStates.all where def.usesBaseBody {
                let expressions: [BloubExpression?] =
                    def.usesBaseFace ? [nil] + BloubExpressions.all.map { $0 } : [nil]
                for expression in expressions {
                    let key = Key(shape: shape.id, state: def.id, expression: expression?.id)
                    out[key] = offset(def, shape.radii, expression)
                }
            }
        }
        return out
    }()

    /// The offset to apply to both eyes for this shape on this state, in
    /// ball-radius units — the engine puts it back to its scale.
    ///
    /// Zero as soon as there is no chosen shape, which covers the circle too:
    /// on the circle both profiles are the same, so the margin is already the
    /// one required and the search exits on its first test. The silhouette
    /// measured off the video therefore does not move, with no special case.
    public static func eyeOffset(
        shape: BloubShapeID?,
        state: BloubStateID,
        expression: BloubExpressionID?
    ) -> (x: Double, y: Double) {
        guard let shape else { return (0, 0) }
        // a state with no resting face has one entry, whatever the expression
        return table[Key(shape: shape, state: state, expression: expression)]
            ?? table[Key(shape: shape, state: state, expression: nil)]
            ?? (0, 0)
    }
}
