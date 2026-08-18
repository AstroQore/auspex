# CLAUDE.md

Auto-loaded by Claude Code at the start of every session in this repository.

The operating manual — repository map, the Core/App split, build and
verification flow, the `~/.auspex/` write rule, privacy rules, and the
worktree/branch/commit workflow — lives in [AGENTS.md](AGENTS.md).
`AGENTS.md` is self-contained and authoritative. Read it before touching
any code, resource, or script here.

Four things that cause silent failures or public-repo accidents:

1. **Every write goes through `AuspexPaths`, under `~/.auspex/`.** Never write
   into another harness's directory — their session stores are read-only to
   Auspex. (`AGENTS.md` § 6)
2. **Sanitize process argv before logging or storing it.** `cursor-agent`
   passes `--api-key` in argv. (`AGENTS.md` § 6)
3. **Do not re-add the app sandbox.** A sandboxed Auspex launches fine and
   shows an empty board, because it can read none of the stores it exists to
   observe. (`AGENTS.md` § 5)
4. **No personal paths, tokens, or real transcript content in commits.**
   Fixtures use `/Users/example/...`. (`AGENTS.md` § 7)

Work in `.agents/worktrees/<branch>`, never on the main tree.
