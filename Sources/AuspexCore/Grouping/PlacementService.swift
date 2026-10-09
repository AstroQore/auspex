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
/// That one needs the disk, so its answer is remembered per directory and the
/// `stat` happens once however many sessions report the same folder.
public actor PlacementService {
    private let resolver: ProjectResolver
    private var rules: ScratchRules
    private let directoryExists: @Sendable (String) -> Bool
    private var lastResolved: [SessionKey: String] = [:]
    /// Whether a directory with no repository around it is on disk, by
    /// directory. Asked once per directory, not once per session.
    private var existence: [String: Bool] = [:]

    /// Whether `path` names something on this Mac. The default for
    /// ``init(resolver:rules:directoryExists:)``.
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
    public init(
        resolver: ProjectResolver = ProjectResolver(),
        rules: ScratchRules = ScratchRules(),
        directoryExists: @escaping @Sendable (String) -> Bool = PlacementService.directoryExists
    ) {
        self.resolver = resolver
        self.rules = rules
        self.directoryExists = directoryExists
    }

    /// The placement for a session's directory, or `nil` when this session's
    /// directory has already been resolved and has not changed.
    public func placement(for key: SessionKey, cwd: String) async -> ProjectPlacement? {
        guard !cwd.isEmpty else { return nil }
        guard lastResolved[key] != cwd else { return nil }
        lastResolved[key] = cwd
        return await resolve(cwd: cwd, harness: key.harness)
    }

    /// Resolves regardless of what was resolved before — for a caller that
    /// knows the branch moved.
    public func refresh(key: SessionKey, cwd: String) async -> ProjectPlacement? {
        guard !cwd.isEmpty else { return nil }
        lastResolved[key] = cwd
        return await resolve(cwd: cwd, harness: key.harness)
    }

    /// Placements for every session on a board that has one to resolve,
    /// skipping the ones already answered.
    ///
    /// One pass over a snapshot, which is how a host drives this: after a
    /// frame, ask for whatever is new, and hand the result to
    /// ``SessionRegistry/applyPlacements(_:)``.
    public func placements(for identities: [SessionIdentity]) async -> [SessionKey: ProjectPlacement] {
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

    /// Forgets what has been resolved, so the next report of any directory
    /// resolves again.
    public func forgetAll() {
        lastResolved.removeAll(keepingCapacity: true)
        existence.removeAll(keepingCapacity: true)
        Task { [resolver] in await resolver.invalidateAll() }
    }

    /// Forgets one session — a host calls this when a session is re-seeded.
    public func forget(_ key: SessionKey) {
        lastResolved[key] = nil
    }

    // MARK: - Resolving

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
        if let known = existence[directory] { return known }
        let answer = directoryExists(directory)
        existence[directory] = answer
        return answer
    }
}
