#!/usr/bin/env python3
"""Check an Auspex character package against the format in docs/CHARACTERS.md.

    Scripts/validate_character.py ~/.auspex/characters/claudeCode-default
    Scripts/validate_character.py Resources/Characters/*

Exits non-zero when any package has an error. Warnings never fail the run: a
package with one strip in it is the normal state of things while art is being
drawn one pose at a time, and a validator that called that "broken" would be a
validator people stop running.

Pixels are read with Pillow when it is installed and with a small built-in PNG
reader otherwise, so the pixel checks work on a stock python3. The built-in
reader handles what this format asks for — 8-bit, non-interlaced PNG — and says
so plainly when a file is something else, rather than passing it silently.
"""

from __future__ import annotations

import argparse
import json
import os
import struct
import sys
import zlib

CELL_SIZES = (32, 48)
ANCHORS = ("bottomCenter",)
KINDS = ("person", "pet")

CORE_POSES = (
    "idle",
    "thinking",
    "typing",
    "writing",
    "delegating",
    "blocked",
    "stale",
    "ended",
)
OPTIONAL_POSES = ("walkDown", "walkRight", "walkUp", "spawn")
POSES = CORE_POSES + OPTIONAL_POSES

HARNESSES = (
    "claudeCode",
    "claudeCowork",
    "codex",
    "chatgptWork",
    "cursor",
    "grokBuild",
    "grokBot",
    "antigravity",
    "geminiCLI",
)

# Empty columns each side of a 32-pixel cell, scaled with the cell. The desk's
# monitor stands just outside the cell, so art that fills every column collides
# with it.
SIDE_MARGIN_AT_32 = 8

# Straight alpha, no matte: a pixel is drawn or it is not. A few in-between
# pixels are a rounding artefact; a field of them is a sprite that was scaled
# from a bigger painting, which arrives as mush under nearest-neighbour.
SEMI_TRANSPARENT_TOLERANCE = 0.005


class Report:
    """Errors, warnings, and notes for one package."""

    def __init__(self, name: str, path: str) -> None:
        self.name = name
        self.path = path
        self.errors: list[str] = []
        self.warnings: list[str] = []
        self.notes: list[str] = []

    def error(self, message: str) -> None:
        self.errors.append(message)

    def warn(self, message: str) -> None:
        self.warnings.append(message)

    def note(self, message: str) -> None:
        self.notes.append(message)

    @property
    def ok(self) -> bool:
        return not self.errors

    def render(self) -> str:
        head = f"{self.name}  ({self.path})"
        lines = [head]
        for note in self.notes:
            lines.append(f"      {note}")
        for message in self.warnings:
            lines.append(f"  warn  {message}")
        for message in self.errors:
            lines.append(f"  FAIL  {message}")
        verdict = "ok" if self.ok else "FAILED"
        counts = []
        if self.errors:
            counts.append(f"{len(self.errors)} error" + ("s" if len(self.errors) != 1 else ""))
        if self.warnings:
            counts.append(f"{len(self.warnings)} warning" + ("s" if len(self.warnings) != 1 else ""))
        lines.append(f"  -> {verdict}" + (f" ({', '.join(counts)})" if counts else ""))
        return "\n".join(lines)


# --------------------------------------------------------------------------
# Reading pixels


class Bitmap:
    """RGBA pixels, addressed as `bitmap.alpha(x, y)`."""

    def __init__(self, width: int, height: int, rgba: bytes) -> None:
        self.width = width
        self.height = height
        self.rgba = rgba

    def alpha(self, x: int, y: int) -> int:
        return self.rgba[(y * self.width + x) * 4 + 3]


def read_with_pillow(path):
    from PIL import Image  # noqa: PLC0415 — optional dependency, by design

    with Image.open(path) as image:
        rgba = image.convert("RGBA")
        return Bitmap(rgba.width, rgba.height, rgba.tobytes())


def read_with_stdlib(path):
    """Decode an 8-bit non-interlaced PNG with zlib and struct.

    Raises `ValueError` for anything else, which the caller turns into "pixel
    checks skipped, install Pillow" rather than into a failure.
    """
    with open(path, "rb") as handle:
        data = handle.read()
    if data[:8] != b"\x89PNG\r\n\x1a\n":
        raise ValueError("not a PNG file")

    pos = 8
    width = height = depth = colour = interlace = None
    palette = b""
    transparency = b""
    idat = bytearray()
    while pos + 8 <= len(data):
        (length,) = struct.unpack(">I", data[pos : pos + 4])
        tag = data[pos + 4 : pos + 8]
        body = data[pos + 8 : pos + 8 + length]
        if tag == b"IHDR":
            width, height, depth, colour, _, _, interlace = struct.unpack(">IIBBBBB", body)
        elif tag == b"PLTE":
            palette = body
        elif tag == b"tRNS":
            transparency = body
        elif tag == b"IDAT":
            idat += body
        elif tag == b"IEND":
            break
        pos += 12 + length

    if width is None:
        raise ValueError("no IHDR chunk")
    if depth != 8:
        raise ValueError(f"{depth}-bit samples; this reader only handles 8-bit")
    if interlace:
        raise ValueError("interlaced")
    channels = {0: 1, 2: 3, 3: 1, 4: 2, 6: 4}.get(colour)
    if channels is None:
        raise ValueError(f"unsupported colour type {colour}")

    raw = zlib.decompress(bytes(idat))
    stride = width * channels
    out = bytearray(width * height * 4)
    previous = bytearray(stride)
    offset = 0
    for y in range(height):
        filter_type = raw[offset]
        offset += 1
        line = bytearray(raw[offset : offset + stride])
        offset += stride
        if filter_type == 1:
            for i in range(channels, stride):
                line[i] = (line[i] + line[i - channels]) & 0xFF
        elif filter_type == 2:
            for i in range(stride):
                line[i] = (line[i] + previous[i]) & 0xFF
        elif filter_type == 3:
            for i in range(stride):
                left = line[i - channels] if i >= channels else 0
                line[i] = (line[i] + ((left + previous[i]) >> 1)) & 0xFF
        elif filter_type == 4:
            for i in range(stride):
                a = line[i - channels] if i >= channels else 0
                b = previous[i]
                c = previous[i - channels] if i >= channels else 0
                p = a + b - c
                pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
                pred = a if (pa <= pb and pa <= pc) else (b if pb <= pc else c)
                line[i] = (line[i] + pred) & 0xFF
        elif filter_type != 0:
            raise ValueError(f"unknown row filter {filter_type}")

        for x in range(width):
            base = x * channels
            target = (y * width + x) * 4
            if colour == 6:
                out[target : target + 4] = line[base : base + 4]
            elif colour == 2:
                out[target : target + 3] = line[base : base + 3]
                out[target + 3] = 255
            elif colour == 0:
                grey = line[base]
                out[target : target + 3] = bytes((grey, grey, grey))
                out[target + 3] = 255
            elif colour == 4:
                grey = line[base]
                out[target : target + 3] = bytes((grey, grey, grey))
                out[target + 3] = line[base + 1]
            else:  # palette
                index = line[base]
                entry = palette[index * 3 : index * 3 + 3] or b"\x00\x00\x00"
                out[target : target + 3] = entry
                out[target + 3] = transparency[index] if index < len(transparency) else 255
        previous = line

    return Bitmap(width, height, bytes(out))


def read_bitmap(path):
    """`(bitmap, None)` or `(None, reason it could not be read)`."""
    try:
        return read_with_pillow(path), None
    except ImportError:
        pass
    except Exception as error:  # noqa: BLE001 — any decoder failure is a report line
        return None, f"Pillow could not read it: {error}"
    try:
        return read_with_stdlib(path), None
    except Exception as error:  # noqa: BLE001
        return None, f"{error}; install Pillow for the pixel checks on this file"


# --------------------------------------------------------------------------
# Checking


def is_hex_colour(value) -> bool:
    return (
        isinstance(value, str)
        and value.startswith("#")
        and len(value) in (7, 9)
        and all(c in "0123456789abcdefABCDEF" for c in value[1:])
    )


def check_manifest(report: Report, directory: str):
    """Returns the manifest dict, or `None` when there is nothing to check."""
    path = os.path.join(directory, "character.json")
    if not os.path.isfile(path):
        report.error("No character.json in this folder.")
        return None
    try:
        with open(path, encoding="utf-8") as handle:
            manifest = json.load(handle)
    except (OSError, ValueError) as error:
        report.error(f"character.json could not be read: {error}")
        return None
    if not isinstance(manifest, dict):
        report.error("character.json is not a JSON object.")
        return None

    folder = os.path.basename(os.path.normpath(directory))
    identifier = manifest.get("id")
    if not isinstance(identifier, str) or not identifier.strip():
        report.error('character.json has no "id".')
    elif identifier != folder:
        report.warn(
            f'id is "{identifier}" but the folder is named "{folder}". '
            "The id is what overrides a built-in, not the folder."
        )

    name = manifest.get("displayName")
    if not isinstance(name, str) or not name.strip():
        report.warn('No "displayName"; the id is shown instead.')

    kind = manifest.get("kind", "person")
    if kind not in KINDS:
        report.error(f'kind is "{kind}"; it has to be one of {", ".join(KINDS)}.')

    harness = manifest.get("harness")
    if harness is not None and harness not in HARNESSES:
        report.warn(
            f'harness "{harness}" is not one Auspex watches, so this character is never '
            "a default. It can still be chosen by hand."
        )

    accent = manifest.get("accent")
    if accent is None:
        report.warn('No "accent"; surfaces outside the scene fall back to a neutral colour.')
    elif not is_hex_colour(accent):
        # A warning, not an error: the loader draws the character anyway and
        # only surfaces outside the scene lose the colour. The two checkers
        # agree on severity so a package that passes here behaves as described.
        report.warn(f'accent "{accent}" is not a #RRGGBB colour.')

    cell = manifest.get("cell", 32)
    if cell not in CELL_SIZES:
        report.error(f"cell is {cell!r}; it has to be {' or '.join(str(c) for c in CELL_SIZES)}.")
        manifest["cell"] = None

    anchor = manifest.get("anchor", "bottomCenter")
    if anchor not in ANCHORS:
        report.error(f'anchor is "{anchor}"; the only anchor is "bottomCenter".')

    poses = manifest.get("poses", {})
    if not isinstance(poses, dict):
        report.error('"poses" is not an object.')
        manifest["poses"] = {}
        return manifest
    for pose, spec in sorted(poses.items()):
        if pose not in POSES:
            report.warn(f'"{pose}" is not a pose the scene draws; it is ignored.')
            continue
        if not isinstance(spec, dict):
            report.error(f'poses.{pose} is not an object.')
            continue
        frames = spec.get("frames", 1)
        fps = spec.get("fps", 8)
        if not isinstance(frames, int) or isinstance(frames, bool) or frames < 1:
            report.error(f"poses.{pose}.frames is {frames!r}; it has to be a whole number ≥ 1.")
        if not isinstance(fps, (int, float)) or isinstance(fps, bool) or fps <= 0:
            report.error(f"poses.{pose}.fps is {fps!r}; it has to be a number > 0.")

    return manifest


def check_strip(report: Report, directory: str, pose: str, spec, cell: int) -> None:
    path = os.path.join(directory, f"{pose}.png")
    declared = spec.get("frames", 1) if isinstance(spec, dict) else None

    bitmap, reason = read_bitmap(path)
    if bitmap is None:
        report.warn(f"{pose}.png: pixel checks skipped — {reason}")
        return

    if bitmap.height != cell:
        report.error(
            f"{pose}.png is {bitmap.width}×{bitmap.height}; a strip is one row {cell} pixels tall."
        )
        return
    if bitmap.width == 0 or bitmap.width % cell:
        report.error(
            f"{pose}.png is {bitmap.width} pixels wide, which is not a whole number of "
            f"{cell}-pixel frames."
        )
        return

    frames = bitmap.width // cell
    if declared is not None and declared != frames:
        report.error(
            f"{pose}.png holds {frames} frames but character.json declares {declared}. "
            f"Width has to be cell × frames = {cell} × {declared} = {cell * declared}."
        )
    if declared is None:
        report.warn(f"{pose}.png is not listed in character.json.")

    # Corners, on the whole strip: a matte or a baked background shows up here
    # before it shows up anywhere else.
    corners = [
        (0, 0),
        (bitmap.width - 1, 0),
        (0, bitmap.height - 1),
        (bitmap.width - 1, bitmap.height - 1),
    ]
    opaque_corners = [(x, y) for x, y in corners if bitmap.alpha(x, y) != 0]
    if opaque_corners:
        report.error(
            f"{pose}.png has an opaque corner at "
            + ", ".join(f"({x},{y})" for x, y in opaque_corners)
            + ". The background has to be transparent."
        )

    semi = sum(
        1
        for y in range(bitmap.height)
        for x in range(bitmap.width)
        if 0 < bitmap.alpha(x, y) < 255
    )
    total = bitmap.width * bitmap.height
    share = semi / total if total else 0
    if share > SEMI_TRANSPARENT_TOLERANCE:
        report.error(
            f"{pose}.png has {semi} semi-transparent pixels ({share:.1%}); pixel art is drawn "
            "at final size with no anti-aliasing, so every pixel is either drawn or not."
        )
    elif semi:
        report.warn(f"{pose}.png has {semi} semi-transparent pixel(s).")

    margin = max(1, round(cell * SIDE_MARGIN_AT_32 / 32))
    for frame in range(frames):
        origin = frame * cell
        intrudes = any(
            bitmap.alpha(origin + x, y) != 0
            for y in range(cell)
            for x in list(range(margin)) + list(range(cell - margin, cell))
        )
        if intrudes:
            report.error(
                f"{pose}.png frame {frame} draws inside the {margin}-pixel side margin. "
                f"The figure belongs in columns {margin}–{cell - margin - 1} of its cell; "
                "the desk's monitor stands where the rest is."
            )
            break

    first_frame_pixels = [
        (x, y)
        for y in range(cell)
        for x in range(cell)
        if bitmap.alpha(x, y) != 0
    ]
    if not first_frame_pixels:
        report.error(
            f"{pose}.png frame 0 is empty. Frame 0 is what Reduce Motion shows, so it has "
            "to stand on its own as a pose."
        )
        return

    lowest = max(y for _, y in first_frame_pixels)
    if lowest < cell - 4:
        report.warn(
            f"{pose}.png frame 0 stops {cell - 1 - lowest} pixels above the bottom of its "
            "cell; the anchor is bottomCenter, so it will float above the seat."
        )


def validate(directory: str) -> Report:
    name = os.path.basename(os.path.normpath(directory))
    report = Report(name, os.path.abspath(directory))

    if not os.path.isdir(directory):
        report.error("Not a directory.")
        return report

    manifest = check_manifest(report, directory)
    if manifest is None:
        return report

    cell = manifest.get("cell", 32)
    poses = manifest.get("poses", {})
    if cell not in CELL_SIZES:
        report.note("Pixel checks skipped: the cell size is not one the scene can place.")
        return report

    present = sorted(
        entry[:-4]
        for entry in os.listdir(directory)
        if entry.endswith(".png") and os.path.isfile(os.path.join(directory, entry))
    )
    strays = [pose for pose in present if pose not in POSES]
    for stray in strays:
        report.warn(f"{stray}.png is not a pose the scene draws; it is ignored.")

    drawn = [pose for pose in present if pose in POSES]
    for pose in drawn:
        check_strip(report, directory, pose, poses.get(pose), cell)

    for pose, _ in sorted(poses.items()):
        if pose in POSES and pose not in present:
            report.error(f"character.json lists {pose} but there is no {pose}.png.")

    missing_core = [pose for pose in CORE_POSES if pose not in present]
    if missing_core:
        report.warn(
            "Not drawn yet, so the built-in figures are used for: " + ", ".join(missing_core) + "."
        )

    report.note(
        f"cell {cell}  ·  {len(drawn)} strip(s)  ·  "
        + (", ".join(drawn) if drawn else "none")
    )
    return report


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(
        description="Check an Auspex character package (docs/CHARACTERS.md).",
    )
    parser.add_argument("package", nargs="+", help="a character package folder")
    parser.add_argument(
        "--strict",
        action="store_true",
        help="fail on warnings as well as errors",
    )
    args = parser.parse_args(argv)

    reports = [validate(path) for path in args.package]
    print("\n".join(report.render() for report in reports))

    failed = [r for r in reports if not r.ok or (args.strict and r.warnings)]
    if failed:
        print(f"\n{len(failed)} of {len(reports)} package(s) failed.")
        return 1
    print(f"\n{len(reports)} package(s) ok.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
