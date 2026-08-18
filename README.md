# Auspex

<p align="center">
  <strong>One live board for every AI coding agent running on your Mac.</strong>
</p>

<p align="center">
  <img src="https://img.shields.io/badge/status-pre--alpha%2C%20private%20development-orange" alt="Status: pre-alpha, private development">
  <img src="https://img.shields.io/badge/macOS-26%2B-000000?logo=apple" alt="macOS 26+">
  <img src="https://img.shields.io/badge/Swift-6.2-F05138?logo=swift&logoColor=white" alt="Swift 6.2">
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-AGPL--3.0--only-blue" alt="AGPL-3.0-only"></a>
  · <a href="README.zh-CN.md">中文</a>
</p>

Auspex watches every AI coding agent running on your Mac — Claude Code, Codex,
Cursor, Grok Build, Antigravity — in one live board: who is thinking, calling
tools, delegating to sub-agents, writing files, or waiting for permission.
Group sessions by project and task; expose a task board over MCP.

> **Status: pre-alpha, private development.** The repository is a skeleton.
> Nothing observes anything yet — see [Roadmap](#roadmap) for what lands when.

## Why

Running four or five agent harnesses at once means four or five terminal tabs,
none of which can tell you which agent is blocked on a permission prompt, which
one has been thinking for six minutes, or which two are editing the same file.
Each harness already writes a detailed session log to disk. Auspex reads all of
them and puts the answer in one window.

## Requirements

- macOS 26 (Tahoe) or newer, Apple silicon
- Xcode 26 / Swift 6.2 or newer

## Build

Auspex is a plain Swift package with no Xcode project.

```sh
swift build
swift test
```

To produce a runnable, ad-hoc-signed application bundle:

```sh
./Scripts/build_app.sh release   # or: debug
open .build/Auspex.app
```

`AUSPEX_CODESIGN_IDENTITY` overrides ad-hoc signing with a Developer ID
Application identity and enables the hardened runtime.

## How Data Is Collected

Auspex is a **read-only observer of local files**.

- Each supported harness already records its sessions somewhere under your home
  directory — JSONL transcripts, SQLite stores, conversation databases. Auspex
  tails those files and reconstructs a session state machine from them.
- **Every harness store is treated as read-only.** Auspex never writes into
  another tool's directory, never deletes a session, and never modifies a
  transcript.
- **Everything Auspex writes goes under `~/.auspex/`** (mode 0700), routed
  through a single `AuspexPaths` type so the write scope is auditable by
  reading one file.
- **No network.** Auspex has no backend, no telemetry, no analytics, and no
  update service. Nothing leaves your machine.
- Optional harness hooks (M3) are opt-in and local: they notify the running app
  over a Unix socket at `~/.auspex/mcp.sock` so state updates land instantly
  instead of on the next file poll.

Auspex runs **without the macOS app sandbox**, because a sandboxed app cannot
read across the harness directories it exists to observe. That is a deliberate
trade-off, not an oversight, and it is not a license for casual filesystem
access — see [`AGENTS.md`](AGENTS.md).

## Privacy

Agent transcripts are some of the most sensitive text on a developer's machine:
they contain source code, infrastructure details, and whatever was pasted into
a prompt at 2am. Auspex treats them accordingly.

- Session content stays local, in a SQLite database under `~/.auspex/`.
- Process command lines are sanitized before they are logged or stored — some
  harnesses pass credentials in argv (`cursor-agent --api-key …`).
- Nothing is uploaded, and there is no opt-out telemetry to disable, because
  there is no telemetry.
- The repository is public: no real tokens, org IDs, account IDs, email
  addresses, or `/Users/<name>` paths belong in source, fixtures, or logs.

## Roadmap

| Milestone | Scope |
| --------- | ----- |
| **M0** | Repository skeleton and the shared `agent-session-kit` package: session model, event stream, source-adapter protocol. |
| **M1** | Live board for Claude Code and Codex — running / thinking / tool call / waiting-for-permission / idle, updating in real time. |
| **M2** | All five harnesses, plus project and task grouping and the pixel scene view. |
| **M3** | MCP task board over `~/.auspex/mcp.sock` (with an `--mcp-stdio` bridge) and opt-in harness hooks for instant updates. |
| **M4** | Control — act on a session from Auspex, not just watch it. |

## Architecture

[`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) describes the target design:
source adapters, the event stream and state reducer, the session registry, the
GRDB store, and the MCP surface. Most of it is not implemented yet.

## Contributing

See [`CONTRIBUTING.md`](CONTRIBUTING.md) for the branch and PR workflow and the
privacy rules, and [`AGENTS.md`](AGENTS.md) for the full operating manual —
including the conventions AI agents working in this repository must follow.

Security reports: [`SECURITY.md`](SECURITY.md).

## License

AGPL-3.0-only. Copyright © 2026 AstroQore. See [`LICENSE`](LICENSE).
