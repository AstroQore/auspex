import AgentSessionKit
import AgentSessionLive
import Foundation

/// Keeps project resolution off the registry's hot path, and does it once per
/// answer rather than once per event.
///
/// A tailer re-reports a session's working directory constantly — Claude Code
/// writes it on every transcript line — so the registry sees hundreds of
/// `identityUpdated(cwd:)` patches saying what the last one said. Resolving a
/// placement means several `stat` calls and two small file reads, and doing
/// that inside the actor that also folds events would put the filesystem on the
/// path of every keystroke a person's agent produces.
///
/// So this is a separate actor with one rule: a `(key, cwd)` pair is resolved
/// **once**. The second report of the same directory for the same session
/// answers `nil`, which is what the caller should do nothing about. That is the
/// whole of the debounce, and it is a better one than a timer — it is exact,
/// it needs no clock, and it makes the tests deterministic.
///
/// Cache invalidation is the resolver's problem, not this one's: a branch
/// switch changes `HEAD`, which is what ``ProjectResolver`` watches. Ask again
/// for the same directory with ``refresh(key:cwd:)`` when a host has reason to
/// think the branch moved.
///
/// ## Scratch before projects
///
/// ``ScratchRules`` are asked first, with the session's harness, and a
/// directory they claim never reaches the resolver: it is placed as scratch
/// and gets no `projects` row. After the resolver, one more question — a
/// directory in no repository that is not on this Mac either is scratch too.
///
/// ## Asking the disk
///
/// A directory that *is* there is remembered, so the `stat` happens once
/// however many sessions report the same folder. A directory that is **not**
/// there is never remembered: a missing folder is the one answer that can
/// change for the better, so every fresh resolution asks again, and the
/// sessions already placed as missing are asked again on every
/// ``missingRecheckInterval`` — the cadence of the ingest layer's own full
/// rediscovery sweep — or when a host calls ``recheckMissing()``.
public actor PlacementService {
    private let resolver: ProjectResolver
    private var rules: ScratchRules
    private let directoryExists: @Sendable (String) -> Bool
    private let clock: @Sendable () -> Date
    private var lastResolved: [SessionKey: String] = [:]
    /// Directories known to be on disk. Only the yes is kept — see the
    /// type's note.
    private var existing: Set<String> = []
    /// What each session placed as missing was last told, so a recheck that
    /// finds the folder still gone does not hand the same answer back.
    private var placedMissing: [SessionKey: ProjectPlacement] = [:]
    /// Sessions whose missing verdict is being asked again.
    private var rechecking: Set<SessionKey> = []
    private var lastMissingCheck: Date

    /// How often the sessions placed as missing are asked about again: once
    /// per full discovery sweep, which the ingest layer runs every minute.
    public static let missingRecheckInterval: TimeInterval = 60

    /// Whether `path` names something on this Mac. The default for
    /// ``init(resolver:rules:directoryExists:clock:)``.
    public static let directoryExists: @Sendable (String) -> Bool = { path in
        FileManager.default.fileExists(atPath: path)
    }

    /// Creates a service over a resolver.
    ///
    /// - Parameters:
    ///   - resolver: answers the directories the rules leave alone.
    ///   - rules: what is scratch before a repository is even looked for.
    ///   - directoryExists: injected so the demo — whose directories are
    ///     invented — and a test can say what is on disk.
    ///   - clock: what ``missingRecheckInterval`` is measured against.
    public init(
        resolver: ProjectResolver = ProjectResolver(),
        rules: ScratchRules = ScratchRules(),
        directoryExists: @escaping @Sendable (String) -> Bool = PlacementService.directoryExists,
        clock: @escaping @Sendable () -> Date = Date.init
    ) {
        self.resolver = resolver
        self.rules = rules
        self.directoryExists = directoryExists
        self.clock = clock
        self.lastMissingCheck = clock()
    }

    /// The placement for a session's directory, or `nil` when this session's
    /// directory has already been resolved and has not changed.
    public func placement(for key: SessionKey, cwd: String) async -> ProjectPlacement? {
        guard !cwd.isEmpty else { return nil }
        guard lastResolved[key] != cwd else { return nil }
        lastResolved[key] = cwd
        let placement = await resolve(cwd: cwd, harness: key.harness)
        let previous = rechecking.remove(key) != nil ? placedMissing[key] : nil
        remember(placement, for: key)
        // A recheck that found the folder still missing has nothing new to
        // say, and saying it again would rewrite the session's row for
        // nothing once a minute.
        if let previous, previous == placement { return nil }
        return placement
    }

    /// Resolves regardless of what was resolved before — for a caller that
    /// knows the branch moved.
    public func refresh(key: SessionKey, cwd: String) async -> ProjectPlacement? {
        guard !cwd.isEmpty else { return nil }
        lastResolved[key] = cwd
        rechecking.remove(key)
        let placement = await resolve(cwd: cwd, harness: key.harness)
        remember(placement, for: key)
        return placement
    }

    /// Placements for every session on a board that has one to resolve,
    /// skipping the ones already answered.
    ///
    /// One pass over a snapshot, which is how a host drives this: after a
    /// frame, ask for whatever is new, and hand the result to
    /// ``SessionRegistry/applyPlacements(_:)``. Once per
    /// ``missingRecheckInterval`` it first lets go of every missing verdict,
    /// so a folder that came back is found on this pass.
    public func placements(for identities: [SessionIdentity]) async -> [SessionKey: ProjectPlacement] {
        let now = clock()
        if now.timeIntervalSince(lastMissingCheck) >= Self.missingRecheckInterval {
            lastMissingCheck = now
            recheckMissing()
        }
        var out: [SessionKey: ProjectPlacement] = [:]
        for identity in identities {
            guard let cwd = identity.cwd,
                  let placement = await placement(for: identity.key, cwd: cwd)
            else { continue }
            out[identity.key] = placement
        }
        return out
    }

    /// Replaces the person's own scratch folders.
    ///
    /// A change forgets every answer, so the next pass places every session
    /// again under the new rules — a folder just marked as scratch leaves the
    /// project list on the next tick rather than on the next launch. The
    /// resolver's cache is kept: a repository did not move because a rule did.
    public func setUserScratchPrefixes(_ prefixes: [String]) {
        let next = ScratchRules(home: rules.home, userPrefixes: prefixes)
        guard next != rules else { return }
        rules = next
        lastResolved.removeAll(keepingCapacity: true)
    }

    /// The rules in force. Test seam.
    public var scratchRules: ScratchRules { rules }

    /// Asks again about every session placed under a folder that was missing.
    ///
    /// For a host that knows a full discovery sweep just ran; the service also
    /// does this on its own once per ``missingRecheckInterval``. The next
    /// ``placements(for:)`` pass resolves those sessions afresh, and hands
    /// back only the ones whose answer changed.
    public func recheckMissing() {
        existing.removeAll(keepingCapacity: true)
        for key in placedMissing.keys {
            lastResolved[key] = nil
            rechecking.insert(key)
        }
    }

    /// Forgets what has been resolved, so the next report of any directory
    /// resolves again.
    public func forgetAll() {
        lastResolved.removeAll(keepingCapacity: true)
        existing.removeAll(keepingCapacity: true)
        placedMissing.removeAll(keepingCapacity: true)
        rechecking.removeAll(keepingCapacity: true)
        Task { [resolver] in await resolver.invalidateAll() }
    }

    /// Forgets one session — a host calls this when a session is re-seeded.
    public func forget(_ key: SessionKey) {
        lastResolved[key] = nil
        placedMissing[key] = nil
        rechecking.remove(key)
    }

    // MARK: - Resolving

    private func remember(_ placement: ProjectPlacement, for key: SessionKey) {
        if placement.placementNote == ScratchRules.Reason.missing.rawValue {
            placedMissing[key] = placement
        } else {
            placedMissing[key] = nil
        }
    }

    private func resolve(cwd: String, harness: Harness) async -> ProjectPlacement {
        if let match = rules.match(cwd: cwd, harness: harness) {
            return .scratch(match)
        }
        let placement = await resolver.resolve(cwd: cwd)
        // A directory inside a repository is placed by the repository whether
        // or not this checkout is still on disk: an agent worktree removed
        // after its branch merged still belongs to the project it was cut
        // from, and the walk up already found it.
        guard !placement.isProjectless, placement.gitRoot == nil else { return placement }
        guard !exists(placement.projectRootPath) else { return placement }
        return .scratch(ScratchRules.missing(directory: placement.projectRootPath))
    }

    private func exists(_ directory: String) -> Bool {
        if existing.contains(directory) { return true }
        guard directoryExists(directory) else { return false }
        existing.insert(directory)
        return true
    }
}
