# Changelog

All notable changes to Auspex are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

Auspex is pre-alpha; Dev previews may be published, but there is no Stable
release yet. `RELEASING.md` describes how one is cut when there is.

## [Unreleased]

### Fixed

- Packaged apps now resolve SwiftPM resources from `Contents/Resources`, so a
  GitHub-downloaded build no longer crashes in `Bundle.module` when the CI
  checkout fallback path is absent. Release CI smoke-tests the copied archive.
- MCP writes no longer infer identity from the most recently active socket;
  official bridge requests carry request-scoped, kernel-roster-corroborated
  process attribution, while ambiguous legacy connections fail closed.
- Takeover approval expires when the reviewed task version or holder changed,
  and Catch-up ignores tool/token churn, uses a fresh click-time cursor, avoids
  duplicate orphan rows, and scopes branch collisions to a project.
- Login launch respects a user disabling the item in macOS and a later
  Finder/Dock reopen restores the normal main window.
- Liveness probes exclude retained ended history instead of re-running every
  harness filesystem check over thousands of sessions every three seconds.
- Discovery tails a one-hour recent working set instead of a full day of
  dormant stores, while live presence/worker evidence overrides the cutoff and
  SQLite/WAL polling keeps its two-second correctness cadence.
- Person-authored task writes now refresh Roost, Live Ledger and Catch-up only
  after the store accepts the transaction, avoiding stale queues and read/write races.
- Every Auspex-owned window, sheet and popover clears only its implicit initial
  responder; no control starts highlighted, while Tab/arrow navigation and
  subsequent focus feedback remain intact. Native Kill alert is now an owned sheet.

### Added

- A 30-second Catch-up panel with a ranked human queue (including takeover
  approvals), semantic changes and non-notifying amber watch signals.
- Carbon-inspired task integrity: monotonic versions and `expected_version`,
  atomic dependency validation, durable human-approved takeover requests,
  holder-only completion into Review, and attempt context in `tasks.get`.
- Review Next navigation, on-demand bounded local-Git Delivery evidence, and
  copy-only provenance-labelled Handoff Packets.
- Safe `overview.get`, `tasks.get`, `tasks.release`, `sessions.get`, and
  project-scoped `sessions.list` context without peer transcripts or prompts.
- An installable, versioned `auspex-coordination` Supervisor/Worker/Reviewer
  Skill with owned-directory hashing, backups and exact reversal.
- Explicit Launch at login controls in first-run setup and General Settings,
  implemented with ServiceManagement and a quiet login launch.

### Changed

- The bundled coordination Skill now carries task versions through writes and
  treats `pending_takeover` as a request rather than ownership.

## [0.1.0-dev.2] - 2026-08-21

### Changed

- **The board's unit is the task, not the session.** A session is a process,
  and half the processes on a busy machine are subagents — a step inside
  somebody else's job, spawned and finished within one turn. Drawing each as a
  peer of the thing that spawned it gave a wall where a delegation of four read
  as four independent pieces of work, and the reader reassembled the family in
  their head every time they looked.

  Every surface now folds them. The Ledger draws one card per piece of work
  with its sessions as a strip of member dots and a `↳ 3`; the sidebar lists
  project → checkout → task, with sessions only under a task somebody opened;
  the Aviary gives one desk per task with the task's title on the nameplate;
  the Flock draws one bird per task with its members as small avatars under it;
  the Flight gains a Task scope that merges every member's lane into one
  waterfall. The header, the menu bar and the sidebar count *units*, so a
  family of three is one working task. A single global switch — "Show
  subagents", in the grouping menu, persisted — lists the sessions on every
  card at once for people who want the old density, and a chevron per card
  does it for one.

  Work nobody filed a task for gets exactly the same card, derived from the
  root of its delegation and marked `auto`, with "Promote to task…" beside it.
  The task protocol stays enrichment rather than a dependency.

- **Finishing a task asks for a review; it does not close it.** `tasks.complete`
  and `auspex.notify(done)` move a task to a new **Review** state — still open,
  still counted, still on the wall, wearing the sentence the worker wrote — and
  only a person's close moves it to `done`. An agent saying it is done is a
  claim about its own work, and the one thing a board full of agents must not
  let any of them do is mark their own homework. The chip that used to say
  `✓ N done` says `✓ N in review`.

- **The views are named for the birds.** Ledger, Aviary, Flock, Flight, and the
  Tasks page is the Roost. `--view` still takes `board`, `scene`, `crew` and
  `trajectory`, because they are in people's shell histories and in settings
  files already written.

- **A flock bird's body is its session, and its colour is its harness.** The
  wall gave each harness a silhouette; on a board of ninety that is one bird
  drawn forty times. Bodies now come from a ten-strong plump family seeded by
  the session key, every one of them at least 0.72 as narrow as it is wide —
  asserted over the catalogue, because a shape with a point in it reads as
  spiky at 56 points and vanishes at 22. The wall itself is half the size it
  was.

### Added

- **Tasks carry what they are and what they wait for.** A kind
  (feature/fix/chore/research), labels, an importance in words as well as a
  number, and dependencies. `tasks.list` takes `ready_only` and `label`, so
  "find me something to pick up" is one call rather than a list plus a
  judgement. A task waiting on unfinished work says `waits on AUX-…` and is not
  ready.

- **Notes have kinds and refs.** `tasks.log` takes `decision`, `evidence`,
  `risk` or `note`, and a `ref` — a commit, a URL, a path. That is the whole
  difference between a work log and a chat transcript: an agent that writes
  "checked, it holds" has said nothing anybody can verify.

- **A task has a page.** Its handle, status, importance, labels, project and
  milestone; the claim and every session on it with per-member state and
  freshness; what it waits on; its history, with a place to write into it; and
  Close, Reopen, Release claim and Promote. Reached from a card's double click
  or ⌘↩.

- **⌘K.** A palette over the frame in hand: a handle out of a brief, a project
  you have not scrolled to, a session by name, and the two or three actions
  that otherwise need a right-click on a card you have to find first.

- **Filters.** Importance, label, harness, ready-only, claimed/unclaimed and
  orphaned claims, offered only where the wall can answer them, with a bar that
  says what is on and one click per facet to take it off.

- **Orphaned claims.** A claim whose session ended without finishing is marked
  amber on its card, filterable, and has Release beside it. Its own marker
  rather than a bucket: debris is not the same thing as work that is stuck.

- **What each harness finishes.** The Harnesses page gains claimed, finished
  and median claim-to-finish, because "how many of its sessions are open" is
  mostly history on a machine that has run agents all week.

- **Projects contain tasks.** Plans and projects used to be two roots side by
  side, so a task an agent filed over MCP without a plan landed in a lane called
  "Unfiled" — which meant "nobody asked where this belongs", next to the project
  it obviously belonged to. There is one hierarchy now: **project ⊃ task ⊃
  sessions**. `tasks.create` resolves the caller's project from the session on
  the other end of the socket, using the same `BoardSnapshot.projectKey(for:)`
  the wall groups cards by, and a task inherits its project from the milestone
  it is filed under or from the session that first claims it.

  A plan is demoted to a **milestone**: an optional heading inside a project.
  The `plans.*` tools keep their names — briefs already in flight carry them —
  and describe themselves as milestones. The Tasks page draws one lane per
  project with milestone sub-headers inside, hides projects with nothing in them
  unless the window is bound to one, and says "Nothing to do" once instead of
  drawing a dash in each of four columns. The Projects page gains a column for
  the work each project is carrying, including projects whose sessions have all
  gone home.

  Schema v5 adds `tasks.project_key` and `plans.project_key` and backfills every
  task that was already there from its claimer, then its filer, then its
  milestone; what is left lands in a **Scratch** project a person can empty
  rather than a `NULL` nobody can find.

- **Attention is something said, not something inferred.** A card is counted as
  wanting a person, or as having finished, only when something explicit said so
  — an agent calling `auspex.notify`, a `PermissionRequest` hook, a harness's
  own permission wait, or `tasks.complete`. The old `done unseen` bucket was
  inferred from a closed turn, which on a machine that has been running agents
  all week is true of several hundred sessions at once; a count nobody can act
  on takes the counts beside it down with it. The inference survives as a faint
  dot on a card, counted nowhere and notified never.

  Activity and attention are now orthogonal: an agent that reports finishing
  while a `swift build` is still running is `working` and `done` at once. The
  buckets are `needsYou · doneReported · working · idle · ended`, and every
  surface reads the one map the frame carries — the board's ring and banner, the
  header's chips, the sidebar's dots and per-project counts, the menu bar, the
  crew wall's badges, the Trajectory's banner and timeline marker, and which
  column a task is drawn in.

  Both loud buckets clear themselves: opening the card, typing into that
  session's own terminal, the agent going back to work, "Dismiss", the header's
  new **Mark all as seen**, or a day going by. `session_views` grows
  `acknowledged_at` and `ack_reason` so the answer survives a relaunch.

- **A session waiting on a person now walks to the garden's front row** instead
  of keeping its desk, and shares that row with anything that reported
  finishing — a red `!` and a green `✓` by the path. A raised hand among forty
  desks is something you have to find. The back lawn keeps the resting and the
  dozing, and is still the half that gives way when a busy repository fills the
  map; nothing on the front row is ever bounded away.

- **Settings → Agents** gains one switch: whether a reported finish raises a
  macOS notification (on by default). A session blocked on a person always
  raises one, and deliberately has no switch.

### Added

- **Every card says how full its session's context window is.** The `/context`
  gauge, for the three harnesses whose stores record it: a thin bar and
  `898.8k / 1M · 90 %` under the counters, coloured by the board's own state
  language — quiet ink under 70 %, tool-amber to 90 %, needs-you red above it,
  because a session about to compact is closer to "somebody should look" than
  to anything new. A tiny `⟲ 2` after it counts the compactions it has already
  been through.

  One definition of "used" on every row, so the gauge means the same thing
  wherever it appears: **the tokens that were in the model's context when it
  was last called** — the whole prompt, cached prefix included, and the reply
  just generated excluded, because that lands in the next call's input. Claude
  Code's `input_tokens` plus both cache counters; Codex's
  `last_token_usage.input_tokens`; Grok Build's `contextTokensUsed`. Cursor,
  AntiGravity, Grok Bot, Claude Cowork and Gemini CLI record nothing that
  answers it and get no gauge at all — a bar at zero would say something none
  of them said.

  The dotted half is the part worth knowing about. Codex and Grok write their
  window size into their own logs; Claude Code computes it in-process and never
  writes it down, so Auspex looks it up from the model id. What is uncertain is
  therefore the *denominator*, never the fill — so the fill stays solid and the
  unfilled remainder goes dotted, which says "this is roughly where the wall is"
  rather than "this measurement is soft". A model the lookup table has never
  heard of still reports a fill, with no bar: `421k` is worth showing, and a
  guessed denominator is not.

  And the gauge never prints more than 100 %. A fill past the window is not a
  session at 425 % — no harness overruns its own window by four times — it is
  Auspex holding the wrong denominator, which is what a model bigger than the
  lookup table knows about looks like. So the gauge stops dividing: `850.1k ·
  window ?`, in the quietest ink, with a tooltip saying the model's window is
  not on record. Not red, because the one wrong answer there is a card sending
  somebody to wrap up a session that has plenty of room. The trajectory lane
  and the composition bar refuse the same reading for the same reason, and the
  popover's ledger still prints what was recorded so the figure can be checked.

- **The trace header opens what is actually in the window.** `context 96.4k /
  200k (48 %)` beside the token totals it is most often confused with, and a
  popover behind it with the exact counts, the cached share, the compaction
  count, and an estimated composition — messages, tool results, everything
  else, free.

  The composition is Auspex's own estimate and every line of the panel says so.
  Claude Code's `/context` is exact because Claude Code is the thing holding
  the window; it knows its system prompt, its tool schemas and the skills it
  loaded, and none of that reaches disk. What does reach disk is the
  conversation, which Auspex already indexes, so messages and tool results are
  estimated at four characters to the token and the rest is inferred by
  subtraction. Four bands rather than Claude's seven: fabricating "System tools
  1.9 %" out of a number nobody wrote down would be a worse answer than one
  band honestly labelled *everything else*. When almost nothing could be
  attributed — a session Auspex met after it started — the panel says that too,
  rather than letting the remainder read as a claim about a system prompt.

  The scan runs when the panel opens, never on a frame: two index seeks from
  the newest compaction forward, capped, off the main actor.

- **A Context lane on the trajectory.** A fourth row under Input, Model and
  Tools: a step line of how full the window was, with a rule wherever the
  harness threw the window away. Readings are anchored to a step index rather
  than to a timestamp, so they land in the right place under all three scales —
  the x axis is a clock under Duration and a count under Turns and Calls. A
  step line rather than a smooth one, because nothing was measured between two
  readings, and each run is coloured by the level it is *at* rather than the
  one it ends in, so a session that sat at 48 % for a minute is drawn calm for
  that minute. The lane appears only for a session that has readings; five of
  the nine harnesses record none, and a lane that is empty on most of the board
  is a lane a reader learns to ignore.

- **The Codex row on the Harnesses page names its plan window.** `used 43 % ·
  resets in 2 h 10 m · plan pro`, read out of a rollout that was already being
  tailed. Codex writes a `rate_limits` block beside its token counters and no
  other store on this Mac writes one at all, so this is one line on one row.
  Nothing here asks a network what anybody's quota is; the tooltip says so, and
  says how old the claim is.

- **`--render-context`**, which draws that popover on its own.
  `ImageRenderer` has no window and therefore no popover, so `--render-board`
  can draw the header control and never what is behind it. The renderer runs
  the real demo pipeline and the real estimate query, because a picture of an
  estimate that skipped the query proves nothing.

- **Auspex updates itself, on a stable channel or a dev one.** Tagged builds go
  out as GitHub Releases and an installed copy keeps itself current: Settings →
  Updates, or Auspex → Check for Updates…. One signed feed serves both streams,
  and Dev is *additive* — a preview build still receives every stable release,
  because Sparkle always considers its untagged items. Choosing to try a
  preview should never mean missing the next fix.

  Every archive is signed with the project's EdDSA key and verified against the
  key compiled into the running copy before a byte is unpacked, so the check
  does not depend on Apple's — which matters while builds are ad-hoc signed.
  Nothing installs without being asked: this is a window people leave open for
  days, and an app that replaced itself under a running session would take the
  session's window with it.

  The channel lives in `~/.auspex/settings.json` beside every other setting;
  an absent or unrecognised value means stable, because the failure direction
  of this one setting has to be the one that installs less.

- **A release process, in two scripts and three workflows.**
  `Scripts/release_app.sh` cuts a release — version bump, changelog section,
  branch, tag — and refuses a build number Sparkle would treat as a downgrade.
  `Scripts/generate_update_feed.sh` adds one signed item to the feed and
  asserts that it dropped nothing already in it. CI builds from the tag into a
  *draft* release, and publishing that draft is what rebuilds the feed. See
  `RELEASING.md`.

- **Light and dark, and the Mac decides.** Auspex forced dark for as long as it
  had one palette. Every token is a pair now — declared in one total `switch`,
  so a colour cannot exist in one appearance and not the other — and the window
  follows the appearance the Mac is set to, including a scheduled switch at
  sunset. **Settings → Appearance** overrides that with System · Light · Dark,
  switches the sidebar between the system's own material and the board's flat
  ground, and shows which accent, background and foreground the choice resolved
  to. Both are persisted in `~/.auspex/settings.json`; an absent key means
  "follow", so nobody has to go and ask for the behaviour the setting exists to
  give them.

  Both columns are retuned around one anchor pair — `#2D2D2B` ground, `#F9F9F7`
  paper — so the dark side moves off near-black onto a warm charcoal and the
  two are the same room lit differently. A single app accent, terracotta
  `#CC7D5E`, arrives for selection, keyboard focus and every system control's
  tint, and "this control is on" stops being a surface step, because on a white
  panel there is nowhere lighter to go. State colours keep their hue and clear
  3:1 on their own pill in both; harness accents keep their hue *exactly* and
  only lose brightness, by the least that brings each to 3:1 on a white ground.
  `AuspexPaletteTests` computes every WCAG ratio from the table on each build,
  so the numbers in the palette's documentation cannot rot.

  Nothing has to be relaunched. The three surfaces that hold bytes rather than a
  dynamic colour — the board's tiled grid, the activity strips' `CALayer`s, and
  the office's textures — each rebake on an appearance change, and the tests
  drive them through a real one and check what they are holding afterwards. The
  office gets a daylit column of its own rather than the dark one inverted, and
  its glows change how they *meet* the floor: additive light on a white floor
  can only make white, so in light a glow paints the state's hue instead.

  `--appearance system|light|dark` draws one launch in an appearance without
  writing it down, which is how the performance budget is measured against
  both; `appearance=light` on `--render-board`, `--render-scene`,
  `--render-crew` and `--render-trajectory` gives every screenshot in
  `docs/screenshots/` a `-light` twin.

- **The scene is a place, not a room: a meeting room and a garden, and people
  who walk to them.** The map is one continuous plan — the office as it was,
  with two annexes under it — and a session's *position* is now the first thing
  a glance reads. A session that is delegating walks to a long table with the
  subagents it spawned down the sides, one table per family, a screen at the
  far end carrying the parent's state colour. Anything resting goes to the
  garden: idle on a bench, gone-quiet dozing, **finished-while-you-were-
  elsewhere holding a note**, and over walking out through the gate. A session
  waiting on a person never leaves its desk, whatever else is true of it.
  Both annexes are on by default and switch off in **Settings → Scene**
  (persisted in `~/.auspex/settings.json`), and off means everybody stays at
  their desks — the office exactly as it was, verified by rendering it both
  ways and diffing the pixels.
- **`SceneZoning`, `SceneRoute` and the annex half of `SceneLayout`** in
  `AuspexCore` — all of it pure and tested. Placement is a function of the
  board, the delegation edges it admits to, and the set of sessions the task
  ledger calls unread; a table is a family in one project, the same rule a bay
  follows. A desk is *held* while its occupant is away rather than freed, which
  is what keeps the office's geometry identical, sits a returning session back
  down where it was, and gives a walk somewhere to walk from. A route is three
  straight legs — out to the walkway, along it, back in — with a gutter down
  the left joining the strips; between two strips it is those with a trip down
  the gutter in the middle. No pathfinder, and every leg axis-aligned so it is
  one `SKAction.move` with one walk strip over it.
- **Walking, at no per-frame cost.** A walk is a node of its own that lives
  exactly as long as the walk: both ends draw themselves empty and it carries
  the sprite either would have. It uses the character package's `walkDown` /
  `walkUp` / `walkRight` strips, mirrored for left, and falls back to the
  procedural rig for a package that has none. A walk whose whole path is
  outside the cull is skipped, a session that changes its mind halfway turns
  round from where it had got to, Reduce Motion has no walking in it at all,
  and a render lands everybody before the shutter opens.
- **The demo covers the whole map.** `delegateMany` fans a parent out to two
  subagents at once (two `delegate` beats in a row are two delegations, so a
  family of three never existed to photograph); the renderer refreshes
  staleness against the instant being drawn, against the demo's own compressed
  threshold, so a still can show a dozing session; and `DemoScript` declares
  which of its sessions nobody has read, because whether a person has *looked*
  is the one fact about a board no harness store holds.
- **`--render-scene … --office-only`** draws the map with both annexes off, so
  "the annexes changed nothing about the office" is a picture two commands
  apart rather than a claim.

- **Harness hooks, so "waiting for you" stops being a guess.** A permission
  prompt is the one state no harness writes to disk: from outside, an agent
  waiting for a person and an agent thinking hard are the same silence. The
  Settings → Agents page (and the first-launch sheet) now installs hook entries
  for Claude Code, Grok Build and Cursor, and wraps Codex's single `notify`
  slot, each naming its file and its events before anything is ticked and each
  removable from the row that installed it. `Auspex --hook <harness>` is what
  the entries run: it reads the harness's JSON, writes one line to
  `~/.auspex/mcp.sock`, and exits 0 within 200 ms whatever happens — a hook
  that can hang is a harness that can hang. Tool calls are deliberately not
  reported; the tailer already describes those, and counting them twice would
  be worse than late.
- **Vendor marks, not initials.** `HarnessLogo` loads each vendor's own
  single-colour SVG from `Sources/AuspexApp/Resources/ProviderIcons`, draws it
  as a template tinted with the harness accent, and caches it per
  `(harness, size)`. Every surface that identified a harness with two condensed
  condensed capitals now wears the mark on the same tinted tile: the board card, the
  sidebar, the trace header, the search results, the Harnesses page, the empty
  state, the menu bar, and the desk fronts in the scene. The two-letter
  `HarnessStyle` property they came from is gone, so nothing can reuse it, and
  the SF Symbols survive only as
  `HarnessLogo.fallback(for:)` for a mark that failed to load.
- **Claude Cowork and ChatGPT Work are first-class harnesses.**
  `AuspexAdapters.all` runs `ClaudeCoworkLiveAdapter`, and `featured` is now the
  seven a person can actually be running: Claude Code, Claude Cowork, Codex,
  ChatGPT Work, Cursor, Grok Build, AntiGravity. The Harnesses page shows all
  seven, and the two rows that name one directory say why on the row —
  `~/.codex/sessions` carries both Codex and ChatGPT Work rollouts, told apart
  by each rollout's `originator`. The demo board gained a Claude Cowork session
  and a ChatGPT Work session, so all seven are visible in `--demo`.
- Full harness names everywhere. A menu bar row now carries the vendor mark and
  the harness's full name rather than a two-letter code, and no UI string
  abbreviates a harness.

- SwiftPM package scaffold: `AuspexCore` library on GRDB 7 and
  `agent-session-kit`, and the `AuspexApp` SwiftUI executable, both in
  Swift 6 language mode.
- `AuspexPaths` — single source of truth for the `~/.auspex/` tree, created
  lazily with mode 0700, with an injectable home directory for tests and a
  containment check that refuses to create anything outside its base.
- `AuspexStore` — GRDB store on a WAL `DatabasePool`, whose append-only
  `v1_initial` migration creates the whole schema: projects and worktrees,
  sessions, the event log, the tool-call ledger, indexed message text with
  an FTS5 index over it, the task board, per-source tailing cursors, and
  `meta`. A session row carries the reducer's snapshot verbatim plus the
  columns the board sorts and filters on, projected out of it in one place
  so the two cannot drift.
- Full-text search across every harness at once, using FTS5's `trigram`
  tokenizer so a Chinese substring and an identifier glued inside a longer
  one are both found — neither of which a word tokenizer can do.
- `SessionRepository` — snapshot upsert and fetch, batched event append and
  recent-event windows, the tool-call ledger, and search.
  `SourceCursorRepository` persists how far each tailer has read, so a
  relaunch resumes instead of re-reading gigabytes of history.
- `RetentionPolicy` and `RetentionJob` — 2000 events per session, 14 days
  measured from when Auspex observed an event rather than from the source's
  own timestamp, 30 days of searchable text, and a per-harness exclusion
  list for the index. Stored in `meta`; not scheduled yet.
- `SessionRegistry` — an actor that bootstraps from the store, folds the
  `AgentEvent` stream through `SessionStateReducer`, batches writes into one
  transaction per 250 ms, and re-evaluates staleness on a one-second tick.
- `BoardSnapshot` — the immutable frame the UI renders, published coalesced
  to at most 20 Hz, sorted alive-first and then by which session most needs
  a person, and grouped by harness and by project.
- **The live board.** A wall of session cards in a `NavigationSplitView`:
  sidebar, board, session trace. Each card carries its harness accent rail
  and vendor mark, a state pill, the current tool or target, an elapsed-in-state
  stopwatch, turn / tool-call / token counters, and the project, pid, and
  model. Group by nothing, by harness, or by project, with sticky section
  headers carrying live counts; search every transcript from the toolbar.
- **A state language built out of colour and motion.** Every card ends in one
  2 pt pulse line whose rhythm is its state: a slow breath for thinking, a
  travelling segment while a tool is open, one tick per child while
  delegating, and a hard strobe plus a red glow for a session blocked on a
  permission prompt. One `repeatForever` animation per animating card and
  none at all for idle or ended ones; every rhythm collapses to a static bar
  under Reduce Motion.
- **`HarnessStyle` and `StateStyle`** — the fixed accent hue and vendor mark
  for each of the eight harnesses, and the colour, label, and motion
  for each session state, defined once so the board, the trace, the menu bar,
  and M2's scene view cannot disagree. Colours are dynamic `NSColor`s, so
  light mode works without an asset catalog.
- **`SessionTraceView`** — a session's identity, its parent link, and a trace
  waterfall of its events on a continuous spine: timestamps to a tenth of a
  second, a coloured node per event kind, turn separators, filter chips, and
  tail-following that yields the moment the reader scrolls away. A tool call
  is one row carrying its duration rather than two; clicking a row opens the
  full text and the pretty-printed payload.
- **`BoardGrouping` and `TraceEntry`** in `AuspexCore` — the pure grouping,
  sorting, and event-summarising the views render, testable without a window.
- **`LiveBoardModel`** — the single consumer of `SessionRegistry`'s frame
  stream. The trace stays live by re-reading `recentEvents` whenever a frame
  moves the selected session, debounced so a burst is one query.
- **`AppEnvironment` wires the pipeline**: store → registry → merged event
  stream, fed by `IngestCoordinator` and a `LivenessResolver` loop, with
  `SourceCursorRepository` now conforming to the kit's `SourceCursorStore` so
  a relaunch resumes where the tailers stopped. `AuspexAdapters.all` is empty
  until the Claude Code and Codex adapters land, and the empty board says so
  rather than looking broken.
- **Menu bar extra** showing live, delegating, and blocked counts, and a menu
  of live sessions that opens the window onto the one you pick.
- **`--demo`** (or `AUSPEX_DEMO=1`) replays a fabricated board — eight
  sessions across all five harnesses, seeded and reproducible — out of an
  in-memory store, so the UI can be developed and demonstrated before any
  adapter exists. It reads no harness store and writes nothing to disk.
- **The scene view.** The same board read as a room: every session is a pixel
  agent at a desk, every project is a room they share, and a sub-agent sits at
  a smaller desk beside its parent with a dotted tether back to it. A
  **Board / Scene** control above the grid switches between them, and the
  choice is remembered. The two answer different questions — the wall says what
  one session is doing, the office says what the whole machine is doing without
  being read — so the loudest channel here is light: a monitor's colour is its
  session's state, its rhythm is that state's motion, and the spill lands on
  the desk and the agent. Blocked sessions strobe red, raise a hand, and put an
  exclamation over the desk; everything else stays quiet. The canvas is an
  `NSScrollView`, so two fingers pan and pinch at once with the platform's own
  momentum and elastic edges; ⌘-scroll zooms, a two-finger double tap frames the
  room under the pointer, and **Fit** frames the whole building. Clicking a
  desk sets the same selection clicking a card does, in
  both directions. Every rhythm collapses to a static pose under Reduce Motion.
- **`SceneLayout`** in `AuspexCore` — the pure, tested seating plan behind it.
  Keeps an allocation table rather than laying out from the board's own order,
  which sorts by urgency: a desk is held for as long as its session is on the
  board, a newcomer takes the lowest free slot, and nothing already seated
  moves when somebody arrives or leaves. Vacated desks in the middle of a row
  stay on the plan as empty workstations and are reused; trailing ones are
  trimmed. Rooms are shelved left to right and wrap, so four small projects
  read as one building rather than a column four screens tall.
- **`SceneDirector`** diffs the SpriteKit graph against each frame instead of
  rebuilding it — a node recreated twenty times a second is a node whose
  `repeatForever` restarts twenty times a second — and the view runs at 30 fps
  and pauses itself when its window is occluded or hidden.
- **Procedural placeholder sprites and `SpriteLibrary`.** The agents are drawn
  in code today, in their harness's own accent hue, from small RGBA buffers
  rendered with nearest-neighbour filtering. Real frame strips drop in per
  harness, variant, and pose from `~/.auspex/sprites/` or the app bundle, with
  the procedural rig as the fallback for anything nobody has drawn yet.
  [`docs/SPRITES.md`](docs/SPRITES.md) specifies the atlas.
- **`--render-scene <path> [seconds]`** renders the office to a PNG offscreen
  from the demo board, so the README's screenshot is a reproducible build
  artefact containing no real session, path, or name.
  a person, and grouped by harness and by project. Carries the delegation
  forest as `tree`, and groups a child that recorded no directory of its own
  under its nearest ancestor's project rather than leaving it homeless.
- `ProjectResolver` — turns a working directory into a `ProjectPlacement` by
  reading git's own files (`.git`, `commondir`, `HEAD`) and never shelling out
  to `git`. A linked worktree resolves to the **repository** it was branched
  from, so three agents in three worktrees of one repo are one project with
  three checkouts. Recognises the agent-worktree conventions —
  `.agents/worktrees/<task>` and the `.claude`, `.codex`, `.cursor`, `.grok`
  variants — and reports the task name. Cached per directory, invalidated by
  `HEAD`'s mtime, with a 30-second TTL for directories that have no `HEAD` to
  watch.
- `PlacementService` — resolves each `(session, directory)` pair once, which is
  what keeps a harness that re-reports its cwd on every transcript line from
  costing a filesystem walk per line.
- `ProjectRepository` — upserts `projects` and `worktrees` from placements,
  points `sessions.project_id` / `worktree_id` at them, writes `root_key` from
  the session tree, and answers `fetchProjects(withCounts:)`,
  `sessions(inProject:)`, and `sessions(inTreeRootedAt:)`. A later resolution
  that learned less never erases what an earlier one knew.
- `SessionTree` / `SessionTreeBuilder` — the cross-harness delegation forest
  built from `identity.parent`, with `rootKey(for:)`, `descendants(of:)`, and
  per-node depth. Total by construction: an orphan whose parent is not on the
  board becomes a root, and a contradictory pair of stored parents is broken
  rather than followed.
- `SessionRegistry.applyPlacements(_:)` and `applyLinks(_:)` — the entry
  points that turn resolved placements and inferred parent links into ordinary
  `identityUpdated` events, so the snapshot, the event log, the store, and the
  board learn them the same way everything else is learned. A link is refused
  for a session that acquired a recorded parent in the meantime, and one
  naming a parent the board does not have is dropped.
- `GroupingCoordinator` — the thin three-second driver that runs both off the
  registry's actor, because `sysctl` and `stat` do not belong on the path of
  every event. Sessions that are no longer running keep their session id but
  lose their pid, so a recycled pid cannot be mistaken for a live parent.
  `AppEnvironment` starts it alongside the liveness loop, sharing one
  `ProcessTable` between them so a tick costs one process-table read rather
  than two — in demo mode as well as live, so both exercise the same path.
- **Projects sidebar** — a live tree of every project on the board, built from
  the frame rather than from the database so it cannot disagree with the wall
  next to it: `project → checkout → session`, with a dot per harness at work,
  a count of what is running, and the agent worktree's *task* as the checkout's
  label wherever the path follows the convention. A project opens itself the
  first time something in it goes live, and never re-opens after that, so it
  does not fight a reader who closed it. Directories in no repository are
  listed too, marked "no git". Selecting a project filters the wall to it;
  selecting a session selects its card. `ProjectTree` does the building, in
  Core, where it is tested.
- **Group by: Tree** — the wall as a delegation forest. Each root that
  delegated gets a section with its children nested behind a rail; roots that
  delegated to nobody share one trailing section, because a tree of one is not
  a tree. A card carries a "↳ N children" badge for what is below it and a
  chip naming its parent, which selects the parent when clicked. The forest is
  rebuilt from the *filtered* sessions, so a child whose parent a harness
  filter removed becomes a root rather than vanishing.
- **Project filter** — applied on every grouping axis and answered against the
  frame, so a subagent with no directory of its own stays with the project it
  inherited. A bar above the wall says which project is showing and clears it.
- **Trace header** now shows the project, the branch, the agent worktree's
  task, the parent, the children, and — the point of the row — *how* the
  parent link was established: a spawn the parent's own log recorded, an
  inherited environment variable, a process ancestry, or a person's decision.
  Those are claims of very different strength, and a header that showed a
  parent without saying which invites a reader to trust a guess as a record.
- **Harnesses page** — one rack row per harness: whether its store exists on
  this Mac, live / idle / total sessions from the board, last activity, and
  the MCP servers it is configured with. The three come from three different
  places on three different schedules and are kept apart, because "no sessions
  on the board" reading as "not installed" would be the most misleading thing
  the page could say.
- `HarnessMCPConfigStore` — **read-only** parsing of each harness's own MCP
  configuration: `mcpServers` in `~/.claude.json` (global and per-project
  scopes kept apart) and `~/.cursor/mcp.json` and
  `~/.gemini/config/mcp_config.json`, and `[mcp_servers.<name>]` tables in
  `~/.codex/config.toml` and `~/.grok/config.toml`. The TOML side is a
  tolerant section scanner rather than a parser: a sub-table is not a server, a
  quoted name is unquoted, and a construct it does not understand costs it that
  table rather than the file. It never writes, never creates a missing file,
  and reports "no config file", "could not be read", and "no servers" as three
  different answers. Whether Auspex's own server is registered is shown as an
  empty socket — it arrives in M3.
- Main window (`NavigationSplitView`) and a menu bar extra with Open and Quit.
  The sidebar's destinations are Live / Tasks / Harnesses / Settings; Projects
  is not one of them, because the tree below them *is* the projects section.
- `--mcp-stdio` and `--hook` command-line placeholders, dispatched before
  AppKit starts; both exit 2 until M3.
- `Scripts/build_app.sh` — packages and ad-hoc signs `.build/Auspex.app`, and
  fails the build if the signed bundle claims the app-sandbox entitlement.
- Open-source scaffolding: README (English and Chinese), architecture notes,
  contributor and security policies, issue and PR templates, and CI.

### Changed

- **The scene's canvas is the platform's.** The office now hangs on an
  `NSScrollView` whose document view is empty, flipped, world-sized and never
  drawn; the `SKView` stays the size of the window underneath it and renders
  whatever rectangle the clip view is showing, read onto the `SKCameraNode`
  once per frame. Panning, momentum, elastic edges, the scroll-direction
  preference and the live pinch are the platform's, which is what makes two
  fingers scale and move the map at the same time — the thing a hand-rolled
  magnify handler cannot do, because zooming around a centroid does not
  translate when the centroid travels. What stayed ours is the travel of such a
  pinch (applied only when the system is not already scrolling for the same
  fingers), a zoom on ⌘-scroll, a smart zoom that frames the room under the
  pointer, and the landing on the crisp zoom ladder when the fingers lift. The
  `SKView` is deliberately not the document view: a document is scaled by the
  magnification, so a Metal-backed one would need a drawable the size of the
  building times the zoom — 559 MB for a forty-project office at 4× on a Retina
  display, and 3.5 GB for a six-hundred-session one, to draw a picture 900
  points wide.
- **Hovering costs a rectangle test rather than a walk of the office.** Every
  mouse-moved event used to call `SKScene.nodes(at:)`, which visits every node
  in the scene and allocates; measured on a 600-session office that is 5.0 ms
  per hit test, and a trackpad asks several times per frame. The pointer is now
  placed against the floor plan — the room first, then that room's desks — at
  0.14 µs per hit test, and at most once per drawn frame however often the
  pointer moved between them.
- `AuspexAdapters.installed` and `watchRoots(home:)` index by each adapter's
  `handledHarnesses` rather than its primary `harness`, so ChatGPT Work is not
  reported as unwatched while its sessions are on the board.
- `HarnessMCPConfigStore` no longer answers `~/.claude.json` for Claude Cowork.
  Cowork's MCP servers come from Claude.app's own settings inside the app
  container, so the location is `nil` and the Harnesses page says *managed by
  Claude.app* rather than reporting the CLI's servers as Cowork's.
