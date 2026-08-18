# Architecture

> **Target design; not all implemented.** Auspex is pre-alpha. This document
> describes where the project is going. Today the repository contains the
> package skeleton, `AuspexPaths`, the full `AuspexStore` schema with its
> repositories, `SessionRegistry` and `BoardSnapshot`, and an empty window.
> Nothing produces an event stream yet. Each section notes the milestone that
> makes it real.

## Packages

Auspex is split across two repositories so the hard part — knowing how each
harness records a session — is reusable on its own.

### `agent-session-kit` (sibling repository) — M0/M1

- **`AgentSessionKit`** — the vocabulary. `AgentEvent`, `AgentSession`,
  `SessionState`, `HarnessID`, and the `SourceAdapter` protocol. Pure model
  and parsing types, no I/O scheduling, no UI.
- **`AgentSessionLive`** — the moving parts. File tailing, directory watching,
  read-only SQLite polling, debouncing, and the concrete adapters for each
  harness.

`AuspexCore` depends on both products. `Package.swift` resolves the sibling
by path while the package is unpublished; switching to the git URL is a TODO
there.

### `AuspexCore` (this repository)

The testable half of the app: storage, aggregation, grouping, and the MCP
server. Everything worth a test lives here.

### `AuspexApp` (this repository)

SwiftUI scenes, windows, the menu bar extra, and the SpriteKit scene. View
glue only.

## Data Flow

```
   ~/.claude/projects        ~/.codex/sessions        ~/.cursor/chats
   ~/.grok/sessions          AntiGravity conversations
            │                        │                       │
            └────────────────┬───────┴───────────────────────┘
                             ▼
                      SourceAdapters              (read-only tail / poll)
                             │
                             ▼
                     AgentEvent stream            (one ordered async stream)
                             │
                             ▼
                   SessionStateReducer            (events → SessionState)
                             │
                             ▼
                     SessionRegistry              (live set of sessions)
                             │
                             ▼
                      BoardSnapshot               (immutable render input)
                             │
        ┌────────────────────┼────────────────────┐
        ▼                    ▼                    ▼
   Board (SwiftUI)    SpriteKit Scene        MenuBar extra
```

**SourceAdapters** watch each harness's on-disk store and emit events. They
never write: transcripts are tailed with a byte cursor, and SQLite stores are
opened read-only with a live WAL expected. Each adapter owns exactly one
harness's file format. — *M1 (Claude Code, Codex), M2 (the rest).*

**AgentEvent stream** merges every adapter into a single ordered async stream:
turn started, assistant text, tool call started/finished, sub-agent spawned,
file written, permission requested, turn ended, session ended. — *M1.*

**SessionStateReducer** folds that stream into a `SessionState` per session —
thinking, calling a tool, delegating, writing, waiting for permission, idle,
ended — plus the derived facts the board shows: current tool, elapsed time in
state, sub-agent tree, files touched. Pure function of (state, event); this is
the piece that must stay unit-testable. — *M1.*

**SessionRegistry** is an actor holding the live set. It bootstraps from the
store so a relaunch shows the board it had rather than an empty one, folds each
event through the reducer, batches writes into one transaction per 250 ms, and
re-evaluates staleness on a one-second tick — the one derived value that
changes because time passed rather than because something happened. Session
birth and death are the reducer's; project and task grouping are *M2*. —
*M1.*

**BoardSnapshot** is an immutable value the UI renders, published on an
`AsyncStream` coalesced to at most 20 Hz — a board redrawn faster than that is
redrawn for nobody. Views never read the registry directly, so the SwiftUI
board, the pixel scene, and the menu bar always agree. Sorted alive first, then
by which session most needs a person, then by recency; grouped by harness and
by project. — *M1.*

## Storage

GRDB over SQLite at `~/.auspex/auspex.db`, opened through `AuspexStore` as a
`DatabasePool` in WAL mode so ingest writes while the UI reads. Timestamps are
`REAL` epoch seconds throughout — the board and the retention job range-scan
them constantly, and a float compares without a parse.

**Schema evolves by append-only `DatabaseMigrator` migrations.** Never edit a
shipped one. `v1_initial` creates:

| Table | Holds |
| --- | --- |
| `projects`, `worktrees` | checkouts and their worktrees, so branches of one repository group together — *M2* |
| `sessions` | one row per session, keyed `"<harness>:<id>"` |
| `events` | the append-only event log |
| `tool_calls` | one row per call, so durations need no replay of the log |
| `messages` + `messages_fts` | indexed message text and the FTS5 index over it |
| `tasks`, `task_links`, `task_log`, `tags`, `session_tags` | the shared task board — *M3* |
| `source_cursors` | where each tailer stopped reading |
| `meta` | key/value, including the retention policy |

A session row carries `snapshot_json` — the reducer's `SessionSnapshot`,
verbatim — plus the columns the board sorts and filters on (`harness`, `state`,
`state_detail`, `is_alive`, `last_event_at`, token and turn counters, …)
projected out of it. The projection is written in one place, so the two cannot
drift, and the board never decodes a blob to sort. `events.detail_json`
likewise holds the whole encoded `AgentEventKind`, so a row round-trips back
into the event that produced it without the schema growing a column per case.

**FTS5 with the `trigram` tokenizer**, over `messages` as an external-content
table kept in step by three triggers. Trigram rather than a word tokenizer
because Auspex indexes source code and Chinese prose: a word tokenizer finds
neither `SessionRegistry` inside `makeSessionRegistry` nor any CJK substring,
since there are no spaces to split on. The costs are a larger index and a
three-character minimum query, both paid deliberately. Queries are quoted
before they reach `MATCH`, so search stays a text box rather than an expression
language.

**Retention** is a `RetentionPolicy` in `meta`: 2000 events per session, 14
days measured from when Auspex *observed* an event rather than from the
source's own timestamp (a cold-start seed of week-old history must not be
deleted on the way in), 30 days of searchable text, and a per-harness list
excluded from the index entirely. `RetentionJob.run()` deletes and then
reclaims pages with `PRAGMA incremental_vacuum`; the database is opened in
incremental auto-vacuum mode for it. Not scheduled yet — *M4*.

Every path is vended by `AuspexPaths`, which creates directories at mode 0700
and refuses to create anything outside `~/.auspex/`. That containment check is
what makes "Auspex only writes under `~/.auspex/`" a property of the code
rather than a convention.

## MCP

Auspex exposes its task board to agents over MCP, so an agent can see what its
siblings are doing and claim, update, or complete a shared task. — *M3.*

- **Transport: a Unix domain socket at `~/.auspex/mcp.sock`.** Local user
  only, never a TCP port. The running app owns the listener.
- **`auspex --mcp-stdio`** is a thin bridge for MCP clients that speak stdio:
  it connects to the socket and pumps stdin/stdout. It is dispatched in
  `main.swift` *before* `App.main()`, because MCP clients spawn this binary as
  a plain child process — sometimes inside their own sandbox — and bringing up
  NSApplication there is fatal.
- **`auspex --hook`** is the counterpart for harness hooks: a harness invokes
  it on a lifecycle event, and it forwards the event over the same socket so
  the board updates instantly instead of on the next file poll. Hooks are
  opt-in; file tailing remains the baseline so Auspex works with harnesses
  that have no hook mechanism.

Both flags currently print a not-implemented line to stderr and exit 2.

## Non-Goals

- **No network.** No backend, no telemetry, no update service, no cloud sync.
- **No writes into harness directories.** Auspex observes; it does not manage
  another tool's state. Acting on a session (M4) means driving the harness
  through its own supported interface, not editing its files.
- **No inference of missing data.** Where a harness log does not record a
  value, the field stays `nil`. A wrong model or a guessed state is worse than
  an empty one.
