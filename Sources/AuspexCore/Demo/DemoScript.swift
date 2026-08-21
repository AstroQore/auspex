import AgentSessionKit
import AgentSessionLive
import Foundation

/// A fabricated board, for developing and demonstrating the UI before the
/// harness adapters land.
///
/// The script is a flat, offset-ordered list of events across several
/// synthetic sessions. A host replays it against wall-clock time; nothing here
/// sleeps, reads a file, or looks at the real machine, which is what makes the
/// whole thing reproducible from a seed.
///
/// Everything in it is invented. Paths live under `/Users/example`, session
/// ids are fixed strings, and no line was captured from a real transcript —
/// the same rule the test fixtures follow, for the same reason: this ships in
/// a public repository and gets screenshotted.
///
/// ## Shape of a loop
///
/// Each session opens with a compressed prologue — a turn or two of history
/// emitted inside the first half second — so the board is populated the moment
/// the window appears rather than filling in over a minute. The live beats
/// follow at real-time gaps, staggered so that within a few seconds of launch
/// the wall shows every state at once: something thinking, something mid-tool,
/// something writing, one session delegating to a child, and one blocked on a
/// permission prompt.
public struct DemoScript: Sendable, Equatable {
    /// One event and when to emit it, measured from the start of the loop.
    public struct Step: Sendable, Equatable {
        /// Seconds since the loop began.
        public let offset: TimeInterval
        /// The event to feed the registry.
        public let event: AgentEvent

        public init(offset: TimeInterval, event: AgentEvent) {
            self.offset = offset
            self.event = event
        }
    }

    /// Every step, ascending by ``Step/offset``.
    public let steps: [Step]

    /// How long one loop lasts. A replayer waits this long before starting
    /// the next generation.
    public let duration: TimeInterval

    /// The seed the script was built from, so a bug report can name it.
    public let seed: UInt64

    /// The default seed. Any value works; this one produces a board with all
    /// five hero harnesses visible and the permission prompt early.
    public static let defaultSeed: UInt64 = 0xA5_9E_C0_DE

    /// The home directory of the invented machine every path here hangs off.
    ///
    /// A constant rather than a convention, because one of the rules the demo
    /// exercises is positional: ``HarnessSandbox`` recognises the Codex
    /// desktop's per-thread scratch by where it sits under a home, so the
    /// resolver behind a demo board has to be told which home that is.
    public static let homeDirectory = "/Users/example"

    /// Builds one loop.
    ///
    /// - Parameters:
    ///   - seed: drives every jitter. The same seed and generation always
    ///     produce byte-identical steps, event ids included.
    ///   - startedAt: the instant offset `0` corresponds to. Only used to
    ///     stamp the events; a replayer re-stamps them with the real emission
    ///     time so a card's elapsed-in-state readout is honest.
    ///   - generation: which pass around the loop this is. Sessions keep their
    ///     keys across generations — a loop restarts the same eight sessions
    ///     rather than piling up new ones — so the board stays a fixed size no
    ///     matter how long the demo runs.
    ///   - scale: how many times to run the cast. `1` is the demo as written;
    ///     `12` is roughly the size a busy machine reaches. See
    ///     ``scaledBlueprints(_:)``.
    public static func make(
        seed: UInt64 = DemoScript.defaultSeed,
        startedAt: Date,
        generation: Int = 0,
        scale: Int = 1
    ) -> DemoScript {
        var rng = SeededRandom(seed: seed &+ UInt64(bitPattern: Int64(generation)))
        var steps: [Step] = []
        for blueprint in scaledBlueprints(scale) {
            var writer = Writer(
                blueprint: blueprint,
                startedAt: startedAt,
                generation: generation,
                rng: rng
            )
            writer.compile()
            steps.append(contentsOf: writer.steps)
            rng = writer.rng
        }
        steps.sort { lhs, rhs in
            if lhs.offset != rhs.offset { return lhs.offset < rhs.offset }
            return lhs.event.sequence < rhs.event.sequence
        }
        let end = steps.last?.offset ?? 0
        return DemoScript(steps: steps, duration: end + 6, seed: seed)
    }

    private init(steps: [Step], duration: TimeInterval, seed: UInt64) {
        self.steps = steps
        self.duration = duration
        self.seed = seed
    }

    /// The cast, run `scale` times over.
    ///
    /// The demo is twelve sessions in five projects, which is a good board and
    /// a small one. The pathology this exists for only shows at the size a real
    /// machine reaches — the report that prompted it had eighty-one live
    /// sessions and a hundred and forty-three rows in the sidebar — and the one
    /// place that size can be reached without reading somebody's store is here.
    ///
    /// Every copy is *distinct* in the three ways that matter, or it would not
    /// reproduce anything: a repeated session id folds back into one card in
    /// the registry, a shared directory piles twelve copies under one project
    /// row, and a repeated pid makes twelve sessions look like one process.
    ///
    /// Copy zero is the script as written, so `--demo-scale 1` and no flag at
    /// all are the same board — which is what keeps every screenshot, every
    /// offscreen render and every test that asserts on the demo unaffected by
    /// this existing.
    static func scaledBlueprints(_ scale: Int) -> [Blueprint] {
        guard scale > 1 else { return Blueprint.all }
        return (0..<scale).flatMap { copy in Blueprint.all.map { $0.copy(copy) } }
    }

    /// The session keys the script uses, for a host that wants to pre-select
    /// one or assert on the board it produced.
    public static var sessionKeys: [SessionKey] {
        Blueprint.all.map(\.key)
    }

    /// How long one of these sessions may claim to be working without saying
    /// anything before it counts as stale.
    ///
    /// Not the reducer's ninety seconds, and deliberately so. The demo
    /// compresses a working day into two minutes: a build that would take ten
    /// takes twenty-two, a subagent lives half a minute, a session is
    /// forgotten about and remembered inside one loop. Staleness means
    /// "silent for longer than the work should have taken", and against a
    /// clock running fifty times fast the real threshold can never fire — so a
    /// still of the demo could never show a state the scene draws. This is the
    /// same rule in the same proportion.
    public static let staleAfter: TimeInterval = 13

    /// The sessions the demo's imaginary reader has not opened yet.
    ///
    /// The one fact about a board that no harness on the machine holds is
    /// whether a person has *looked*. Everything else in this script is
    /// derivable from events; this is not, so the demo has to state it.
    ///
    /// It drives the faint reply dot and nothing else. What a *bucket* is made
    /// of is something an agent said out loud, and the demo says those in
    /// ``DemoTaskLedger`` — a `blocked` call and a `done` receipt — because
    /// that is where a real board's two loud buckets come from too.
    ///
    /// Session 8, deliberately: it closes a turn and stays open in the editor,
    /// which is the shape the dot is about. An ended session is in the
    /// collapsed fold, where a dot would be decoration.
    public static var unreadSessionKeys: [SessionKey] {
        [SessionKey(harness: .cursor, sessionID: "e07c4a91b2d8635f")]
    }

    /// What the demo's agents have said out loud, as of `now`.
    ///
    /// The two loud buckets on a real board are made of explicit signals —
    /// `auspex.notify`, a permission hook, a harness's own wait — and never of
    /// an inference. So the demo says them out loud too, and one list serves
    /// both the running app (``DemoTaskLedger`` writes these into its
    /// in-memory ledger) and the headless renderers, which have no store to
    /// read and would otherwise have to fabricate a second, divergent board.
    ///
    /// `blocked` rather than `needs_input` for the call, and that is the
    /// clearing rule working rather than a preference: a demo replays a
    /// scripted conversation on a loop, so every session is about to receive
    /// another prompt — and any notice is answered by the person talking to
    /// that session again. It would clear itself within seconds of the demo
    /// starting, which is correct and would make for a demo of nothing. A
    /// blocker is about the world rather than about the conversation.
    /// How far into a loop the demo's notices are recorded.
    ///
    /// After every scripted session has received its live prompt, and for the
    /// reason a real board has: a call is cleared by the person talking to
    /// that session again, so a notice filed *before* the loop's prompts would
    /// answer itself within seconds and the demo would show an empty header.
    public static let noticeOffset: TimeInterval = 8

    public static func notices(now: Date) -> [SessionKey: AgentNotice] {
        let keys = sessionKeys
        var notices: [SessionKey: AgentNotice] = [:]
        if keys.count > 4 {
            notices[keys[4]] = AgentNotice(
                session: keys[4],
                kind: .blocked,
                message:
                    "Two step enums disagree about status 9. "
                    + "Ship the partial decode, or keep digging?",
                createdAt: now.addingTimeInterval(-2)
            )
        }
        // Session 6 closes its turn and exits a few seconds later, which is
        // exactly the case a receipt has to survive: the process going away
        // does not un-finish the work, or un-write the line somebody still has
        // to read.
        if keys.count > 5 {
            notices[keys[5]] = AgentNotice(
                session: keys[5],
                kind: .done,
                message:
                    "Fixed the three-way split: the remainder is distributed, not truncated.",
                createdAt: now.addingTimeInterval(-2)
            )
        }
        return notices
    }

    /// What the reader has looked at, as of `now`: everything except
    /// ``unreadSessionKeys``.
    public static func seenAt(now: Date) -> [SessionKey: Date] {
        let unread = Set(unreadSessionKeys)
        var seen: [SessionKey: Date] = [:]
        for key in sessionKeys where !unread.contains(key) { seen[key] = now }
        return seen
    }
}

// MARK: - Beats

extension DemoScript {
    /// One thing a synthetic session does. The blueprint is a list of these;
    /// ``Writer`` turns them into events with plausible gaps between them.
    enum Beat: Sendable {
        /// A person asks for something. Opens a turn.
        case prompt(String)
        /// The model reasons for roughly this long.
        case think(TimeInterval)
        /// The model says something.
        case say(String)
        /// A tool runs and succeeds.
        case tool(String, ToolKind, String?, TimeInterval)
        /// A tool runs and fails.
        case toolFails(String, ToolKind, String?, TimeInterval)
        /// A file is written — the state the board calls out separately.
        case write(String, TimeInterval)
        /// A child session runs to completion while the parent waits.
        case delegate(String, String, TimeInterval)
        /// Several children run at once while the parent waits for all of
        /// them, arriving a beat apart and leaving a beat apart.
        ///
        /// Separate from ``delegate(_:_:_:)`` because two of those in a row is
        /// two delegations, not one with two children: the second child would
        /// start after the first had already finished, and a board showing a
        /// family of three would never once be drawn. Fanning out is what
        /// delegation actually looks like, and it is what the meeting room was
        /// built to show.
        case delegateMany([String], String, TimeInterval)
        /// A permission prompt sits unanswered for this long, then resolves.
        /// The tool is `nil` where the harness reports only that a person is
        /// needed — Grok Bot's roster carries a flag and no tool name.
        case permission(String?, TimeInterval, Bool)
        /// Tokens are billed.
        case usage(Int, Int, Int)
        /// The harness records how full its context window is: tokens used,
        /// the window, and whether it wrote the window down itself.
        ///
        /// Separate from ``usage(_:_:_:)`` because they are different kinds of
        /// number and the board draws them differently — one is a running
        /// total and one is a level. Codex and Grok write the window into
        /// their logs; Claude Code does not, so a Claude beat is `derived` and
        /// the card draws its gauge as an estimate.
        case context(used: Int, window: Int?, derived: Bool)
        /// The harness compacts its own context.
        case compact
        /// The harness records the plan window it is billing against, and how
        /// long until it rolls over. Codex is the only one that does.
        case quota(percent: Double, resetsIn: TimeInterval?, plan: String?)
        /// The turn closes.
        case endTurn
        /// Nothing happens.
        case idle(TimeInterval)
        /// The session exits.
        case end(SessionEndReason)
    }

    /// A synthetic session: who it is, and what it does.
    struct Blueprint: Sendable {
        let harness: Harness
        let sessionID: String
        /// `nil` for a harness whose store records no working directory. Grok
        /// Bot is the only one: its conversations run on xAI's servers, and a
        /// demo that gave it a plausible `/Users/example` path would be
        /// demonstrating a grouping the real adapter can never produce.
        let cwd: String?
        let gitRoot: String?
        let branch: String?
        let title: String
        /// `nil` where the store genuinely does not record which model
        /// answered.
        let model: String?
        /// `nil` where the work did not happen in a process on this Mac.
        let pid: pid_t?
        let entrypoint: String
        let variant: String?
        /// Emitted inside the first half second, so the board opens populated.
        let prologue: [Beat]
        /// Emitted at real-time gaps.
        let live: [Beat]
        /// How long to wait before the live beats begin. Staggering is what
        /// keeps eight sessions from changing state in lockstep.
        let startDelay: TimeInterval

        var key: SessionKey {
            SessionKey(harness: harness, sessionID: sessionID)
        }

        var sourcePath: String {
            switch harness {
            case .claudeCode:
                "/Users/example/.claude/projects/\(projectSlug)/\(sessionID).jsonl"
            case .claudeCowork:
                // Claude.app's own container, one throwaway workspace per run.
                "/Users/example/Library/Application Support/Claude/local-agent-mode-sessions"
                    + "/w1/a/local_\(sessionID)/.claude/projects/\(projectSlug)/\(sessionID).jsonl"
            case .codex, .chatgptWork:
                "/Users/example/.codex/sessions/2026/08/19/rollout-\(sessionID).jsonl"
            case .cursor:
                "/Users/example/.cursor/chats/\(sessionID)/store.db"
            case .grokBuild:
                "/Users/example/.grok/sessions/\(sessionID)/updates.jsonl"
            case .antigravity, .geminiCLI:
                "/Users/example/.gemini/antigravity/conversations/\(sessionID).json"
            case .grokBot:
                "/Users/example/Library/Application Support/Grok Bot"
                    + "/sand-client-persistence/\(sessionID).blob"
            }
        }

        /// Only ever read by the Claude source paths, which belong to a
        /// harness that always has a directory. The fallback exists so the
        /// property stays total rather than because anything reaches it.
        private var projectSlug: String {
            guard let path = gitRoot ?? cwd else { return sessionID }
            return BoardGrouping.projectName(forPath: path)
        }

        /// The same session again, as somebody else — see
        /// ``DemoScript/scaledBlueprints(_:)``.
        ///
        /// Copy `0` is the blueprint itself, unchanged. Every other copy gets a
        /// session id, a directory and a pid of its own, and its children get
        /// ids of their own too — a delegation whose child kept the original's
        /// id would put one subagent under twelve different parents.
        ///
        /// The id keeps its *shape*: only the last three characters are
        /// replaced, so a UUID stays a UUID and `conv:2026-08-19:4d81a0` stays
        /// a conversation id. A scaled board has to look like a board, because
        /// the whole point of it is to be looked at.
        func copy(_ index: Int) -> DemoScript.Blueprint {
            guard index > 0 else { return self }
            let tag = String(format: "%03x", index & 0xFFF)
            func distinct(_ id: String) -> String {
                guard id.count > 3 else { return id + tag }
                return String(id.dropLast(3)) + tag
            }
            func elsewhere(_ path: String?) -> String? {
                path.map { $0 + "-" + tag }
            }
            func rewritten(_ beats: [DemoScript.Beat]) -> [DemoScript.Beat] {
                beats.map { beat in
                    switch beat {
                    case .delegate(let child, let agentType, let seconds):
                        .delegate(distinct(child), agentType, seconds)
                    case .delegateMany(let children, let agentType, let seconds):
                        .delegateMany(children.map(distinct), agentType, seconds)
                    default:
                        beat
                    }
                }
            }
            return DemoScript.Blueprint(
                harness: harness,
                sessionID: distinct(sessionID),
                cwd: elsewhere(cwd),
                gitRoot: elsewhere(gitRoot),
                branch: branch,
                title: "\(title) \(index + 1)",
                model: model,
                pid: pid.map { $0 &+ pid_t(index &* 100) },
                entrypoint: entrypoint,
                variant: variant,
                prologue: rewritten(prologue),
                live: rewritten(live),
                // Spread over the same second the original starts in. Twelve
                // copies opening in lockstep would produce a board that
                // changes state all at once, which is an animation rather than
                // the readout the load is supposed to be measured against.
                startDelay: startDelay + Double(index % 16) * 0.11
            )
        }
    }
}

// MARK: - The cast

extension DemoScript.Blueprint {
    /// The fourteen sessions the demo board shows.
    ///
    /// Chosen to cover all eight featured harnesses, every state the card can
    /// be in, both grouping axes (five directories, two of them shared by
    /// different harnesses, plus the one pseudo project), both kinds of
    /// parent/child pair — one the parent's own log recorded (1 → its
    /// subagent) and one only an identity records (12 → 2) — and both shapes
    /// of *done unseen*: one session that closed a turn and exited (6), and
    /// one that closed a turn and is still sitting open (8).
    ///
    /// Two of them are about placement rather than about a state. 13 runs in
    /// the Codex desktop's own per-thread scratch, which is a directory that
    /// is not a project; 14 is an AntiGravity command line, whose workspace
    /// and model exist only in the side files the CLI writes beside its
    /// conversation database. Both used to land under "No project".
    ///
    /// Every blueprint opens with a real instruction and answers with real
    /// prose, because that is what the board's ledger lines draw: a demo whose
    /// prompts were placeholders would screenshot as a board with two empty
    /// rows on every card.
    ///
    /// Claude Cowork, ChatGPT Work, and Grok Bot are here for a reason beyond
    /// coverage: each shares a vendor mark with a sibling, so a demo board
    /// that omitted them would never show whether the accent and the full
    /// name are enough to tell one Claude — or one xAI — row from another.
    static let all: [DemoScript.Blueprint] = [
        // 1. The long-running one: tools, a subagent, then a permission wall.
        DemoScript.Blueprint(
            harness: .claudeCode,
            sessionID: "3f2a1c88-4b6d-4e21-9a7c-0d51e8b23a94",
            cwd: "/Users/example/Code/auspex",
            gitRoot: "/Users/example/Code/auspex",
            branch: "feat/board-ui",
            title: "Build the live board",
            model: "claude-opus-5",
            pid: 41_207,
            entrypoint: "terminal",
            variant: "cli",
            prologue: [
                .prompt("Wire the board to the registry and give the cards a real design"),
                .think(1.2),
                .tool("Read", .fileRead, "Sources/AuspexCore/Registry/SessionRegistry.swift", 0.6),
                .tool("Grep", .search, "boardSnapshots", 0.3),
                // A failure in the compressed history, so the board opens with
                // one red row in it: a session whose past is all green is not
                // what anybody's afternoon looks like, and it leaves the one
                // colour that means "look here" untested in every screenshot.
                .toolFails("Bash", .shell, "swift build 2>&1 | tail -20", 0.9),
                .say("The registry's frame stream is single-consumer, so the board has to be its one reader."),
                .usage(48_210, 3_140, 31_800),
                // Claude Code writes the counters and not the window, so this
                // gauge is the `derived` one: the card draws its remainder
                // dotted and the popover says which half was looked up.
                .context(used: 96_400, window: 200_000, derived: true),
                .endTurn
            ],
            live: [
                .prompt("Now add the trace inspector"),
                .think(2.5),
                .tool("Read", .fileRead, "Sources/AuspexCore/Store/SessionRepository.swift", 3.0),
                .write("Sources/AuspexApp/Trace/SessionTraceView.swift", 6.0),
                // Two at once, not one after the other: a fan-out is what
                // delegation actually looks like, and a family of three is
                // what the meeting room was built to seat.
                .delegateMany(
                    [
                        "9c4e7b10-22af-4d33-8f61-77ac0e5d1b42",
                        "1d83f5a6-90bc-4e77-a215-46f0c9d31e28"
                    ],
                    "explore",
                    22.0
                ),
                .say("The inspector needs the tool-call ledger to pair starts with finishes."),
                .permission("Bash", 26.0, true),
                .tool("Bash", .shell, "swift build 2>&1 | tail -20", 9.0),
                .usage(62_900, 5_480, 44_100),
                // Past ninety per cent: the top of the ramp, and the one board
                // state that means "finish the thought before it forgets".
                // A long session that has compacted once and is filling up
                // again is what the gauge exists to make visible.
                .compact,
                .context(used: 184_600, window: 200_000, derived: true),
                .endTurn,
                .idle(8.0)
            ],
            startDelay: 1.0
        ),

        // 2. Codex grinding through a build. Mostly one very long shell call.
        DemoScript.Blueprint(
            harness: .codex,
            sessionID: "0198f4c2-77bd-7a10-b3e9-5c2d84f10ab6",
            cwd: "/Users/example/Code/auspex",
            gitRoot: "/Users/example/Code/auspex",
            branch: "feat/codex-adapter",
            title: "Codex rollout adapter",
            model: "gpt-5.6-terra",
            pid: 41_882,
            entrypoint: "terminal",
            variant: "codex_cli_rs",
            prologue: [
                .prompt("Tail ~/.codex/sessions rollouts and emit AgentEvents"),
                .think(0.9),
                .tool("shell", .shell, "ls ~/.codex/sessions", 0.4),
                .usage(21_400, 1_890, 12_000),
                // Codex writes `model_context_window` into every token_count,
                // so this gauge is measured: a solid bed, no dotted remainder,
                // and a popover with nothing to hedge.
                .context(used: 33_400, window: 272_000, derived: false),
                .quota(percent: 31.0, resetsIn: 12_600, plan: "pro"),
                .endTurn
            ],
            live: [
                .prompt("Run the suite"),
                .think(1.4),
                .tool("shell", .shell, "swift test --filter CodexAdapter", 22.0),
                .write("Sources/AgentSessionLive/Adapters/Codex/CodexTailer.swift", 5.0),
                .toolFails("shell", .shell, "swift test --filter CodexAdapter", 11.0),
                .say("One rollout fixture has a null timestamp; guarding it."),
                .write("Tests/CodexAdapterTests/RolloutFixtures.swift", 4.0),
                .tool("shell", .shell, "swift test --filter CodexAdapter", 13.0),
                .usage(33_050, 4_120, 18_600),
                // Three quarters of the way in: the middle band of the ramp,
                // which is the one that says "not now, but soon".
                .context(used: 201_500, window: 272_000, derived: false),
                .quota(percent: 43.2, resetsIn: 7_800, plan: "pro"),
                .endTurn,
                .idle(6.0)
            ],
            startDelay: 0.4
        ),

        // 3. Cursor, editing steadily. The writingFile state, mostly.
        DemoScript.Blueprint(
            harness: .cursor,
            sessionID: "b8d31f0a4c7e2916",
            cwd: "/Users/example/Code/storefront-web",
            gitRoot: "/Users/example/Code/storefront-web",
            branch: "feat/checkout-v2",
            title: "Checkout step indicator",
            model: "composer-2",
            pid: 38_140,
            entrypoint: "ide",
            variant: nil,
            prologue: [
                .prompt("Extract the checkout stepper into its own component"),
                .think(0.8),
                .write("src/components/CheckoutStepper.tsx", 0.5),
                .usage(12_800, 2_240, 4_100),
                .endTurn
            ],
            live: [
                .prompt("Make step 3 announce itself to screen readers"),
                .think(1.8),
                .write("src/components/CheckoutStepper.tsx", 9.0),
                .write("src/components/CheckoutStepper.test.tsx", 7.0),
                .tool("run_terminal_cmd", .shell, "pnpm vitest run checkout", 12.0),
                .say("Added aria-current and a visually hidden live region."),
                .usage(18_400, 3_010, 6_800),
                .endTurn,
                .idle(14.0)
            ],
            startDelay: 2.2
        ),

        // 4. Grok Build, blocked almost immediately. The red card.
        DemoScript.Blueprint(
            harness: .grokBuild,
            sessionID: "sess_7hq2mv4k9x",
            cwd: "/Users/example/Code/ingest-pipeline",
            gitRoot: "/Users/example/Code/ingest-pipeline",
            branch: "main",
            title: "Backfill the events table",
            model: "grok-4.6",
            pid: 39_551,
            entrypoint: "terminal",
            variant: nil,
            prologue: [
                .prompt("Backfill observed_at for every event written before the migration"),
                .think(1.1),
                .tool("read_file", .fileRead, "migrations/007_observed_at.sql", 0.4),
                .usage(9_600, 1_120, 2_400),
                // Grok computes its own gauge and writes both halves into
                // `signals.json`. Barely into a half-million-token window:
                // the bottom band of the ramp, where most sessions live.
                .context(used: 61_300, window: 500_000, derived: false),
                .endTurn
            ],
            live: [
                .prompt("Go ahead and run it against the local database"),
                .think(1.6),
                .permission("execute_command", 34.0, false),
                .say("Holding — that would rewrite 1.2M rows in place. Writing a dry run instead."),
                .write("scripts/backfill_dry_run.py", 6.0),
                .tool("execute_command", .shell, "python scripts/backfill_dry_run.py", 8.0),
                .usage(14_200, 2_650, 3_900),
                .endTurn,
                .idle(10.0)
            ],
            startDelay: 1.6
        ),

        // 5. AntiGravity, searching the web and reading widely.
        DemoScript.Blueprint(
            harness: .antigravity,
            sessionID: "conv:2026-08-19:4d81a0",
            cwd: "/Users/example/Code/mobile-client",
            gitRoot: "/Users/example/Code/mobile-client",
            branch: "chore/deps",
            title: "Audit the dependency tree",
            model: "gemini-3.7-flash",
            pid: 37_006,
            entrypoint: "ide",
            variant: "ide",
            prologue: [
                .prompt("Which of our direct dependencies have known advisories?"),
                .think(1.0),
                .tool("search_web", .web, "swift-nio advisories 2026", 0.6),
                .endTurn
            ],
            live: [
                .prompt("Check the transitive ones too"),
                .think(2.2),
                .tool("read_resource", .mcp, "sbom://mobile-client/latest", 5.0),
                .tool("search_web", .web, "grpc-swift CVE 2026", 7.0),
                .tool("grep_search", .search, "Package.resolved", 2.5),
                .say("Two transitive packages are behind; neither has an advisory."),
                .usage(28_700, 6_310, 9_200),
                .endTurn,
                .idle(16.0)
            ],
            startDelay: 3.0
        ),

        // 6. A second Claude Code session in a different project, ending mid-loop.
        DemoScript.Blueprint(
            harness: .claudeCode,
            sessionID: "7a1b9d43-5e02-4c8f-b6d1-3e90f2a71c55",
            cwd: "/Users/example/Code/storefront-web",
            gitRoot: "/Users/example/Code/storefront-web",
            branch: "fix/cart-total",
            title: "Cart total rounds down",
            model: "claude-sonnet-5",
            pid: 40_310,
            entrypoint: "terminal",
            variant: "cli",
            prologue: [
                .prompt("The cart total is a cent short when a line item has a 3-way split"),
                .think(1.3),
                .tool("Grep", .search, "roundingMode", 0.5),
                .write("src/lib/money.ts", 0.6),
                .tool("Bash", .shell, "pnpm vitest run money", 0.7),
                .usage(16_900, 2_480, 7_700),
                .endTurn
            ],
            live: [
                .say("Fixed: the split was truncating instead of distributing the remainder."),
                // The turn closes *before* the session does, which is what
                // makes this the board's `done unseen` card: something
                // finished, nobody has read it, and the process going away
                // afterwards does not change either fact.
                .endTurn,
                .idle(9.0),
                .end(.exited)
            ],
            startDelay: 0.8
        ),

        // 7. Codex on infrastructure, killed part way through.
        DemoScript.Blueprint(
            harness: .codex,
            sessionID: "0198f4d1-1c33-7b52-9e08-6a4f2b7c1d09",
            cwd: "/Users/example/Code/infra-terraform",
            gitRoot: nil,
            branch: "main",
            title: "Plan the staging cluster",
            model: "gpt-5.6-luna",
            pid: 36_774,
            entrypoint: "terminal",
            variant: "codex_exec",
            prologue: [
                .prompt("terraform plan for staging, summarise the destructive changes"),
                .think(1.0),
                .tool("shell", .shell, "terraform plan -out=staging.tfplan", 0.9),
                .endTurn
            ],
            live: [
                .think(3.0),
                .tool("shell", .shell, "terraform show -json staging.tfplan", 5.0),
                .idle(4.0),
                .end(.killed)
            ],
            startDelay: 2.8
        ),

        // 8. Cursor, idle the whole loop. Every wall has one — and for the
        //    first forty-eight seconds it is also the ledger's other shape:
        //    a session that is still open in the editor, closed its turn, and
        //    is sitting there waiting to be read. Idle, not ended, and unseen.
        DemoScript.Blueprint(
            harness: .cursor,
            sessionID: "e07c4a91b2d8635f",
            cwd: "/Users/example/Code/design-tokens",
            gitRoot: "/Users/example/Code/design-tokens",
            branch: "main",
            title: "Token naming pass",
            model: "composer-2",
            pid: 35_902,
            entrypoint: "ide",
            variant: nil,
            prologue: [
                .prompt("Rename the surface tokens to match the new scale"),
                .think(0.7),
                .write("tokens/color.json", 0.5),
                .say("Renamed 24 tokens and updated the two usages outside the package."),
                .usage(7_400, 1_180, 2_050),
                .endTurn
            ],
            live: [
                .idle(48.0),
                .prompt("One more: fold the elevation tokens in"),
                .think(2.0),
                .write("tokens/elevation.json", 5.0),
                .endTurn
            ],
            startDelay: 0.2
        ),

        // 9. Claude Cowork: a background run Claude.app started for itself, in
        //    a directory that is not a checkout. Same mark as Claude Code,
        //    different accent, different store.
        DemoScript.Blueprint(
            harness: .claudeCowork,
            sessionID: "c41d7e69-8a05-4b12-9f37-2e6b8d40a913",
            cwd: "/Users/example/Documents/ops-runbook",
            gitRoot: nil,
            branch: "main",
            title: "Reconcile the on-call runbook",
            model: "claude-opus-5",
            pid: 42_615,
            entrypoint: "claude-app",
            variant: nil,
            prologue: [
                .prompt("Read the runbook and list every step that names a person rather than a rota"),
                .think(1.1),
                .tool("Read", .fileRead, "runbook/on-call.md", 0.5),
                .usage(11_300, 1_640, 5_200),
                .endTurn
            ],
            live: [
                .prompt("Rewrite those steps against the rota, and keep the wording"),
                .think(2.1),
                .write("runbook/on-call.md", 7.0),
                .tool("Read", .fileRead, "runbook/escalation.md", 3.0),
                .say("Four steps named an individual. All four now point at the rota."),
                .usage(19_800, 3_920, 8_400),
                .endTurn,
                .idle(12.0)
            ],
            startDelay: 1.3
        ),

        // 10. ChatGPT Work: the desktop app's Work mode. Same rollout tree as
        //     Codex, same OpenAI mark, told apart by the accent and the name.
        DemoScript.Blueprint(
            harness: .chatgptWork,
            sessionID: "0198f5a3-64e1-7c09-a2b7-91d3fe0c5482",
            cwd: "/Users/example/Code/storefront-web",
            gitRoot: "/Users/example/Code/storefront-web",
            branch: "chore/analytics-schema",
            title: "Reconcile the analytics schema",
            model: "gpt-5.6-sol",
            pid: 43_128,
            entrypoint: "desktop",
            variant: "codex_work_desktop",
            prologue: [
                .prompt("Compare the event schema in the docs with the one the client emits"),
                .think(1.4),
                .tool("shell", .shell, "rg -n 'track\\(' src/analytics", 0.6),
                .usage(15_700, 2_050, 6_600),
                .endTurn
            ],
            live: [
                .prompt("Write up the drift and open a checklist"),
                .think(2.6),
                .tool("read_resource", .mcp, "schema://storefront/events", 6.0),
                .write("docs/analytics-drift.md", 8.0),
                .say("Six events carry properties the schema does not declare."),
                .permission("shell", 18.0, true),
                .tool("shell", .shell, "pnpm analytics:validate", 10.0),
                .usage(26_400, 4_760, 11_900),
                .endTurn,
                .idle(9.0)
            ],
            startDelay: 2.0
        ),

        // 11. Grok Bot: a cloud bot, and the only session on the board with
        //     no directory of its own. No tools, no model, no tokens, no pid —
        //     the run happened on xAI's servers and the desktop client only
        //     replicated the conversation. It is here to prove two things a
        //     screenshot should show: that a harness with no project still
        //     gets a section of its own rather than the residue, and that a
        //     *needs you* with no tool name renders.
        DemoScript.Blueprint(
            harness: .grokBot,
            sessionID: "7c1f8ad4-5b02-4e77-9d38-2ab6014ef905",
            cwd: nil,
            gitRoot: nil,
            branch: nil,
            title: "Release Scout",
            model: nil,
            pid: nil,
            entrypoint: "desktop",
            variant: "bot",
            prologue: [
                .prompt("Watch the release feed and tell me when the changelog stops matching it"),
                .think(1.6),
                .say("Watching. I will check the feed every hour and flag anything undocumented."),
                .endTurn
            ],
            live: [
                .prompt("What did you find this morning?"),
                .think(3.2),
                .say("Three releases shipped and two of them are not in the changelog."),
                .think(1.4),
                .say("One is a behaviour change, so I would rather you decided how to word it."),
                // The roster's `awaitingUserResponse`: the client says a
                // person is needed and never says what for.
                .permission(nil, 22.0, true),
                .say("Filed under the release notes, in your wording."),
                .endTurn,
                .idle(11.0)
            ],
            startDelay: 2.6
        ),

        // 12. Codex Auto Review: the guardian rollout that reviews session 2's
        //     work. Nothing in either rollout's body mentions the other — the
        //     only record of the relationship is this session's provider
        //     variant, `auto-review:<root session id>`, so it is deliberately
        //     emitted with *no* parent in its identity and left for
        //     `SessionRelations` to fold. A demo that hard-coded the edge would
        //     be a picture of the feature rather than a test of it.
        DemoScript.Blueprint(
            harness: .codex,
            sessionID: "0198f6d0-11ac-7e54-8b26-3ad70f9c1e83",
            cwd: "/Users/example/Code/auspex",
            gitRoot: "/Users/example/Code/auspex",
            branch: "feat/codex-adapter",
            title: "Review the rollout adapter",
            // The runtime Codex bills a guardian pass against, and half of
            // what the kit matches on to recognise one.
            model: "codex-auto-review",
            // A guardian run holds no writer lock of its own, so nothing
            // attributes a process to it — the same shape the real adapter
            // produces.
            pid: nil,
            entrypoint: "subagent",
            variant: "auto-review:0198f4c2-77bd-7a10-b3e9-5c2d84f10ab6",
            prologue: [
                .prompt("Review the changes on feat/codex-adapter before they land"),
                .think(1.1),
                .tool("shell", .shell, "git diff --stat origin/main...", 0.5),
                .usage(9_600, 1_120, 5_200),
                .endTurn
            ],
            live: [
                .prompt("Check the fixture guard too"),
                .think(2.2),
                .tool("shell", .shell, "git diff -- Tests/CodexAdapterTests", 7.0),
                .say("The null-timestamp guard is right, but it swallows a malformed date too."),
                .usage(14_300, 1_980, 7_400),
                .endTurn,
                .idle(12.0)
            ],
            startDelay: 1.6
        ),

        // 13. A Codex desktop thread, running where the desktop app put it:
        //     `~/Documents/Codex/<date>/<name>`, a folder made for this one
        //     conversation. It has a directory and it is not a project, which
        //     is the whole of what this session is on the board to show — it
        //     belongs under "Codex · scratch" with `zhe` on its card, not
        //     under a project called `zhe` that will mean nothing tomorrow.
        DemoScript.Blueprint(
            harness: .codex,
            sessionID: "0198f7b4-2ce9-7f31-84ad-6b0c7e2915df",
            cwd: "/Users/example/Documents/Codex/2026-08-19/zhe",
            gitRoot: nil,
            branch: nil,
            title: "Work out the retry backoff",
            model: "gpt-5.6-sol",
            pid: 44_902,
            entrypoint: "desktop",
            variant: "codex_desktop",
            prologue: [
                .prompt("What backoff should a queue use when the downstream is rate limiting?"),
                .think(1.2),
                .say("Exponential with full jitter, capped — I will work the numbers."),
                .endTurn
            ],
            live: [
                .prompt("Show me what that looks like at 200 requests a second"),
                .think(2.4),
                .write("backoff.py", 5.0),
                .tool("shell", .shell, "python backoff.py --rps 200", 6.0),
                .say("Full jitter settles in four retries; the capped variant takes seven."),
                .usage(11_400, 1_640, 3_800),
                .endTurn,
                .idle(14.0)
            ],
            startDelay: 2.2
        ),

        // 14. AntiGravity's command line, which records neither its workspace
        //     nor its model in the conversation database — both come from the
        //     side files the CLI writes beside it. Before the kit read those,
        //     every session like this one sat under "No project" with a blank
        //     where the model goes; it is here so a screenshot shows the
        //     difference rather than a release note claiming it.
        DemoScript.Blueprint(
            harness: .antigravity,
            sessionID: "conv:2026-08-19:9f30c1",
            cwd: "/Users/example/Code/ingest-pipeline",
            gitRoot: "/Users/example/Code/ingest-pipeline",
            branch: "main",
            title: "Summarise last night's ingest failures",
            model: "gemini-3.7-flash",
            pid: 45_118,
            entrypoint: "terminal",
            variant: "cli",
            prologue: [
                .prompt("Group last night's ingest failures by cause"),
                .think(1.4),
                .tool("run_command", .shell, "jq -r .cause logs/ingest-*.jsonl | sort | uniq -c", 0.7),
                .endTurn
            ],
            live: [
                .prompt("Which of those are new since Friday?"),
                .think(2.0),
                .tool("grep_search", .search, "TimeoutError", 4.5),
                .say("Two causes are new, and both are the same upstream host timing out."),
                .usage(16_900, 2_480, 5_100),
                .endTurn,
                .idle(9.0)
            ],
            startDelay: 3.4
        )
    ]
}

// MARK: - Compilation

extension DemoScript {
    /// Turns one blueprint's beats into events.
    ///
    /// A struct rather than a function because compiling a beat needs a
    /// running offset, a sequence number, a byte offset into the pretend
    /// transcript, and the random generator — and threading five inout
    /// parameters through a dozen call sites is worse than owning them.
    private struct Writer {
        let blueprint: Blueprint
        let startedAt: Date
        let generation: Int
        var rng: SeededRandom
        var steps: [Step] = []

        private var offset: TimeInterval = 0
        private var sequence: Int64 = 0
        private var byteOffset: Int64 = 4_096
        private var callIndex = 0
        private var permissionIndex = 0
        /// Compressed prologue timing: history lands in the first half second.
        private var isPrologue = true

        init(blueprint: Blueprint, startedAt: Date, generation: Int, rng: SeededRandom) {
            self.blueprint = blueprint
            self.startedAt = startedAt
            self.generation = generation
            self.rng = rng
        }

        mutating func compile() {
            emit(.sessionStarted(identity: identity))
            for beat in blueprint.prologue { compile(beat) }
            isPrologue = false
            offset = blueprint.startDelay
            for beat in blueprint.live { compile(beat) }
        }

        private var identity: SessionIdentity {
            SessionIdentity(
                key: blueprint.key,
                sourcePath: blueprint.sourcePath,
                variant: blueprint.variant,
                cwd: blueprint.cwd,
                gitRoot: blueprint.gitRoot,
                gitBranch: blueprint.branch,
                pid: blueprint.pid,
                procStart: startedAt.addingTimeInterval(-1_800),
                title: blueprint.title,
                model: blueprint.model,
                entrypoint: blueprint.entrypoint
            )
        }

        private mutating func compile(_ beat: Beat) {
            switch beat {
            case .prompt(let text):
                emit(.turnStarted)
                advance(0.05)
                emit(.userPrompt(preview: preview(text)))
                emit(.textBody(role: .user, text: text, toolCallID: nil))

            case .think(let seconds):
                emit(.thinking)
                advance(seconds)

            case .say(let text):
                emit(.assistantText(preview: preview(text)))
                emit(.textBody(role: .assistant, text: text, toolCallID: nil))
                advance(0.4)

            case .tool(let name, let kind, let target, let seconds):
                runTool(name: name, kind: kind, target: target, seconds: seconds, fails: false)

            case .toolFails(let name, let kind, let target, let seconds):
                runTool(name: name, kind: kind, target: target, seconds: seconds, fails: true)

            case .write(let path, let seconds):
                runTool(
                    name: writeToolName,
                    kind: .fileWrite,
                    target: path,
                    seconds: seconds,
                    fails: false
                )

            case .delegate(let childID, let agentType, let seconds):
                compileDelegation(childIDs: [childID], agentType: agentType, seconds: seconds)

            case .delegateMany(let childIDs, let agentType, let seconds):
                compileDelegation(childIDs: childIDs, agentType: agentType, seconds: seconds)

            case .permission(let tool, let seconds, let allowed):
                permissionIndex += 1
                let id = "perm-\(generation)-\(permissionIndex)"
                emit(.permissionRequested(id: id, tool: tool))
                advance(seconds)
                emit(.permissionResolved(id: id, allowed: allowed))
                advance(0.3)

            case .usage(let input, let output, let cached):
                emit(.usage(
                    model: blueprint.model,
                    inputTokens: input + jitter(upTo: 400),
                    outputTokens: output + jitter(upTo: 120),
                    cachedTokens: cached
                ))

            case .context(let used, let window, let derived):
                // No jitter, unlike `.usage`. A fill is a *level*, and the
                // demo's percentages are chosen to land one session in each
                // band of the ramp — a random nudge would move a screenshot
                // across a threshold. It would also draw from the script's
                // shared generator, which every other beat's jitter and delay
                // is downstream of.
                emit(.contextUsage(
                    used: used,
                    window: window,
                    cached: nil,
                    source: derived ? .derived : .measured
                ))

            case .compact:
                // No `advance`, deliberately. A compaction is one line the
                // harness writes between two others, and the beats around it
                // already carry the time — while `advance` draws from the
                // script's shared generator, which every later session's
                // timing is downstream of. A new beat must not move somebody
                // else's clock.
                emit(.compaction)

            case .quota(let percent, let resetsIn, let plan):
                emit(.quota(
                    usedPercent: percent,
                    resetsAt: resetsIn.map { startedAt.addingTimeInterval(offset + $0) },
                    plan: plan
                ))

            case .endTurn:
                emit(.turnEnded(reason: .complete))
                advance(0.4)

            case .idle(let seconds):
                advance(seconds)

            case .end(let reason):
                emit(.sessionEnded(reason: reason))
                advance(0.5)
            }
        }

        /// The tool a harness uses to change a file, as that harness spells it.
        private var writeToolName: String {
            switch blueprint.harness {
            case .claudeCode, .claudeCowork: "Edit"
            case .codex, .chatgptWork: "apply_patch"
            case .cursor: "edit_file"
            case .grokBuild: "write_file"
            case .antigravity, .geminiCLI: "replace_file_content"
            // Unreachable: the cloud client's cache records no tool calls at
            // all — the run happened server-side — so no Grok Bot blueprint
            // has a `.write` beat. Named rather than crashed on, because a
            // switch that traps is a switch that ships a trap.
            case .grokBot: "write"
            }
        }

        private mutating func runTool(
            name: String,
            kind: ToolKind,
            target: String?,
            seconds: TimeInterval,
            fails: Bool
        ) {
            callIndex += 1
            let id = "call-\(generation)-\(callIndex)"
            emit(.toolCallStarted(id: id, name: name, kind: kind, target: target))
            advance(seconds)
            // Only failures carry a result body. A harness that logs tool
            // output logs all of it, but a demo that emitted a fabricated
            // paragraph per call would double the length of every trace to
            // show a sentence nobody wrote — and the one result a reader
            // actually needs is the one that explains a red row.
            if fails {
                emit(.textBody(role: .toolResult, text: Self.failure(for: kind), toolCallID: id))
            }
            emit(.toolCallFinished(id: id, isError: fails))
            advance(0.2)
        }

        /// What a failed call said, per kind of tool. Invented, like the rest
        /// of the script, and phrased the way the real thing would be.
        private static func failure(for kind: ToolKind) -> String {
            switch kind {
            case .shell: "exit 1 · 1 test failed, 84 passed"
            case .fileRead: "no such file or directory"
            case .fileWrite: "the file changed on disk after it was read"
            case .search: "the pattern is not valid"
            case .web: "the request timed out"
            case .mcp: "the server returned an error"
            case .subagent: "the child exited before it answered"
            case .plan: "the plan was rejected"
            case .other: "the call returned an error"
            }
        }

        /// Spawns `ids` at once and waits for all of them.
        ///
        /// They arrive a beat apart, work over the same stretch, and leave a
        /// beat apart — which is what a fan-out looks like and what makes a
        /// family of three a thing a still of the board can catch. One id is
        /// the ordinary case and needs no separate path.
        private mutating func compileDelegation(
            childIDs: [String],
            agentType: String,
            seconds: TimeInterval
        ) {
            guard !childIDs.isEmpty else { return }
            var children: [(key: SessionKey, call: String, task: String)] = []

            for (index, childID) in childIDs.enumerated() {
                let child = SessionKey(harness: blueprint.harness, sessionID: childID)
                callIndex += 1
                let toolUseID = "call-\(generation)-\(callIndex)"
                let task = Self.childTasks[index % Self.childTasks.count]
                emit(.subagentStarted(child: child, agentType: agentType, toolUseID: toolUseID))

                // The child's own short life, on the same timeline.
                let childIdentity = SessionIdentity(
                    key: child,
                    sourcePath: blueprint.sourcePath,
                    variant: blueprint.variant,
                    parent: blueprint.key,
                    parentLink: .subagent(toolUseID: toolUseID),
                    cwd: blueprint.cwd,
                    gitRoot: blueprint.gitRoot,
                    gitBranch: blueprint.branch,
                    pid: blueprint.pid.map { $0 + 1 + pid_t(index) },
                    procStart: startedAt,
                    title: task,
                    model: blueprint.model,
                    entrypoint: blueprint.entrypoint
                )
                emit(.sessionStarted(identity: childIdentity), session: child)
                emit(.turnStarted, session: child)
                emit(.userPrompt(preview: task), session: child)
                children.append(
                    (child, "call-\(generation)-child-\(callIndex)", task)
                )
                advance(0.5)
            }

            advance(seconds * 0.2)
            for entry in children {
                emit(
                    .toolCallStarted(
                        id: entry.call, name: "Grep", kind: .search, target: "recentEvents("
                    ),
                    session: entry.key
                )
                advance(0.3)
            }
            advance(seconds * 0.5)

            let tail = seconds * 0.3 / Double(children.count)
            for entry in children {
                emit(.toolCallFinished(id: entry.call, isError: false), session: entry.key)
                emit(
                    .usage(
                        model: blueprint.model,
                        inputTokens: 8_100,
                        outputTokens: 940,
                        cachedTokens: 0
                    ),
                    session: entry.key
                )
                emit(.turnEnded(reason: .complete), session: entry.key)
                emit(.sessionEnded(reason: .exited), session: entry.key)
                emit(.subagentFinished(child: entry.key))
                advance(tail)
            }
            advance(0.3)
        }

        /// What a subagent was sent to find out. One per child, so a family at
        /// a table is three people doing three things rather than one prompt
        /// printed three times.
        private static let childTasks = [
            "Find every call site of recentEvents",
            "Check which adapters still tail synchronously",
            "List the fixtures with no timestamp"
        ]

        // MARK: Primitives

        /// Appends one event at the current offset.
        private mutating func emit(_ kind: AgentEventKind, session: SessionKey? = nil) {
            sequence += 1
            byteOffset += Int64(192 + jitter(upTo: 512))
            let event = AgentEvent(
                id: rng.nextUUID(),
                session: session ?? blueprint.key,
                timestamp: startedAt.addingTimeInterval(offset),
                observedAt: startedAt.addingTimeInterval(offset),
                sequence: sequence,
                kind: kind,
                raw: RawRef(path: blueprint.sourcePath, byteOffset: byteOffset)
            )
            steps.append(Step(offset: offset, event: event))
            // Two events at the same instant are what a real flush looks like,
            // but a trace reads better when they are merely close.
            offset += 0.02
        }

        /// Moves the clock forward by `seconds`, give or take.
        ///
        /// The jitter is what keeps eight sessions from pulsing in unison —
        /// a wall where every card changes state on the same tick looks like
        /// an animation, not a readout.
        private mutating func advance(_ seconds: TimeInterval) {
            guard !isPrologue else {
                // History is compressed: keep the ordering, drop the waiting.
                offset += min(seconds, 0.04)
                return
            }
            let spread = seconds * 0.18
            offset += max(0.05, seconds + Double(jitter(upTo: 200)) / 100.0 * spread / 2)
        }

        private mutating func jitter(upTo bound: Int) -> Int {
            bound <= 0 ? 0 : Int(rng.next() % UInt64(bound))
        }

        /// The short form a state event carries. Adapters cut previews at a
        /// couple of hundred characters; the trace folds the full body back in.
        private func preview(_ text: String) -> String {
            text.count <= 120 ? text : String(text.prefix(119)) + "…"
        }
    }
}

// MARK: - Seeded randomness

/// SplitMix64 — a small, fast, fully specified generator.
///
/// `SystemRandomNumberGenerator` is not reproducible and Swift's standard
/// library ships no seeded generator, so a script that must replay identically
/// from a seed has to bring its own. SplitMix64 is the standard answer: eight
/// lines, no state beyond a `UInt64`, and a fixed algorithm that will not
/// change under us the way a library implementation might.
///
/// Not for anything that needs to be unguessable. This picks how many
/// milliseconds a fake tool call takes.
public struct SeededRandom: RandomNumberGenerator, Sendable {
    private var state: UInt64

    public init(seed: UInt64) {
        self.state = seed
    }

    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// A UUID drawn from this generator, so a replayed script produces the
    /// same event ids and can be compared value-for-value in a test.
    public mutating func nextUUID() -> UUID {
        let high = next()
        let low = next()
        return UUID(uuid: (
            UInt8(truncatingIfNeeded: high >> 56),
            UInt8(truncatingIfNeeded: high >> 48),
            UInt8(truncatingIfNeeded: high >> 40),
            UInt8(truncatingIfNeeded: high >> 32),
            UInt8(truncatingIfNeeded: high >> 24),
            UInt8(truncatingIfNeeded: high >> 16),
            UInt8(truncatingIfNeeded: high >> 8),
            UInt8(truncatingIfNeeded: high),
            UInt8(truncatingIfNeeded: low >> 56),
            UInt8(truncatingIfNeeded: low >> 48),
            UInt8(truncatingIfNeeded: low >> 40),
            UInt8(truncatingIfNeeded: low >> 32),
            UInt8(truncatingIfNeeded: low >> 24),
            UInt8(truncatingIfNeeded: low >> 16),
            UInt8(truncatingIfNeeded: low >> 8),
            UInt8(truncatingIfNeeded: low)
        ))
    }
}
