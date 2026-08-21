// The mapping between bible-strong-avatar-lab's expression vocabulary
// (AGPL-3.0-only, © Stéphane Montlouis-Calixte) and bloub's face (MIT, ©
// Jérémy Perret). See THIRD_PARTY_NOTICES.md.
//
// Written by hand, unlike `AvatarLabPresets.swift`: the numbers are theirs,
// the conversion is ours, and it is the one place allowed to know what
// avatar-lab's units mean.

import Foundation

/// How an avatar-lab preset becomes a ``BloubExpression``.
///
/// ## The two models are the same model
///
/// Both put two eye capsules on a sphere and rotate the sphere. That is why
/// this file is arithmetic rather than art direction: avatar-lab measures in
/// **face units** on a sphere of radius 120 and bloub measures in **degrees**
/// on a sphere of radius 1, and the whole conversion is dividing by 120 and
/// reading the result as radians.
///
/// | avatar-lab | bloub | conversion |
/// | --- | --- | --- |
/// | `headX` (pitch, up positive) | `gaze.pitch` | degrees, as-is |
/// | `headY` (yaw, right positive) | `gaze.yaw` | degrees, as-is |
/// | `headZ` (roll, right side down) | `gaze.roll` | degrees, as-is |
/// | `positionY` (the pair's latitude, down positive) | `gaze.pitch` | subtracted, as degrees |
/// | `spacing` (full separation) | `split` (half separation) | `spacing / 2`, as degrees |
/// | `width`, `height` | eye capsule | `/ 120`, i.e. arc on a unit sphere |
/// | `leftAngle`, `rightAngle` | eye `tilt` | degrees, as-is |
///
/// ## The three fields that do not travel, and why that is not a loss
///
/// - **`perspective`** is 1 across the whole bundled set, which is avatar-lab's
///   own default. bloub narrows the far eye through the sphere's depth factor
///   already — that is the measurement the port is built on — so there is
///   nothing here to apply and nothing missing.
/// - **`positionXLeft` / `positionXRight`** are 0 across the whole bundled set.
///   bloub has no per-eye longitudinal offset; a preset that used one would be
///   approximated by the pair's spacing, and none does.
/// - **`eyeMotion` / `bodyMotion`** are `none` across the whole set. bloub's
///   own resting life — the seeded gaze drift, the breath, the blink schedule —
///   is what animates a held expression here, and it is richer than either.
///
/// A test pins all three, so an upstream re-calibration that started using them
/// fails here rather than silently dropping them.
///
/// ## What stays bloub's
///
/// The **body** and the **decor**. avatar-lab draws faces on surfaces; the
/// silhouettes, the thinking dots, the orbit's rings, the "!" and the burst are
/// bloub's measurements and are untouched by anything in this file. avatar-lab
/// adds a face vocabulary and the choreography that sequences it, and that is
/// all it adds.
public enum AvatarLabFace {
    /// avatar-lab's sphere radius, in its own face units — `RADIUS` in
    /// `packages/avatar-core/src/geometry.ts`. Every length in a preset is an
    /// arc measured on a sphere this big, so dividing by it gives radians.
    public static let sphereRadius = 120.0

    /// Degrees per face unit. The one constant this whole file rests on.
    public static let degreesPerUnit = 180 / (.pi * sphereRadius)

    /// One preset, as a bloub expression.
    public static func face(_ preset: AvatarLabExpression) -> BloubExpression {
        // The pair's latitude. Both eyes carry it in the bundled set; the mean
        // is what a preset that split them would mean by "where the eyes are",
        // and bloub has one pitch to say it with.
        let latitude = (preset.positionYLeft + preset.positionYRight) / 2
        return BloubExpression(
            id: anchor(preset),
            gaze: BloubGaze(
                yaw: preset.headY,
                // Latitude is measured down the face and pitch is measured up,
                // so it is subtracted. Getting this sign wrong is invisible in
                // a still and obvious in a sequence: every downward glance
                // would look up.
                pitch: preset.headX - latitude * degreesPerUnit,
                roll: preset.headZ
            ),
            split: preset.spacing / 2 * degreesPerUnit,
            eyes: (
                eye(width: preset.widthLeft, height: preset.heightLeft, tilt: preset.leftAngle),
                eye(width: preset.widthRight, height: preset.heightRight, tilt: preset.rightAngle)
            )
        )
    }

    /// One eye. `open` is left at 1 on purpose: avatar-lab says "half shut" by
    /// squashing the capsule's **height**, where bloub has a separate lid, and
    /// carrying the same droop through both levers would shut the eye twice.
    /// The blink is still a lid, and it is still the engine's.
    private static func eye(width: Double, height: Double, tilt: Double) -> BloubEyeConfig {
        BloubEyeConfig(
            width: width / sphereRadius,
            height: height / sphereRadius,
            open: 1,
            tilt: tilt
        )
    }

    /// Every preset as a bloub expression, keyed by avatar-lab's id.
    ///
    /// Resolved once. A sequence step names an expression by id and is sampled
    /// sixty times a second; converting on each sample would be arithmetic
    /// nobody asked for.
    public static let faces: [String: BloubExpression] = Dictionary(
        uniqueKeysWithValues: (AvatarLabPresets.expressions + [AvatarLabPresets.neutral])
            .map { ($0.id, face($0)) }
    )

    /// The face a sequence step asks for, or avatar-lab's own neutral.
    public static func face(id: String) -> BloubExpression {
        faces[id] ?? faces[AvatarLabPresets.neutral.id] ?? BloubExpressions.expression(.neutral)
    }

    // MARK: The anchor

    /// Which of bloub's catalogue expressions this preset is nearest.
    ///
    /// Not decoration, and not used to draw anything. ``BloubEyeFit`` solves
    /// the eye-placement correction **per pose** and yields a table keyed on
    /// (shape, state, expression); an avatar-lab face exists in no such table,
    /// so it borrows the correction of the catalogue expression it most nearly
    /// is. Adding these as fresh ``BloubExpressionID`` cases instead would
    /// multiply the solver's work by 26 for a correction measured in single
    /// units — see `BloubEyeFit`'s own note on what solving per frame cost.
    ///
    /// Assigned by semantic key rather than by index so that a re-calibration
    /// upstream, which moves numbers but keeps names, does not silently
    /// re-anchor the whole set.
    public static func anchor(_ preset: AvatarLabExpression) -> BloubExpressionID {
        anchors[preset.semanticKey] ?? .neutral
    }

    public static let anchors: [String: BloubExpressionID] = [
        "upward-side-glance": .curious,
        "downward-gaze": .shy,
        "joyful-down-right": .gleeful,
        "surprised-left": .surprised,
        "sleepy-squint": .sleepy,
        "skeptical-right": .wary,
        "small-attentive": .attentive,
        "angry-right": .angry,
        "curious-left": .curious,
        "asymmetric-down-right": .confused,
        "attentive-left": .attentive,
        "joyful-wide": .excited,
        "wide-downward-gaze": .surprised,
        "eyes-closed": .sleepy,
        "skeptical-left": .wary,
        "far-right-glance": .curious,
        "angry-left": .angry,
        "playful-right": .happy,
        "asymmetric-up-left": .confused,
        "gentle-downward-gaze": .sad,
        "wide-down-left": .surprised,
        "surprised-wide-left": .frightened,
        "drowsy-closed": .sleepy,
        "suspicious-right": .wary,
        "shy-downward": .shy,
        "neutral": .neutral
    ]
}
