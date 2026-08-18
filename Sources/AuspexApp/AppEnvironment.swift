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
/// LivenessResolver ──┘                                     │
///        (or DemoEventSource, in demo mode)                └─> AuspexStore ─> SessionRepository ─> trace
/// ```
///
/// The two producers are merged into one stream rather than given to the
/// registry separately, because `run(events:)` takes a single stream and a
/// liveness event is an `AgentEvent` like any other — folding it through the
/// same reducer is what keeps "the process died" and "the session ended"
/// consistent with each other.
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

    private var registry: SessionRegistry?
    private var coordinator: IngestCoordinator?
    private var demoSource: DemoEventSource?
    private var eventContinuation: AsyncStream<AgentEvent>.Continuation?
    private var tasks: [Task<Void, Never>] = []
    private var didStart = false

    public init(paths: AuspexPaths = .default, mode: Mode = .live) {
        self.paths = paths
        self.mode = mode
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
        board.start(registry: registry, repository: SessionRepository(store: store))

        // Buffered generously: a harness flushing a whole turn can put a few
        // hundred events in flight before the registry drains any of them, and
        // dropping the oldest of those would drop the start of the turn.
        let (events, continuation) = AsyncStream<AgentEvent>.makeStream(
            of: AgentEvent.self,
            bufferingPolicy: .bufferingNewest(8_192)
        )
        eventContinuation = continuation

        tasks.append(Task { [weak self] in
            do {
                // Before any producer starts, so a relaunch shows the board it
                // had rather than one that fills in as each harness happens to
                // write its next line.
                try await registry.bootstrap()
            } catch {
                self?.board.record(notice: "Stored sessions could not be reloaded: \(error).")
            }
            await registry.run(events: events)
        })

        switch mode {
        case .demo:
            startDemo(into: continuation)
        case .live:
            startLive(store: store, into: continuation)
        }
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
        eventContinuation?.finish()
        eventContinuation = nil
        await coordinator?.stop()
        coordinator = nil
        demoSource = nil
        await registry?.stop()
        registry = nil
    }

    // MARK: Producers

    private func startLive(store: AuspexStore, into continuation: AsyncStream<AgentEvent>.Continuation) {
        let home = paths.homeDirectory.path
        let coordinator = IngestCoordinator(
            adapters: AuspexAdapters.all,
            home: home,
            cursorStore: store.sourceCursors
        )
        self.coordinator = coordinator

        tasks.append(Task { [weak self] in
            let streams = await coordinator.start()
            self?.tasks.append(Task { [weak self] in
                for await notice in streams.notices {
                    self?.board.record(notice: Self.describe(notice))
                }
            })
            for await event in streams.events {
                continuation.yield(event)
            }
        })

        // Liveness answers a question no transcript can: the harness process
        // is gone, so the session that looked like it was thinking has in fact
        // stopped. Arguments and working directories are deliberately not read
        // — a liveness probe needs neither, and some harnesses pass
        // credentials in argv.
        let resolver = LivenessResolver(
            adapters: AuspexAdapters.all,
            table: ProcessTable(includesArguments: false, includesWorkingDirectory: false),
            home: home
        )
        tasks.append(Task { [weak self] in
            await resolver.runLoop(
                every: .seconds(3),
                identities: { [weak self] in
                    guard let registry = await self?.registry else { return [] }
                    return await registry.snapshot().sessions.map(\.identity)
                },
                into: continuation
            )
        })
    }

    private func startDemo(into continuation: AsyncStream<AgentEvent>.Continuation) {
        let source = DemoEventSource(continuation: continuation)
        demoSource = source
        tasks.append(Task { await source.run() })
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
    case projects
    case tasks
    case harnesses
    case settings

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .live: "Live"
        case .projects: "Projects"
        case .tasks: "Tasks"
        case .harnesses: "Harnesses"
        case .settings: "Settings"
        }
    }

    public var systemImage: String {
        switch self {
        case .live: "dot.radiowaves.left.and.right"
        case .projects: "folder"
        case .tasks: "checklist"
        case .harnesses: "cpu"
        case .settings: "gearshape"
        }
    }

    /// The milestone this section arrives in, or `nil` when it is here.
    public var arrivesIn: String? {
        switch self {
        case .live: nil
        case .projects, .harnesses: "M2"
        case .tasks, .settings: "M3"
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

    /// Reads the flag from the command line, with an environment variable as
    /// the alternative for the case where the launcher owns the argv —
    /// `open -a Auspex` cannot pass arguments through.
    public static func current(
        arguments: [String] = CommandLine.arguments,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> AppLaunchOptions {
        AppLaunchOptions(
            isDemo: arguments.dropFirst().contains("--demo")
                || environment["AUSPEX_DEMO"] == "1"
        )
    }

    /// The mode these options select.
    public var mode: AppEnvironment.Mode { isDemo ? .demo : .live }
}
