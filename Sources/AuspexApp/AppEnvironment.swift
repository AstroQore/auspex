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

    /// The sidebar's project tree.
    let projects = ProjectsModel()

    /// The projects a person made and the rules they wrote — the user layer
    /// the board places and filters with.
    let catalog: ProjectCatalogModel

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
    private var tasks: [Task<Void, Never>] = []
    private var didStart = false

    /// How often the grouping pass runs.
    ///
    /// The same three seconds as the liveness loop and as `ProcessTable`'s own
    /// cache window, so a tick of each costs one process-table read between
    /// them rather than two.
    private static let groupingInterval = Duration.seconds(3)

    public init(paths: AuspexPaths = .default, mode: Mode = .live) {
        self.paths = paths
        self.mode = mode
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

    // MARK: Lifecycle

    /// Brings the pipeline up. Idempotent; the window's `task` calls it.
    func start() {
        guard !didStart else { return }
        didStart = true

        // Before the pipeline: the first frame should already be placed by the
        // person's projects and filtered by their rules, rather than showing
        // everything for a moment and then settling.
        catalog.onChange = { [board] claims, rules, showsIgnored in
            board.setUserLayer(claims: claims, rules: rules, showsIgnored: showsIgnored)
        }
        catalog.load()

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
        // The sidebar's tree is derived from the same frame the board is, and
        // once per frame rather than once per render.
        board.onFrame = { [projects] frame in projects.rebuild(board: frame) }
        board.start(registry: registry, repository: SessionRepository(store: store))
        projects.start(repository: ProjectRepository(store: store))
        harnesses.start(
            home: paths.homeDirectory,
            watchRoots: AuspexAdapters.watchRoots(home: paths.homeDirectory.path)
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
        tasks.append(Task.detached { [weak self] in
            do {
                // Before any producer starts, so a relaunch shows the board it
                // had rather than one that fills in as each harness happens to
                // write its next line.
                try await registry.bootstrap()
            } catch {
                await self?.board.record(notice: "Stored sessions could not be reloaded: \(error).")
            }
            await registry.run(events: events)
        })

        // One process table for both loops. `ProcessTable` caches for three
        // seconds and both tick on three seconds, so sharing it turns two
        // `sysctl(KERN_PROC_ALL)` sweeps per tick into one. Arguments and
        // working directories are deliberately not read: neither loop needs
        // them, and some harnesses pass credentials in argv.
        let table = ProcessTable(includesArguments: false, includesWorkingDirectory: false)

        switch mode {
        case .demo:
            startDemo(into: continuation)
        case .live:
            startLive(store: store, table: table, into: continuation)
        }

        startGrouping(registry: registry, table: table)
    }

    /// Starts the pass that answers where each session is and who started it.
    ///
    /// Runs in demo mode too. The demo's directories are under
    /// `/Users/example`, so nearly every placement resolves to "a directory in
    /// no repository, named after itself" and every link is already recorded by
    /// the script — which is the point: the demo exercises the same code path
    /// the live board does, and a coordinator that only ran in one of them
    /// would be a coordinator only tested in one of them.
    private func startGrouping(registry: SessionRegistry, table: any ProcessTableReading) {
        let grouping = GroupingCoordinator(registry: registry, table: table)
        tasks.append(Task.detached { await grouping.run(every: Self.groupingInterval) })
    }

    /// Stops every producer and flushes what the registry has buffered.
    ///
    /// Called on `NSApplication.willTerminate`. The registry's `stop()` waits
    /// for an in-flight transaction and commits the rest, so quitting mid-burst
    /// does not lose the last quarter second of a session.
    func shutdown() async {
        for task in tasks { task.cancel() }
        tasks.removeAll()
        board.stop()
        projects.stop()
        harnesses.stop()
        eventContinuation?.finish()
        eventContinuation = nil
        await coordinator?.stop()
        coordinator = nil
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
            cursorStore: store.sourceCursors
        )
        self.coordinator = coordinator

        tasks.append(Task.detached { [weak self] in
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
        tasks.append(Task.detached {
            await resolver.runLoop(
                every: .seconds(3),
                identities: {
                    guard let registry = registryForLiveness else { return [] }
                    return await registry.snapshot().sessions.map(\.identity)
                },
                into: continuation
            )
        })
    }

    private func startDemo(into continuation: AsyncStream<AgentEvent>.Continuation) {
        let source = DemoEventSource(continuation: continuation)
        demoSource = source
        tasks.append(Task.detached { await source.run() })
    }

    /// Keeps a task alive for `shutdown()` to cancel.
    private func track(_ task: Task<Void, Never>) {
        tasks.append(task)
    }

    /// A notice, as a sentence rather than as an enum dump.
    private static func describe(_ notice: IngestNotice) -> String {
        String(describing: notice)
    }
}

/// Top-level areas of the app.
///
/// Only ``live`` has a surface today. The rest are listed rather than hidden
/// because the sidebar is also the app's table of contents: a person should be
/// able to see that projects and tasks are coming without having to read a
/// roadmap.
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
        case .tasks: "Tasks"
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
    public var arrivesIn: String? {
        switch self {
        case .live, .allSessions, .projects, .harnesses, .settings: nil
        case .tasks: "M3"
        }
    }

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

    /// Which way to look at the board on launch, when the command line said.
    ///
    /// It exists because the performance budget is a gate: "scene on screen,
    /// no user input, ≤ 15 % process CPU" cannot be measured on a view that
    /// only a person clicking a segmented control can reach. With this, one
    /// command launches straight into the view being measured and `top` has
    /// something honest to look at.
    public var viewMode: BoardViewMode?

    /// Reads the flag from the command line, with an environment variable as
    /// the alternative for the case where the launcher owns the argv —
    /// `open -a Auspex` cannot pass arguments through.
    public static func current(
        arguments: [String] = CommandLine.arguments,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> AppLaunchOptions {
        let rest = arguments.dropFirst()
        let named = rest.firstIndex(of: "--view").flatMap { index -> String? in
            let next = rest.index(after: index)
            return next < rest.endIndex ? rest[next] : nil
        }
        return AppLaunchOptions(
            isDemo: rest.contains("--demo") || environment["AUSPEX_DEMO"] == "1",
            viewMode: (named ?? environment["AUSPEX_VIEW"]).flatMap(BoardViewMode.init(rawValue:))
        )
    }

    /// The mode these options select.
    public var mode: AppEnvironment.Mode { isDemo ? .demo : .live }
}

extension AppEnvironment {
    /// The environment the app starts with, set up the way the command line
    /// asked for.
    @MainActor
    public static func launched(_ options: AppLaunchOptions = .current()) -> AppEnvironment {
        let environment = AppEnvironment(mode: options.mode)
        if let viewMode = options.viewMode { environment.board.viewMode = viewMode }
        return environment
    }
}
