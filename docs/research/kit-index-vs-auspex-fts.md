# Should the search field move to agent-session-kit's session index?

**Recommendation: no. Keep Auspex's own FTS, and copy three of the kit
index's ideas into it — about 65 lines, no second database.**

Assessed against kit 0.4.2 (`SessionIndexStore`, `SessionIndexService`,
FTS schema v5) and Auspex at `cfd35fc`.

## The two designs

| | kit `SessionIndexService` | Auspex `SessionRepository.search` |
| --- | --- | --- |
| How text arrives | **pull**: walks every adapter's `discoverSessionFiles`, then `extractMetadata` + `parseTranscript` on any file whose mtime/size moved | **push**: the `textBody` events the tailer is already producing, batched into the persist transaction |
| Where it lives | its own SQLite file, raw `sqlite3`, caller-named — the kit has no default location | `messages` + `messages_fts` inside `~/.auspex/auspex.db`, GRDB |
| Scoping | title, user, assistant, system, tool; project-path include/exclude; hide/list/resolve `providerVariant` | harness list only (and the app does not even pass that) |
| Snippets | `snippet(…, '<b>', '</b>', …)` | `snippet(…, '‹', '›', …)` — text, never markup |
| Caps | 2 000 chars per message, 512 KiB per session, 4 MiB / 128 sessions per commit, 32 MiB page cache | none |
| Retention | none. Rows live until the file vanishes; the only switch is a global "index bodies" flag | `RetentionPolicy.indexesText(for:)` refuses an excluded harness *before* it is written; `RetentionJob` prunes by `ftsMaxAge` and by exclusion |
| Coverage | every session file on the machine, including ones Auspex never watched | what Auspex's pipeline actually observed |

Nothing in Auspex references the kit index today.

## Why not swap

**1. The ingest model is backwards for a live board.** Auspex already reads
every one of those bytes once, as a moving cursor over the tail, because
`AGENTS.md` § 6 requires JSONL parsing to be O(n). `refreshIndex` re-reads the
*whole file* through `parseTranscript` whenever mtime or size changed — which
for a session that is being written is every pass — and walks all seven
adapters' trees to find out. Adopting it means a second full-file reader of
the same transcripts, on a schedule of its own, against a resting budget of
3 % CPU (§ 4.1). The kit's own bounded-rebuild work in 0.4.2 is about keeping
*that* pass's heap in hand; it does not make the pass unnecessary.

**2. It would silently break a user setting.** Excluding a harness from the
search index is Auspex's, and it works because the exclusion is applied at the
one place text enters — `SessionRegistry.indexText`. The kit index has no
equivalent: it indexes whatever its adapters discover. A person who excluded
Grok Bot would keep finding Grok Bot transcripts, and the store growing them.
`ftsMaxAge` has no equivalent either.

**3. Two databases that cannot be joined.** `messages` is in the same GRDB
database as `sessions` and `events`, which is what lets `BriefBackfill` rebuild
a session's assignment from indexed prompts in the same transaction that
updates the session row. A kit index is a separate file opened by a separate
SQLite handle; that query becomes a cross-process fan-in, and every future
"search within this project" would have to be answered by shipping a candidate
set between the two.

**4. "Shared with vibe-bar" means shared code, not a shared index.** The kit
deliberately has no default database location, and Auspex may not write outside
`~/.auspex/` (§ 6). Two apps would still keep two files; what is shared either
way is the parsing, which Auspex already gets from the same package.

Identity is *not* an obstacle, for the record: `SessionSummary` carries both
`harness` and `sessionID`, so a `SessionKey` is reconstructible from a hit.

## What the kit index does that Auspex's cannot

One thing, and it is real: it searches sessions Auspex never tailed — history
older than the store, or written while Auspex was not running. Auspex's index
only holds what its pipeline saw.

That is the trigger to revisit this. If "find that thing I did in March" becomes
a requirement, the answer is to run the kit index **alongside** the live one as
an explicit, user-started archive search — not to replace the live one with it.

## What to copy instead (~65 lines, no new database)

The good ideas in the kit index are all expressible against the table Auspex
already has, because `messages` already stores the role and lives next to
`sessions`:

| Borrow | Where | Est. |
| --- | --- | --- |
| Role scoping (`user` / `assistant` / `tool` / `system`) | a `roles:` parameter on `SessionRepository.search`, filtering `m.role`; a scope control beside the field | ~15 |
| Project include/exclude | join `messages` to `sessions` on `session_key` — free, same database, and something the kit index cannot do at all | ~20 |
| Title matching as a second pass | `sessions.title` / `session_id` `LIKE`, merged ahead of body hits | ~20 |
| A per-session body cap | `RetentionPolicy`, mirroring the kit's 512 KiB. Auspex has **no** cap today: `indexMessage` stores whatever it is handed | ~10 |

Auspex's snippet delimiters should stay guillemets. The kit's `<b>` markers
are for a caller that renders HTML; a SwiftUI `Text` would show the tags.

## Cost of the swap, if it were taken anyway

| | Lines |
| --- | --- |
| Delete: schema + triggers, index writes, `search`, registry indexing, UI wiring | ≈ 455 |
| Rewrite against a store it cannot join: `BriefBackfill` | ≈ 53 |
| Tests to rewrite | ≈ 120 |
| New: second-database lifecycle, refresh scheduling and its CPU budget, progress, a retention layer the kit does not have | not yet written |

550–700 lines touched before the new work starts, to lose retention and gain a
second reader of every transcript on the disk. The brief's bar for doing it —
"< ~300 lines and strictly better" — is not met on either half.
