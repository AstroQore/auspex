import AgentSessionKit
import AgentSessionLive
import Foundation

/// The user layer, indexed for the board to ask once per session per frame.
///
/// ## Why it is a value on the frame
///
/// Every surface that asks which project a session belongs to asks
/// ``BoardSnapshot/projectKey(for:)``: the wall's sections, the sidebar's
/// tree, a card's subtitle, the scene's floor plates, the trace header. If the
/// user layer were applied in the model, each of those would have to be taught
/// about it separately and one of them would be forgotten. Carrying the claims
/// *on the frame* instead means the answer changes in one place and every
/// reader of that frame gets the same one — which is the same argument that
/// made ``BoardSnapshot`` a value in the first place.
///
/// ## Longest prefix, and why ties are settled by age
///
/// Two projects may claim overlapping trees: `~/Code` and `~/Code/auspex`. The
/// longer claim wins, because it is the one that was made about this directory
/// rather than about the tree it sits in. When two claims are the *same*
/// length the older project keeps it, so adding a project can never silently
/// move somebody else's sessions; the id breaks the last tie so the answer is
/// stable across launches rather than dependent on dictionary order.
public struct ProjectClaims: Sendable, Equatable {
    /// One claimed root, resolved to the project that claimed it.
    struct Claim: Sendable, Equatable {
        let root: String
        let key: String
        let projectID: UUID
        let createdAt: Date
    }

    /// The projects behind the claims, in the order they were given.
    public let projects: [AuspexProject]

    /// Claims, longest root first, so the first match is the answer.
    private let claims: [Claim]
    private let byKey: [String: AuspexProject]

    /// No user projects: every session is placed exactly as the resolver
    /// placed it.
    public static let empty = ProjectClaims(projects: [])

    public init(projects: [AuspexProject]) {
        self.projects = projects
        var claims: [Claim] = []
        var byKey: [String: AuspexProject] = [:]
        for project in projects {
            byKey[project.key] = project
            for root in project.roots where !root.isEmpty {
                claims.append(
                    Claim(
                        root: root,
                        key: project.key,
                        projectID: project.id,
                        createdAt: project.createdAt
                    )
                )
            }
        }
        claims.sort { lhs, rhs in
            if lhs.root.count != rhs.root.count { return lhs.root.count > rhs.root.count }
            if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
            return lhs.projectID.uuidString < rhs.projectID.uuidString
        }
        self.claims = claims
        self.byKey = byKey
    }

    /// `true` when nothing is claimed and the board can skip this layer
    /// entirely.
    public var isEmpty: Bool { claims.isEmpty }

    // MARK: - Asking

    /// The project key claiming `path`, or `nil` when nobody claims it.
    public func key(forPath path: String) -> String? {
        claim(forPath: path)?.key
    }

    /// The project claiming `path`.
    public func project(forPath path: String) -> AuspexProject? {
        claim(forPath: path).flatMap { byKey[$0.key] }
    }

    private func claim(forPath path: String) -> Claim? {
        let path = ProjectPath.normalize(path)
        guard !path.isEmpty else { return nil }
        return claims.first { ProjectPath.contains($0.root, path) }
    }

    /// The project key claiming a session, from whichever of its three
    /// directories is claimed most specifically.
    ///
    /// All three are asked — the worktree it is checked out in, the repository
    /// that worktree belongs to, and the directory the harness was started in
    /// — because a claim on any of them is a claim on the session. A worktree
    /// parked outside its repository is the case that needs it: git says the
    /// project is the repository, and a person who claimed the worktree's
    /// parent directory meant the worktree.
    public func key(for session: SessionSnapshot) -> String? {
        guard !claims.isEmpty else { return nil }
        var best: Claim?
        for path in [
            session.identity.worktreePath, session.identity.gitRoot, session.identity.cwd,
        ] {
            guard let path, let claim = claim(forPath: path) else { continue }
            if best == nil || claim.root.count > (best?.root.count ?? 0) { best = claim }
        }
        return best?.key
    }

    /// The project a board key belongs to, when it is a user project's.
    public func project(forKey key: String) -> AuspexProject? { byKey[key] }

    /// What to call a project key, when a person has named it.
    public func name(forKey key: String) -> String? { byKey[key]?.name }

    /// `#RRGGBB` for a project key, when a colour was chosen.
    public func colorHex(forKey key: String) -> String? { byKey[key]?.colorHex }

    /// Whether a project key belongs to a pinned project. Pinned projects sort
    /// first on every surface that lists projects.
    public func isPinned(_ key: String) -> Bool { byKey[key]?.isPinned ?? false }

    /// Reorders project keys so pinned ones come first, keeping the order
    /// inside each half.
    ///
    /// Stable rather than sorted: the order it is given is the board's, which
    /// puts the project that needs a person at the top, and pinning is a
    /// promotion out of that order rather than a replacement for it.
    public func pinnedFirst<T>(_ items: [T], key: (T) -> String) -> [T] {
        guard !claims.isEmpty, projects.contains(where: \.isPinned) else { return items }
        var pinned: [T] = []
        var rest: [T] = []
        for item in items {
            if isPinned(key(item)) { pinned.append(item) } else { rest.append(item) }
        }
        return pinned + rest
    }
}
