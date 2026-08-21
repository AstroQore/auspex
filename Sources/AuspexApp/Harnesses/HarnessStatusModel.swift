import AgentSessionKit
import AuspexCore
import Foundation
import Observation

/// The Harnesses page's state: what is installed on this Mac, and what each
/// harness has been told about MCP.
///
/// Both answers come off disk, and neither changes while a person watches, so
/// they are read once at start and then on a slow timer rather than derived per
/// frame. The counts on the page are not here at all — they come from the
/// board, which already has them, and re-deriving them on a timer would let the
/// page disagree with the wall.
@MainActor
@Observable
final class HarnessStatusModel {
    /// The harnesses whose store exists on this Mac. The counts are filled in
    /// against a frame by ``rows(board:)``.
    private(set) var detected: Set<Harness> = []

    /// What each harness's config file says.
    private(set) var configs: [Harness: HarnessMCPConfig] = [:]

    /// When the files were last read.
    private(set) var refreshedAt: Date?

    /// `true` while the first read is in flight.
    private(set) var isLoading = false

    private var watchRoots: [Harness: [URL]] = [:]
    private var home = AuspexPaths.realHomeDirectory()
    private var refreshTask: Task<Void, Never>?

    /// How often the config files are re-read. A person edits one of these,
    /// switches back, and expects the page to have noticed — half a minute is
    /// short enough for that and long enough to cost nothing.
    private static let refreshInterval = Duration.seconds(30)

    /// The harnesses this page reports on: the five a person is likely to be
    /// running.
    let harnesses = AuspexAdapters.featured

    /// A demo's stand-in: every harness "detected", and a fabricated MCP
    /// table for each.
    ///
    /// The page (and any offscreen render of it) must never show this Mac's
    /// real MCP server names under a fabricated board, so a demo does not get
    /// the file-reading loop at all — it gets a plausible fiction with nothing
    /// in it that came off the machine.
    ///
    /// Fabricated rather than empty. The MCP column is the half of this page
    /// that answers "what can this harness reach", and a demo that left it
    /// blank could not show the page working — nor the thing that went wrong
    /// with it, which only happens to a harness with a long list.
    func startFabricated() {
        refreshTask?.cancel()
        refreshTask = nil
        detected = Set(harnesses)
        configs = Dictionary(
            uniqueKeysWithValues: harnesses.compactMap { harness in
                Self.fabricatedConfig(for: harness).map { (harness, $0) }
            }
        )
        refreshedAt = Date()
        isLoading = false
    }

    /// The invented MCP table one harness gets in a demo.
    ///
    /// `nil` for the two harnesses that have no local config file at all, so
    /// the demo shows the same "managed by Claude.app" note the real page
    /// does. The names are made up and the list is deliberately long for the
    /// first one: eight servers in a squeezed column is the case that broke.
    private static func fabricatedConfig(for harness: Harness) -> HarnessMCPConfig? {
        guard let location = HarnessMCPConfigStore.location(
            for: harness, home: URL(fileURLWithPath: "/Users/example")
        ) else { return nil }
        let global: [String]
        var scoped: [String] = []
        switch harness {
        case .claudeCode:
            global = [
                "auspex", "chrome-control", "filesystem", "ledger-observability",
                "notes", "postgres", "sequential-thinking", "weather-desk"
            ]
            scoped = ["storefront-fixtures"]
        case .codex:
            global = ["auspex", "filesystem", "postgres"]
        case .cursor:
            global = ["filesystem", "notes"]
            scoped = ["mobile-client-devtools"]
        case .chatgptWork:
            global = ["auspex", "filesystem", "postgres"]
        default:
            global = ["filesystem"]
        }
        return HarnessMCPConfig(
            harness: harness,
            location: location,
            exists: true,
            serverNames: global,
            scopedServerNames: scoped,
            didParse: true
        )
    }

    /// Starts reading, and keeps re-reading until ``stop()``.
    func start(home: URL, watchRoots: [Harness: [URL]]) {
        self.home = home
        self.watchRoots = watchRoots
        refreshTask?.cancel()
        isLoading = true
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                do {
                    try await Task.sleep(for: Self.refreshInterval)
                } catch {
                    return
                }
            }
        }
    }

    func stop() {
        refreshTask?.cancel()
        refreshTask = nil
    }

    /// Re-reads detection and configuration, off the main actor.
    ///
    /// `~/.claude.json` is a few hundred kilobytes of JSON that has nothing to
    /// do with drawing a window, and parsing it on the main actor would drop
    /// frames on the wall next door for no reason.
    func refresh() async {
        let harnesses = harnesses
        let roots = watchRoots
        let store = HarnessMCPConfigStore(homeDirectory: home)

        let read = await Task.detached(priority: .utility) {
            () -> (detected: Set<Harness>, configs: [Harness: HarnessMCPConfig]) in
            let fileManager = FileManager.default
            var detected: Set<Harness> = []
            var configs: [Harness: HarnessMCPConfig] = [:]
            for harness in harnesses {
                let exists = (roots[harness] ?? []).contains {
                    fileManager.fileExists(atPath: $0.path)
                }
                if exists { detected.insert(harness) }
                configs[harness] = store.config(for: harness)
            }
            return (detected, configs)
        }.value

        detected = read.detected
        configs = read.configs
        refreshedAt = Date()
        isLoading = false
    }

    /// The page's rows for one frame.
    func rows(board: BoardSnapshot, units: [TaskUnit] = []) -> [HarnessStatus] {
        HarnessStatus.rows(
            harnesses: harnesses,
            board: board,
            storePaths: storePaths,
            detected: detected,
            configs: configs,
            units: units
        )
    }

    /// The store to name per harness: the first root its adapter watches.
    private var storePaths: [Harness: String] {
        watchRoots.compactMapValues { $0.first?.path }
    }
}
