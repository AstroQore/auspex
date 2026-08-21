#!/usr/bin/env python3
"""Regenerate `Sources/AuspexCore/Crew/AvatarLabPresets.swift` from avatar-lab.

Usage:
    Scripts/port_avatar_lab.py /Users/example/src/bible-strong-avatar-lab

The source of truth is
[bible-strong-avatar-lab](https://github.com/smontlouis/bible-strong-avatar-lab)
— AGPL-3.0-only, © Stéphane Montlouis-Calixte — specifically:

    src/features/avatar/presets.ts       the expression calibration table,
                                         the per-state expression pools and
                                         the blink profiles
    src/features/animation/sequences.ts  `createInitialSequences()`, which is
                                         what turns those pools into the
                                         built-in animations

Auspex is AGPL-3.0-only as well, so the data and the logic travel with
attribution; see THIRD_PARTY_NOTICES.md.

## Why a script and not a hand-typed table

The calibration table is 25 rows of 11 measured numbers and the sequences are
derived from it by code, not written out. Re-deriving them by hand once would
be error-prone; re-deriving them by hand after an upstream re-calibration would
be hopeless. So this reads the TypeScript and re-runs the derivation, and the
generated file says at the top that it is generated.

It parses rather than executes: no Node has to be installed, and a `.ts` file
that changed shape enough to break the parse fails loudly here instead of
producing a plausible-looking wrong table.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

# --- Parsing ---------------------------------------------------------------


def read(path: Path) -> str:
    if not path.is_file():
        sys.exit(f"port_avatar_lab: {path} does not exist")
    return path.read_text(encoding="utf-8")


def parse_semantic_keys(source: str) -> dict[str, str]:
    """`bundledExpressionSemanticKeys` — expression id → semantic name."""
    block = extract_block(source, "export const bundledExpressionSemanticKeys", "{", "}")
    keys = dict(re.findall(r"'(expression-\d+)':\s*'([a-z0-9-]+)'", block))
    if not keys:
        sys.exit("port_avatar_lab: no semantic keys found in presets.ts")
    return keys


def parse_calibrated(source: str) -> list[list[float]]:
    """The `calibrated` table: 11 measured numbers per expression."""
    block = extract_block(source, "const calibrated: number[][]", "[", "]")
    rows = [
        [float(value) for value in re.findall(r"-?\d+(?:\.\d+)?", row)]
        for row in re.findall(r"\[([^\[\]]*)\]", block)
    ]
    if not rows or any(len(row) != 11 for row in rows):
        sys.exit("port_avatar_lab: the calibrated table is not 11 columns wide")
    return rows


def parse_default_expression(source: str) -> dict[str, float]:
    block = extract_block(source, "export const defaultExpression: Expression", "{", "}")
    return {
        name: float(value)
        for name, value in re.findall(r"(\w+):\s*(-?\d+(?:\.\d+)?)\s*,", block)
    }


def parse_state_groups(source: str) -> list[tuple[str, list[str]]]:
    """`stateGroups` — the two families, in declaration order."""
    block = extract_block(source, "export const stateGroups", "{", "}")
    groups: list[tuple[str, list[str]]] = []
    for name, body in re.findall(r"([A-Za-zÀ-ÿ' ]+|'[^']+'):\s*\[([^\]]*)\]", block):
        ids = re.findall(r"'([a-z]+)'", body)
        if ids:
            groups.append((name.strip().strip("'"), ids))
    if len(groups) != 2:
        sys.exit("port_avatar_lab: expected exactly two state groups")
    return groups


def parse_state_pools(source: str) -> dict[str, list[int]]:
    block = extract_block(source, "export const statePools", "{", "}")
    pools = {
        name: [int(value) for value in re.findall(r"\d+", body)]
        for name, body in re.findall(r"(\w+):\s*\[([^\]]*)\]", block)
    }
    if not pools:
        sys.exit("port_avatar_lab: no state pools found in presets.ts")
    return pools


def parse_blink_profiles(source: str) -> dict[str, dict[str, float]]:
    block = extract_block(source, "const blinkProfiles", "{", "}")
    profiles: dict[str, dict[str, float]] = {}
    for name, body in re.findall(r"(\w+):\s*\{([^}]*)\}", block):
        profiles[name] = {
            field: float(value)
            for field, value in re.findall(r"(\w+):\s*(\d+(?:\.\d+)?)", body)
        }
    expected = {"natural", "calm", "attentive", "active", "reactive"}
    if set(profiles) != expected:
        sys.exit(f"port_avatar_lab: blink profiles are {set(profiles)}, expected {expected}")
    return profiles


def parse_state_sets(source: str) -> dict[str, set[str]]:
    """`calmStates` / `attentiveStates` / `reactiveStates`."""
    sets: dict[str, set[str]] = {}
    for name in ("calmStates", "attentiveStates", "reactiveStates"):
        match = re.search(rf"const {name} = new Set\(\s*\[?([^)]*?)\]?\s*\)", source, re.S)
        if match is None:
            sys.exit(f"port_avatar_lab: {name} not found in presets.ts")
        sets[name] = set(re.findall(r"'([a-z]+)'", match.group(1)))
    return sets


def parse_step_defaults(source: str) -> tuple[float, str]:
    """`createInitialSequences` — the transition every built-in step gets."""
    start = source.find("export const createInitialSequences")
    if start < 0:
        sys.exit("port_avatar_lab: createInitialSequences not found in sequences.ts")
    block = extract_block(source[start:], "(expressionIndex, index) =>", "{", "}")
    transition = re.search(r"transitionMs:\s*(\d+)", block)
    style = re.search(r"transition:\s*'(\w+)'", block)
    if transition is None or style is None:
        sys.exit("port_avatar_lab: createInitialSequences no longer names a step transition")
    return float(transition.group(1)), style.group(1)


def extract_block(source: str, anchor: str, opening: str, closing: str | None, **_: object) -> str:
    """The balanced `opening`…`closing` run that follows `anchor`."""
    start = source.find(anchor)
    if start < 0:
        sys.exit(f"port_avatar_lab: `{anchor}` not found")
    # From the *end* of the anchor: a TypeScript type annotation can carry the
    # opening bracket itself — `const calibrated: number[][] = [` — and finding
    # the first `[` after the name would land in the type.
    start += len(anchor)
    index = source.find(opening, start)
    if index < 0:
        sys.exit(f"port_avatar_lab: `{anchor}` is not followed by `{opening}`")
    if closing is None:
        # A whole statement: run to the end of the declaration.
        end = source.find("\n)\n", index)
        return source[index : end if end > 0 else len(source)]
    depth = 0
    for position in range(index, len(source)):
        if source[position] == opening:
            depth += 1
        elif source[position] == closing:
            depth -= 1
            if depth == 0:
                return source[index : position + 1]
    sys.exit(f"port_avatar_lab: `{anchor}` has an unbalanced `{opening}`")


# --- Re-deriving what the TypeScript computes -------------------------------


def playback_config(
    name: str,
    profiles: dict[str, dict[str, float]],
    sets: dict[str, set[str]],
) -> tuple[float, dict[str, float]]:
    """`getStatePlaybackConfig`, re-run here: (expression interval, blink)."""
    if name == "idle":
        blink = profiles["natural"]
    elif name in sets["calmStates"]:
        blink = profiles["calm"]
    elif name in sets["attentiveStates"]:
        blink = profiles["attentive"]
    elif name in sets["reactiveStates"]:
        blink = profiles["reactive"]
    else:
        blink = profiles["active"]
    if name == "idle":
        interval = 5200.0
    elif name in sets["calmStates"]:
        interval = 3600.0
    else:
        interval = 2300.0
    return interval, blink


# --- Emitting Swift ---------------------------------------------------------


def number(value: float) -> str:
    """A Swift literal that round-trips the measurement exactly."""
    if value == int(value):
        return f"{int(value)}"
    return repr(value)


def swift_identifier(name: str) -> str:
    parts = name.split("-")
    return parts[0] + "".join(part.capitalize() for part in parts[1:])


HEADER = """// Ported from bible-strong-avatar-lab —
// https://github.com/smontlouis/bible-strong-avatar-lab
// AGPL-3.0-only, © Stéphane Montlouis-Calixte. See THIRD_PARTY_NOTICES.md.
//
// GENERATED by Scripts/port_avatar_lab.py — do not edit by hand. The numbers
// are avatar-lab's calibration table and the derivation of the sequences from
// it is `createInitialSequences()` re-run; both come from that project, where
// they are measurements and authored choreography rather than settings. The
// mapping onto bloub's face lives in AvatarLabFace.swift, which is written by
// hand and is the only file allowed to interpret these numbers.

import Foundation
"""


def emit(  # noqa: PLR0913
    semantic_keys: dict[str, str],
    calibrated: list[list[float]],
    default_expression: dict[str, float],
    groups: list[tuple[str, list[str]]],
    pools: dict[str, list[int]],
    profiles: dict[str, dict[str, float]],
    sets: dict[str, set[str]],
    step_transition_ms: float,
    step_style: str,
) -> str:
    out: list[str] = [HEADER]

    # --- the expression record ---------------------------------------------
    out.append(
        '''
/// One of avatar-lab's expression presets, in avatar-lab's own units.
///
/// Carried verbatim rather than pre-converted, so a re-calibration upstream is
/// a re-run of the generator and nothing else. ``AvatarLabFace`` is what turns
/// one of these into a ``BloubExpression``, and it is the only place that is
/// allowed to know what the units mean.
public struct AvatarLabExpression: Sendable, Hashable, Identifiable {
    /// avatar-lab's own id, e.g. `expression-07`.
    public let id: String
    /// What the studio calls it, e.g. `angry-right`.
    public let semanticKey: String
    /// Head orientation in degrees: X pitches (positive looks up), Y yaws
    /// (positive looks right), Z rolls (positive drops the right side).
    public let headX: Double
    public let headY: Double
    public let headZ: Double
    /// Eye box, in avatar-lab face units — hundredths of its sphere's radius
    /// of 120, so 50 is an arc of 50/120 radians.
    public let widthLeft: Double
    public let widthRight: Double
    public let heightLeft: Double
    public let heightRight: Double
    /// The eyes' full separation, same units: each eye sits at ±spacing/2.
    public let spacing: Double
    public let positionXLeft: Double
    public let positionXRight: Double
    /// The pair's latitude on the sphere. Positive puts the eyes lower.
    public let positionYLeft: Double
    public let positionYRight: Double
    /// Each eye capsule's own rotation, degrees, positive = the top goes right.
    public let leftAngle: Double
    public let rightAngle: Double
    /// avatar-lab's projection strength. 1 throughout the bundled set, which
    /// is why this port has nothing to apply it to: bloub already narrows the
    /// far eye through the sphere's own depth factor.
    public let perspective: Double

    public init(
        id: String,
        semanticKey: String,
        headX: Double, headY: Double, headZ: Double,
        widthLeft: Double, widthRight: Double,
        heightLeft: Double, heightRight: Double,
        spacing: Double,
        positionXLeft: Double, positionXRight: Double,
        positionYLeft: Double, positionYRight: Double,
        leftAngle: Double, rightAngle: Double,
        perspective: Double
    ) {
        self.id = id
        self.semanticKey = semanticKey
        self.headX = headX
        self.headY = headY
        self.headZ = headZ
        self.widthLeft = widthLeft
        self.widthRight = widthRight
        self.heightLeft = heightLeft
        self.heightRight = heightRight
        self.spacing = spacing
        self.positionXLeft = positionXLeft
        self.positionXRight = positionXRight
        self.positionYLeft = positionYLeft
        self.positionYRight = positionYRight
        self.leftAngle = leftAngle
        self.rightAngle = rightAngle
        self.perspective = perspective
    }
}
'''
    )

    # --- the sequence vocabulary -------------------------------------------
    ordered_ids = [state for _, ids in groups for state in ids]
    group_of = {state: name for name, ids in groups for state in ids}
    lifecycle_name, reaction_name = groups[0][0], groups[1][0]

    out.append(
        f'''
/// Which family a sequence belongs to.
///
/// avatar-lab names them in French — `{lifecycle_name}` and `{reaction_name}`;
/// the raw values keep those names so a sequence can be matched against the
/// studio without a translation table.
public enum AvatarSequenceGroup: String, Sendable, Hashable, CaseIterable {{
    /// What an avatar does while nothing has happened to it.
    case lifeCycle = "{lifecycle_name}"
    /// A short thing that happens *to* an avatar and then stops.
    case reaction = "{reaction_name}"
}}

/// How a step arrives.
public enum AvatarSequenceCurve: String, Sendable, Hashable, CaseIterable {{
    case spring
    case smooth
    case snappy
}}

/// What happens when a sequence runs out of steps.
public enum AvatarSequencePlayback: String, Sendable, Hashable, CaseIterable {{
    case loop
    case once
    case pingPong
}}

/// One beat of a sequence: an expression, how it is reached, and how long it
/// is then held.
public struct AvatarSequenceStep: Sendable, Hashable {{
    /// The ``AvatarLabExpression/id`` this step rests on.
    public let expressionID: String
    /// How long the step is held, seconds. avatar-lab stores milliseconds.
    public let hold: Double
    /// How long the morph into it takes, seconds.
    public let transition: Double
    public let curve: AvatarSequenceCurve

    public init(
        expressionID: String,
        hold: Double,
        transition: Double,
        curve: AvatarSequenceCurve
    ) {{
        self.expressionID = expressionID
        self.hold = hold
        self.transition = transition
        self.curve = curve
    }}
}}

/// A sequence's own blink rhythm. Seconds, not milliseconds.
public struct AvatarBlinkRhythm: Sendable, Hashable {{
    public let isEnabled: Bool
    public let initialDelay: Double
    public let minInterval: Double
    public let maxInterval: Double
    public let duration: Double

    public init(
        isEnabled: Bool,
        initialDelay: Double,
        minInterval: Double,
        maxInterval: Double,
        duration: Double
    ) {{
        self.isEnabled = isEnabled
        self.initialDelay = initialDelay
        self.minInterval = minInterval
        self.maxInterval = maxInterval
        self.duration = duration
    }}
}}

/// One of avatar-lab's built-in animations.
public struct AvatarSequence: Sendable, Hashable, Identifiable {{
    public let id: AvatarSequenceID
    public let group: AvatarSequenceGroup
    public let playback: AvatarSequencePlayback
    public let steps: [AvatarSequenceStep]
    public let blink: AvatarBlinkRhythm

    public init(
        id: AvatarSequenceID,
        group: AvatarSequenceGroup,
        playback: AvatarSequencePlayback,
        steps: [AvatarSequenceStep],
        blink: AvatarBlinkRhythm
    ) {{
        self.id = id
        self.group = group
        self.playback = playback
        self.steps = steps
        self.blink = blink
    }}

    /// The same sequence, played a different way.
    ///
    /// A life-cycle sequence loops; the choreographer plays some of them once
    /// as a reaction and needs to say so without a second copy of the data.
    public func played(_ mode: AvatarSequencePlayback) -> AvatarSequence {{
        AvatarSequence(id: id, group: group, playback: mode, steps: steps, blink: blink)
    }}
}}
'''
    )

    out.append("\n/// The built-in animations' ids, in avatar-lab's declaration order.\n")
    out.append("public enum AvatarSequenceID: String, Sendable, Hashable, CaseIterable {\n")
    for state in ordered_ids:
        out.append(f"    case {state}\n")
    out.append("}\n")

    # --- the data ----------------------------------------------------------
    out.append(
        """
/// avatar-lab's bundled vocabulary, as data.
public enum AvatarLabPresets {
"""
    )

    out.append(
        "    /// The calibrated presets, in avatar-lab's own order — the index a\n"
        "    /// ``statePools`` entry refers to is this array's index.\n"
        "    public static let expressions: [AvatarLabExpression] = [\n"
    )
    for index, row in enumerate(calibrated):
        (
            head_x,
            head_y,
            head_z,
            width_left,
            width_right,
            height_left,
            height_right,
            spacing,
            latitude,
            left_angle,
            right_angle,
        ) = row
        expression_id = f"expression-{index:02d}"
        out.append(
            f"""        AvatarLabExpression(
            id: "{expression_id}",
            semanticKey: "{semantic_keys[expression_id]}",
            headX: {number(head_x)}, headY: {number(head_y)}, headZ: {number(head_z)},
            widthLeft: {number(width_left)}, widthRight: {number(width_right)},
            heightLeft: {number(height_left)}, heightRight: {number(height_right)},
            spacing: {number(spacing)},
            positionXLeft: 0, positionXRight: 0,
            positionYLeft: {number(latitude)}, positionYRight: {number(latitude)},
            leftAngle: {number(left_angle)}, rightAngle: {number(right_angle)},
            perspective: 1
        ),
"""
        )
    out.append("    ]\n")

    out.append(
        f"""
    /// avatar-lab's `defaultExpression`: a straight-on face, and the fallback
    /// for a step whose expression cannot be resolved.
    public static let neutral = AvatarLabExpression(
        id: "expression-neutral",
        semanticKey: "neutral",
        headX: {number(default_expression["headX"])},
        headY: {number(default_expression["headY"])},
        headZ: {number(default_expression["headZ"])},
        widthLeft: {number(default_expression["widthLeft"])},
        widthRight: {number(default_expression["widthRight"])},
        heightLeft: {number(default_expression["heightLeft"])},
        heightRight: {number(default_expression["heightRight"])},
        spacing: {number(default_expression["spacing"])},
        positionXLeft: {number(default_expression["positionXLeft"])},
        positionXRight: {number(default_expression["positionXRight"])},
        positionYLeft: {number(default_expression["positionYLeft"])},
        positionYRight: {number(default_expression["positionYRight"])},
        leftAngle: {number(default_expression["leftAngle"])},
        rightAngle: {number(default_expression["rightAngle"])},
        perspective: {number(default_expression["perspective"])}
    )

    /// Every preset, the neutral one included, keyed by id.
    public static let expressionsByID: [String: AvatarLabExpression] = Dictionary(
        uniqueKeysWithValues: (expressions + [neutral]).map {{ ($0.id, $0) }}
    )
"""
    )

    # sequences
    out.append(
        """
    /// The built-in animations, as `createInitialSequences()` derives them
    /// from the pools and the per-state playback config.
    public static let sequences: [AvatarSequence] = [
"""
    )
    for state in ordered_ids:
        interval, blink = playback_config(state, profiles, sets)
        pool = pools.get(state, [0])
        group = "lifeCycle" if group_of[state] == lifecycle_name else "reaction"
        out.append(f"        AvatarSequence(\n            id: .{state},\n")
        out.append(f"            group: .{group},\n")
        out.append("            playback: .loop,\n            steps: [\n")
        for expression_index in pool:
            expression_id = f"expression-{expression_index:02d}"
            out.append(
                f'                AvatarSequenceStep(expressionID: "{expression_id}", '
                f"hold: {number(interval / 1000)}, "
                f"transition: {number(step_transition_ms / 1000)}, curve: .{step_style}),\n"
            )
        out.append("            ],\n")
        out.append(
            "            blink: AvatarBlinkRhythm(\n"
            "                isEnabled: true,\n"
            f"                initialDelay: {number(blink['initialDelayMs'] / 1000)},\n"
            f"                minInterval: {number(blink['minIntervalMs'] / 1000)},\n"
            f"                maxInterval: {number(blink['maxIntervalMs'] / 1000)},\n"
            f"                duration: {number(blink['durationMs'] / 1000)}\n"
            "            )\n"
            "        ),\n"
        )
    out.append("    ]\n")

    out.append(
        """
    public static let sequencesByID: [AvatarSequenceID: AvatarSequence] = Dictionary(
        uniqueKeysWithValues: sequences.map { ($0.id, $0) }
    )

    /// The sequence for an id. Total by construction — every case of
    /// ``AvatarSequenceID`` is generated from the table above — and a test
    /// pins that.
    public static func sequence(_ id: AvatarSequenceID) -> AvatarSequence {
        sequencesByID[id] ?? sequences[0]
    }
}
"""
    )
    return "".join(out)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path, help="a bible-strong-avatar-lab checkout")
    parser.add_argument(
        "--out",
        type=Path,
        default=Path(__file__).resolve().parent.parent
        / "Sources/AuspexCore/Crew/AvatarLabPresets.swift",
    )
    parser.add_argument(
        "--report", action="store_true", help="print what was read, as JSON, and stop"
    )
    arguments = parser.parse_args()

    presets = read(arguments.source / "src/features/avatar/presets.ts")
    sequences = read(arguments.source / "src/features/animation/sequences.ts")

    semantic_keys = parse_semantic_keys(presets)
    calibrated = parse_calibrated(presets)
    default_expression = parse_default_expression(presets)
    groups = parse_state_groups(presets)
    pools = parse_state_pools(presets)
    profiles = parse_blink_profiles(presets)
    sets = parse_state_sets(presets)
    step_transition_ms, step_style = parse_step_defaults(sequences)

    if len(semantic_keys) != len(calibrated):
        sys.exit(
            f"port_avatar_lab: {len(calibrated)} calibrated rows but "
            f"{len(semantic_keys)} semantic keys"
        )
    ordered = [state for _, ids in groups for state in ids]
    missing = [state for state in ordered if state not in pools]
    if missing:
        sys.exit(f"port_avatar_lab: no expression pool for {missing}")

    if arguments.report:
        print(
            json.dumps(
                {
                    "expressions": len(calibrated),
                    "sequences": len(ordered),
                    "groups": {name: ids for name, ids in groups},
                },
                indent=2,
                ensure_ascii=False,
            )
        )
        return

    arguments.out.write_text(
        emit(
            semantic_keys,
            calibrated,
            default_expression,
            groups,
            pools,
            profiles,
            sets,
            step_transition_ms,
            step_style,
        ),
        encoding="utf-8",
    )
    print(
        f"port_avatar_lab: {len(calibrated)} expressions + neutral, "
        f"{len(ordered)} sequences → {arguments.out.name}"
    )


if __name__ == "__main__":
    main()
