# Changelog

All notable changes to Auspex are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

Auspex is pre-alpha; there are no released versions yet.

## [Unreleased]

### Added

- SwiftPM package scaffold: `AuspexCore` library on GRDB 7 and
  `agent-session-kit`, and the `AuspexApp` SwiftUI executable, both in
  Swift 6 language mode.
- `AuspexPaths` — single source of truth for the `~/.auspex/` tree, created
  lazily with mode 0700, with an injectable home directory for tests and a
  containment check that refuses to create anything outside its base.
- `AuspexStore` — GRDB store on a WAL `DatabasePool`, whose append-only
  `v1_initial` migration creates the whole schema: projects and worktrees,
  sessions, the event log, the tool-call ledger, indexed message text with
  an FTS5 index over it, the task board, per-source tailing cursors, and
  `meta`. A session row carries the reducer's snapshot verbatim plus the
  columns the board sorts and filters on, projected out of it in one place
  so the two cannot drift.
- Full-text search across every harness at once, using FTS5's `trigram`
  tokenizer so a Chinese substring and an identifier glued inside a longer
  one are both found — neither of which a word tokenizer can do.
- `SessionRepository` — snapshot upsert and fetch, batched event append and
  recent-event windows, the tool-call ledger, and search.
  `SourceCursorRepository` persists how far each tailer has read, so a
  relaunch resumes instead of re-reading gigabytes of history.
- `RetentionPolicy` and `RetentionJob` — 2000 events per session, 14 days
  measured from when Auspex observed an event rather than from the source's
  own timestamp, 30 days of searchable text, and a per-harness exclusion
  list for the index. Stored in `meta`; not scheduled yet.
- `SessionRegistry` — an actor that bootstraps from the store, folds the
  `AgentEvent` stream through `SessionStateReducer`, batches writes into one
  transaction per 250 ms, and re-evaluates staleness on a one-second tick.
- `BoardSnapshot` — the immutable frame the UI renders, published coalesced
  to at most 20 Hz, sorted alive-first and then by which session most needs
  a person, and grouped by harness and by project.
- **The live board.** A wall of session cards in a `NavigationSplitView`:
  sidebar, board, session trace. Each card carries its harness accent rail
  and monogram, a state pill, the current tool or target, an elapsed-in-state
  stopwatch, turn / tool-call / token counters, and the project, pid, and
  model. Group by nothing, by harness, or by project, with sticky section
  headers carrying live counts; search every transcript from the toolbar.
- **A state language built out of colour and motion.** Every card ends in one
  2 pt pulse line whose rhythm is its state: a slow breath for thinking, a
  travelling segment while a tool is open, one tick per child while
  delegating, and a hard strobe plus a red glow for a session blocked on a
  permission prompt. One `repeatForever` animation per animating card and
  none at all for idle or ended ones; every rhythm collapses to a static bar
  under Reduce Motion.
- **`HarnessStyle` and `StateStyle`** — the fixed accent hue and two-letter
  monogram for each of the eight harnesses, and the colour, label, and motion
  for each session state, defined once so the board, the trace, the menu bar,
  and M2's scene view cannot disagree. Colours are dynamic `NSColor`s, so
  light mode works without an asset catalog.
- **`SessionTraceView`** — a session's identity, its parent link, and a trace
  waterfall of its events on a continuous spine: timestamps to a tenth of a
  second, a coloured node per event kind, turn separators, filter chips, and
  tail-following that yields the moment the reader scrolls away. A tool call
  is one row carrying its duration rather than two; clicking a row opens the
  full text and the pretty-printed payload.
- **`BoardGrouping` and `TraceEntry`** in `AuspexCore` — the pure grouping,
  sorting, and event-summarising the views render, testable without a window.
- **`LiveBoardModel`** — the single consumer of `SessionRegistry`'s frame
  stream. The trace stays live by re-reading `recentEvents` whenever a frame
  moves the selected session, debounced so a burst is one query.
- **`AppEnvironment` wires the pipeline**: store → registry → merged event
  stream, fed by `IngestCoordinator` and a `LivenessResolver` loop, with
  `SourceCursorRepository` now conforming to the kit's `SourceCursorStore` so
  a relaunch resumes where the tailers stopped. `AuspexAdapters.all` is empty
  until the Claude Code and Codex adapters land, and the empty board says so
  rather than looking broken.
- **Menu bar extra** showing live, delegating, and blocked counts, and a menu
  of live sessions that opens the window onto the one you pick.
- **`--demo`** (or `AUSPEX_DEMO=1`) replays a fabricated board — eight
  sessions across all five harnesses, seeded and reproducible — out of an
  in-memory store, so the UI can be developed and demonstrated before any
  adapter exists. It reads no harness store and writes nothing to disk.
- `--mcp-stdio` and `--hook` command-line placeholders, dispatched before
  AppKit starts; both exit 2 until M3.
- `Scripts/build_app.sh` — packages and ad-hoc signs `.build/Auspex.app`, and
  fails the build if the signed bundle claims the app-sandbox entitlement.
- Open-source scaffolding: README (English and Chinese), architecture notes,
  contributor and security policies, issue and PR templates, and CI.
