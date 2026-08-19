// Ported from bloub — https://github.com/jeremy-prt/bloub
// MIT License, © 2026 Jérémy Perret. See THIRD_PARTY_NOTICES.md.

/// One eye's configuration.
public struct BloubEyeConfig: Sendable, Hashable {
    /// Local width (the capsule's short axis), in ball-radius units.
    public var width: Double
    /// Local height (the long axis).
    public var height: Double
    /// 1 = open, 0 = shut.
    public var open: Double
    /// The capsule's own tilt, degrees, positive = the top goes right.
    ///
    /// Applied **after** the sphere's tangent frame. Without it both eyes
    /// necessarily lean the same way (that is the head's roll), and anger and
    /// sadness — which want mirrored tilts — are out of reach.
    public var tilt: Double

    public init(width: Double, height: Double, open: Double = 1, tilt: Double = 0) {
        self.width = width
        self.height = height
        self.open = open
        self.tilt = tilt
    }
}

/// The resting expression: a head orientation, an eye spacing, and two eyes.
public struct BloubExpression: Sendable, Hashable {
    public var id: BloubExpressionID
    public var gaze: BloubGaze
    public var split: Double
    public var eyes: (BloubEyeConfig, BloubEyeConfig)

    public init(
        id: BloubExpressionID,
        gaze: BloubGaze,
        split: Double,
        eyes: (BloubEyeConfig, BloubEyeConfig)
    ) {
        self.id = id
        self.gaze = gaze
        self.split = split
        self.eyes = eyes
    }

    public static func == (lhs: BloubExpression, rhs: BloubExpression) -> Bool {
        lhs.id == rhs.id && lhs.gaze == rhs.gaze && lhs.split == rhs.split
            && lhs.eyes.0 == rhs.eyes.0 && lhs.eyes.1 == rhs.eyes.1
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(gaze)
        hasher.combine(split)
        hasher.combine(eyes.0)
        hasher.combine(eyes.1)
    }
}

/// The expression catalogue's ids.
///
/// Raw values are bloub's own ids, so a number here can be compared against
/// `src/bot/expressions.ts` without a translation table. Labels deliberately
/// do not live in the engine: the catalogue carries ids and the display
/// resolves them.
public enum BloubExpressionID: String, Sendable, CaseIterable, Hashable {
    case neutral = "neutre"
    case attentive = "attentif"
    case surprised = "surpris"
    case excited = "excite"
    case happy = "heureux"
    case gleeful = "hilare"
    case angry = "colere"
    case sad = "triste"
    case frightened = "effraye"
    case wary = "mefiant"
    case confused = "confus"
    case curious = "curieux"
    case proud = "fier"
    case shy = "timide"
    case bored = "blase"
    case sleepy = "somnolent"
}

/// The face has only two capsules, so everything is played on four levers: the
/// head's orientation, the eyes' spacing, their proportions, and each eye's own
/// tilt. That last one is what makes anger and sadness possible: they want
/// **mirrored** tilts, which the head's roll alone cannot produce.
///
/// Only the resting state carries an expression. The video's expressive states
/// (wink, wide eyes, notification) keep theirs — reproducing those is the whole
/// point.
///
/// A tilt is only visible on an elongated eye: an eye whose width/height ratio
/// approaches 1 is a circle and looks the same at every angle. bloub enforces a
/// two-tier rule on that, and so does this port's test suite.
public enum BloubExpressions {
    /// Both eyes identical, tilts mirrored when one is given.
    private static func pair(
        _ w: Double,
        _ h: Double,
        _ tilt: Double = 0,
        _ open: Double = 1
    ) -> (BloubEyeConfig, BloubEyeConfig) {
        (
            BloubEyeConfig(width: w, height: h, open: open, tilt: tilt),
            BloubEyeConfig(width: w, height: h, open: open, tilt: -tilt)
        )
    }

    private static func eye(
        _ w: Double,
        _ h: Double,
        _ tilt: Double = 0,
        _ open: Double = 1
    ) -> BloubEyeConfig {
        BloubEyeConfig(width: w, height: h, open: open, tilt: tilt)
    }

    public static let all: [BloubExpression] = [
        // the pose measured frame by frame on the reference video
        BloubExpression(
            id: .neutral,
            gaze: BloubFace.restGaze,
            split: BloubFace.eyeSplit,
            eyes: (
                eye(BloubFace.eyeWidth, BloubFace.eyeHeight),
                eye(BloubFace.eyeWidth, BloubFace.eyeHeight)
            )
        ),
        BloubExpression(
            id: .attentive,
            gaze: BloubGaze(yaw: 4, pitch: 5, roll: -4),
            split: 16,
            eyes: pair(0.21, 0.44)
        ),
        BloubExpression(
            id: .surprised,
            gaze: BloubGaze(yaw: 3, pitch: -3, roll: 0),
            split: 19,
            eyes: pair(0.45, 0.47)
        ),
        BloubExpression(
            id: .excited,
            gaze: BloubGaze(yaw: 6, pitch: -14, roll: 0),
            split: 19.5,
            eyes: pair(0.4, 0.56, -10)
        ),
        // eyes creased into arcs: the tops converge slightly
        BloubExpression(
            id: .happy,
            gaze: BloubGaze(yaw: 5, pitch: 9, roll: 0),
            split: 17,
            eyes: pair(0.27, 0.17, 14)
        ),
        BloubExpression(
            id: .gleeful,
            gaze: BloubGaze(yaw: 4, pitch: 14, roll: 0),
            split: 18,
            eyes: pair(0.34, 0.13, 20)
        ),
        // tops converging hard towards the centre + narrowed eyes
        BloubExpression(
            id: .angry,
            gaze: BloubGaze(yaw: 3, pitch: 7, roll: 0),
            split: 17,
            eyes: pair(0.34, 0.15, 30)
        ),
        // the reverse: the tops diverge, and the gaze falls
        BloubExpression(
            id: .sad,
            gaze: BloubGaze(yaw: 3, pitch: -13, roll: 0),
            split: 16,
            eyes: pair(0.22, 0.4, -28)
        ),
        BloubExpression(
            id: .frightened,
            gaze: BloubGaze(yaw: 2, pitch: -20, roll: 0),
            split: 20.5,
            eyes: pair(0.4, 0.6)
        ),
        // one eye distinctly more closed than the other
        BloubExpression(
            id: .wary,
            gaze: BloubGaze(yaw: 12, pitch: 6, roll: -6),
            split: 16,
            eyes: (eye(0.21, 0.4), eye(0.22, 0.15))
        ),
        // asymmetric on both axes: mismatched sizes AND tilts. The creased eye
        // is deliberately flat (ratio 1.6): near a ratio of 1 it would be
        // round and its tilt would not show.
        BloubExpression(
            id: .confused,
            gaze: BloubGaze(yaw: -14, pitch: 3, roll: 8),
            split: 16.5,
            eyes: (eye(0.2, 0.44, -18), eye(0.28, 0.17, 14))
        ),
        // the head leans: the roll is what carries curiosity
        BloubExpression(
            id: .curious,
            gaze: BloubGaze(yaw: 16, pitch: -9, roll: -15),
            split: 16.5,
            eyes: (eye(0.24, 0.46, -8), eye(0.2, 0.38, -8))
        ),
        BloubExpression(
            id: .proud,
            gaze: BloubGaze(yaw: 5, pitch: 17, roll: 0),
            split: 17,
            eyes: pair(0.3, 0.15, 18)
        ),
        BloubExpression(
            id: .shy,
            gaze: BloubGaze(yaw: -19, pitch: -14, roll: -7),
            split: 14,
            eyes: pair(0.17, 0.3)
        ),
        // horizontal slits and a gaze that wanders off to the side
        BloubExpression(
            id: .bored,
            gaze: BloubGaze(yaw: -22, pitch: 2, roll: 0),
            split: 16,
            eyes: pair(0.3, 0.12)
        ),
        // half-dropped lids: through `open`, so the same vertical squash the
        // blink uses
        BloubExpression(
            id: .sleepy,
            gaze: BloubGaze(yaw: 6, pitch: -9, roll: -3),
            split: 16,
            eyes: pair(0.2, 0.42, 0, 0.42)
        )
    ]

    public static let byID: [BloubExpressionID: BloubExpression] = Dictionary(
        uniqueKeysWithValues: all.map { ($0.id, $0) }
    )

    public static let `default` = BloubExpressionID.neutral

    public static func expression(_ id: BloubExpressionID) -> BloubExpression {
        byID[id] ?? all[0]
    }

    /// Interpolates two expressions: a change of mood slides, it does not jump.
    public static func blend(
        _ a: BloubExpression,
        _ b: BloubExpression,
        _ t: Double
    ) -> BloubExpression {
        func lerpEye(_ x: BloubEyeConfig, _ y: BloubEyeConfig) -> BloubEyeConfig {
            BloubEyeConfig(
                width: BloubMath.lerp(x.width, y.width, t),
                height: BloubMath.lerp(x.height, y.height, t),
                open: BloubMath.lerp(x.open, y.open, t),
                tilt: BloubMath.lerp(x.tilt, y.tilt, t)
            )
        }
        return BloubExpression(
            id: b.id,
            gaze: BloubGaze(
                yaw: BloubMath.lerp(a.gaze.yaw, b.gaze.yaw, t),
                pitch: BloubMath.lerp(a.gaze.pitch, b.gaze.pitch, t),
                roll: BloubMath.lerp(a.gaze.roll, b.gaze.roll, t)
            ),
            split: BloubMath.lerp(a.split, b.split, t),
            eyes: (lerpEye(a.eyes.0, b.eyes.0), lerpEye(a.eyes.1, b.eyes.1))
        )
    }
}
