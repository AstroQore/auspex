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
