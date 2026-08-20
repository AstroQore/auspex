# AGENTS.md

Operating manual for AI agents (and humans) working in this repository.
Authoritative; `CLAUDE.md` just points here.

## 1. What Auspex Is

A native macOS app that observes every AI coding agent running on the user's
Mac — Claude Code, Codex, Cursor, Grok Build, Antigravity — and shows them on
one live board: who is thinking, calling tools, delegating to sub-agents,
writing files, or waiting for permission. Sessions group by project and task,
and the task board is exposed over MCP.

Pure Swift package, ad-hoc-signed, **unsandboxed**, distributed as source.
No Xcode workspace, no installer, no notarized release, no server, no network.

**Status: pre-alpha.** The repository is a skeleton; most of
`docs/ARCHITECTURE.md` is target design, not shipped code.

## 2. Repository Map

```
Package.swift              SwiftPM manifest — tools 6.2, macOS 26, Swift 6 language mode
Sources/
  AuspexCore/              Testable library. All logic lives here.
    AuspexPaths.swift      Single source of truth for the ~/.auspex/ tree
    AuspexVersion.swift    Build identity; mirrors Resources/Info.plist
    Store/AuspexStore.swift  GRDB store + DatabaseMigrator
  AuspexApp/               SwiftUI executable. UI glue only.
    main.swift             Subcommand dispatch, then AuspexApp.main()
    AuspexApp.swift        App scene: WindowGroup + MenuBarExtra
    AppEnvironment.swift   Observable dependency holder (placeholder)
    RootView.swift         NavigationSplitView shell
Tests/AuspexCoreTests/     swift-testing suites
Resources/
  Info.plist               Bundle metadata; com.astroqore.auspex
  Auspex.entitlements      Deliberately empty — see § 5
Scripts/build_app.sh       swift build → .app bundle → codesign → sandbox assert
docs/ARCHITECTURE.md       Target architecture
```

**The target split is load-bearing.** `AuspexCore` holds every parser, reducer,
adapter, and storage type, and is testable without a running app.
`AuspexApp` holds windows, scenes, and view code. If a piece of logic is worth
a test, it belongs in Core.

## 3. Toolchain

macOS 26 (Tahoe) or newer on Apple silicon, Xcode 26 / Swift 6.2 or newer.
Both targets compile in Swift 6 language mode; keep it that way.

## 4. Verification Before Completion

Before claiming a change works, run all four:

```sh
swift build
swift test
./Scripts/build_app.sh release
codesign -dv --entitlements - .build/Auspex.app
```

The `codesign` output must be an empty `<dict/>` plist with no
`com.apple.security.app-sandbox` key. `build_app.sh` also asserts this and
fails the build if the key appears.

### 4.1 Performance budget (first priority, not a nice-to-have)

Auspex runs all day next to the harnesses it watches. Rich motion is wanted;
paying for it with CPU is not. Every change that touches the pipeline, the
board, the scene or the crew must hold these numbers on this machine's
real stores (~600 sessions) and say so in the PR/commit/report:

| Situation | Budget |
| --- | --- |
| Live, window visible, no user input, ≥ 2 min after launch | ≤ 3 % process CPU, main thread idle |
| Live, during a harness burst (a transcript growing every second) | ≤ 10 % process CPU, board updates within 0.5 s |
| Scene or Crew view on screen, 60 animating characters | ≤ 15 % process CPU; offscreen views cost 0 (clocks stop when hidden) |
| First launch with a cold store | discovery finishes in < 10 s, never blocks the UI |

Rules that follow from it:

- One clock per view (`TimelineView` at the container), ≤ 30 fps unless a
  motion needs more; only *visible, active* cards animate; nothing animates
  in a view that is not on screen.
- Views never hold or compare `SessionSnapshot`s. The model derives flat,
  `Equatable` row values once per coalesced frame (`BoardRowBuilder`); SwiftUI
  compares those.
- Discovery is incremental: route a changed path to the one adapter that owns
  it; full sweeps are a slow safety net, not the mechanism.
- Measure, don't guess: `top -l 4 -s 5 -pid <pid>` and `sample <pid> 3`
  after a ≤ 2-minute background live launch, then kill it. Agents working on
  this repo launch the app only briefly and in the background, and never
  leave an instance running.

## 5. Why Auspex Is Unsandboxed

Auspex's entire job is to read session stores that other tools scatter across
the home directory (`~/.claude/projects`, `~/.codex/sessions`,
`~/.cursor/chats`, `~/.grok/sessions`, AntiGravity's conversation databases).
A sandboxed app cannot read across those trees, and it cannot bind
`~/.auspex/mcp.sock`. So `Resources/Auspex.entitlements` is an empty dict on
purpose.

**The failure mode is silent.** A sandboxed Auspex launches fine and shows an
empty board. Do not re-add the sandbox without coordinating the observation
features first.

**Unsandboxed is not a license for casual filesystem access.** Treat the user's
disk with the discipline a sandboxed app would: read only the harness stores
Auspex actually observes, and write nothing outside `~/.auspex/`.

## 6. Code Conventions

- **Swift package, two targets.** Heavy logic in `AuspexCore`, UI glue in
  `AuspexApp`. Logic worth testing goes in Core.
- **All writes go through `AuspexPaths`.** Every file Auspex owns lives under
  `~/.auspex/` (mode 0700) and its URL is vended by `AuspexPaths`. Do not
  build a path by hand, and do not add a second write root. `AuspexPaths`
  refuses to create a directory outside its base — keep it that way, because
  it is what makes the write scope a property of the code rather than a
  convention.
- **Never write into another harness's directory.** Their stores are read-only
  to Auspex: no writes, no deletes, no transcript edits, no lock files, no
  "harmless" touch. If a harness store must be opened with SQLite, open it
  read-only and expect a live WAL.
- **One exception, and it is the whole exception: `HarnessInstaller`.**
  Registering Auspex's MCP server with a harness, installing the short
  task-protocol note, and registering the hooks mean writing `~/.claude.json`,
  `~/.claude/settings.json`, `~/.codex/config.toml`, `~/.cursor/hooks.json`,
  `~/.claude/CLAUDE.md` and their siblings. That is allowed only through
  `Sources/AuspexCore/Config/HarnessInstaller.swift` and the
  `HookInstaller`s it delegates to, and only under all five of these
  conditions — if a change would break any of them, it does not belong there:
  1. **A person clicked.** Never on launch, never on a timer, never while a
     page is merely being looked at.
  2. **Inside a region Auspex owns.** A `# >>> auspex >>>` block, one JSON
     member named `auspex`, or — in a hook table, which is a list other tools
     append to and where JSON gives no comment to fence with — the entries
     whose command runs the Auspex binary with `--hook`. Bytes somebody else
     wrote are never re-serialised; that is why `ConfigTextEditors` edits text
     rather than round-tripping a parser.
  3. **Backed up first**, into `~/.auspex/backups/`. A `.bak` beside the
     original would itself be a write into a harness's directory.
  4. **Verified after.** Re-read, re-parsed, and restored from the backup if
     the file no longer parses.
  5. **Exactly reversible.** Uninstall removes the fence, the member or our
     hook entries and nothing else. Where a slot had to be *displaced* rather
     than shared — Codex's single `notify` — the fence records the original
     line verbatim so uninstall can put it back byte for byte.

  The observation layer keeps the absolute rule. It has no reason to write,
  and a second write path is how that stops being true.
- **Home directory resolution** goes through `AuspexPaths.realHomeDirectory()`.
  New hits on `NSHomeDirectory()`, `FileManager.default.homeDirectoryForCurrentUser`,
  `URL.homeDirectory`, or `getenv("HOME")` in product code are bugs — a stray
  `HOME` in a spawned agent's environment would otherwise redirect us.
- **Sanitize process argv before logging or storing it.** Some harnesses pass
  credentials on the command line — `cursor-agent` takes `--api-key` in argv,
  so anything derived from `ps`, `sysctl KERN_PROCARGS2`, or a process
  snapshot is a potential secret leak. Strip the value of every
  credential-shaped flag before that string reaches a log line, the database,
  or the UI.
- **Transcripts are sensitive.** Session content is source code and whatever
  was pasted into a prompt. It stays in the local database; it is never logged
  at whole-message granularity and never leaves the machine.
- **JSONL parsing must be O(n).** Session logs grow to tens of megabytes and
  are tailed continuously. Use a moving cursor; never `removeSubrange` in a
  read loop.
- **Migrations are append-only.** Never edit a `registerMigration` block that
  has shipped; add the next one.

## 7. Privacy & Source-Content Rules

The repository is public and AGPL-3.0-only — every commit, file, and diff is
visible to the world. What is **not** allowed in any commit:

- Real API keys, OAuth tokens, session cookies, JWTs, organization UUIDs,
  account IDs, or personal email addresses — in source, tests, fixtures, or
  log strings.
- `/Users/<name>` paths or machine hostnames anywhere, including examples and
  test output. **Fixtures use `/Users/example/...`** and synthetic tokens.
- Real transcript content captured from an actual session. Fixtures are
  hand-written or synthesized.
- Logging raw credentials, raw argv, or unsanitized prompt text.
- Re-enabling the app sandbox without coordinating the observation features
  (§ 5).

Before finishing any change, grep your diff:

```sh
git diff | grep -nE '/Users/|sk-|ghp_|xox[baprs]-|eyJ|Bearer |api[-_]?key' \
         | grep -v '/Users/example'
```

(BSD `grep` has no PCRE lookahead, hence the second stage rather than a
`(?!example)` in the pattern.)

This is a source-content rule. It applies to what you commit, not who you
commit as.

## 8. Git Workflow

- **Agents work in `.agents/worktrees/<branch>`, never on the main tree.**
  Multiple agents may be working here at once; a shared checkout means one
  agent's build sees another's half-written files. `.agents/worktrees/` is
  gitignored.

  ```sh
  git worktree add .agents/worktrees/feat-live-board -b feat/live-board main
  ```

- **Branch prefixes:** `feat/`, `fix/`, `chore/`, `docs/`, `refactor/`,
  `test/`. Conventional prefixes go on branch names.
- **Commit subjects** use the conventional form (`feat:`, `fix:`, `chore:`,
  `build:`, `docs:`, `refactor:`, `test:`), imperative, ≤ 72 characters.
  Explain *why* in the body, not just what.
- **Every commit ends with a `Co-Authored-By:` trailer** naming the real
  participants when more than one human or agent shaped it, e.g.
  `Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>`.
- **Commit identity.** Use your own git identity, or GitHub's privacy email
  (`<id>+<login>@users.noreply.github.com`) if you would rather keep a personal
  mailbox out of the public log.
- Never force-push `main`.

## 9. What Not To Change Without Explicit Instruction

- The empty `Resources/Auspex.entitlements` (§ 5).
- The `~/.auspex/` write scope and the `AuspexPaths` containment check.
- The bundle identifier `com.astroqore.auspex`.
- The read-only stance toward every other harness's directory.
