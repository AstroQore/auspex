# Third-party notices

## Direct dependencies

- [agent-session-kit](https://github.com/AstroQore/agent-session-kit) — session
  discovery, live tailing, and the MCP transport. License: AGPL-3.0-only.
- [GRDB.swift](https://github.com/groue/GRDB.swift) — SQLite toolkit. License:
  [MIT](https://github.com/groue/GRDB.swift/blob/master/LICENSE).

## Ported source

`Sources/AuspexCore/Crew/` is a Swift port of the animation engine of
[bloub](https://github.com/jeremy-prt/bloub) — MIT, © 2026 Jérémy Perret. The
geometry, the state catalogue and every numeric constant come from that
project, where they are measurements taken frame by frame off xAI's official
Grok Bot video rather than settings. Auspex uses the engine to draw one
avatar per session and supplies its own colours; bloub's own colour palette is
carried only so a frame produced here can be compared against one produced
there. Each ported file carries the notice in its header.

**Where the port deliberately leaves the measurements.** The poses, silhouettes,
decor, gaze angles, eye capsules and amplitudes are bloub's and stay untouched.
The *timing of the transitions between them* is Auspex's own, because bloub is a
montage watched at illustration size and this is a wall of 200-point cards
watched out of the corner of an eye: a state change is a visible 420–600 ms
ease-in-out with the face trailing the body by 60 ms, rather than a 0.2 s blink
that hides the change; the blink survives, centred on the morph's midpoint. For
the same reason the catalogue's few straight lines — the orbit's spin-up, the
"!"'s return, the swoosh's sweep, the thinking dots' clamped pulse and the decor
opacity ramps — are eased here. `Sources/AuspexCore/Crew/BloubTransition.swift`
holds the whole deviation and the reasoning for it in one place.

`Sources/AuspexCore/Crew/AvatarLabPresets.swift` is a generated port of the
expression and animation vocabulary of
[bible-strong-avatar-lab](https://github.com/smontlouis/bible-strong-avatar-lab)
— AGPL-3.0-only, © Stéphane Montlouis-Calixte. Auspex is AGPL-3.0-only, so the
data and the derivation travel under the same license. What is ported is the 25
calibrated expression presets plus that project's neutral default, its
per-state expression pools and blink profiles, and the 23 built-in animations
its `createInitialSequences()` derives from them — in two families, a life
cycle (sleeping, waking, idle, listening, thinking, searching, working) and
sixteen reactions. `Scripts/port_avatar_lab.py` reads
`src/features/avatar/presets.ts` and `src/features/animation/sequences.ts` from
a checkout and re-runs that derivation, so a re-calibration upstream is a
re-run rather than a re-typing.

**What the two ports each own.** avatar-lab supplies the **face** — the eye
geometry of an expression and the choreography that sequences it. bloub keeps
the **body and the decor** — every silhouette, the thinking dots, the orbit's
rings, the travelling "!", the burst's particles, the resting gaze drift and
the sphere the eyes live on. `Sources/AuspexCore/Crew/AvatarLabFace.swift` is
the single seam between them and is Auspex's own: it converts avatar-lab's face
units (arcs on a sphere of radius 120) into bloub's degrees and ball-radius
fractions, and nothing else in the tree interprets avatar-lab's numbers.
`Sources/AuspexCore/Crew/AvatarSequencePlayer.swift` and
`Sources/AuspexCore/Crew/CrewChoreographer.swift` are Auspex's own as well:
avatar-lab plays a sequence off a browser timer with mutable cursors, and
Auspex needs a seeded pure function of time so that sixty avatars can be
sampled off one clock and a screenshot can be reproduced.

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
