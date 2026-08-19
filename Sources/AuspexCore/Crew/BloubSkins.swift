// Ported from bloub — https://github.com/jeremy-prt/bloub
// MIT License, © 2026 Jérémy Perret. See THIRD_PARTY_NOTICES.md.

import Foundation

/// The customiser's shape ids. Raw values are bloub's own.
public enum BloubShapeID: String, Sendable, CaseIterable, Hashable {
    case circle = "cercle"
    case pebble = "galet"
    case squircle
    case capsule
    case triangle
    case hexagon = "hexagone"
    case cloud = "nuage"
    case droplet = "goutte"
}

/// The customiser's colour ids. Raw values are bloub's own.
///
/// Auspex does not use this palette — a crew avatar wears its harness accent,
/// which is the one identity channel the whole app agrees on. The catalogue is
/// carried anyway because it is what the reference renders use, so a frame
/// produced here can be compared against one produced there.
public enum BloubColorID: String, Sendable, CaseIterable, Hashable {
    case ink = "encre"
    case cream = "creme"
    case brown = "brun"
    case red = "rouge"
    case orange
    case amber = "ambre"
    case green = "vert"
    case turquoise
    case blue = "bleu"
    case violet
    case pink = "rose"
    case grey = "gris"
}

/// One customiser shape: an id and its radial profile.
public struct BloubBodyShape: Sendable, Hashable {
    public var id: BloubShapeID
    public var radii: [Double]
}

/// Shapes and colours offered by bloub's customiser.
///
/// Unlike the animation silhouettes (``BloubProfiles``) these are **not**
/// measured off the video: they are built analytically from the original
/// customiser's grid. Two distinct sources, deliberately — the animated states
/// have to stay faithful to the video, the base shapes are a user's choice.
///
/// A chosen shape only replaces the body on states flagged
/// ``BloubStateDef/usesBaseBody``. Everywhere else the silhouette **is** the
/// animation and must not be overwritten.
public enum BloubSkins {
    /// Brings the peak radius back to `max` so every shape weighs the same to
    /// the eye.
    private static func normalize(_ radii: [Double], _ max: Double = 1) -> [Double] {
        guard let peak = radii.max(), peak > 0 else { return radii }
        let k = max / peak
        return radii.map { $0 * k }
    }

    /// Pebble: a circle deformed by two low harmonics, so irregular but smooth.
    private static let pebble: [Double] = normalize(
        BloubShape.angles.map { 1 + 0.075 * cos(2 * $0 + 0.5) + 0.035 * cos(3 * $0 + 2.1) },
        1.02
    )

    /// Cloud: a union of bumps, wide at the bottom, two lobes on top.
    private static let cloud: [Double] = normalize(
        BloubShape.unionOfCirclesProfile([
            (x: -0.44, y: 0.2, r: 0.54),
            (x: 0.46, y: 0.2, r: 0.5),
            (x: 0.02, y: 0.3, r: 0.6),
            (x: -0.24, y: -0.3, r: 0.48),
            (x: 0.3, y: -0.24, r: 0.44)
        ]),
        1.02
    )

    /// Droplet: a fat disc at the bottom, a drawn-out point on top.
    private static let droplet: [Double] = normalize(
        BloubShape.profile(
            fromPolygon: BloubShape.hullOfCircles(0, 0.28, 0.66, 0, -0.96, 0.05),
            centerX: 0,
            centerY: 0
        ),
        1.04
    )

    /// Capsule lying down: the hull of two discs side by side.
    private static let capsule: [Double] = BloubShape.profile(
        fromPolygon: BloubShape.hullOfCircles(-0.42, 0, 0.62, 0.42, 0, 0.62),
        centerX: 0,
        centerY: 0
    )

    public static let all: [BloubBodyShape] = [
        BloubBodyShape(
            id: .circle,
            radii: [Double](repeating: 1, count: BloubProfiles.sampleCount)
        ),
        BloubBodyShape(id: .pebble, radii: pebble),
        // 1.15 and not 1.02: on a superellipse the peak radius is the
        // diagonal, so normalising on it gives a shape that looks smaller
        // than the circle.
        BloubBodyShape(
            id: .squircle,
            radii: normalize(BloubShape.superellipseProfile(4.2), 1.15)
        ),
        BloubBodyShape(id: .capsule, radii: capsule),
        // -90°: one vertex towards the top of the screen (y points down)
        BloubBodyShape(
            id: .triangle,
            radii: BloubShape.regularPolygonProfile(
                sides: 3,
                radius: 1.12,
                cornerRadius: 0.34,
                rotationDegrees: -90
            )
        ),
        // 0°: vertices left and right, so the top and bottom edges are flat
        BloubBodyShape(
            id: .hexagon,
            radii: BloubShape.regularPolygonProfile(
                sides: 6,
                radius: 1.04,
                cornerRadius: 0.26,
                rotationDegrees: 0
            )
        ),
        BloubBodyShape(id: .cloud, radii: cloud),
        BloubBodyShape(id: .droplet, radii: droplet)
    ]

    public static let byID: [BloubShapeID: BloubBodyShape] = Dictionary(
        uniqueKeysWithValues: all.map { ($0.id, $0) }
    )

    public static let `default` = BloubShapeID.circle

    public static func radii(_ id: BloubShapeID) -> [Double] {
        byID[id]?.radii ?? all[0].radii
    }

    /// The original customiser's palette.
    public static let colors: [BloubColorID: BloubRGB] = [
        .ink: BloubRGB(hex: "#0a0a0c"),
        .brown: BloubRGB(hex: "#8b5e3c"),
        .red: BloubRGB(hex: "#e8483f"),
        .orange: BloubRGB(hex: "#f08a24"),
        .amber: BloubRGB(hex: "#f0b429"),
        .green: BloubRGB(hex: "#3ecf8e"),
        .turquoise: BloubRGB(hex: "#2fbfa0"),
        .blue: BloubRGB(hex: "#3b93f0"),
        .violet: BloubRGB(hex: "#8b5cf6"),
        .pink: BloubRGB(hex: "#e152b0"),
        .grey: BloubRGB(hex: "#a3a3a3"),
        .cream: BloubRGB(hex: "#f1efe9")
    ]
}
