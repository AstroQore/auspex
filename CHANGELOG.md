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
- Empty main window (`NavigationSplitView` with Live / Projects / Tasks /
  Harnesses / Settings) and a menu bar extra with Open and Quit.
- `--mcp-stdio` and `--hook` command-line placeholders, dispatched before
  AppKit starts; both exit 2 until M3.
- `Scripts/build_app.sh` — packages and ad-hoc signs `.build/Auspex.app`, and
  fails the build if the signed bundle claims the app-sandbox entitlement.
- Open-source scaffolding: README (English and Chinese), architecture notes,
  contributor and security policies, issue and PR templates, and CI.
