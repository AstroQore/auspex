# Sprite atlas convention

How to draw the people in Auspex's [scene view](../README.md#scene-view), and
where to put them so the app finds them.

Nothing here has to exist. The scene ships with a procedural placeholder rig —
sixteen-pixel figures composed in code from the harness's own accent hue — and
every lookup that misses falls back to it. Art can therefore land one pose at a
time: draw `claudeCode/default/typing.png` and Claude Code sessions start
typing for real while every other harness keeps its rectangles.

## Where files go

```
<root>/<harness>/<variant>/<pose>.png     the frame strip
<root>/<harness>/<variant>/<pose>.json    optional, overrides the defaults
```

Two roots are searched, nearest first:

| Root | For |
| --- | --- |
| `~/.auspex/sprites/` | Trying art without rebuilding. Auspex only ever reads it. |
| `Sprites/` inside `Auspex.app/Contents/Resources/` | Art that ships with the app. |

Within a root, a session's own **variant** is tried before `default`, so one
harness can have several looks — `cursor/ide/typing.png` beside
`cursor/default/typing.png` — and only the entrypoints that deserve their own
art need it.

### Harness folder names

The folder is the harness's raw name, exactly as spelled here:

`codex` · `chatgptWork` · `claudeCode` · `claudeCowork` · `geminiCLI` ·
`antigravity` · `grokBuild` · `cursor`

### Variant folder names

`default` is required; it is what every session falls back to. Everything else
is a value some adapter recorded in `SessionIdentity.variant`, and the ones
seen so far are `cli`, `codex_cli_rs`, `codex_exec`, and `ide`. Do not guess at
new ones — an unmatched variant costs nothing, it just uses `default`.

### Pose names

Eight, and they are the scene's own vocabulary rather than the session state
machine's: `toolCalling` and `writingFile` are both *typing*, they only differ
in tempo and screen colour.

| File | When it plays | What it should show |
| --- | --- | --- |
| `idle.png` | Turn closed, nothing outstanding | Sunk into the chair, still |
| `thinking.png` | Reasoning, no tool open | Slow, small motion — a head bob, a blink |
| `typing.png` | A tool call is open | Hands working, fast |
| `writing.png` | The working tree is being changed | Hands working, deliberate; paper is a nice touch |
| `delegating.png` | Subagents are running | Standing, handing something to the right |
| `blocked.png` | Waiting for a person | One hand up. This is the one that has to catch the eye |
| `stale.png` | Working, but silent too long | Still, drowsy |
| `ended.png` | Session over | Leaving, or an empty chair |

A missing pose falls back to the placeholder rig for that pose only, so a set
can be finished in any order. `blocked` is the one worth drawing first.

## The strip

- **One horizontal row.** Frames run left to right, no second row, no padding
  or margin between cells and none around the edge.
- **Square cells by default.** The loader infers `columns = width / height`, so
  a 6-frame 32-pixel animation is a 192 × 32 PNG. A non-square cell needs a
  manifest (below).
- **32 × 32 pixels per cell** is the size to draw for. It is rendered at two
  scene points per pixel, so a cell is 64 × 64 points on screen at 1:1 zoom.
- **Compose inside the cell.** Put the figure's feet on the bottom row and keep
  it inside the middle 24 columns and the bottom 30 rows. The cell is anchored
  bottom-centre at the workstation's seat, and the desk's monitor stands 4
  points to the right of the cell's right edge — art that fills all 32 columns
  will collide with it.
- **Transparent background.** Straight alpha, no matte, no baked shadow. The
  monitor's coloured light is drawn *over* the figure and needs the alpha to be
  honest.
- **Author at final resolution.** Textures are filtered nearest-neighbour, so a
  32-pixel sprite downscaled from a 512-pixel painting arrives as mush. Draw
  the pixels.
- **8 frames per second** unless a manifest says otherwise. Two to eight frames
  reads well; a single-frame strip is legal and means "a static pose".
- **Colour is yours.** Nothing is tinted at runtime, so each harness's art
  carries its own hue. The board and the placeholder rig use these accents, and
  matching them is what keeps one harness one colour across the whole app:
  Codex `#2DD4BF`, ChatGPT Work `#22A06B`, Claude Code `#E0785A`, Claude Cowork
  `#CE8F6E`, Gemini CLI `#7DD3FC`, AntiGravity `#B4E048`, Grok Build `#F45FA0`,
  Cursor `#4C8DFF`.

## The manifest

Optional, and only worth writing when the defaults are wrong:

```json
{ "frameWidth": 24, "fps": 12 }
```

| Key | Default | Meaning |
| --- | --- | --- |
| `frameWidth` | the image's height | Cell width in pixels. Set it when cells are not square. |
| `fps` | `8` | Frames per second. |

Cell *height* is always the image's height — a strip is one row.

## A finished folder

```
~/.auspex/sprites/
└── claudeCode/
    ├── default/
    │   ├── blocked.png      64 × 32   2 frames
    │   ├── delegating.png  128 × 32   4 frames
    │   ├── idle.png         32 × 32   1 frame
    │   ├── thinking.png     96 × 32   3 frames
    │   ├── typing.png      192 × 32   6 frames
    │   ├── typing.json      { "fps": 12 }
    │   └── writing.png     128 × 32   4 frames
    └── cli/
        └── typing.png      192 × 32   6 frames
```

Claude Code sessions launched from a terminal type with the `cli` art; every
other Claude Code session uses `default`; `stale` and `ended` have no art yet,
so those two poses stay procedural.

## Reduce Motion

When the system asks for less motion, a strip is not played — its first frame
is shown as a still. So **frame 0 of every strip must be a legible standalone
pose**, not a mid-swing in-between. It is also what a person sees for any pose
drawn as a single frame.
