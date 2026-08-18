# Contributing to Auspex

Thanks for helping improve Auspex. The project is a native macOS app that
observes local AI coding-agent sessions — Claude Code, Codex, Cursor, Grok
Build, Antigravity — and shows them on one live board. Changes should keep
that surface fast, quiet, private, and honest about what it does and does not
know.

Auspex is **pre-alpha**. Interfaces move without warning.

## Development Setup

Auspex is a Swift package with two targets:

- **`AuspexCore`** — parsers, source adapters, the session state reducer, the
  GRDB store, path and privacy helpers. Everything testable.
- **`AuspexApp`** — SwiftUI windows, the menu bar extra, and view code. Glue
  only.

If a piece of logic is worth a test, it belongs in Core.

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

## Branch and PR Workflow

Start from an up-to-date `main`, then create a topic branch with a
conventional prefix: `feat/`, `fix/`, `chore/`, `docs/`, `refactor/`, or
`test/`.

Commit subjects use the conventional form too (`feat: …`, `fix: …`),
imperative and under 72 characters, with the *why* in the body. Add a
`Co-Authored-By:` trailer when more than one person or agent shaped the
commit.

If several agents or checkouts may be active at once, use a separate git
worktree under `.agents/worktrees/<branch>` so each branch has its own tree.

Submit changes through a pull request against `main`. Never force-push `main`.

### Commit Identity

Use your own git identity — there is no shared maintainer alias. Auspex is
open source and the git log is public. To keep a personal mailbox out of that
log, configure GitHub's privacy email for this repo:

```sh
git config --local user.name  "Your GitHub Name"
git config --local user.email "<id>+<login>@users.noreply.github.com"
```

## Privacy Rules

These matter more here than in most projects: Auspex handles agent
transcripts, which contain source code and whatever was pasted into a prompt.

- **Never write outside `~/.auspex/`.** New persistent state goes through
  `AuspexPaths`, which refuses paths outside its base directory.
- **Treat every other harness's store as read-only.** No writes, no deletes,
  no transcript edits, no lock files. Open their SQLite databases read-only.
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

## Implementation Notes

- JSONL scanning must stay linear — session logs reach tens of megabytes and
  are tailed continuously. Use a moving cursor, never `removeSubrange` in a
  read loop.
- Database migrations are append-only. Never edit a shipped migration.
- Home directory resolution goes through `AuspexPaths.realHomeDirectory()`,
  not `NSHomeDirectory()` or `$HOME`.
- Where a harness log genuinely does not record a value, leave it `nil`. An
  empty field is better than an inferred one that is wrong.
