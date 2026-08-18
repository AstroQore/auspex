## Summary

-

## Validation

- [ ] `swift build`
- [ ] `swift test`
- [ ] `./Scripts/build_app.sh release`
- [ ] `codesign -dv --entitlements - .build/Auspex.app` (empty `<dict/>`, no `app-sandbox` key)

## Privacy Checklist

- [ ] No real tokens, API keys, cookies, JWTs, org IDs, account IDs, or email addresses.
- [ ] No personal `/Users/<name>` paths or machine hostnames — fixtures use `/Users/example/...`.
- [ ] Process argv is sanitized before it is logged or stored (`cursor-agent` passes `--api-key` in argv).
- [ ] New persistent state goes through `AuspexPaths` and lives under `~/.auspex/`.
- [ ] No writes into another harness's directory — their stores are read-only to Auspex.

## Area

- [ ] `AuspexCore` (paths, store, reducers, registry)
- [ ] `AuspexApp` (windows, menu bar, board UI)
- [ ] Harness source adapters
- [ ] MCP surface or hooks
- [ ] Build, packaging, CI, or docs
