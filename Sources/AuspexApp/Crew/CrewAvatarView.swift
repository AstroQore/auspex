import AuspexCore
import SwiftUI

/// One avatar, drawn from one ``BloubFrame``.
///
/// ## Why a `Canvas` and not a stack of shapes
///
/// A frame is a 64-point outline, two transformed capsules, up to six
/// depth-sorted arcs and a handful of dots, and all of it changes every tick.
/// Expressed as SwiftUI shapes that would be a fresh view tree sixty times a
/// second per avatar; in a `Canvas` it is one immediate-mode pass with no view
/// identity to reconcile. The view itself holds nothing but the frame, so a
/// wall of sixty avatars is sixty draw calls and no state.
///
/// ## The eyes are holes
///
/// They are punched out of the body, not painted over it. That is what makes
/// them clip themselves against the silhouette when they slide towards the
/// edge, and it is the whole reason the far eye can pass behind the limb
/// without a line of cropping code. Here that is a `drawLayer` with
/// `destinationOut`, which reproduces the reference's SVG mask exactly —
/// including a partly-transparent eye, which an even-odd fill could not do.
///
/// The body is backed by an opaque path in the **card's** colour first, because
/// a hole shows whatever is behind it: without the backing, the half of an
/// orbit ring that is drawn behind the body would reappear inside the eyes.
struct CrewAvatarView: View {
    let frame: BloubFrame
    /// The body's colour — the harness accent.
    let ink: Color
    /// What shows through the eyes: the surface the avatar is standing on.
    let paper: Color
    /// A halo, for the one state that is allowed to shout.
    var glow: Color?
    /// How bright the halo is right now, 0…1.
    ///
    /// A static glow is a sticker; a breathing one is a thing waiting for you.
    /// The wall feeds this from the same clock the engine reads, so it costs a
    /// cosine per card and no animation transaction at all.
    var glowStrength: Double = 1

    var body: some View {
        Canvas(opaque: false, rendersAsynchronously: false) { context, size in
            draw(in: &context, size: size)
        }
        .shadow(
            color: glow?.opacity(0.30 + 0.35 * glowStrength) ?? .clear,
            radius: 10 + 7 * glowStrength
        )
        .shadow(
            color: glow?.opacity(0.45 + 0.30 * glowStrength) ?? .clear,
            radius: 2 + 2.5 * glowStrength
        )
        .accessibilityHidden(true)
    }

    private func draw(in context: inout GraphicsContext, size: CGSize) {
        // The engine works in a viewBox of ±`halfViewBox`; the margin beyond
        // the ball's radius is what houses the rings.
        let span = BloubFrameOfReference.halfViewBox * 2
        let unit = min(size.width, size.height) / span
        context.translateBy(x: size.width / 2, y: size.height / 2)
        context.scaleBy(x: unit, y: unit)

        let body = Self.path(frame.body)

        // 1. the half of every ring that is behind the body, so the body
        //    occludes it. That real depth sort is what makes the rings read as
        //    orbits rather than as flat drawing.
        for arc in frame.arcs {
            stroke(arc.back, of: arc, in: &context)
        }

        // 2. the burst's particles spiral in behind the core and are swallowed
        if frame.dotsBehind {
            for dot in frame.dots { fill(dot, in: &context) }
        }

        // 3. the body, opaque, with the eyes and the pastille's notch removed
        context.opacity = frame.bodyAlpha
        context.fill(body, with: .color(paper))
        context.drawLayer { layer in
            layer.fill(body, with: .color(ink))
            layer.blendMode = .destinationOut
            for eye in frame.eyes {
                layer.fill(Self.eyePath(eye), with: .color(.black.opacity(eye.alpha)))
            }
            if let notch = frame.notch {
                layer.fill(Self.circle(notch.x, notch.y, notch.radius), with: .color(.black))
            }
        }
        context.opacity = 1

        if !frame.dotsBehind {
            for dot in frame.dots { fill(dot, in: &context) }
        }

        // 4. the notification pastille, sitting on the circumference
        if let pastille = frame.notify {
            context.fill(
                Self.circle(pastille.x, pastille.y, pastille.radius),
                with: .color(Color(frame: BloubDecor.notifyBlue))
            )
        }

        for arc in frame.arcs {
            stroke(arc.front, of: arc, in: &context)
        }
    }

    // MARK: Pieces

    private func stroke(
        _ subpaths: [[BloubPoint]],
        of arc: BloubArc,
        in context: inout GraphicsContext
    ) {
        guard !subpaths.isEmpty else { return }
        var path = Path()
        for points in subpaths where points.count > 1 {
            path.move(to: CGPoint(x: points[0].x, y: points[0].y))
            for point in points.dropFirst() {
                path.addLine(to: CGPoint(x: point.x, y: point.y))
            }
        }
        guard !path.isEmpty else { return }
        let shading = GraphicsContext.Shading.linearGradient(
            Gradient(colors: arc.gradientStops.map(Color.init(frame:))),
            startPoint: CGPoint(x: arc.gradientStart.x, y: arc.gradientStart.y),
            endPoint: CGPoint(x: arc.gradientEnd.x, y: arc.gradientEnd.y)
        )
        context.opacity = arc.opacity
        context.stroke(
            path,
            with: shading,
            style: StrokeStyle(lineWidth: arc.width, lineCap: .round, lineJoin: .round)
        )
        context.opacity = 1
    }

    private func fill(_ dot: BloubDot, in context: inout GraphicsContext) {
        // The depth haze is mixed here because this is the only place that
        // knows what colour the body was drawn in.
        let colour: Color
        if let explicit = dot.color {
            colour = Color(frame: explicit)
        } else if let depth = dot.depth {
            colour = paper.mix(with: ink, by: depth)
        } else {
            colour = ink
        }

        let path: Path
        if let polygon = dot.polygon, polygon.count > 2 {
            // A shape given in ball-radius units, centred on the origin: the
            // leaning "!"'s dot is a teardrop, round end towards the bar and a
            // point away from it, not a disc.
            var outline = Path()
            outline.move(to: CGPoint(x: polygon[0].x, y: polygon[0].y))
            for point in polygon.dropFirst() {
                outline.addLine(to: CGPoint(x: point.x, y: point.y))
            }
            outline.closeSubpath()
            let transform = CGAffineTransform(translationX: dot.x, y: dot.y)
                .rotated(by: dot.rotation * .pi / 180)
                .scaledBy(x: frame.scale, y: frame.scale)
            path = outline.applying(transform)
        } else {
            path = Self.circle(dot.x, dot.y, dot.radius)
        }
        context.opacity = dot.opacity
        context.fill(path, with: .color(colour))
        context.opacity = 1
    }

    // MARK: Geometry

    private static func path(_ outline: BloubOutline) -> Path {
        var path = Path()
        guard !outline.curves.isEmpty else { return path }
        path.move(to: CGPoint(x: outline.start.x, y: outline.start.y))
        for curve in outline.curves {
            path.addCurve(
                to: CGPoint(x: curve.end.x, y: curve.end.y),
                control1: CGPoint(x: curve.control1.x, y: curve.control1.y),
                control2: CGPoint(x: curve.control2.x, y: curve.control2.y)
            )
        }
        path.closeSubpath()
        return path
    }

    /// A capsule of `width` × `height` centred on the origin, put in place by
    /// the eye's tangent matrix. A stadium, not a rounded rectangle: the corner
    /// radius is half the short side, which is the exact shape the video shows.
    private static func eyePath(_ eye: BloubEye) -> Path {
        let width = max(eye.width, 0.01)
        let height = max(eye.height, 0.01)
        let radius = min(width, height) / 2
        let capsule = Path(
            roundedRect: CGRect(x: -width / 2, y: -height / 2, width: width, height: height),
            cornerSize: CGSize(width: radius, height: radius),
            style: .circular
        )
        return capsule.applying(
            CGAffineTransform(a: eye.a, b: eye.b, c: eye.c, d: eye.d, tx: eye.e, ty: eye.f)
        )
    }

    private static func circle(_ x: Double, _ y: Double, _ r: Double) -> Path {
        Path(ellipseIn: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2))
    }
}

extension Color {
    /// A colour the engine produced. Built in sRGB explicitly: the hue wheel's
    /// values were computed against an sRGB reference, and letting them mean
    /// whatever the display profile says would shift every ring.
    init(frame rgb: BloubRGB) {
        self.init(.sRGB, red: rgb.red, green: rgb.green, blue: rgb.blue, opacity: 1)
    }
}
