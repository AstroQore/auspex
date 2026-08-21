# Security Policy

Auspex reads local AI coding-agent session stores to show what each agent is
doing on your Mac. Those transcripts contain source code, infrastructure
details, and whatever was pasted into a prompt, so treat security reports and
diagnostics about it as sensitive by default.

## Reporting a vulnerability

Use **GitHub private vulnerability reporting** on this repository:
[Security → Report a vulnerability](https://github.com/AstroQore/auspex/security/advisories/new).
It reaches the maintainer privately and nobody else. If it is unavailable to
you, open a minimal public issue describing the affected area with no secrets
and no transcript content, and ask for a private channel.

Please include the Auspex version or commit, your macOS version, which
harnesses were involved, and the smallest reproduction you can manage —
ideally one that runs under `--demo`, which opens no harness store, writes
nothing to disk, and puts every path under `/Users/example`.

**Do not paste:**

- API keys, OAuth tokens, session cookies, JWTs, or Keychain values.
- Raw process command lines — some harnesses pass credentials in argv
  (`cursor-agent --api-key …`).
- Real email addresses, organization IDs, account IDs, or workspace
  identifiers.
- Unsanitized session logs or transcript content.
- `/Users/<your-name>` paths. Use `/Users/example/...`.

## What Auspex reads

One directory tree per supported harness, all of them under your home
directory, all of them opened **read-only**:

| Harness | Store |
| --- | --- |
| Claude Code | `~/.claude/projects`, `~/.config/claude/projects` |
| Claude Cowork | `~/Library/Application Support/Claude/local-agent-mode-sessions` |
| Codex · ChatGPT Work | `~/.codex/sessions`, `~/.codex/archived_sessions` |
| Cursor | `~/.cursor/chats`, `~/.cursor/projects` |
| Grok Build | `~/.grok/sessions`, `~/.grok/active_sessions.json` |
| Grok Bot | `~/Library/Application Support/Grok Bot/sand-client-persistence` |
| AntiGravity | `~/.gemini/antigravity`, `~/.gemini/antigravity-cli` |

Plus each harness's MCP and hook configuration, so the Harnesses page can say
what that harness is wired to; git's own metadata, to work out which project a
session belongs to; and the process table, to work out which session started
which.

## What Auspex never reads

- **Credential files.** Nothing named `*token*` or `*credential*`, no auth
  JSON, no Keychain item, no browser profile. Auspex authenticates to nothing
  and has no use for one.
- **Anything outside the trees above.** It is not a filesystem browser; being
  unsandboxed is not a licence to wander.
- **Any remote resource.** There is nothing to read from, because there is
  nothing to connect to.

A build that reads a credential file is a security bug, whether or not it does
anything with what it read.

## Supported versions

Auspex is **pre-alpha**. There are no released versions and no backports;
security fixes land on `main` and artifacts should be rebuilt from the fixed
source. Once releases exist, the update feed is EdDSA-signed and every archive
is verified against the key compiled into your copy before a byte is unpacked.

## Security expectations

- **Read-only toward other tools.** Auspex never writes into another harness's
  directory, never deletes a session, and never modifies a transcript. A bug
  that causes a write into one of those trees is a security bug. SQLite stores
  are opened read-only.
- **A single write scope.** Everything Auspex persists lives under
  `~/.auspex/` (mode 0700), routed through `AuspexPaths`, which refuses paths
  outside that base.
- **One deliberate exception, fenced.** Registering Auspex's MCP server and its
  hooks means writing that harness's config. It happens only when a person
  clicks it in Settings → Harnesses, only inside a region Auspex owns (a
  `>>> auspex >>>` fence, a JSON member named `auspex`, or hook entries whose
  command runs the Auspex binary), only after a backup into
  `~/.auspex/backups/`, and it can be undone exactly.
- **Hooks cannot block or veto an agent.** `auspex --hook <harness>` runs as a
  synchronous child of a working agent, forwards its payload over the socket,
  and exits 0 within 200 ms whatever happens.
- **No network.** Auspex has no backend, no telemetry, and no analytics. A
  build that opens an outbound connection — other than the update check, which
  is Sparkle asking this repository for an appcast — is a security bug.
- **Local IPC only.** The MCP surface listens on a Unix domain socket at
  `~/.auspex/mcp.sock`, reachable only by the local user, never on a TCP port.
- **Untrusted input is treated as untrusted.** Text an agent writes over MCP is
  stripped of control characters, bidirectional overrides and zero-width
  formatters before it reaches the store or the screen.
- **Sanitized logging.** Process command lines are stripped of
  credential-shaped arguments before they are logged, stored, or displayed.
- **Unsandboxed by design.** Auspex runs without the macOS app sandbox because
  a sandboxed app cannot read across the harness directories it observes and
  cannot bind its own socket (see `AGENTS.md` § 5). The least-access
  expectation still holds: read only the stores actually observed, write only
  under `~/.auspex/`, never log raw secrets.
