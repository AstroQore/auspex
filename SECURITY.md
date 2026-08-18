# Security Policy

Auspex reads local AI coding-agent session stores — Claude Code, Codex,
Cursor, Grok Build, Antigravity — to show what each agent is doing on your
Mac. Those transcripts contain source code, infrastructure details, and
whatever was pasted into a prompt, so please treat security reports and
diagnostics as sensitive by default.

## Reporting a Vulnerability

Use GitHub private vulnerability reporting if it is available on this
repository. If it is not, open a minimal public issue describing the affected
area without including any secrets or transcript content, then ask for a
private channel.

Do not paste:

- API keys, OAuth tokens, session cookies, JWTs, or Keychain values.
- Raw process command lines — some harnesses pass credentials in argv
  (`cursor-agent --api-key …`).
- Real email addresses, organization IDs, account IDs, or workspace
  identifiers.
- Unsanitized session logs or transcript content.
- `/Users/<your-name>` paths. Use `/Users/example/...`.

## Supported Versions

Auspex is **pre-alpha** software under active private development. There are
no released versions and no backports; security fixes land on `main` and
artifacts should be rebuilt from the fixed source.

## Security Expectations

- **Read-only toward other tools.** Auspex never writes into another harness's
  directory, never deletes a session, and never modifies a transcript. A bug
  that causes a write into one of those trees is a security bug.
- **A single write scope.** Everything Auspex persists lives under
  `~/.auspex/` (mode 0700), routed through `AuspexPaths`, which refuses paths
  outside that base.
- **No network.** Auspex has no backend, no telemetry, and no update service.
  A build that opens an outbound connection is a security bug.
- **Local IPC only.** The MCP surface listens on a Unix domain socket at
  `~/.auspex/mcp.sock`, reachable only by the local user, never on a TCP port.
- **Sanitized logging.** Process command lines are stripped of
  credential-shaped arguments before they are logged, stored, or displayed.
- **Unsandboxed by design.** Auspex runs without the macOS app sandbox because
  a sandboxed app cannot read across the harness directories it observes (see
  `AGENTS.md` § 5). The least-access expectation still holds: read only the
  stores actually observed, write only under `~/.auspex/`, never log raw
  secrets.
