import AuspexCore
import Foundation
import Testing

/// What the ported avatar-lab vocabulary guarantees.
///
/// The data is generated (`Scripts/port_avatar_lab.py`), so these are not
/// "does the table say what I typed" assertions — nobody typed it. They are
/// the three things a regeneration could quietly break: the **shape** of the
/// vocabulary (how many of each, ids unique, every reference resolvable), the
/// **conversion** onto bloub's face, and the **assumptions** the conversion
/// rests on — the fields that are constant across the bundled set and are
/// therefore not carried.
@Suite("avatar-lab vocabulary")
struct AvatarLabPresetsTests {
    // MARK: Integrity

    @Test("the bundled set is 25 calibrated presets plus a neutral")
    func expressionCount() {
        #expect(AvatarLabPresets.expressions.count == 25)
        #expect(AvatarLabPresets.expressionsByID.count == 26)
        #expect(AvatarLabPresets.expressionsByID["expression-neutral"] != nil)
    }

    @Test("every expression id and semantic key is unique")
    func expressionIdentity() {
        let all = AvatarLabPresets.expressions + [AvatarLabPresets.neutral]
        #expect(Set(all.map(\.id)).count == all.count)
        #expect(Set(all.map(\.semanticKey)).count == all.count)
        // The id is the index, zero-padded: a sequence step naming
        // `expression-07` must land on the eighth row and no other.
        for (index, expression) in AvatarLabPresets.expressions.enumerated() {
            #expect(expression.id == "expression-\(String(format: "%02d", index))")
        }
    }

    @Test("the two families hold 7 life-cycle and 16 reaction sequences")
    func sequenceCount() {
        #expect(AvatarLabPresets.sequences.count == 23)
        #expect(AvatarSequenceID.allCases.count == 23)
        let byGroup = Dictionary(grouping: AvatarLabPresets.sequences, by: \.group)
        #expect(byGroup[.lifeCycle]?.count == 7)
        #expect(byGroup[.reaction]?.count == 16)
    }

    @Test("every sequence id resolves, and to itself")
    func sequenceLookup() {
        for id in AvatarSequenceID.allCases {
            #expect(AvatarLabPresets.sequence(id).id == id)
        }
        #expect(Set(AvatarLabPresets.sequences.map(\.id)).count == 23)
    }

    @Test("every step names an expression that exists")
    func stepsResolve() {
        for sequence in AvatarLabPresets.sequences {
            #expect(!sequence.steps.isEmpty, "\(sequence.id) has no steps")
            for step in sequence.steps {
                #expect(
                    AvatarLabPresets.expressionsByID[step.expressionID] != nil,
                    "\(sequence.id) names \(step.expressionID)"
                )
            }
        }
    }

    @Test("every sequence has a usable hold, transition and blink window")
    func timingsAreSane() {
        for sequence in AvatarLabPresets.sequences {
            for step in sequence.steps {
                #expect(step.hold > 0)
                // A transition longer than the hold would mean a step that is
                // never actually reached before the next one starts.
                #expect(step.transition > 0 && step.transition <= step.hold)
            }
            let blink = sequence.blink
            #expect(blink.minInterval < blink.maxInterval)
            #expect(blink.duration > 0 && blink.duration < blink.minInterval)
            #expect(blink.initialDelay >= 0)
            // The player jitters a blink boundary by a quarter of the window
            // either way; ordering only survives if the window is under the
            // mean gap, which is `max < 3 * min`.
            #expect(blink.maxInterval < 3 * blink.minInterval)
        }
    }

    @Test("a calm sequence blinks slower than an attentive one, which blinks slower than a reactive one")
    func blinkFamilies() {
        // avatar-lab's own `presets-test.ts`, restated against the port: this
        // is the ordering the vocabulary is *for*, and a generator that lost
        // the profile lookup would still produce a table that parses.
        let sleeping = AvatarLabPresets.sequence(.sleeping).blink
        let listening = AvatarLabPresets.sequence(.listening).blink
        let excited = AvatarLabPresets.sequence(.excited).blink
        #expect(sleeping.minInterval > listening.minInterval)
        #expect(listening.minInterval > excited.minInterval)
        #expect(sleeping.duration > excited.duration)
        // And idle is the slow one among the working states.
        #expect(
            AvatarLabPresets.sequence(.idle).steps[0].hold
                > AvatarLabPresets.sequence(.listening).steps[0].hold
        )
    }

    // MARK: The conversion onto bloub's face

    @Test("every preset converts to a face bloub can draw")
    func facesAreDrawable() {
        for preset in AvatarLabPresets.expressions + [AvatarLabPresets.neutral] {
            let face = AvatarLabFace.face(preset)
            for eye in [face.eyes.0, face.eyes.1] {
                // In ball-radius units, and inside the envelope the catalogue
                // already spans — `wide` is 0.356 × 0.875 — so the eye-fit
                // table's corrections still apply.
                #expect(eye.width > 0.05 && eye.width <= 0.5)
                #expect(eye.height > 0.05 && eye.height <= 0.9)
                #expect(eye.open == 1)
            }
            // Half the separation, in degrees. bloub's own rest split is 15.46
            // and its catalogue runs 14 to 20.5.
            #expect(face.split > 3 && face.split < 22)
            #expect(abs(face.gaze.yaw) < 45)
            #expect(abs(face.gaze.pitch) < 45)
            #expect(abs(face.gaze.roll) < 45)
        }
    }

    @Test("the conversion is the arithmetic it claims to be")
    func conversionIsExact() {
        // `expression-01`, `downward-gaze`: headX -35.6, headY 0.7,
        // headZ -8.5, spacing 57.7, latitude -42.
        let preset = AvatarLabPresets.expressionsByID["expression-01"]!
        let face = AvatarLabFace.face(preset)
        let unit = AvatarLabFace.degreesPerUnit
        #expect(abs(face.gaze.yaw - 0.7) < 1e-9)
        #expect(abs(face.gaze.pitch - (-35.6 - (-42) * unit)) < 1e-9)
        #expect(abs(face.gaze.roll - (-8.5)) < 1e-9)
        #expect(abs(face.split - 57.7 / 2 * unit) < 1e-9)
        #expect(abs(face.eyes.0.width - 29.4 / 120) < 1e-9)
        #expect(abs(face.eyes.1.height - 49.8 / 120) < 1e-9)
    }

    @Test("a downward gaze looks down and an upward one looks up")
    func gazeSigns() {
        // The one sign that is invisible in a still and wrong in every frame
        // of a sequence if it is flipped.
        func pitch(_ key: String) -> Double {
            let preset = AvatarLabPresets.expressions.first { $0.semanticKey == key }!
            return AvatarLabFace.face(preset).gaze.pitch
        }
        #expect(pitch("downward-gaze") < 0)
        #expect(pitch("gentle-downward-gaze") < 0)
        #expect(pitch("shy-downward") < 0)
        #expect(pitch("upward-side-glance") > 0)
        // And the left/right pair really is a pair.
        func yaw(_ key: String) -> Double {
            let preset = AvatarLabPresets.expressions.first { $0.semanticKey == key }!
            return AvatarLabFace.face(preset).gaze.yaw
        }
        #expect(yaw("far-right-glance") > 0)
        #expect(yaw("curious-left") < 0)
        #expect(yaw("angry-left") < yaw("angry-right"))
    }

    @Test("a squint is flatter than a wide-eyed stare")
    func eyeShapes() {
        func height(_ key: String) -> Double {
            let preset = AvatarLabPresets.expressions.first { $0.semanticKey == key }!
            let face = AvatarLabFace.face(preset)
            return (face.eyes.0.height + face.eyes.1.height) / 2
        }
        #expect(height("sleepy-squint") < height("joyful-wide"))
        #expect(height("drowsy-closed") < height("surprised-left"))
        #expect(height("eyes-closed") < height("attentive-left"))
    }

    @Test("every preset anchors on a catalogue expression, and none invents one")
    func anchorsResolve() {
        for preset in AvatarLabPresets.expressions + [AvatarLabPresets.neutral] {
            let anchor = AvatarLabFace.anchor(preset)
            #expect(AvatarLabFace.anchors[preset.semanticKey] == anchor)
            #expect(BloubExpressions.byID[anchor] != nil)
        }
        // The anchor table says nothing about presets that do not exist: a
        // renamed semantic key upstream should fail here rather than silently
        // fall back to neutral for the whole set.
        let known = Set((AvatarLabPresets.expressions + [AvatarLabPresets.neutral])
            .map(\.semanticKey))
        #expect(Set(AvatarLabFace.anchors.keys) == known)
    }

    // MARK: The assumptions the conversion rests on

    @Test("the fields the conversion drops really are constant upstream")
    func droppedFieldsAreConstant() {
        for preset in AvatarLabPresets.expressions {
            // Documented in `AvatarLabFace`: each of these is dropped because
            // it is the same everywhere, not because it did not fit.
            #expect(preset.perspective == 1, "\(preset.id) uses perspective")
            #expect(preset.positionXLeft == 0 && preset.positionXRight == 0)
            #expect(preset.positionYLeft == preset.positionYRight)
        }
    }

    @Test("the faces are resolved once and are the same objects every time")
    func facesAreCached() {
        let first = AvatarLabFace.face(id: "expression-11")
        let second = AvatarLabFace.face(id: "expression-11")
        #expect(first == second)
        #expect(AvatarLabFace.faces.count == 26)
        // An unknown id falls back rather than trapping: a sequence is data,
        // and data can be wrong without taking a wall of avatars with it.
        #expect(AvatarLabFace.face(id: "expression-99") == AvatarLabFace.face(id: "expression-neutral"))
    }
}
