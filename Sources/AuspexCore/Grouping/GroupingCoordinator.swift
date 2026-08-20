import AgentSessionKit
import AgentSessionLive
import Foundation

/// Drives the two questions that are answered by looking at the machine rather
/// than at a log: where a session is, and who started it.
///
/// Deliberately thin. Everything it calls is separately testable —
/// ``ProjectResolver`` against a temporary tree, ``ProcessLinker`` against a
/// fixed process table, ``SessionRegistry/applyPlacements(_:)`` and
/// ``SessionRegistry/applyLinks(_:)`` against a scripted board — and what is
/// left here is the order they run in and the interval they run on.
///
/// It is not an actor and holds no state, so ``tick()`` can be called from a
/// test as readily as from ``run(every:)``.
///
/// ## Why it is not inside the registry
///
/// Reading the process table is `sysctl`, and resolving a placement is
/// `stat`. Both are cheap and neither belongs on an actor that also folds
/// every event a dozen agents produce — a registry that waited on the
/// filesystem would stall the board behind it. So the work happens on this
/// task, against a snapshot of the identities, and only the answers cross back
/// in.
public struct GroupingCoordinator: Sendable {
    /// The board to read from and write back to.
    public let registry: SessionRegistry
    /// Resolves and debounces working directories.
    public let placements: PlacementService
    /// Infers parent links.
    public let linker: ProcessLinker
    /// The process table both the linker and its evidence come from.
    public let table: any ProcessTableReading

    /// Creates a coordinator.
    ///
    /// - Parameters:
    ///   - registry: the live set.
    ///   - table: the process table. `ProcessTable` caches for three seconds,
    ///     so a tick on the same cadence costs one read.
    ///   - placements: injectable so a host can share one resolver with
    ///     whatever else needs it.
    ///   - linker: injectable for its `commandWindow`.
    public init(
        registry: SessionRegistry,
        table: any ProcessTableReading,
        placements: PlacementService = PlacementService(),
        linker: ProcessLinker = ProcessLinker()
    ) {
        self.registry = registry
        self.table = table
        self.placements = placements
        self.linker = linker
    }

    /// One pass: resolve the directories that changed, then apply the links —
    /// the ones a harness recorded in an identity, and the ones the process
    /// table can see.
    ///
    /// Placements first, because a link moves a child under its parent's
    /// project and the parent's project should be known by then.
    ///
    /// Recorded relationships are proposed ahead of inferred ones so that a
    /// pass which finds both for the same child applies the recorded one.
    /// ``SessionRegistry/applyLinks(_:)`` fills blanks in order, and
    /// ``SessionIdentityPatch/applied(to:)`` would refuse the weaker evidence
    /// afterwards anyway — the order is what makes that agreement visible here
    /// rather than only two files away.
    ///
    /// - Returns: how many placements and how many links were applied, which is
    ///   what a test asserts on and what a host can log.
    @discardableResult
    public func tick() async -> (placements: Int, links: Int) {
        let identities = await registry.linkableIdentities()
        guard !identities.isEmpty else { return (0, 0) }

        let resolved = await placements.placements(for: identities)
        let placed = await registry.applyPlacements(resolved)

        let links = SessionRelations.links(identities: identities)
            + linker.infer(identities: identities, table: table)
        let linked = await registry.applyLinks(links)
        return (placed, linked)
    }

    /// Ticks on `interval` until the surrounding task is cancelled.
    ///
    /// Three seconds matches the liveness cadence and `ProcessTable`'s own
    /// cache window: a parent link that appears one tick after the child does
    /// is a row that settles into place while a person is still reading the
    /// first line of it.
    public func run(every interval: Duration = .seconds(3)) async {
        while !Task.isCancelled {
            await tick()
            do {
                try await Task.sleep(for: interval)
            } catch {
                return
            }
        }
    }
}
