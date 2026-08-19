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
by project, and carrying the delegation forest as `tree`. — *M1.*

## Grouping

Two axes cut across the board, and neither is recorded by any harness: **where**
a session is working, and **who** started it.

### Where: `ProjectResolver` → `projects` / `worktrees`

`ProjectResolver` turns a working directory into a `ProjectPlacement` by reading
git's own files — `.git` (a directory in a main checkout, a file naming a
gitdir in a linked worktree), `<gitdir>/commondir`, and `<gitdir>/HEAD`. No
`git` subprocess: a placement is resolved per session and re-checked whenever a
session moves, and a process launch per session per change is real CPU spent on
a question three short text files already answer.

The placement's `projectRootPath` is the **main repository**, so three agents in
three worktrees of one repo are one project with three checkouts rather than
three projects. Paths following the agent-worktree conventions —
`.agents/worktrees/<task>` and the `.claude`, `.codex`, `.cursor`, `.grok`
variants — also yield `agentWorktreeTask`, which is usually the most
informative label a row has before a title arrives. A directory in no
repository is its own project, named after itself.

Placements are cached per directory and invalidated by `HEAD`'s modification
date, because the branch is the only part of the answer that goes stale; a
directory with no `HEAD` to watch expires on a 30-second TTL instead.

`PlacementService` is the debounce in front of it: a `(session, cwd)` pair is
resolved **once**, which matters because Claude Code re-reports its working
directory on every transcript line. `ProjectRepository` writes what comes out —
upserting `projects` and `worktrees`, pointing `sessions.project_id` /
`worktree_id` at them, and answering the questions a live board cannot, like
"every session this machine has ever run in this repository". — *M2.*

### Who: `ProcessLinker` → `sessions.parent_key` / `root_key`

A Claude Code tool call that runs `codex exec` is a real parent/child pair that
*neither* log records. `ProcessLinker` (in `AgentSessionLive`) recovers it from
the process table: first the environment — a harness passes its session id to
everything it launches, so `CLAUDE_CODE_SESSION_ID` in a Codex process's
environment is evidence only the parent could have left — and failing that the
spawn tree. The result is a `ParentLink` of `.envInherited` or
`.spawnedProcess`, ranked *below* the `.subagent` links adapters read out of a
log and the `.manual` ones a person makes, and only ever applied to a session
that has no parent yet.

`SessionTreeBuilder` folds those parents into a `SessionTree`: roots, depths,
`descendants(of:)`, and the `root_key` every session row stores. It is total —
orphans whose parent is not on the board become roots, and a cycle is broken
rather than followed. `BoardSnapshot.byProject` uses it to place a child that
recorded no directory of its own (a subagent has no process and no cwd) under
its nearest ancestor's project.

`GroupingCoordinator` runs both on a three-second tick, off the registry's
actor — `sysctl` and `stat` do not belong on the path of every event — and
feeds the answers back in through `SessionRegistry.applyPlacements(_:)` and
`applyLinks(_:)`, which turn them into ordinary `identityUpdated` events.
`AppEnvironment` starts it beside the liveness loop and hands both the same
`ProcessTable`, whose three-second cache then serves one read per tick instead
of two. — *M2.*

### What the UI does with both

Neither axis is a view's to compute. `ProjectTree` and `BoardGrouping` are in
Core, over a `BoardSnapshot`, so the sidebar and the wall are two renderings of
one answer rather than two answers.

- **`ProjectTree`** is the sidebar's shape: `project → checkout → session`.
  Projects come from `BoardSnapshot.projectKey(for:)` — the *instance* method,
  which walks a session's ancestors, so a subagent with no directory of its own
  lands under its parent's project. Checkouts divide a project by
  `worktreePath ?? gitRoot ?? cwd`, which is what puts three worktrees of one
  repository side by side under one name. Only the display *names* come from
  the store, through `ProjectRepository.fetchProjects(withCounts:)`: a project
  outlives every session in it, and the name is the one fact a live frame
  cannot supply. Every count is the frame's, so the sidebar and the cards
  cannot disagree.
- **`BoardGroupBy.tree`** is the wall's: `SessionTreeBuilder` over the sessions
  that survived the filters — not over `snapshot.tree` — so a child whose
  parent a harness filter removed becomes a root instead of disappearing.
  Roots that delegated get a section each; the rest share one.
- **The project filter** is applied on every axis and resolved against the
  frame for the same reason the grouping is, so filtering to a project keeps
  the children that inherited it.

`ParentLink` reaches the UI intact rather than being flattened into "has a
parent": the trace header names the evidence, because a spawn a log recorded
and a shared process ancestor are not the same claim.

## Harness Configuration

`HarnessMCPConfigStore` reads each harness's own MCP configuration — the
`mcpServers` object in `~/.claude.json`, `~/.cursor/mcp.json`, and
`~/.gemini/config/mcp_config.json`, and the `[mcp_servers.<name>]` tables in
`~/.codex/config.toml` and `~/.grok/config.toml` — and takes the server names
and nothing else.

It is **read-only in the strong sense**: no writes, no creation of a missing
file, no rewriting of a file it could not fully parse. § 6 of `AGENTS.md`
applies to a harness's configuration exactly as it applies to its transcripts.

The TOML side is a section scanner, not a parser, and deliberately so. The
question asked of the file is "which `[mcp_servers.<name>]` tables are in
here", a full parser would be a dependency, and — worse — it would fail the
*whole file* on a construct it disliked, which is the wrong answer for a status
page: a config Auspex cannot fully parse still has a legible server list. So
`[mcp_servers.foo.env]` is read as a sub-table of `foo` rather than as a server
called `foo.env`, a quoted name is unquoted, and anything unrecognised costs
its own table rather than the file. "No config file", "could not be read", and
"no servers" stay three distinct answers all the way to the screen. — *M2.*

## Storage

GRDB over SQLite at `~/.auspex/auspex.db`, opened through `AuspexStore` as a
`DatabasePool` in WAL mode so ingest writes while the UI reads. Timestamps are
`REAL` epoch seconds throughout — the board and the retention job range-scan
them constantly, and a float compares without a parse.

**Schema evolves by append-only `DatabaseMigrator` migrations.** Never edit a
shipped one. `v1_initial` creates:

| Table | Holds |
| --- | --- |
| `projects`, `worktrees` | checkouts and their worktrees, so branches of one repository group together |
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

Three columns are deliberately *not* part of that projection:
`project_id`, `worktree_id`, and `root_key`. Each is resolved on a different
schedule from the snapshot — a placement needs the filesystem, a root needs the
whole delegation tree — so `ProjectRepository` owns them, and an upsert of the
snapshot leaves them alone rather than blanking them on every event until the
resolver catches up. A brand-new row still gets `root_key = key`, because a
session with no parent is its own root and grouping should never see NULL.

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
