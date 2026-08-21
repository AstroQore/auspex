# Third-party notices

## Direct dependencies

- [agent-session-kit](https://github.com/AstroQore/agent-session-kit) — session
  discovery, live tailing, and the MCP transport. License: AGPL-3.0-only.
- [GRDB.swift](https://github.com/groue/GRDB.swift) — SQLite toolkit. License:
  [MIT](https://github.com/groue/GRDB.swift/blob/master/LICENSE).

## Ported source

`Sources/AuspexCore/Crew/` carries two ports, and the division between them is
load-bearing: **bloub supplies the bodies and the engine, avatar-lab supplies
the expressions and the choreography.**

### bloub — the bodies and the engine

A Swift port of the animation engine of
[bloub](https://github.com/jeremy-prt/bloub) — MIT, © 2026 Jérémy Perret. Its
numeric constants are measurements taken frame by frame off xAI's official Grok
Bot video rather than settings. What Auspex uses is:

- the **silhouettes** — one per harness — and the eased interpolation between
  them;
- the **eye model**: two capsules seated on a sphere with a real head
  orientation, so the far eye narrows, tilts and passes behind the limb with no
  cropping code;
- the **resting life**: the seeded gaze drift, the breath, the lid curve, and
  the blink at the midpoint of a transition;
- the **transition grammar** in `BloubTransition.swift`.

What Auspex deliberately does **not** use is bloub's *state* catalogue as a
state display. bloub says "thinking" by turning the body into three pulsing
dots and "waiting" by turning it into a travelling "!", and each of those costs
the avatar the silhouette that says which harness it is. Those states are still
in the port and still exact; the crew simply never leaves `idle`, which is the
one catalogue state that wears a chosen body and a face handed in from outside.

**Where the port leaves the measurements**, and why: the *timing of the
transitions* is Auspex's own, because bloub is a montage watched at illustration
size and this is a wall of 200-point cards watched out of the corner of an eye.
A change is a visible 420–600 ms ease-in-out rather than a 0.2 s blink that
hides it; the blink survives, centred on the morph's midpoint. For the same
reason the catalogue's few straight lines are eased here.
`Sources/AuspexCore/Crew/BloubTransition.swift` holds the whole deviation and
the reasoning for it in one place.

### bible-strong-avatar-lab — the expressions and the choreography

`Sources/AuspexCore/Crew/AvatarLabPresets.swift` is a generated port of the
expression and animation vocabulary of
[bible-strong-avatar-lab](https://github.com/smontlouis/bible-strong-avatar-lab)
— AGPL-3.0-only, © Stéphane Montlouis-Calixte. Auspex is AGPL-3.0-only as well,
so the data and the derivation travel under the same license. What is ported is
the 25 calibrated expression presets plus that project's neutral default, its
per-state expression pools and blink profiles, and the 23 built-in animations
its `createInitialSequences()` derives from them — in two families, a life cycle
(sleeping, waking, idle, listening, thinking, searching, working) and sixteen
reactions. `Scripts/port_avatar_lab.py` reads `src/features/avatar/presets.ts`
and `src/features/animation/sequences.ts` from a checkout and re-runs that
derivation, so a re-calibration upstream is a re-run rather than a re-typing.

This vocabulary is the crew's **entire state language**. Every Auspex state maps
to a *pool* of several of these animations rather than to one, played from a
per-session seed with jittered timing, so no two avatars are ever in step.

### The seam, and what is Auspex's own

`Sources/AuspexCore/Crew/AvatarLabFace.swift` is the single seam between the two
ports and is Auspex's own: it converts avatar-lab's face units (arcs on a sphere
of radius 120) into bloub's degrees and ball-radius fractions, and nothing else
in the tree interprets avatar-lab's numbers.
`Sources/AuspexCore/Crew/AvatarSequencePlayer.swift` and
`Sources/AuspexCore/Crew/CrewChoreographer.swift` are Auspex's own as well:
avatar-lab plays a sequence off a browser timer with mutable cursors and an
integrated spring, and Auspex needs a seeded pure function of time so that sixty
avatars can be sampled off one clock, a card whose clock stopped can resume on
the frame it left, and a screenshot can be reproduced.

## Brand marks

`Sources/AuspexApp/Resources/ProviderIcons/` carries the vendor marks Auspex uses to identify
which harness a session belongs to — Anthropic (Claude Code, Claude Cowork),
OpenAI (Codex, ChatGPT Work), Cursor, xAI (Grok Build), Google (AntiGravity,
Gemini CLI). They are reproduced from the vendors' public brand assets, as
single-colour SVGs, solely to label that vendor's own product in the UI, and
were first collected for [Vibe Bar](https://github.com/AstroQore/vibe-bar).
They are not covered by this project's license.

All project names and trademarks belong to their respective owners. Listing a
project or showing its mark here does not imply affiliation, sponsorship, or
endorsement.
