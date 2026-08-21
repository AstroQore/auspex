# Contributing to Auspex

Thanks for helping improve Auspex. It is a native macOS app that observes the
AI coding-agent sessions already running on your Mac — Claude Code, Claude
Cowork, Codex, ChatGPT Work, Cursor, Grok Build, Grok Bot, AntiGravity — and
puts them on one live board. Changes should keep that surface fast, quiet,
private, and honest about what it does and does not know.

Auspex is **pre-alpha**. Interfaces move without warning.

Two documents sit above this one. [`AGENTS.md`](AGENTS.md) is the full
operating manual and is authoritative; everything below is the short version
with the section numbers to look up.
[`CODE_OF_CONDUCT.md`](CODE_OF_CONDUCT.md) applies to every interaction here.

## Development setup

Auspex is a plain Swift package with no Xcode project, and two targets:

- **`AuspexCore`** — parsers, source adapters, the session state reducer, the
  GRDB store, path and privacy helpers. Everything testable.
- **`AuspexApp`** — SwiftUI windows, the menu bar extra, and view code. Glue
  only.

If a piece of logic is worth a test, it belongs in Core. (`AGENTS.md` § 2)

Before opening a pull request, run all four:

```sh
swift build
swift test
./Scripts/build_app.sh release
codesign -dv --entitlements - .build/Auspex.app
```

Auspex runs **unsandboxed** so it can read the harness session stores it
observes. The `codesign` output must be an empty `<dict/>` plist with no
`com.apple.security.app-sandbox` key — `build_app.sh` asserts this too. See
[`AGENTS.md`](AGENTS.md) § 5 for the reasoning.

To work on Auspex and `agent-session-kit` side by side, do not edit the pin in
`Package.swift` — put the kit in edit mode instead (`AGENTS.md` § 3.1):

```sh
swift package edit agent-session-kit --path ../agent-session-kit
```

## Looking at the change you made

`--demo` replays a fabricated board instead of tailing the real stores: a
dozen sessions across all eight harnesses, walking through prompts, tool
calls, a sub-agent, a permission prompt, an agent calling for a person, and a
couple of endings, on a loop. It runs entirely in memory — no harness store is
opened, no `~/.auspex/` is created, nothing is written to disk, and every path
in it is under `/Users/example`.

```sh
.build/Auspex.app/Contents/MacOS/Auspex --demo
```

That last property is what makes it the right thing to screenshot. A picture
of your real board is a picture of your machine, and this repository is
public. Every screenshot in the README is rendered from the demo board by the
app itself (`--render-board`, `--render-scene`, `--render-crew`,
`--render-trajectory`).

`open -a` cannot pass arguments through, so run the binary directly, or set
`AUSPEX_DEMO=1`. Kill the instance when you are done — do not leave one
running.

## Tests

`swift test` runs both suites (swift-testing). What is worth writing:

- **Adapters** get fixtures. Hand-written or synthesized, never captured from
  a real session, and rooted under `/Users/example/...`.
- **Reducers** get the transition you changed, plus the one next to it.
- **Migrations are append-only.** Never edit a shipped migration; add another.
- **Where a harness genuinely does not record a value, assert `nil`.** An
  empty field is better than an inferred one that is wrong, and a test that
  pins that is what stops the next person from inferring it.

## The performance budget

This is first priority rather than a nice-to-have, because Auspex is left open
all day beside the agents it watches. The full table is in
[`AGENTS.md`](AGENTS.md) § 4.1; the shape of it:

| Situation | Budget |
| --- | --- |
| Live, window visible, idle, ≥ 2 min after launch | ≤ 3 % process CPU |
| Live, during a harness burst | ≤ 10 % CPU, board updates within 0.5 s |
| Aviary or Flock on screen, 60 animating characters | ≤ 15 % CPU; offscreen views cost 0 |
| First launch, cold store | discovery under 10 s, never blocking the UI |

The rules that fall out of it: one clock per view, only visible and active
cards animate, nothing animates in a view that is not on screen, views compare
flat `Equatable` row values rather than session snapshots, and discovery
routes a changed path to the one adapter that owns it instead of sweeping.

Measure rather than guess — `top -l 4 -s 5 -pid <pid>` and `sample <pid> 3`
after a short background launch — and put the number in the pull request.

## Privacy rules

These matter more here than in most projects: Auspex handles agent
transcripts, which contain source code and whatever was pasted into a prompt
at 2am. (`AGENTS.md` § 6, § 7)

- **Never write outside `~/.auspex/`.** New persistent state goes through
  `AuspexPaths`, which refuses paths outside its base directory.
- **Treat every other harness's store as read-only.** No writes, no deletes,
  no transcript edits, no lock files. Open their SQLite databases read-only.
  The one exception is registering the MCP server and the hooks, which happens
  only when a person clicks it, inside a fenced region, after a backup.
- **Never read a credential file.** Not anything named `*token*` or
  `*credential*`, not a harness's auth JSON. Auspex has no use for one.
- **Sanitize process argv before logging or storing it.** Some harnesses pass
  credentials on the command line (`cursor-agent --api-key …`).
- **No real secrets or personal paths in commits** — no API keys, OAuth
  tokens, cookies, JWTs, org IDs, account IDs, or email addresses, and no
  `/Users/<name>` paths. Fixtures use `/Users/example/...` and synthetic
  tokens.
- **No captured transcript content in fixtures.** Hand-write or synthesize
  them.
- **No network calls.** Auspex has no backend and no telemetry; keep it that
  way.

Grep your own diff before you finish (`AGENTS.md` § 7):

```sh
git diff | grep -nE '/Users/|sk-|ghp_|xox[baprs]-|eyJ|Bearer |api[-_]?key' \
         | grep -v '/Users/example'
```

## Branch and PR workflow

Start from an up-to-date `main`, then create a topic branch with a
conventional prefix: `feat/`, `fix/`, `chore/`, `docs/`, `refactor/`, or
`test/`.

**Work in a worktree, not in the main tree.** Several people and several
agents may be working here at once, and a shared checkout means one build sees
another's half-written files. `.agents/worktrees/` is gitignored.

```sh
git worktree add .agents/worktrees/feat-live-board -b feat/live-board main
```

Commit subjects use the conventional form too (`feat: …`, `fix: …`),
imperative and under 72 characters, with the *why* in the body. Add a
`Co-Authored-By:` trailer naming the real participants when more than one
person or agent shaped the commit. Keep commits small; each one should build
and test green on its own.

Submit changes through a pull request against `main`. Never force-push `main`.

### Commit identity

Use your own git identity — there is no shared maintainer alias. Auspex is
open source and the git log is public. To keep a personal mailbox out of that
log, configure GitHub's privacy email for this repo:

```sh
git config --local user.name  "Your GitHub Name"
git config --local user.email "<id>+<login>@users.noreply.github.com"
```

## If you are an AI agent

You are welcome here — most of this codebase was written by one — and the
rules are the same, with three additions that come up every time.

- **Read [`AGENTS.md`](AGENTS.md) first.** It is self-contained and
  authoritative, and it is shorter than the code you were about to change.
- **Work from a written brief in your own worktree**, and report what you
  actually verified: the commands, their output, and what you did not do. A
  worker that says it is blocked is worth more than one that retries.
- **Register with the board if it is running.** Auspex serves an MCP server on
  `~/.auspex/mcp.sock`: claim your task, say when you are blocked, call
  `auspex.notify` instead of going quiet. If Auspex is not running the bridge
  exits 1 and nothing else happens — the protocol is enrichment, never a
  dependency.

## Implementation notes

- JSONL scanning must stay linear — session logs reach tens of megabytes and
  are tailed continuously. Use a moving cursor, never `removeSubrange` in a
  read loop.
- Database migrations are append-only. Never edit a shipped migration.
- Home directory resolution goes through `AuspexPaths.realHomeDirectory()`,
  not `NSHomeDirectory()` or `$HOME`.
- Pipeline work stays off the main actor (`Task.detached`); UI models are
  `@MainActor @Observable`. Both targets compile in Swift 6 language mode.
- Where a harness log genuinely does not record a value, leave it `nil`. An
  empty field is better than an inferred one that is wrong.
- Harnesses are named in full, everywhere, and wear their vendor's own mark.
  Never an abbreviation, never a monogram.
