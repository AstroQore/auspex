import AgentSessionKit
import AgentSessionLive
import Foundation

/// A project the *person* decided on, on top of the ones the resolver derives.
///
/// ## Why there are two layers at all
///
/// ``ProjectResolver`` answers "which repository is this directory in", and it
/// answers it well enough that most boards never need anything else: three
/// worktrees of one checkout are one project without anybody being asked. What
/// it cannot answer is the question that has no answer on disk — *these six
/// directories are one piece of work*. A monorepo split across two clones, a
/// service and the terraform that deploys it, a scratch directory that belongs
/// with the repository it is a scratch directory for: none of that is written
/// down anywhere for a resolver to find.
///
/// So the automatic layer stays exactly as it is, and this sits over it. A user
/// project **claims** roots; any session working under a claimed root is placed
/// in it, whatever git says. Claims win over automatic placement, and when two
/// claim the same directory the longer root wins — the specific claim is the
/// one that was made about *this* directory rather than about the tree it
/// happens to sit in.
///
/// ## Why the members are kept
///
/// ``members`` are the harness project entries a person imported — an entry in
/// `~/.claude.json`'s `projects`, a `[projects."…"]` table in Codex's config.
/// They are kept beside the roots rather than folded into them because they
/// record *where the claim came from*: a root a person typed and a root that
/// arrived from Claude Code's registry look identical afterwards, and only one
/// of them can be refreshed by importing again.
public struct AuspexProject: Codable, Sendable, Hashable, Identifiable {
    /// Who made this project.
    public enum Origin: String, Codable, Sendable {
        /// Derived by the resolver. Nothing writes one of these today — the
        /// automatic layer needs no row — but the case exists so a project
        /// that gets promoted from one keeps its history.
        case auto
        /// Somebody made it in the Projects page.
        case user
        /// It came in from a harness registry.
        case imported = "import"
    }

    public let id: UUID
    /// What the board, the sidebar and the scene call it.
    public var name: String
    /// A colour for the row, as `#RRGGBB`. `nil` uses the board's own.
    public var colorHex: String?
    /// The directories this project claims. Any number, in the order they were
    /// added; the first is also the project's board key — see ``key``.
    public var roots: [String]
    /// The harness registry entries this project was imported from.
    public var members: [HarnessProjectRef]
    /// Pinned projects sort first everywhere a project is listed.
    public var isPinned: Bool
    /// Where it came from.
    public var createdBy: Origin
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        name: String,
        colorHex: String? = nil,
        roots: [String] = [],
        members: [HarnessProjectRef] = [],
        isPinned: Bool = false,
        createdBy: Origin = .user,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.colorHex = colorHex
        self.roots = roots.map(ProjectPath.normalize)
        self.members = members
        self.isPinned = isPinned
        self.createdBy = createdBy
        self.createdAt = createdAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, colorHex = "color", roots, members
        case isPinned = "pinned", createdBy, createdAt
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        colorHex = try container.decodeIfPresent(String.self, forKey: .colorHex)
        roots = (try container.decodeIfPresent([String].self, forKey: .roots) ?? [])
            .map(ProjectPath.normalize)
        members = try container.decodeIfPresent([HarnessProjectRef].self, forKey: .members) ?? []
        isPinned = try container.decodeIfPresent(Bool.self, forKey: .isPinned) ?? false
        createdBy = try container.decodeIfPresent(Origin.self, forKey: .createdBy) ?? .user
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
    }

    /// The key this project's sessions group under.
    ///
    /// The first root, so a user project's key is still a path and every
    /// surface that already knows how to show one — the sidebar, the section
    /// header, the scene's floor plate — keeps working without being taught a
    /// new kind of key. A project with no roots yet claims nothing, and gets a
    /// key nothing can match rather than an empty string that would collide
    /// with the residue.
    public var key: String {
        roots.first ?? "\(AuspexProject.unclaimedPrefix)\(id.uuidString)"
    }

    /// What the key of a rootless project begins with. Never a path, so it can
    /// never collide with one.
    public static let unclaimedPrefix = "auspex-project:"

    /// Whether this project claims `path` — the path itself, or anything under
    /// it. Returns the matching root, so a caller can compare lengths.
    public func claimedRoot(for path: String) -> String? {
        let path = ProjectPath.normalize(path)
        return roots
            .filter { ProjectPath.contains($0, path) }
            .max { $0.count < $1.count }
    }

    /// Adds a root, normalised, if it is not already claimed by this project.
    public mutating func addRoot(_ path: String) {
        let root = ProjectPath.normalize(path)
        guard !root.isEmpty, !roots.contains(root) else { return }
        roots.append(root)
    }

    /// Removes a root and any imported member that named it.
    public mutating func removeRoot(_ path: String) {
        let root = ProjectPath.normalize(path)
        roots.removeAll { $0 == root }
        members.removeAll { ProjectPath.normalize($0.path) == root }
    }

    /// Adds an imported registry entry and the root it names.
    public mutating func add(member: HarnessProjectRef) {
        let root = ProjectPath.normalize(member.path)
        if let index = members.firstIndex(where: {
            $0.harness == member.harness && ProjectPath.normalize($0.path) == root
        }) {
            members[index] = member
        } else {
            members.append(member)
        }
        addRoot(root)
    }
}

/// One entry in a harness's own project registry.
///
/// Read-only in the strongest sense: Auspex takes the path and, where the
/// registry records one, when it was last touched. Nothing else in those files
/// is read, and nothing is ever written back — `AGENTS.md` § 6 applies to a
/// harness's registry exactly as it applies to its transcripts.
public struct HarnessProjectRef: Codable, Sendable, Hashable, Identifiable {
    /// Which harness's registry this came from.
    public let harness: Harness
    /// The working directory the registry names.
    public let path: String
    /// When the registry last recorded activity there, when it records that at
    /// all. `nil` is "not recorded", never "long ago".
    public var lastSeen: Date?

    public var id: String { "\(harness.rawValue)\u{1F}\(path)" }

    public init(harness: Harness, path: String, lastSeen: Date? = nil) {
        self.harness = harness
        self.path = path
        self.lastSeen = lastSeen
    }

    /// The last path component, for a list that cannot show a whole path.
    public var displayName: String {
        BoardGrouping.projectName(forPath: path)
    }
}

/// Path arithmetic for claims: one normalisation and one containment test,
/// in one place.
///
/// Both are string operations on purpose. A claim is checked against every
/// session on every frame, and a `realpath` per check would put the filesystem
/// on the board's render path for a question that a comparison already answers
/// — the resolver has already done the work of turning a session's directory
/// into a real one.
public enum ProjectPath {
    /// Trims whitespace, expands a leading `~`, resolves `.`/`..`, and drops a
    /// trailing slash so `/a/b/` and `/a/b` are the same claim.
    ///
    /// The `~` is expanded through ``AuspexPaths/realHomeDirectory()`` rather
    /// than through `NSString.expandingTildeInPath`, which reads `$HOME` — a
    /// stray `HOME` in a spawned agent's environment would otherwise turn a
    /// person's claim into a claim on somebody else's directory.
    public static func normalize(_ path: String) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        var expanded = trimmed
        if trimmed == "~" || trimmed.hasPrefix("~/") {
            expanded = AuspexPaths.realHomeDirectory().path + trimmed.dropFirst(1)
        }
        // Through `PathText.native`: `standardizingPath` hands back a bridged
        // `NSString`, this is a *project key*, and a project key is compared
        // on every frame by everything that groups by one. See ``PathText``.
        let standardized = PathText.native((expanded as NSString).standardizingPath)
        guard standardized.count > 1, standardized.hasSuffix("/") else { return standardized }
        return String(standardized.dropLast())
    }

    /// Whether `path` is `root` or sits under it.
    ///
    /// Component-wise, so `/a/bc` is not under `/a/b`. Both arguments are
    /// expected to be normalised already; the check is a prefix comparison and
    /// runs per session per frame.
    public static func contains(_ root: String, _ path: String) -> Bool {
        guard !root.isEmpty, !path.isEmpty else { return false }
        if root == path { return true }
        if root == "/" { return path.hasPrefix("/") }
        return path.hasPrefix(root + "/")
    }
}
