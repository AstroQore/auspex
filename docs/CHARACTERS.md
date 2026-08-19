# Character packages

How to draw the people in Auspex's [scene view](../README.md#scene-view), and
where to put them so the app finds them.

Nothing here has to exist. The office ships with a procedural rig —
sixteen-pixel figures composed in code from the harness's own accent hue — and
every lookup that misses falls back to it, **per pose**. So art can land one
pose at a time: draw `blocked.png` and every session waiting on a person turns
into a person with their hand up, while everything else keeps its rectangles.
`blocked` is the one worth drawing first.

The rig is also a look somebody may simply prefer, so it is selectable rather
than only a fallback — see [The built-in look](#the-built-in-look).

A character is a *package*: one folder, one manifest, one frame strip per pose.

```
Resources/Characters/<character-id>/     ships with the app
~/.auspex/characters/<character-id>/     yours — hot-loaded, no rebuild
├── character.json
├── idle.png  thinking.png  typing.png  writing.png
├── delegating.png  blocked.png  stale.png  ended.png
└── walkDown.png  walkRight.png  walkUp.png  spawn.png     (optional)
```

## `character.json`

```json
{
  "id": "claudeCode-default",
  "displayName": "Ember",
  "kind": "person",
  "harness": "claudeCode",
  "accent": "#E0785A",
  "cell": 32,
  "anchor": "bottomCenter",
  "poses": {
    "idle":       {"frames": 2, "fps": 2},
    "thinking":   {"frames": 4, "fps": 4},
    "typing":     {"frames": 6, "fps": 12},
    "writing":    {"frames": 4, "fps": 6},
    "delegating": {"frames": 4, "fps": 6},
    "blocked":    {"frames": 2, "fps": 2},
    "stale":      {"frames": 2, "fps": 1},
    "ended":      {"frames": 4, "fps": 6}
  }
}
```

| Key | Required | Meaning |
| --- | --- | --- |
| `id` | yes | Stable identity. A package in `~/.auspex/characters/` with the same id **replaces** the built-in one. Conventionally the folder name. |
| `displayName` | no | The name a person reads. Defaults to `id`. |
| `kind` | no | `person` or `pet`. Same format either way; it only describes what was drawn. Defaults to `person`. |
| `harness` | no | The harness this character is the default for, spelled as the harness's own raw name. Without it the character is never automatic, only chosen. |
| `accent` | no | `#RRGGBB`, the character's main colour — the shirt colour for a person. Used by surfaces outside the scene. |
| `cell` | no | The square cell's edge in pixels: **32 or 48**. Defaults to 32. |
| `anchor` | no | `bottomCenter`, the only anchor. |
| `poses` | yes | Pose name to `{frames, fps}`. `frames` defaults to 1, `fps` to 8. |

### Harness names

`claudeCode` · `claudeCowork` · `codex` · `chatgptWork` · `cursor` ·
`grokBuild` · `grokBot` · `antigravity` · `geminiCLI`

### Pose names

Eight core poses and four optional ones. They are the scene's own vocabulary
rather than the session state machine's: `toolCalling` and `writingFile` are
both *typing*, they only differ in tempo and screen colour.

| File | When it plays | What it should show |
| --- | --- | --- |
| `idle.png` | Turn closed, nothing outstanding | Sitting still, one blink |
| `thinking.png` | Reasoning, no tool open | Head up, turning slightly |
| `typing.png` | A tool call is open | Hands alternating on the keys, fast |
| `writing.png` | The working tree is being changed | One hand writing, one steadying paper; slower |
| `delegating.png` | Subagents are running | Standing, holding a note out to the right |
| `blocked.png` | Waiting for a person | Turned to face the viewer, one hand up. **This is the one that has to catch the eye.** |
| `stale.png` | Working, but silent too long | Still, nodding off |
| `ended.png` | Session over | Walking out to the lower right, or one frame of an empty chair |
| `walkDown/Right/Up.png` | Optional | Walking to a desk or to the break area |
| `spawn.png` | Optional | A subagent arriving |

A pose with no file uses the built-in rig for that pose only. A pose listed
in `poses` with no file is a mistake and is reported.

## The strip

- **One horizontal row.** Frames run left to right — no second row, no padding
  between cells, no margin around the edge. `width = cell × frames`,
  `height = cell`.
- **Draw at final size.** Textures are filtered nearest-neighbour, so a
  32-pixel sprite downscaled from a 512-pixel painting arrives as mush. No
  anti-aliasing, no soft shadows, no gradients.
- **Transparent background**, straight alpha. No matte, no baked shadow: the
  monitor's coloured light is drawn *over* the figure and needs the alpha to be
  honest.
- **Compose inside the cell.** Feet on the bottom row, and at least 8 empty
  columns each side at `cell: 32` (12 at 48). The cell is anchored bottom-centre
  at the workstation's seat and the desk's monitor stands just outside it, so
  art that fills every column collides with the furniture. A person is about
  16 × 24 pixels inside a 32-pixel cell.
- **Frame 0 has to stand on its own.** Under Reduce Motion a strip is not
  played — its first frame is shown as a still — and it is what a single-frame
  pose shows too. Never make it a mid-swing in-between.
- **1 px outline** in `#1A1A1E`, flat fills, at most about eight colours per
  character. Three recognisable features at most: a hairstyle, one accessory,
  the shirt colour.

## Two cell sizes, one apparent size

A 48-pixel cell is a *more detailed* character, not a bigger one. Both sizes
are drawn 64 points tall — 32-pixel art at two points per pixel, 48-pixel art
at one and a third — so an office mixing them has one population rather than
two.

## The built-in look

The procedural rig is not only the fallback — it is a character in its own
right, listed in Settings → Characters as **Auspex built-in** and selectable
per harness exactly the way a package is. It is composed in code from each
harness's own accent, so it is always installed, never missing a pose, and
never out of date with a harness Auspex has just learned about.

A harness set to **Auspex built-in** keeps the little pixel people even when a
package claims that harness. A package overrides the built-in look only when it
is *chosen*, or when **Automatic** picks it — and Automatic means "whichever
package names this harness, and the built-in figures while none does". That
distinction is the reason the choice is a value rather than an optional id: no
choice at all means *keep picking for me*, and choosing the built-in figures
means *stop picking*.

## Which character a session wears

Resolved in this order, and the first answer wins:

1. A **session override**, if one was set for that exact session.
2. The **harness default** chosen in Settings → Characters — a package, or
   **Auspex built-in**.
3. The package whose `harness` names it, preferring the conventional
   `<harness>-default` id when more than one does.
4. The procedural built-in rig.

Both choices live in `~/.auspex/character-selection.json` and are written only
by Auspex. A choice pointing at a package that has since been deleted is
ignored, not obeyed — the harness falls back to step 3, not to the rig.

The file is a flat map of harness names and session keys to character ids, with
one reserved value: `"@built-in"` means the procedural rig. A harness with no
entry at all is on Automatic, which is what a selection file written before the
rig was selectable still means. `@` is reserved; a package whose id is
`@built-in` is loaded and can be automatic for a harness, but can never be
picked by hand, and Settings → Characters says so.

## Overriding a built-in

Copy `Auspex.app/Contents/Resources/Characters/<id>/` into
`~/.auspex/characters/`, keep the `id`, change the pixels. The user copy
replaces the built-in entirely; Settings → Characters says which built-in was
replaced.

## Hot reload

`~/.auspex/characters/` is watched, subtree and all, so a package dropped in or
a strip redrawn in place appears in a running app — no relaunch, no rebuild.
Changes are debounced, so saving eight strips from a script costs one rescan.
Auspex only ever *reads* this folder; it creates it when you press **Open
characters folder** and puts nothing in it.

Built-in packages are read from the app bundle at launch and are not watched.

## Checking a package

```sh
Scripts/validate_character.py ~/.auspex/characters/claudeCode-default
```

Checks the manifest's fields, the cell size, every strip's width and height
against its declared frame count, transparent corners, anti-aliased edge
pixels, the side margins, and that frame 0 is not empty. Warnings — a pose
nobody has drawn yet, a package that names no harness — never fail the run;
pass `--strict` when they should. Pillow is used when it is installed; without
it a built-in PNG reader does the same checks.

The validator is stricter than the loader on purpose. A `kind` or `anchor` the
format does not define fails here and is quietly replaced with the default in
the app: a mistake in a manifest should stop a package from being *shipped*,
not stop an office from being *drawn*.

`Tests/Fixtures/Characters/example-default/` is a complete package in this
format, and is small enough to read.

## What the app does with a broken package

Nothing fails loudly. A package that cannot be read is still listed in
Settings → Characters with what is wrong with it, and the office falls back to
the built-in rig for whatever could not be drawn. When `character.json`
disagrees with the pixels — four frames declared over a six-frame strip — the
**pixels win** and the discrepancy is reported, because playing four frames of
a six-frame cycle looks broken in a way that is very hard to trace back to a
stale JSON file.
