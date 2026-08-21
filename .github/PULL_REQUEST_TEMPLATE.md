## Summary

-

<!-- What changed and *why*. If it changes what the board shows, say what it
     showed before. -->

## Validation

- [ ] `swift build`
- [ ] `swift test`
- [ ] `./Scripts/build_app.sh release`
- [ ] `codesign -dv --entitlements - .build/Auspex.app` (empty `<dict/>`, no `app-sandbox` key)

## Privacy Checklist

- [ ] Diff grepped clean (`AGENTS.md` § 7):
      `git diff | grep -nE '/Users/|sk-|ghp_|xox[baprs]-|eyJ|Bearer |api[-_]?key' | grep -v '/Users/example'`
- [ ] No real tokens, API keys, cookies, JWTs, org IDs, account IDs, or email addresses.
- [ ] No personal `/Users/<name>` paths or machine hostnames — fixtures use `/Users/example/...`.
- [ ] No captured transcript content in fixtures — hand-written or synthesized.
- [ ] Process argv is sanitized before it is logged or stored (`cursor-agent` passes `--api-key` in argv).
- [ ] New persistent state goes through `AuspexPaths` and lives under `~/.auspex/`.
- [ ] No writes into another harness's directory — their stores are read-only to Auspex.
- [ ] No new network calls.

## Performance

Auspex is left open all day beside the agents it watches, so cost is part of
the change (`AGENTS.md` § 4.1). Tick what applies, or say why it does not.

- [ ] Nothing new runs on the main actor — pipeline work stays in `Task.detached`.
- [ ] Views compare flat row values, not session snapshots.
- [ ] Nothing animates in a view that is not on screen.
- [ ] Idle CPU checked against the budget, or unchanged by construction.

## Conventions

- [ ] Branch has a conventional prefix (`feat/`, `fix/`, `chore/`, `docs/`, `refactor/`, `test/`).
- [ ] Commit subjects are conventional, imperative, ≤ 72 characters, with the *why* in the body.
- [ ] `Co-Authored-By:` trailers name the real participants.
- [ ] Worked in a worktree under `.agents/worktrees/<branch>`, not on the main tree.
- [ ] Logic that is worth a test lives in `AuspexCore`, not `AuspexApp`.

## Area

- [ ] `AuspexCore` (paths, store, reducers, registry)
- [ ] `AuspexApp` (windows, menu bar, board UI)
- [ ] Harness source adapters
- [ ] MCP surface or hooks
- [ ] Build, packaging, CI, or docs
