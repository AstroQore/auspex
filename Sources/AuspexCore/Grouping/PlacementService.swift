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
public actor PlacementService {
    private let resolver: ProjectResolver
    private var lastResolved: [SessionKey: String] = [:]

    /// Creates a service over a resolver.
    public init(resolver: ProjectResolver = ProjectResolver()) {
        self.resolver = resolver
    }

    /// The placement for a session's directory, or `nil` when this session's
    /// directory has already been resolved and has not changed.
    public func placement(for key: SessionKey, cwd: String) async -> ProjectPlacement? {
        guard !cwd.isEmpty else { return nil }
        guard lastResolved[key] != cwd else { return nil }
        lastResolved[key] = cwd
        return await resolver.resolve(cwd: cwd)
    }

    /// Resolves regardless of what was resolved before — for a caller that
    /// knows the branch moved.
    public func refresh(key: SessionKey, cwd: String) async -> ProjectPlacement? {
        guard !cwd.isEmpty else { return nil }
        lastResolved[key] = cwd
        return await resolver.resolve(cwd: cwd)
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

    /// Forgets what has been resolved, so the next report of any directory
    /// resolves again.
    public func forgetAll() {
        lastResolved.removeAll(keepingCapacity: true)
        Task { [resolver] in await resolver.invalidateAll() }
    }

    /// Forgets one session — a host calls this when a session is re-seeded.
    public func forget(_ key: SessionKey) {
        lastResolved[key] = nil
    }
}
