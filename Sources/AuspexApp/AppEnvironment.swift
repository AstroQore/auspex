import AgentSessionKit
import AgentSessionLive
import AuspexCore
import Foundation
import Observation

/// Process-wide dependencies the SwiftUI tree observes.
///
/// It owns the pipeline and nothing else owns any part of it:
///
/// ```text
/// IngestCoordinator ─┐
///                    ├─> merged AgentEvent stream ─> SessionRegistry ─> BoardSnapshot ─> LiveBoardModel
/// LivenessResolver ──┘                                     │ ▲
///        (or DemoEventSource, in demo mode)                │ └── GroupingCoordinator
///                                                          └─> AuspexStore ─> SessionRepository ─> trace
/// ```
///
/// The two producers are merged into one stream rather than given to the
/// registry separately, because `run(events:)` takes a single stream and a
/// liveness event is an `AgentEvent` like any other — folding it through the
/// same reducer is what keeps "the process died" and "the session ended"
/// consistent with each other.
///
/// ``GroupingCoordinator`` is the exception: it *reads* the registry and writes
/// back through `applyPlacements` / `applyLinks` rather than producing events
/// from outside. It has to, because both of its questions are asked *about* the
/// board — which directories are on it, and which of its sessions are each
/// other's ancestors — and neither can be answered by a producer that has never
/// seen it.
///
/// Views never see any of this. They read ``board``.
@MainActor
@Observable
public final class AppEnvironment {
    /// Keep the database poll at the kit's two-second correctness default:
    /// WAL/-shm writes are not guaranteed to produce a useful FSEvent. Bound
    /// cost by tailing recent sources instead. Every adapter's live evidence
    /// (presence lock, worker, fresh write) overrides this discovery cutoff,
    /// and a resumed old source is rediscovered by its new filesystem event.
    static let liveIngestConfiguration = IngestConfiguration(
        activeWindow: 60 * 60
    )

    /// How this launch was asked to behave.
    public enum Mode: String, Sendable {
        /// Tail the real harness stores under the user's home.
        case live
        /// Replay a fabricated board out of an in-memory store. Reads nothing
        /// and writes nothing.
        case demo
    }

    /// Where Auspex reads and writes its own state.
    public let paths: AuspexPaths

    /// What this launch is doing.
    public let mode: Mode

    /// The local database, or `nil` when it could not be opened.
    ///
    /// A failure here is not fatal: an app that cannot open its store can
    /// still show the window and say why, which is more useful than a launch
    /// that dies before drawing anything.
    public let store: AuspexStore?

    /// Why ``store`` is `nil``, for the settings pane to show.
    public let storeErrorDescription: String?

    /// Everything the window renders.
    let board = LiveBoardModel()

    /// Sidebar destinations.
    public let sections: [BoardSection] = BoardSection.allCases

    /// The Harnesses page: detection, counts, and MCP configuration.
    let harnesses = HarnessStatusModel()

    /// The MCP listener agents attach to, and what it is doing.
    ///
    /// Built in ``start()`` rather than here because it needs the process
    /// table the liveness loop already owns — one `sysctl` sweep between them
    /// rather than two — and because a demo must be able to decide not to bind
    /// at all.
    private(set) var mcp: MCPController?

    /// The sidebar's project tree.
    let projects = ProjectsModel()

    /// The Tasks page: plans, tasks, and the live sessions on them.
    let tasks = TasksModel()

    /// The one-click setup: what Auspex would write into each harness's
    /// config, and what has been ticked. Reads on load; writes only on a click.
    let setup = SetupModel()

    /// The projects a person made and the rules they wrote — the user layer
    /// the board places and filters with.
    let catalog: ProjectCatalogModel

    /// Interrupt and kill: the one place the app acts on a session rather than
    /// watching it. Every path through it is behind a click, and the
    /// destructive one is behind a click and a dialog.
    let control = SessionControlModel()

    /// The prefilled "ignore this…" sheet, when one is open.
    ///
    /// Held here rather than in the view that opened it: the menu items that
    /// start one are on cards, on sidebar rows and on the Projects page, and a
    /// sheet presented from three places is three sheets that can be open at
    /// once.
    var ignoreDraft: IgnoreDraft?

    /// Offers a rule rather than writing one — the `…` in every "Ignore this…"
    /// menu item.
    func composeIgnore(_ tag: IgnoreRule.Kind.Tag, value: String) {
        ignoreDraft = IgnoreDraft(tag: tag, value: value)
    }

    private var registry: SessionRegistry?
    private var coordinator: IngestCoordinator?
    private var demoSource: DemoEventSource?
    private var eventContinuation: AsyncStream<AgentEvent>.Continuation?
    private var pipelineTasks: [Task<Void, Never>] = []
    private var didStart = false

    /// How often the grouping pass runs.
    ///
    /// The same three seconds as the liveness loop and as `ProcessTable`'s own
    /// cache window, so a tick of each costs one process-table read between
    /// them rather than two.
    private static let groupingInterval = Duration.seconds(3)

    /// Whether a demo run may start a real process for Interrupt and Kill to
    /// be tried against — see ``DemoSignalTarget``.
    ///
    /// Off for the offscreen renderers. They draw the demo board into a
    /// bitmap and exit; nothing in a bitmap can be clicked, and a renderer
    /// that spawned a process and then called `exit(0)` would leave it behind
    /// every time a screenshot was taken.
    private let offersSignalTarget: Bool

    /// How many times over the demo runs its cast — see
    /// ``AppLaunchOptions/demoScale``. Ignored in a live run, which gets its
    /// size from the machine.
    private let demoScale: Int

    /// An appearance the command line asked for, which is not written down.
    ///
    /// It exists for the same reason ``AppLaunchOptions/viewMode`` does: the
    /// performance budget is a gate, and neither column of the palette can be
    /// measured — or looked at on somebody else's machine — if the only way to
    /// reach it is to change the appearance of the whole Mac. Deliberately not
    /// persisted: a flag passed to one launch must not silently become the
    /// person's setting.
    var appearanceOverride: AppearanceMode?

    /// The appearance every root draws in: what the command line asked for, or
    /// what the person chose.
    var appearance: AppearanceMode { appearanceOverride ?? catalog.appearance }

    /// macOS's Login Items registration. Demo/offscreen launches get an inert
    /// controller so a fabricated board neither reads nor changes the real
    /// machine's setting.
    let loginItem: LoginItemController

    public init(
        paths: AuspexPaths = .default,
        mode: Mode = .live,
        offersSignalTarget: Bool = true,
        demoScale: Int = 1
    ) {
        self.paths = paths
        self.mode = mode
        self.offersSignalTarget = offersSignalTarget
        self.demoScale = AppLaunchOptions.clampedScale(demoScale)
        self.loginItem = mode == .live ? LoginItemController() : .preview()
        // The demo may not read or write `~/.auspex/`, so its catalog has no
        // stores behind it: whatever it is given lives in memory for as long
        // as the process does.
        self.catalog = ProjectCatalogModel(paths: paths, persists: mode == .live)
        do {
            // The demo must not create `~/.auspex/` or touch a database a live
            // instance may be using, so it gets a store that exists only for
            // as long as the process does.
            self.store = mode == .demo
                ? try AuspexStore(inMemory: true)
                : try AuspexStore(paths: paths)
            self.storeErrorDescription = nil
        } catch {
            self.store = nil
            self.storeErrorDescription = String(describing: error)
        }
    }

    /// Version string for the menu bar and the settings pane.
    public var versionDescription: String {
        AuspexVersion.displayString
    }

    /// Sparkle, and what the surfaces say about it.
    ///
    /// Not stored: the updater is process-wide, and the Settings window is a
    /// scene of its own that inherits nothing from this environment, so the
    /// pane has to be able to reach the same one by name.
    var updates: AppUpdateController { .shared }

    // MARK: Lifecycle

    /// Brings the pipeline up. Idempotent; the window's `task` calls it.
    func start() {
        guard !didStart else { return }
        didStart = true

        // Before the pipeline: the first frame should already be placed by the
        // person's projects and filtered by their rules, rather than showing
        // everything for a moment and then settling.
        catalog.onChange = { [board, catalog] claims, rules, showsIgnored in
            board.setUserLayer(
                claims: claims,
                rules: rules,
                showsIgnored: showsIgnored,
                sceneZones: catalog.sceneZones,
                sessionWindow: catalog.sessionWindow,
                showsSubagents: catalog.showsSubagents
            )
        }
        catalog.load()
        // The first catch-up is intentionally bounded: a new install should
        // summarize the work in flight, not turn every retained session into
        // an unread inbox. Later launches resume from the explicit cursor the
        // person moved with "Mark caught up".
        board.setCatchUpSince(
            catalog.lastCatchUpAt ?? Date().addingTimeInterval(-4 * 60 * 60)
        )

        // ServiceManagement is the operational truth. Reconciliation only
        // mirrors its state and, when an in-place update can be proven,
        // refreshes the bundle receipt. It never calls register: a person may
        // have switched the item off directly in System Settings.
        if mode == .live {
            if let reconciliation = loginItem.reconcileDesiredState(
                catalog.launchAtLogin,
                registration: catalog.loginItemRegistration
            ) {
                catalog.setLaunchAtLogin(
                    reconciliation.enabled,
                    registration: reconciliation.registration
                )
            }
        }

        // After the load, so the first check already goes to the stream the
        // person chose rather than to stable and then to theirs. A demo asks
        // for nothing: it promises to read nothing and write nothing, and a
        // background check writes a timestamp into the app's defaults.
        updates.activate(channel: catalog.updateChannel, enabled: mode == .live)

        guard let store else {
            board.record(
                notice: "The store could not be opened, so nothing is being recorded. "
                    + (storeErrorDescription ?? "No reason was given.")
            )
            return
        }

        let registry = SessionRegistry(store: store)
        self.registry = registry
        board.autoSelectsFirstSession = mode == .demo
        // The sidebar's tree is derived from the same frame the board is, in
        // the same pass and off the main actor; the names it is labelled with
        // are the one part only the sidebar's model reads, so they travel the
        // other way.
        board.onTree = { [projects] tree in projects.adopt(tree: tree) }
        projects.onNames = { [board] names in board.setProjectNames(names) }
        board.start(registry: registry, repository: SessionRepository(store: store))
        // The seed goes first: the board reads the ledger as it starts, and a
        // demo whose plan arrived a frame later would show its own empty state
        // for that frame. It writes into the in-memory store a demo makes for
        // itself and never into `~/.auspex/`.
        if mode == .demo { try? DemoTaskLedger.seed(into: TaskRepository(store: store)) }
        board.startLedger(repository: TaskRepository(store: store))
        board.startMap(
            repository: MapRepository(store: store),
            sessions: SessionRepository(store: store)
        )
        tasks.start(repository: TaskRepository(store: store))
        tasks.onLedgerChange = { [weak board] in board?.reloadLedger() }
        projects.start(repository: ProjectRepository(store: store))
        // A demo reads no harness store — and no harness *config* either. The
        // page (and any offscreen render of it) would otherwise show this
        // Mac's real MCP server names under a board that is supposed to be
        // fabricated end to end.
        if mode == .live {
            harnesses.start(
                home: paths.homeDirectory,
                watchRoots: AuspexAdapters.watchRoots(home: paths.homeDirectory.path)
            )
        } else {
            harnesses.startFabricated()
        }
        // The setup sheet writes into real harness configs, so a demo never
        // offers it: a fabricated board must not be able to change the machine.
        setup.load(
            paths: paths,
            command: MCPController.bridgeCommand,
            detected: harnesses.detected,
            isEnabled: mode == .live
        )

        // Buffered generously: a harness flushing a whole turn can put a few
        // hundred events in flight before the registry drains any of them, and
        // dropping the oldest of those would drop the start of the turn.
        let (events, continuation) = AsyncStream<AgentEvent>.makeStream(
            of: AgentEvent.self,
            bufferingPolicy: .bufferingNewest(8_192)
        )
        eventContinuation = continuation

        // Detached: `AppEnvironment` is main-actor, and a plain `Task {}`
        // here would inherit that — the pipeline's `for await` loops would
        // then hop through the main thread once per event and crawl to a
        // handful of events per second whenever the board is busy laying
        // out. Everything that moves events runs off the main actor;
        // only UI notices come back to it.
        pipelineTasks.append(Task.detached { [weak self] in
            do {
                // Before any producer starts, so a relaunch shows the board it
                // had rather than one that fills in as each harness happens to
                // write its next line.
                try await registry.bootstrap()
            } catch {
                await self?.board.record(notice: "Stored sessions could not be reloaded: \(error).")
            }
            // After bootstrap, because it folds into the briefs bootstrap
            // loaded; in a task of its own, because it reads and rewrites a few
            // hundred rows and the first event must not wait for that.
            await self?.startBriefBackfill(store: store, registry: registry)
            await registry.run(events: events)
        })

        // One process table for both loops. `ProcessTable` caches for three
        // seconds and both tick on three seconds, so sharing it turns two
        // `sysctl(KERN_PROC_ALL)` sweeps per tick into one. Arguments and
        // working directories are deliberately not read: neither loop needs
        // them, and some harnesses pass credentials in argv.
        let table = ProcessTable(includesArguments: false, includesWorkingDirectory: false)

        // The same table again, for the third reader. A context menu asking
        // "can this session be signalled" hits the snapshot the last liveness
        // tick already paid for; only an actual send refreshes it.
        control.start(table: table)
        control.onEvent = { [weak self] event in
            self?.eventContinuation?.yield(event)
        }
        control.onNotice = { [board] notice in board.record(notice: notice) }

        startMCP(store: store, table: table)

        switch mode {
        case .demo:
            startDemo(store: store, into: continuation)
        case .live:
            startLive(store: store, table: table, into: continuation)
        }

        startGrouping(registry: registry, table: table, mode: mode)
    }

    /// Brings up the MCP listener and points it at the board.
    ///
    /// The frame goes to the server through the same `onFrame` hook the
    /// sidebar's tree uses, so a tool call reads a value that is already in
    /// hand rather than waking the board model up to ask for one.
    private func startMCP(store: AuspexStore, table: any ProcessTableReading) {
        // A demo must not post a system notification: nothing on its board
        // happened, and a fabricated alert in Notification Centre outlives the
        // window that explained itself.
        let isDemo = mode == .demo
        let controller = MCPController(
            paths: paths,
            store: store,
            table: table,
            isReadOnly: isDemo,
            board: board,
            onNotice: { [weak self] notice in
                await MainActor.run { self?.board.apply(notice: notice) }
                guard !isDemo else { return }
                // A call always gets a banner: it will not resolve itself, and
                // the gap between an agent stopping to ask and a person finding
                // out is the gap this whole surface exists to close. A receipt
                // is good news that keeps, so it has a switch — see
                // ``AuspexSettings/notifiesOnDone``.
                let wanted = await MainActor.run {
                    notice.kind.wantsPerson || self?.catalog.notifiesOnDone ?? true
                }
                guard wanted else { return }
                await AgentNotifier.shared.post(notice)
            },
            onReport: { [weak self] report in
                await MainActor.run { self?.board.apply(report: report) }
            },
            onLedgerChange: { [weak self] in
                await MainActor.run {
                    self?.tasks.reload()
                    self?.board.reloadLedger()
                }
            },
            // A hook's events join the stream the tailers feed, so a permission
            // prompt and a tool call are folded by the same reducer in the
            // order they arrived. The main-actor hop costs nothing at this
            // rate: a hook fires a handful of times a minute, against the
            // hundreds of events a second a burst of transcript can produce.
            onEvents: { [weak self] events in
                await MainActor.run {
                    guard let continuation = self?.eventContinuation else { return }
                    for event in events { continuation.yield(event) }
                }
            }
        )
        mcp = controller
        controller.start()

        // One hook, two readers: the sidebar's tree and the Tasks page both
        // want the frame the wall is drawing, once per applied frame rather
        // than once per render. The MCP server is not one of them — it reads
        // the frame when an agent asks, which is rarer than a frame by three
        // orders of magnitude.
        board.onFrame = { [tasks] frame, units in
            tasks.apply(units: units, board: frame)
        }
    }


    /// Rebuilds the briefs of sessions recorded before Auspex folded any.
    ///
    /// Once per store per event schema — ``BriefBackfill/runIfNeeded(batchSize:)``
    /// owns that decision — and never on the main actor: it is a few hundred
    /// SQLite statements and as many JSON round trips, at utility priority so
    /// it yields to the pipeline it is running beside.
    ///
    /// The result goes back through the registry rather than being left in the
    /// store, so a person watching the board sees the sessions fill in instead
    /// of finding out on the next launch.
    ///
    /// A notice only when something changed, and only counts. The whole point
    /// of the pass is prompts, and a diagnostic line is the last place any of
    /// them should appear.
    private func startBriefBackfill(store: AuspexStore, registry: SessionRegistry) {
        pipelineTasks.append(Task.detached(priority: .utility) { [weak self] in
            do {
                let report = try BriefBackfill(store: store).runIfNeeded()
                guard report.didRun else { return }
                await registry.applyBriefs(report.briefs)
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    // For the sessions the registry does not hold: bootstrap
                    // loads the most recent few hundred, and one past that
                    // limit is seeded from its next event with a brief the
                    // store already knows better than.
                    board.setDerivedBriefs(report.briefs)
                    // The pass may have decided, on the person's behalf, that
                    // sessions quiet for two days have been read. The board
                    // read `session_views` before that happened.
                    board.loadSeen()
                }
                guard report.updated > 0 || report.markedSeen > 0 else { return }
                await self?.board.record(notice: "Auspex \(report.summary).")
            } catch {
                await self?.board.record(
                    notice: "Older sessions could not be filled in: \(error)."
                )
            }
        })
    }

    /// Starts the pass that answers where each session is and who started it.
    ///
    /// Runs in demo mode too, against an empty process table. The script already
    /// records its delegation evidence, so polling this Mac's real process tree
    /// every three seconds adds no fabricated fact and makes an idle demo spend
    /// CPU on unrelated programs. Process-link inference itself is covered by
    /// the integration suite and the live run keeps the shared real table.
    ///
    /// The demo's resolver is told that `/Users/example` is the home, because
    /// one of the rules it exercises is about where a *home* is:
    /// ``HarnessSandbox`` recognises the Codex desktop's per-thread scratch by
    /// its position under one, and a resolver pointed at this Mac's real home
    /// would answer "an ordinary directory" for the demo's own scratch session.
    private func startGrouping(
        registry: SessionRegistry,
        table: any ProcessTableReading,
        mode: Mode
    ) {
        let placements = mode == .demo
            ? PlacementService(resolver: ProjectResolver(homeDirectory: DemoScript.homeDirectory))
            : PlacementService()
        let groupingTable: any ProcessTableReading
        if mode == .demo {
            groupingTable = DemoGroupingProcessTable()
        } else {
            groupingTable = table
        }
        let grouping = GroupingCoordinator(
            registry: registry,
            table: groupingTable,
            placements: placements
        )
        pipelineTasks.append(Task.detached { await grouping.run(every: Self.groupingInterval) })
    }

    /// Stops every producer and flushes what the registry has buffered.
    ///
    /// Called on `NSApplication.willTerminate`. The registry's `stop()` waits
    /// for an in-flight transaction and commits the rest, so quitting mid-burst
    /// does not lose the last quarter second of a session.
    func shutdown() async {
        for task in pipelineTasks { task.cancel() }
        pipelineTasks.removeAll()
        // Before the pipeline goes: a bridge that writes one more line while
        // the store is closing gets a clean EOF instead of a half-answer.
        mcp?.stop()
        mcp = nil
        board.stop()
        projects.stop()
        tasks.stop()
        harnesses.stop()
        eventContinuation?.finish()
        eventContinuation = nil
        await coordinator?.stop()
        coordinator = nil
        // Before dropping it: the demo owns a real `/bin/sleep` for Interrupt
        // and Kill to be tried against, and letting the actor go without
        // stopping it would leave the process behind.
        await demoSource?.stop()
        demoSource = nil
        await registry?.stop()
        registry = nil
    }

    // MARK: Producers

    private func startLive(
        store: AuspexStore,
        table: any ProcessTableReading,
        into continuation: AsyncStream<AgentEvent>.Continuation
    ) {
        let home = paths.homeDirectory.path
        let coordinator = IngestCoordinator(
            adapters: AuspexAdapters.all,
            home: home,
            cursorStore: store.sourceCursors,
            configuration: Self.liveIngestConfiguration
        )
        self.coordinator = coordinator

        pipelineTasks.append(Task.detached { [weak self] in
            let streams = await coordinator.start()
            // Notices are for the UI and arrive rarely; the events are not
            // and do not — they stay off the main actor.
            let noticeTask = Task { @MainActor [weak self] in
                for await notice in streams.notices {
                    self?.board.record(notice: Self.describe(notice))
                }
            }
            await self?.track(noticeTask)
            for await event in streams.events {
                continuation.yield(event)
            }
        })

        // Liveness answers a question no transcript can: the harness process
        // is gone, so the session that looked like it was thinking has in fact
        // stopped.
        let resolver = LivenessResolver(
            adapters: AuspexAdapters.all,
            table: table,
            home: home
        )
        let registryForLiveness = registry
        pipelineTasks.append(Task.detached {
            await resolver.runLoop(
                every: .seconds(3),
                identities: {
                    guard let registry = registryForLiveness else { return [] }
                    return await registry.livenessIdentities()
                },
                into: continuation
            )
        })
    }

    /// Replays the fabricated board, and lets its agents speak once per loop.
    ///
    /// The second half is not decoration. The two loud buckets are made of
    /// things agents said out loud, and a call is cleared by the person
    /// talking to that session again — so a demo that filed its notices once
    /// at launch would show an empty header from the first loop onwards, which
    /// is a demo of the passive half of the app.
    private func startDemo(
        store: AuspexStore,
        into continuation: AsyncStream<AgentEvent>.Continuation
    ) {
        let ledger = TaskRepository(store: store)
        let board = board
        let source = DemoEventSource(
            continuation: continuation,
            scale: demoScale,
            lendsProcess: offersSignalTarget,
            onLoop: { [weak board] in
                let now = Date()
                let notices = DemoScript.notices(now: now)
                for notice in notices.values.sorted(by: {
                    $0.session.description < $1.session.description
                }) {
                    _ = try? ledger.recordNotice(
                        session: notice.session,
                        kind: notice.kind,
                        message: notice.message,
                        urgency: notice.urgency,
                        now: notice.createdAt
                    )
                }
                // Applied on the spot rather than by re-reading, so the cards
                // move on the frame the notices land on. No system
                // notification: nothing on a fabricated board happened.
                await MainActor.run {
                    for notice in notices.values { board?.apply(notice: notice) }
                }
            }
        )
        demoSource = source
        pipelineTasks.append(Task.detached { await source.run() })
    }

    /// Keeps a task alive for `shutdown()` to cancel.
    private func track(_ task: Task<Void, Never>) {
        pipelineTasks.append(task)
    }

    /// A notice, as a sentence rather than as an enum dump.
    private static func describe(_ notice: IngestNotice) -> String {
        String(describing: notice)
    }
}

private struct DemoGroupingProcessTable: ProcessTableReading {
    func processes() -> [ProcessRecord] { [] }
    func environment(pid _: pid_t) -> [String: String]? { nil }
}

/// Top-level areas of the app.
///
/// The sidebar is also the app's table of contents, so a section that is not
/// built yet is listed rather than hidden — see ``arrivesIn``.
public enum BoardSection: String, CaseIterable, Identifiable, Sendable {
    case live
    case allSessions
    case projects
    case tasks
    case harnesses
    case settings

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .live: "Live"
        case .allSessions: "All sessions"
        case .projects: "Projects"
        case .tasks: "Roost"
        case .harnesses: "Harnesses"
        case .settings: "Settings"
        }
    }

    public var systemImage: String {
        switch self {
        case .live: "dot.radiowaves.left.and.right"
        case .allSessions: "square.stack.3d.up"
        case .projects: "folder"
        case .tasks: "checklist"
        case .harnesses: "cpu"
        case .settings: "gearshape"
        }
    }

    /// The milestone this section arrives in, or `nil` when it is here.
    ///
    /// Every section is here now. The property stays because the sidebar is
    /// also this app's table of contents, and the next thing that is announced
    /// before it is built should be announced the same way.
    public var arrivesIn: String? { nil }

    /// Whether the section can be selected.
    public var isAvailable: Bool { arrivesIn == nil }
}

/// How the process was launched.
///
/// Parsed once, before anything else reads `CommandLine`, so the app has one
/// answer rather than three call sites each checking for their own flag.
public struct AppLaunchOptions: Sendable {
    /// Replay a fabricated board instead of tailing real stores.
    public var isDemo: Bool

    /// How many times over to run the demo's cast — `--demo-scale N`.
    ///
    /// The performance budget in `AGENTS.md` § 4.1 is written against a real
    /// machine's store, and a real machine's store is the one thing an agent
    /// working on this repository must not open. This is the way to the same
    /// size without it: `12` is about a hundred and seventy sessions across
    /// sixty projects, which is the shape the report that prompted the work
    /// had. `1` is the demo exactly as written.
    public var demoScale: Int = 1

    /// Which way to look at the board on launch, when the command line said.
    ///
    /// It exists because the performance budget is a gate: "scene on screen,
    /// no user input, ≤ 15 % process CPU" cannot be measured on a view that
    /// only a person clicking a segmented control can reach. With this, one
    /// command launches straight into the view being measured and `top` has
    /// something honest to look at.
    public var viewMode: BoardViewMode?

    /// Which column of the palette to draw in, when the command line said.
    ///
    /// For the same reason, and for one more: looking at the light window on a
    /// Mac that is set to dark should not mean changing the appearance of the
    /// Mac. It is not written to `settings.json` — see
    /// `AppEnvironment.appearanceOverride`.
    public var appearance: AppearanceMode?

    /// Reads the flag from the command line, with an environment variable as
    /// the alternative for the case where the launcher owns the argv —
    /// `open -a Auspex` cannot pass arguments through.
    public static func current(
        arguments: [String] = CommandLine.arguments,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> AppLaunchOptions {
        let rest = arguments.dropFirst()
        func value(after flag: String) -> String? {
            guard let index = rest.firstIndex(of: flag) else { return nil }
            let next = rest.index(after: index)
            return next < rest.endIndex ? rest[next] : nil
        }
        let named = value(after: "--view")
        let appearance = value(after: "--appearance") ?? environment["AUSPEX_APPEARANCE"]
        let scale = (value(after: "--demo-scale") ?? environment["AUSPEX_DEMO_SCALE"])
            .flatMap(Int.init)
        return AppLaunchOptions(
            // A scale asks for a demo. Nobody types `--demo-scale 12` meaning
            // "and also tail my real stores", and a flag that silently did
            // nothing without a second flag beside it is a flag that gets
            // reported as broken.
            isDemo: rest.contains("--demo") || environment["AUSPEX_DEMO"] == "1"
                || (scale ?? 1) > 1,
            demoScale: Self.clampedScale(scale),
            viewMode: (named ?? environment["AUSPEX_VIEW"]).flatMap(BoardViewMode.init(named:)),
            appearance: appearance.flatMap(AppearanceMode.init(rawValue:))
        )
    }

    /// A scale that cannot make the app unusable by accident.
    ///
    /// Below one is the demo as written. The ceiling is a real limit rather
    /// than a tidy round number: the script is a couple of thousand events per
    /// pass of the cast, and a scale of a hundred would spend the first minute
    /// of the launch writing them into SQLite instead of drawing anything.
    static func clampedScale(_ value: Int?) -> Int {
        guard let value else { return 1 }
        return min(max(value, 1), 64)
    }

    /// The mode these options select.
    public var mode: AppEnvironment.Mode { isDemo ? .demo : .live }
}

extension AppEnvironment {
    /// The environment the app starts with, set up the way the command line
    /// asked for.
    @MainActor
    public static func launched(_ options: AppLaunchOptions = .current()) -> AppEnvironment {
        let environment = AppEnvironment(mode: options.mode, demoScale: options.demoScale)
        if let viewMode = options.viewMode { environment.board.viewMode = viewMode }
        environment.appearanceOverride = options.appearance
        return environment
    }
}
