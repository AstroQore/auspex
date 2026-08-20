# Auspex

<p align="center">
  <strong>One live board for every AI coding agent running on your Mac.</strong>
</p>

<p align="center">
  <img src="https://img.shields.io/badge/status-pre--alpha-orange" alt="Status: pre-alpha">
  <img src="https://img.shields.io/badge/macOS-26%2B-000000?logo=apple" alt="macOS 26+">
  <img src="https://img.shields.io/badge/Swift-6.2-F05138?logo=swift&logoColor=white" alt="Swift 6.2">
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-AGPL--3.0--only-blue" alt="AGPL-3.0-only"></a>
  · <a href="README.zh-CN.md">中文</a>
</p>

Auspex watches every AI coding agent running on your Mac — Claude Code, Claude
Cowork, Codex, ChatGPT Work, Cursor, Grok Build, Grok Bot, AntiGravity — and
puts them on one live board: who is thinking, calling tools, delegating to
sub-agents, writing files, or waiting for permission. Sessions group by project
and by who spawned them, and a shared task board is exposed over MCP so the
agents themselves can say what they need.

> **Status: pre-alpha.** It runs, it tails the real stores, and it is used
> daily by its author. There is no tagged release, no notarized build, and no
> upgrade path between versions — the database schema still changes.

![The Auspex board: session cards grouped by project, with one session's trace beside them](docs/screenshots/board.png)

## Why

Running four or five agent harnesses at once means four or five terminal tabs,
none of which can tell you which agent is blocked on a permission prompt, which
one has been thinking for six minutes, which two are editing the same file, or
which one finished twenty minutes ago and is sitting there waiting to be read.
Each harness already writes a detailed session log to disk. Auspex reads all of
them and puts the answer in one window.

## Requirements

- macOS 26 (Tahoe) or newer, Apple silicon
- Xcode 26 / Swift 6.2 or newer

## Build and run

Auspex is a plain Swift package with no Xcode project.

```sh
swift build
swift test
./Scripts/build_app.sh release   # or: debug
open .build/Auspex.app
```

`AUSPEX_CODESIGN_IDENTITY` overrides ad-hoc signing with a Developer ID
Application identity and enables the hardened runtime.

`--demo` replays a fabricated board instead of tailing the real stores — a
dozen sessions across all eight harnesses, walking through prompts, tool calls,
a sub-agent, a permission prompt, an agent calling for a person, and a couple
of endings, on a loop. It runs entirely in memory: no harness store is opened, no
`~/.auspex/` is created, nothing is written to disk, and every path in it is
under `/Users/example`.

```sh
.build/Auspex.app/Contents/MacOS/Auspex --demo
```

`open -a` cannot pass arguments through, so run the binary directly — or set
`AUSPEX_DEMO=1`, which does the same thing. Every screenshot in this README is
rendered from that demo board by the app itself (`--render-board`,
`--render-scene`, `--render-crew`, `--render-trajectory`), so none of them
carries a real session, a real path, or a real name.

## Four ways to read one board

The picker in the header switches how the live sessions are drawn. It is a mode
rather than a destination: the selection, the grouping, the filters and the
trace beside them all survive a switch.

**Board** is the wall of cards — the only view that shows everything at once,
and the one that answers *what is this session doing* precisely: state, tool
name, target file, elapsed, tokens, what it was asked to do, what it last said.

**Scene** is the same board as a place. Every session is a person, every
project is a room, and *where somebody is* is the first thing a glance reads:
working sessions sit at their desks, a delegating session walks to the meeting
room with the sub-agents it spawned around a long table, idle ones rest on a
garden bench — the ones that finished something you have not looked at hold a
note — and an ended session walks out through the gate. The loudest channel is
light: a monitor's colour is its session's state and its rhythm is that
state's motion.

![The scene view: a room per project, agents at desks, their monitors lit by what they are doing](docs/screenshots/scene.png)

The canvas is a real `NSScrollView`, so two fingers pan and pinch at once the
way they do in Preview, with the same momentum and the same elastic edges;
⌘-scroll zooms, a two-finger double tap frames the room under the pointer, and
**Fit** (⌘0) frames everything. Clicking a desk fills the trace inspector, the
same selection clicking a card makes. Under Reduce Motion every rhythm
collapses to a static pose.

| State | The desk | The agent |
| --- | --- | --- |
| Thinking | screen breathes, blue | head bobs |
| Tool call | screen flickers, amber | hands alternate, fast |
| Writing a file | steady green, paper on the desk | hands alternate, half speed |
| Delegating | steady violet, the tether pulses | stands, holds a note out |
| Waiting for permission | strobes red | hand up, red `!` bubble |
| Idle · Stale · Ended | dim · dim · dark | slumped · `zzz` · gone |

Exactly one of those is allowed to shout, and it is the one that will never
resolve itself without a person.

| | |
| --- | --- |
| ![The crew view: one geometric avatar per session](docs/screenshots/crew.png) | ![The trajectory view: a waterfall of one session's turns beside its steps](docs/screenshots/trajectory.png) |
| **Crew** — one geometric avatar per session, its face and posture driven by what that session is doing. The same information as the scene at a tenth of the pixels. | **Trajectory** (⌘T) — one session opened out: a waterfall of its turns, every step it took, and an inspector on whichever one is selected. |

## The board says what agents ask for, not only what they do

Passive observation cannot answer *is this waiting for me*. Claude Code and
Cursor write no permission state to disk, and "I asked you a question and I am
waiting" is invisible in every harness's files. So Auspex runs an MCP server on
`~/.auspex/mcp.sock` and lets a session say so itself.

```jsonc
// ~/.claude.json — Settings → Harnesses writes this for you, fenced and reversible
{ "mcpServers": { "auspex": {
    "command": "/Applications/Auspex.app/Contents/MacOS/Auspex",
    "args": ["--mcp-stdio"]
} } }
```

```toml
# ~/.codex/config.toml
[mcp_servers.auspex]
command = "/Applications/Auspex.app/Contents/MacOS/Auspex"
args = ["--mcp-stdio"]
```

- **`auspex.notify(kind, message)`** — `needs_input`, `needs_review`,
  `blocked`, or `done`, with one sentence. It posts a macOS notification, moves
  the card into that bucket, and puts the agent's own words on it. A
  `needs_input` clears itself when the person next types into that session.
- **`auspex.report(focus, progress)`** — replaces Auspex's inference about what
  a session is doing with the session's own sentence.
- **`plans.*` / `tasks.*`** — the shared task board. A supervisor registers the
  decomposition with `plans.create`, files a `tasks.create` per worker and puts
  the id in each brief; each worker calls `tasks.claim(task_id, role, scope)`,
  `tasks.update` when it is blocked, and `tasks.complete` when it is done.
- **`sessions.self` / `sessions.list` / `sessions.tree` / `peers.status`** —
  read-only. An agent never has to know its own session id: Auspex resolves it
  from the process on the other end of the socket.

Sixteen tools in all. `auspex --mcp-stdio` is a thin bridge for clients that
speak stdio — it connects to the socket and pumps bytes, and exits 1 with one
line when Auspex is not running, so the protocol is enrichment and never a
dependency. The same registration installs **hooks** where a harness has them:
`auspex --hook <harness>` forwards a lifecycle payload over the same socket and
exits 0 within 200 ms whatever happens, because a hook is a synchronous child
of a working agent and must never be able to block or veto it.

![The Tasks page: plans, their tasks, and who claimed each one](docs/screenshots/tasks.png)

## Projects, trees, and the sessions you do not want to see

Two questions cut across the board that no harness records: **where** a session
is working, and **who** started it. Auspex answers both by looking at the
machine — git's own files for the first, the process table for the second.

![The projects sidebar beside a delegation tree on the board](docs/screenshots/projects.png)

- **The sidebar** lists every project on the board with a count of what is
  running in it. Three worktrees of one repository are one project with three
  checkouts, and an agent worktree is labelled with its task rather than its
  path. Clicking a project binds every surface to it — the wall, the tree, and
  the scene's camera.
- **Group by: Tree** turns the wall into the delegation forest. The trace
  header says *how* a parent link was established — a spawn the parent's own
  log recorded, an inherited environment variable, a process ancestry, or a
  person's own decision — because those are claims of very different strength.
- **Your own projects** claim folders, so six directories that are one piece of
  work read as one project whatever git says. **Ignore rules** hide a folder, a
  project, a prompt prefix, a harness, or a title substring. Ignored is not
  deleted: the header offers "N ignored", which puts them back dimmed.

## Harnesses

Eight harnesses are first-class — each gets a row, an accent, and its vendor's
own mark, and each is named in full everywhere it appears. Auspex never
abbreviates one.

| Harness | Vendor | Store Auspex reads |
| --- | --- | --- |
| Claude Code | Anthropic | `~/.claude/projects`, `~/.config/claude/projects` |
| Claude Cowork | Anthropic | `~/Library/Application Support/Claude/local-agent-mode-sessions` |
| Codex | OpenAI | `~/.codex/sessions` — every originator but ChatGPT Work |
| ChatGPT Work | OpenAI | the same tree, `originator` = ChatGPT Work |
| Cursor | Anysphere | `~/.cursor/chats` |
| Grok Build | xAI | `~/.grok/sessions` |
| Grok Bot | xAI | `~/Library/Application Support/Grok Bot/sand-client-persistence` |
| AntiGravity | Google | `~/.gemini/antigravity` |

Two pairs share a vendor mark, because they share a vendor: Claude Code with
Claude Cowork, Codex with ChatGPT Work. They are told apart by their accent and
by their full name, never by a modified logo. Gemini CLI is recognised but not
featured — it is deprecated, and Auspex has no live adapter for it.

The Harnesses page answers *why is this harness not on my board* and *what can
it reach*: whether its store exists on this Mac, how many of its sessions are
live, when it last did anything, and which MCP servers and hooks it has been
configured with. Every file behind that page is read and never written.

There is no screenshot of it here on purpose. That page is a report about *this
machine* — it lists the MCP servers you personally have configured — so a
picture of it is a picture of somebody's setup, and this repository is public.
Run it and look.

## Characters

The people in the scene are placeholders drawn in code until art exists for
them. Real characters are folders — a manifest and one frame strip per pose —
dropped into `~/.auspex/characters/` and picked up without a rebuild or a
relaunch, one pose at a time. [`docs/CHARACTERS.md`](docs/CHARACTERS.md) is the
specification; Settings → Characters is where they are chosen per harness.

## How data is collected

Auspex is a **read-only observer of local files**.

- Each supported harness already records its sessions somewhere under your home
  directory — JSONL transcripts, SQLite stores, conversation databases. Auspex
  tails those files and reconstructs a session state machine from them.
- **Every harness store is read-only.** Auspex never writes into another tool's
  directory, never deletes a session, and never modifies a transcript. SQLite
  stores are opened read-only, with a live WAL expected.
- **Everything Auspex writes goes under `~/.auspex/`** (mode 0700), routed
  through a single `AuspexPaths` type so the write scope is auditable by
  reading one file.
- **One deliberate exception.** Registering Auspex's MCP server and its hooks
  with a harness means writing that harness's config. It happens only when a
  person clicks it in Settings → Harnesses, only inside a region Auspex owns —
  a `>>> auspex >>>` fence, one JSON member named `auspex`, or the hook entries
  whose command runs the Auspex binary — only after a backup into
  `~/.auspex/backups/`, is re-parsed afterwards, and can be undone exactly.
- **No network.** No backend, no telemetry, no analytics, no update service.
  Nothing leaves your machine.

Auspex runs **without the macOS app sandbox**, because a sandboxed app cannot
read across the harness directories it exists to observe, and cannot bind
`~/.auspex/mcp.sock`. That is a deliberate trade-off, not an oversight, and it
is not a license for casual filesystem access — see [`AGENTS.md`](AGENTS.md).

## Privacy

Agent transcripts are some of the most sensitive text on a developer's machine:
they contain source code, infrastructure details, and whatever was pasted into
a prompt at 2am. Auspex treats them accordingly.

- Session content stays local, in a SQLite database under `~/.auspex/`.
- Process command lines are sanitized before they are logged or stored — some
  harnesses pass credentials in argv (`cursor-agent --api-key …`).
- Text an agent writes over MCP is stripped of control characters,
  bidirectional overrides and zero-width formatters before it reaches the store
  or the screen.
- Nothing is uploaded, and there is no opt-out telemetry to disable, because
  there is no telemetry.
- The repository is public: no real tokens, org IDs, account IDs, email
  addresses, or `/Users/<name>` paths belong in source, fixtures, or logs.

## Performance

Auspex runs all day beside the harnesses it watches, so its cost is a feature
rather than an afterthought. The budgets it is held to — and the measurements
behind them — are in [`AGENTS.md` § 4.1](AGENTS.md). In short: the frame the
window draws is derived off the main actor, views compare flat row values
rather than session snapshots, one clock drives every stopwatch, and nothing
animates in a view that is not on screen.

## Roadmap

| Milestone | Scope | State |
| --------- | ----- | ----- |
| **M0** | Repository skeleton and the shared `agent-session-kit` package: session model, event stream, source-adapter protocol. | done |
| **M1** | Live board for Claude Code and Codex, updating in real time, with the session trace and the menu bar. | done |
| **M2** | All eight harnesses, project and task grouping, the user's own projects and ignore rules, the scene and crew views. | done |
| **M3** | MCP task board over `~/.auspex/mcp.sock`, the `--mcp-stdio` bridge, opt-in harness hooks (`--hook`), and one-click registration with each harness. | done |
| **M4** | Retention scheduling, and control — acting on a session from Auspex rather than only watching it. | next |

## Architecture

[`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) describes how it fits together:
source adapters, the event stream and state reducer, the session registry, the
board frame assembler, the GRDB store, and the MCP surface.

## Contributing

See [`CONTRIBUTING.md`](CONTRIBUTING.md) for the branch and PR workflow and the
privacy rules, and [`AGENTS.md`](AGENTS.md) for the full operating manual —
including the conventions AI agents working in this repository must follow.

Security reports: [`SECURITY.md`](SECURITY.md).

## License

AGPL-3.0-only. Copyright © 2026 AstroQore. See [`LICENSE`](LICENSE).
