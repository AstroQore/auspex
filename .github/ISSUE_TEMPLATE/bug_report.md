---
name: Bug report
about: Something in Auspex behaves incorrectly
title: ''
labels: bug
assignees: ''
---

## What happened

<!-- What you saw. If a session was missing, mis-attributed, or stuck in the
     wrong state, say which harness it came from and what that session was
     actually doing at the time. -->

## What you expected

## Steps to reproduce

1.
2.
3.

## Does it reproduce in `--demo`?

`--demo` replays a fabricated board with no harness store opened and every path
under `/Users/example`, so a repro there is one anybody can look at and one you
can paste a screenshot of safely.

```sh
/Applications/Auspex.app/Contents/MacOS/Auspex --demo
```

- [ ] Reproduces in `--demo` — screenshot attached below.
- [ ] Only reproduces against my real stores — described above without pasting
      transcript content.
- [ ] Not applicable (build, packaging, or startup failure).

## Environment

- Auspex version / commit (**Auspex → About**, or `git rev-parse --short HEAD`):
- macOS version (`sw_vers -productVersion`):
- Swift version (`swift --version`):
- Apple silicon or Intel:
- Installed from a Release, or built from source:
- Harnesses involved (Claude Code, Claude Cowork, Codex, ChatGPT Work, Cursor,
  Grok Build, Grok Bot, AntiGravity):
- Harness CLI versions, if known:
- Was Auspex's MCP server registered with that harness (Settings → Harnesses)?

## Logs and diagnostics

<!-- Auspex writes its own logs under ~/.auspex/logs/.

     Please redact before pasting. Do NOT include API keys, OAuth tokens,
     session cookies, organization or account IDs, email addresses,
     `/Users/<your-name>` paths, or raw prompt/transcript content. Replace
     home paths with `/Users/example/...`.

     Note that some harnesses pass credentials on the command line (for
     example `cursor-agent --api-key ...`), so process listings need the same
     care as log files. -->

```text

```
