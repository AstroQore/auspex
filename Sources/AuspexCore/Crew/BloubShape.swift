// Ported from bloub — https://github.com/jeremy-prt/bloub
// MIT License, © 2026 Jérémy Perret. See THIRD_PARTY_NOTICES.md.

import Foundation

/// A point in the engine's frame: x right, y **down**, origin at the ball's
/// centre.
public struct BloubPoint: Sendable, Hashable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

/// One cubic segment of a closed outline.
public struct BloubCubic: Sendable, Hashable {
    public var control1: BloubPoint
    public var control2: BloubPoint
    public var end: BloubPoint

    public init(control1: BloubPoint, control2: BloubPoint, end: BloubPoint) {
        self.control1 = control1
        self.control2 = control2
        self.end = end
    }
}

/// A closed outline as cubics, ready to be replayed into whatever path type
/// the renderer has.
///
/// bloub emits an SVG `d` string here. This port emits the geometry instead:
/// a `Canvas` wants points, and a string would have to be parsed back. The one
/// thing dropped along the way is bloub's `r2` two-decimal rounding, which was
/// there to halve the weight of path strings generated at 60 fps — a
/// serialisation trick, not a measurement.
public struct BloubOutline: Sendable, Hashable {
    public var start: BloubPoint
    public var curves: [BloubCubic]

    public init(start: BloubPoint, curves: [BloubCubic]) {
        self.start = start
        self.curves = curves
    }

    public static let empty = BloubOutline(start: BloubPoint(x: 0, y: 0), curves: [])
}

/// A silhouette: a radial profile r(theta) plus a pose.
///
/// Everything goes through profiles sampled at the **same** angles
/// (``BloubProfiles/sampleCount``), so any two shapes have points that
/// correspond one to one and a morph is a linear interpolation of radii. That
/// is what makes the transitions clean without a path-morphing library.
public struct BloubSilhouette: Sendable, Hashable {
    /// One radius per sample angle, in ball-radius units.
    public var radii: [Double]
    /// Rotation of the profile, radians.
    public var rotation: Double
    /// Centre offset, in ball-radius units.
    public var centerX: Double
    public var centerY: Double
    /// Squash & stretch, applied in screen space (after the rotation).
    public var scaleX: Double
    public var scaleY: Double

    public init(
        radii: [Double],
        rotation: Double = 0,
        centerX: Double = 0,
        centerY: Double = 0,
        scaleX: Double = 1,
        scaleY: Double = 1
    ) {
        self.radii = radii
        self.rotation = rotation
        self.centerX = centerX
        self.centerY = centerY
        self.scaleX = scaleX
        self.scaleY = scaleY
    }
}

/// The shape toolbox: building profiles, blending them, projecting them.
public enum BloubShape {
    /// The sample angles, and their sines and cosines, computed once.
    public static let angles: [Double] = (0..<BloubProfiles.sampleCount).map {
        Double($0) / Double(BloubProfiles.sampleCount) * bloubTau
    }
    static let cosines: [Double] = angles.map(cos)
    static let sines: [Double] = angles.map(sin)

    /// One of the three measured silhouettes, with a pose.
    public static func silhouette(
        _ name: BloubProfiles.Name,
        rotation: Double = 0,
        centerX: Double = 0,
        centerY: Double = 0,
        scaleX: Double = 1,
        scaleY: Double = 1
    ) -> BloubSilhouette {
        BloubSilhouette(
            radii: name.radii,
            rotation: rotation,
            centerX: centerX,
            centerY: centerY,
            scaleX: scaleX,
            scaleY: scaleY
        )
    }

    /// A perfect circle: the neutral base — the dot, the bubble, the target of
    /// every fade.
    ///
    /// The body in the video **is** a perfect circle, not a squircle: radial
    /// deviation under 0.7 %. That is one of the traps bloub lists as
    /// verified and not to be "corrected".
    public static func circle(
        _ radius: Double,
        rotation: Double = 0,
        centerX: Double = 0,
        centerY: Double = 0,
        scaleX: Double = 1,
        scaleY: Double = 1
    ) -> BloubSilhouette {
        BloubSilhouette(
            radii: [Double](repeating: radius, count: BloubProfiles.sampleCount),
            rotation: rotation,
            centerX: centerX,
            centerY: centerY,
            scaleX: scaleX,
            scaleY: scaleY
        )
    }

    /// The brood's shape: an egg.
    ///
    /// ## Why the members are a different shape at all
    ///
    /// A flock card is one lead and everything it spawned. Drawn in the same
    /// silhouette at two sizes, that reads as *one big session and some small
    /// sessions*, and the reader has to work out which is which from the
    /// geometry every time. Drawn as a bird and a brood of chicks it reads
    /// itself: the thing a person is talking to, and the things it started.
    ///
    /// An egg rather than a smaller circle, because the difference has to
    /// survive being 22 points tall. A superellipse a little narrower than
    /// tall, with the lower half widened, is the whole of it — the face on top
    /// is the engine's own, so a chick still blinks and looks around like
    /// everything else on this wall.
    public static func chick(
        _ radius: Double,
        rotation: Double = 0,
        centerX: Double = 0,
        centerY: Double = 0
    ) -> BloubSilhouette {
        let base = superellipseProfile(2.15, sx: 0.86, sy: 1)
        // `sines` runs clockwise from the positive x axis and the canvas has y
        // growing downward, so a positive sine is *below* the middle. Widening
        // there is what makes an egg rather than a pear standing on its point.
        let radii = (0..<BloubProfiles.sampleCount).map { i in
            base[i] * radius * (1 + 0.11 * sines[i])
        }
        return BloubSilhouette(
            radii: radii,
            rotation: rotation,
            centerX: centerX,
            centerY: centerY,
            scaleX: 1,
            scaleY: 1
        )
    }

    /// Interpolates two silhouettes.
    public static func blend(
        _ a: BloubSilhouette,
        _ b: BloubSilhouette,
        _ t: Double
    ) -> BloubSilhouette {
        var radii = [Double](repeating: 1, count: BloubProfiles.sampleCount)
        for i in 0..<BloubProfiles.sampleCount {
            let ra = i < a.radii.count ? a.radii[i] : 1
            let rb = i < b.radii.count ? b.radii[i] : 1
            radii[i] = BloubMath.lerp(ra, rb, t)
        }
        // Shortest-path rotation: avoids a full turn when going from, say,
        // +170° to -170°.
        var delta = b.rotation - a.rotation
        while delta > .pi { delta -= bloubTau }
        while delta < -.pi { delta += bloubTau }
        return BloubSilhouette(
            radii: radii,
            rotation: a.rotation + delta * t,
            centerX: BloubMath.lerp(a.centerX, b.centerX, t),
            centerY: BloubMath.lerp(a.centerY, b.centerY, t),
            scaleX: BloubMath.lerp(a.scaleX, b.scaleX, t),
            scaleY: BloubMath.lerp(a.scaleY, b.scaleY, t)
        )
    }

    /// Projects a silhouette to screen points. `scale` is the ball's radius in
    /// viewBox units.
    public static func points(_ s: BloubSilhouette, scale: Double) -> [BloubPoint] {
        let cr = cos(s.rotation)
        let sr = sin(s.rotation)
        var out = [BloubPoint]()
        out.reserveCapacity(BloubProfiles.sampleCount)
        for i in 0..<BloubProfiles.sampleCount {
            let r = i < s.radii.count ? s.radii[i] : 1
            let x = r * cosines[i]
            let y = r * sines[i]
            // rotate, then squash in screen space, then translate
            let rx = x * cr - y * sr
            let ry = x * sr + y * cr
            out.append(
                BloubPoint(
                    x: (rx * s.scaleX + s.centerX) * scale,
                    y: (ry * s.scaleY + s.centerY) * scale
                )
            )
        }
        return out
    }

    /// Closed polyline → Catmull-Rom cubics.
    ///
    /// With 64 points centred tangents are plenty: the outline is smooth to
    /// the pixel even drawn at 600 pt.
    public static func closedOutline(_ pts: [BloubPoint], tension: Double = 1.0 / 6.0)
        -> BloubOutline
    {
        let n = pts.count
        guard n >= 3 else { return .empty }
        var curves = [BloubCubic]()
        curves.reserveCapacity(n)
        for i in 0..<n {
            let p0 = pts[(i - 1 + n) % n]
            let p1 = pts[i]
            let p2 = pts[(i + 1) % n]
            let p3 = pts[(i + 2) % n]
            curves.append(
                BloubCubic(
                    control1: BloubPoint(
                        x: p1.x + (p2.x - p0.x) * tension,
                        y: p1.y + (p2.y - p0.y) * tension
                    ),
                    control2: BloubPoint(
                        x: p2.x - (p3.x - p1.x) * tension,
                        y: p2.y - (p3.y - p1.y) * tension
                    ),
                    end: p2
                )
            )
        }
        return BloubOutline(start: pts[0], curves: curves)
    }

    /// Arbitrary polygon → radial profile, by ray casting from `center`.
    ///
    /// Builds the shapes that do not express naturally as r(theta) — the "!"'s
    /// tapered bar, for one. Computed once at load, never in the render loop.
    public static func profile(
        fromPolygon poly: [BloubPoint],
        centerX: Double,
        centerY: Double
    ) -> [Double] {
        var radii = [Double](repeating: 0, count: BloubProfiles.sampleCount)
        let n = poly.count
        for k in 0..<BloubProfiles.sampleCount {
            let dx = cosines[k]
            let dy = sines[k]
            var best = 0.0
            for i in 0..<n {
                let a = poly[i]
                let b = poly[(i + 1) % n]
                let ex = b.x - a.x
                let ey = b.y - a.y
                let den = dx * ey - dy * ex
                if abs(den) < 1e-9 { continue }
                let px = a.x - centerX
                let py = a.y - centerY
                let t = (px * ey - py * ex) / den  // distance along the ray
                let u = (px * dy - py * dx) / den  // position on the segment
                if t > best, u >= 0, u <= 1 { best = t }
            }
            radii[k] = best
        }
        return radii
    }

    /// Convex hull of two circles: the "!"'s tapered bar.
    public static func hullOfCircles(
        _ x1: Double,
        _ y1: Double,
        _ r1: Double,
        _ x2: Double,
        _ y2: Double,
        _ r2: Double,
        steps: Int = 96
    ) -> [BloubPoint] {
        let dx = x2 - x1
        let dy = y2 - y1
        let dist = max(hypot(dx, dy), 1e-6)
        // angle of the common external tangents
        let base = atan2(dy, dx)
        let spread = acos(max(-1, min(1, (r1 - r2) / dist)))
        var pts = [BloubPoint]()
        let half = steps / 2
        // arc of the big circle
        for i in 0...half {
            let a = base + spread + (bloubTau - 2 * spread) * Double(i) / Double(half)
            pts.append(BloubPoint(x: x1 + cos(a) * r1, y: y1 + sin(a) * r1))
        }
        // arc of the small circle
        for i in 0...half {
            let a = base - spread + (2 * spread) * Double(i) / Double(half)
            pts.append(BloubPoint(x: x2 + cos(a) * r2, y: y2 + sin(a) * r2))
        }
        return pts
    }

    /// The profile's radius in an arbitrary direction, interpolated between
    /// the two neighbouring samples.
    ///
    /// This is how anything sitting **on** the body — the eyes, the
    /// notification pastille — is re-seated when the silhouette stops being a
    /// circle. Without it an eye placed at 0.62 radius leaves a shape whose
    /// edge is at 0.55 in that direction, and the mask clips it. Any new
    /// element anchored to the outline needs the same treatment.
    public static func radius(_ radii: [Double], atAngle angle: Double) -> Double {
        let n = radii.count
        guard n > 0 else { return 1 }
        let t = (((angle / bloubTau).truncatingRemainder(dividingBy: 1) + 1)
            .truncatingRemainder(dividingBy: 1)) * Double(n)
        let i = Int(t.rounded(.down))
        return BloubMath.lerp(radii[i % n], radii[(i + 1) % n], t - t.rounded(.down))
    }

    /// Superellipse: |x/sx|^n + |y/sy|^n = 1. n = 2 gives an ellipse, n ≈ 4
    /// the customiser's squircle.
    public static func superellipseProfile(_ n: Double, sx: Double = 1, sy: Double = 1)
        -> [Double]
    {
        (0..<BloubProfiles.sampleCount).map { i in
            let c = pow(abs(cosines[i] / sx), n)
            let s = pow(abs(sines[i] / sy), n)
            return pow(c + s, -1 / n)
        }
    }

    /// Radial profile of the **union** of discs: r(theta) is the farthest
    /// ray/circle intersection. Exact as long as the origin is inside the
    /// union — that is what gives the cloud its bumps without a path boolean.
    public static func unionOfCirclesProfile(
        _ circles: [(x: Double, y: Double, r: Double)]
    ) -> [Double] {
        var out = [Double](repeating: 0, count: BloubProfiles.sampleCount)
        for i in 0..<BloubProfiles.sampleCount {
            let dx = cosines[i]
            let dy = sines[i]
            var best = 0.0
            for c in circles {
                let b = dx * c.x + dy * c.y
                let disc = b * b - (c.x * c.x + c.y * c.y - c.r * c.r)
                if disc < 0 { continue }
                let t = b + disc.squareRoot()
                if t > best { best = t }
            }
            out[i] = best
        }
        return out
    }

    /// Polygon with rounded corners, by Minkowski sum with a disc: every edge
    /// is pushed out by `cornerRadius`, every vertex becomes an arc of that
    /// radius. Vertices are therefore to be placed at the wanted radius
    /// **minus** `cornerRadius`. Expects a clockwise polygon (screen frame, y
    /// down).
    static func roundedPolygon(
        _ verts: [BloubPoint],
        cornerRadius rc: Double,
        arcSteps: Int = 10
    ) -> [BloubPoint] {
        let n = verts.count
        var out = [BloubPoint]()
        func normal(_ a: BloubPoint, _ b: BloubPoint) -> Double {
            let dx = b.x - a.x
            let dy = b.y - a.y
            let len = max(hypot(dx, dy), 1)
            // clockwise + y down: the outward normal is (dy, -dx)
            return atan2(-dx / len, dy / len)
        }
        for i in 0..<n {
            let prev = verts[(i - 1 + n) % n]
            let cur = verts[i]
            let next = verts[(i + 1) % n]
            let a0 = normal(prev, cur)
            let a1 = normal(cur, next)
            var d = a1 - a0
            while d > .pi { d -= bloubTau }
            while d < -.pi { d += bloubTau }
            for k in 0...arcSteps {
                let a = a0 + d * Double(k) / Double(arcSteps)
                out.append(BloubPoint(x: cur.x + cos(a) * rc, y: cur.y + sin(a) * rc))
            }
        }
        return out
    }

    /// Regular polygon with rounded corners, inscribed in `radius`.
    public static func regularPolygonProfile(
        sides: Int,
        radius: Double,
        cornerRadius rc: Double,
        rotationDegrees: Double = 0
    ) -> [Double] {
        let rot = rotationDegrees * .pi / 180
        let verts = (0..<sides).map { i -> BloubPoint in
            // clockwise on screen: theta grows with y pointing down
            let a = rot + Double(i) / Double(sides) * bloubTau
            return BloubPoint(x: cos(a) * (radius - rc), y: sin(a) * (radius - rc))
        }
        return profile(
            fromPolygon: roundedPolygon(verts, cornerRadius: rc),
            centerX: 0,
            centerY: 0
        )
    }
}
