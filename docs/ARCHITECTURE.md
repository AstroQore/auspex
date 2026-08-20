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
*file format* — which is not the same as one harness. `CodexLiveAdapter` reads
`~/.codex/sessions`, which carries both Codex and ChatGPT Work rollouts, told
apart by each rollout's `originator`; it reports both through
`SourceAdapter.handledHarnesses`, and `AuspexAdapters` indexes by that so
neither harness can be claimed unwatched while its sessions are on the board.
Claude Cowork is the mirror case — the same format as Claude Code, a different
store inside Claude.app's container, and therefore its own adapter. — *M1
(Claude Code, Codex), M2 (the rest).*

### The seven harnesses

`AuspexAdapters.featured` is the list every surface reports on: Claude Code,
Claude Cowork, Codex, ChatGPT Work, Cursor, Grok Build, AntiGravity. Gemini CLI
is in the kit's catalog and has no live adapter, so it is recognised but not
featured.

Identity is the vendor's own single-colour mark (`HarnessLogo`, loaded from
`Sources/AuspexApp/Resources/ProviderIcons`, drawn as a template in the harness
accent) plus the harness's **full** name. Two pairs share a mark because they
share a vendor; the accent and the name are what separate them, and no UI
string abbreviates a harness.

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

### The user layer: `AuspexProject` and `IgnoreRule`

Everything above is automatic, and automatic answers a question a person did
not ask twice: *these six directories are one piece of work* is not written
down anywhere on disk. So a second layer sits over the resolver's.

An **`AuspexProject`** claims roots. Any session whose worktree, git root, or
working directory is under a claimed root is placed in it, whatever git said.
The longest claim wins, and two claims of equal length go to the older project
— so making a project can never silently move somebody else's sessions. A
project also carries a name, a colour, a pin, and the `HarnessProjectRef`s it
was imported from.

`ProjectClaims` — the index built from those projects — rides on
`BoardSnapshot`. That is the load-bearing decision: `projectKey(for:)` is what
the wall, the sidebar, a card's subtitle, the scene's floor plates and the
trace header all ask, so a user layer applied anywhere else would be a layer
four of the five surfaces remembered to apply. `projectDisplayName(forKey:)` is
the matching answer for a section's title, and pinned projects are promoted to
the front of `BoardGrouping` and `ProjectTree` alike.

Projects are **imported** from the harnesses' own registries, behind
`HarnessProjectSource` so the next one is a file rather than a branch. Claude
Code's is in two places — the encoded directory names under `~/.claude/projects`
(decoded against the file system by the kit's `ClaudeProjectPath`) and the
`projects` keys of `~/.claude.json`, *only* those keys, never the account
information beside them. Codex's is also two: the `[projects."…"]` tables in
`~/.codex/config.toml`, read by the same section scanner the MCP page uses, and
the distinct `cwd`s of `local_thread_catalog` in `~/.codex/sqlite/codex-dev.db`,
opened through the kit's read-only `LiveSQLiteReader`.

An **`IgnoreRule`** hides sessions: a folder and everything under it, a project
however its sessions were placed, the opening of a prompt, a whole harness, or a
substring of a title. `BoardFilter` applies the claims and then the rules,
turning the registry's frame into the one the app draws — `LiveBoardModel.board`
— and *every* surface reads that one. Nothing downstream re-applies a rule, so
nothing downstream can forget to. Hiding a session hides what it delegated to,
because a subagent has no directory, no process and no title of its own.

Ignored is not deleted: the sessions are still ingested, still stored, and still
in the FTS index. The board's header offers "N ignored", which puts them back
dimmed, and every surface that writes a rule says the same sentence about it.

`.promptPrefix` matches `SessionBrief.firstPrompt` — the assignment as the
person typed it, the same string the card's `asked:` line shows — and falls
back to the title for a session whose transcript has not been read far enough
to have a brief yet.

## Harness Configuration

`HarnessMCPConfigStore` reads each harness's own MCP configuration — the
`mcpServers` object in `~/.claude.json`, `~/.cursor/mcp.json`, and
`~/.gemini/config/mcp_config.json`, and the `[mcp_servers.<name>]` tables in
`~/.codex/config.toml` and `~/.grok/config.toml` — and takes the server names
and nothing else.

A harness that shares another's store usually shares its configuration file too,
and is given the same location rather than a second guess: ChatGPT Work reads
Codex's `~/.codex/config.toml`. Claude Cowork is the exception. Its servers come
from Claude.app's own settings inside the app container, not from the CLI's
`~/.claude.json`, so `location(for:)` answers `nil` and the page says *managed
by Claude.app*. Naming a file that has not been verified would report the wrong
servers with full confidence, which is worse than reporting none.

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
| `plans`, `tasks`, `task_links`, `task_log`, `tags`, `session_tags` | the shared task board an orchestrator registers and its workers claim |
| `session_notices`, `session_reports` | what agents said: a live call for a person, and a self-reported focus line |
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

Beside the database are the three files a person edits rather than the app
fills: `character-selection.json`, `projects.json` (the user's projects and the
folders they claim), and `settings.json` (the ignore rules, and whether the
board is revealing them). They are JSON rather than tables because they are
small, rare, and worth being able to open — and separate files rather than one
because they are written by different surfaces at different rhythms, and adding
a folder to a project should not rewrite the ignore rules. Reading any of them
is total: a missing file is an empty value, and one unreadable entry costs that
entry rather than the file.

Every path is vended by `AuspexPaths`, which creates directories at mode 0700
and refuses to create anything outside `~/.auspex/`. That containment check is
what makes "Auspex only writes under `~/.auspex/`" a property of the code
rather than a convention.

## MCP

Auspex exposes itself to agents over MCP: sixteen tools, in three layers.

The first is the one that matters. `auspex.notify(kind, message)` lets a
session say it needs the person — a question, a review, a blocker, or finished
work — and lands it in the right bucket with the agent's own words, a macOS
notification, and a menu-bar count. Passive observation cannot answer that
question at all: Claude Code and Cursor write no permission state to disk, and
"I asked you something and I am waiting" is invisible in every harness's files.

The second is `auspex.report(focus, progress)`, which replaces Auspex's
inference about what a session is doing with the session's own sentence.

The third is the task board — `plans.*` and `tasks.*` — whose intended caller
is whoever *hands work out*: a supervisor registers a plan, files a task per
worker, and puts the id in each brief, so each worker makes one
`tasks.claim(task_id, role, scope)` call. `sessions.list`, `sessions.tree`,
`sessions.self` and `peers.status` are read-only.

- **Transport: a Unix domain socket at `~/.auspex/mcp.sock`.** Local user
  only, never a TCP port. The running app owns the listener.
- **`auspex --mcp-stdio`** is a thin bridge for MCP clients that speak stdio:
  it connects to the socket and pumps stdin/stdout. It is dispatched in
  `main.swift` *before* `App.main()`, because MCP clients spawn this binary as
  a plain child process — sometimes inside their own sandbox — and bringing up
  NSApplication there is fatal.
- **`auspex --hook <harness>`** is the counterpart for harness hooks: a
  harness invokes it on a lifecycle event, and it forwards the payload over
  the same socket so the board updates instantly instead of on the next file
  poll. Hooks are opt-in; file tailing remains the baseline so Auspex works
  with harnesses that have no hook mechanism.

**A hook must never be able to block the harness that runs it.** It is a
synchronous child of a working agent, and in most harnesses a non-zero exit is
a *veto* — Claude Code reads a failed `PermissionRequest` hook as a decision.
So `HookIngress` exits 0 within 200 ms whatever happens: each blocking call has
its own deadline, a watchdog thread ends the process at the limit regardless,
`SO_NOSIGPIPE` keeps a closed socket from killing it with a signal, and Auspex
not running is not an error. It parses nothing, reads no store, and logs
nothing: the harness's JSON goes to the socket verbatim, capped at a megabyte,
with the target, the parent pid and the arrival time attached.

`HookEventRouter`, in the app, is what reads it — and it maps only the facts a
transcript never contains. Tool calls are deliberately *not* mapped: the tailer
describes them better, and a `toolCallStarted` reported twice is counted twice.
What hooks add is `PermissionRequest` (Claude asks for approval in its UI and
writes nothing until the answer arrives, so waiting for a person and thinking
hard are the same silence from outside), session and subagent boundaries at the
instant they happen, and a heartbeat for everything else.

**Identity.** An agent never has to know its own session id. The kernel
reports the socket's peer pid; `MCPSelfResolver` walks up from it until it
finds a process the board already owns, or one of the session-id environment
variables harnesses hand down to everything they spawn. `sessions.self` says
which pid it used and what convinced it, and every tool that acts *as* a
session takes an explicit `session_id` override — so a wrong guess is visible
rather than silent.

**Untrusted input.** Tool arguments are the one place a model writes straight
into the database and onto the screen, so `MCPTextSanitizer` strips control
characters, bidirectional overrides and zero-width formatters, collapses
whitespace and caps length before any value reaches the store. Unknown
argument keys are refused rather than ignored. A demo replay refuses the nine
writing tools by name.

## Non-Goals

- **No network.** No backend, no telemetry, no update service, no cloud sync.
- **No writes into harness directories**, with one deliberate exception:
  `HarnessInstaller`, which registers Auspex's MCP server, installs the
  task-protocol note, and registers the hooks. It runs only when a person
  clicks, writes only in a region Auspex owns — a `>>> auspex >>>` fence, one
  named JSON member, or the hook entries whose command runs the Auspex binary
  — backs the file up to `~/.auspex/backups/` first, re-parses it after, and
  can be undone exactly. The observation layer keeps the absolute rule — see
  `AGENTS.md` § 6. Acting on a session (M4) means driving the harness through
  its own supported interface, not editing its files.
- **No inference of missing data.** Where a harness log does not record a
  value, the field stays `nil`. A wrong model or a guessed state is worse than
  an empty one.
