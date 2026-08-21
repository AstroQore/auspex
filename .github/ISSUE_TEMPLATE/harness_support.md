---
name: Harness support request
about: A coding agent Auspex should be able to see
title: 'Harness support: '
labels: harness
assignees: ''
---

## The harness

- Name (in full — Auspex never abbreviates one):
- Vendor:
- Homepage / repository:
- How it is installed and launched (CLI name, app bundle id, VS Code extension):
- Is it macOS-native, or a terminal CLI, or both?

## Where it writes its sessions

This is the whole question. Auspex is a read-only observer: if a harness keeps
no session record on disk, there is nothing to tail and no adapter to write.

- Directory or file it writes a session to:
- Format (JSONL transcript, SQLite database, JSON per session, something else):
- Roughly how large does one session get?
- Does it rewrite the file, or only append?

<!-- If you can, paste the *shape* of one record with every value replaced —
     field names and types only, no prompt text, no paths, no ids. A schema is
     what an adapter needs; a transcript is what nobody should post. -->

```jsonc
{ "field": "<string>", "ts": "<iso8601>", "role": "<enum>" }
```

## What it records

- [ ] Which model is running
- [ ] Turn boundaries (a prompt, then a reply)
- [ ] Individual tool calls, with the tool name
- [ ] The file a tool touched
- [ ] Sub-agent / delegation spawns, with a link back to the parent
- [ ] Waiting-for-permission state
- [ ] Token or context usage
- [ ] The working directory of the session
- [ ] A resume command, or an id a resume command could take

## Does it have an MCP client or a hook system?

Auspex can be told what a session needs rather than inferring it — an MCP
server it registers (`auspex.notify`, the task board) and lifecycle hooks where
a harness has them. Both are opt-in and reversible.

- MCP client, and the config file it reads:
- Hooks, and the config file that registers them:
- Neither (Auspex would be limited to what the store records):

## Anything else

- Roughly how many people would you guess run this alongside others?
- Are you willing to test a branch against your own store?
