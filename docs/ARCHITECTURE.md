# Architecture

> **Target design; not all implemented.** Auspex is pre-alpha. This document
> describes where the project is going. Today the repository contains the
> package skeleton, `AuspexPaths`, a `meta`-table-only `AuspexStore`, and an
> empty window. Each section notes the milestone that makes it real.

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

Auspex does not depend on it yet. `Package.swift` carries a commented-out
`.package(path: "../agent-session-kit")` line; wiring it up is M0-4.

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

**SessionRegistry** holds the live set, handles session birth and death,
reconciles a restarted harness against sessions already on disk, and attaches
project and task grouping. — *M1, grouping in M2.*

**BoardSnapshot** is an immutable value the UI renders. Views never read the
registry directly, so the SwiftUI board, the pixel scene, and the menu bar
always agree. — *M1.*

## Storage

GRDB over SQLite at `~/.auspex/auspex.db`, opened through `AuspexStore`.

- **Schema evolves by append-only `DatabaseMigrator` migrations.** `v1_initial`
  creates a `meta` key/value table; sessions, events, tasks, and projects
  follow in M1. Never edit a shipped migration.
- **FTS5** indexes transcript text for search across every harness at once —
  the thing no individual CLI can do. *M2.*
- `meta` also holds per-harness scan cursors, so a restart resumes tailing
  where it stopped instead of re-reading gigabytes of history.
- Every path is vended by `AuspexPaths`, which creates directories at mode
  0700 and refuses to create anything outside `~/.auspex/`. That containment
  check is what makes "Auspex only writes under `~/.auspex/`" a property of
  the code rather than a convention.

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
