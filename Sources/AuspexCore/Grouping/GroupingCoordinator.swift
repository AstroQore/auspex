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
/// It is not an actor, so ``tick()`` can be called from a test as readily as
/// from ``run(every:)``. The one thing it carries from pass to pass is a
/// ``LinkerMemo``: which identities the last inference ran over, and the
/// environments it has already read.
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
    /// What the last passes already worked out.
    let memo: LinkerMemo
    /// Which Codex threads another thread spawned, one header read per
    /// thread.
    let spawns: CodexSpawnMemo

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
        self.init(registry: registry, table: table, placements: placements, linker: linker, memo: LinkerMemo())
    }

    init(
        registry: SessionRegistry,
        table: any ProcessTableReading,
        placements: PlacementService = PlacementService(),
        linker: ProcessLinker = ProcessLinker(),
        memo: LinkerMemo,
        spawns: CodexSpawnMemo = CodexSpawnMemo()
    ) {
        self.registry = registry
        self.table = table
        self.placements = placements
        self.linker = linker
        self.memo = memo
        self.spawns = spawns
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
    /// The process inference runs only when an identity it reads — a key, a
    /// pid, a process start, a parent — moved since the last pass that ran
    /// it; on a quiet machine every pass after the first proposes exactly
    /// what the registry already applied or refused. It still runs over every
    /// identity when it does run, because the kit's index of candidate
    /// parents needs all of them. Environments come through the memo either
    /// way, so a process is read once per ``LinkerMemo/environmentLifetime``.
    ///
    /// - Returns: how many placements and how many links were applied, which is
    ///   what a test asserts on and what a host can log.
    ///
    /// Codex threads another thread spawned are tagged first (see
    /// ``CodexThreadSpawn``) and kept out of placement: the project they
    /// belong to is their parent's, which ``BoardSnapshot/projectKey(for:)``
    /// finds by walking up, and their own directory would only invent one.
    @discardableResult
    public func tick() async -> (placements: Int, links: Int) {
        var identities = await registry.linkableIdentities()
        guard !identities.isEmpty else { return (0, 0) }

        let variants = spawns.pendingVariants(for: identities)
        if !variants.isEmpty {
            await registry.applyVariants(variants)
            // This pass reads the tags it just wrote, so the spawn is kept
            // out of placement and linked to its parent now rather than three
            // seconds from now.
            identities = identities.map { identity in
                guard let variant = variants[identity.key] else { return identity }
                var tagged = identity
                tagged.variant = variant
                return tagged
            }
        }

        let placeable = identities.filter { !SessionRelations.isThreadSpawn($0) }
        let resolved = await placements.placements(for: placeable)
        let placed = await registry.applyPlacements(resolved)

        var links = SessionRelations.links(identities: identities)
        if !memo.isUnchanged(identities) {
            memo.prune()
            links += linker.infer(
                identities: identities,
                table: MemoizedEnvironmentTable(base: table, memo: memo)
            )
        }
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
