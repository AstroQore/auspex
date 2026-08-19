import AgentSessionKit
import AgentSessionLive
import Foundation

/// One reason a session should not be on the board.
///
/// ## Ignored is not deleted
///
/// A rule hides a session from every *view* — the wall, the scene, the crew,
/// the sidebar's counts, the menu bar — and changes nothing else. The session
/// is still ingested, its events are still stored, and its text is still in the
/// search index, because the thing a person is asking for when they ignore a
/// folder is a quieter board, not a hole in their history. Every surface that
/// offers a rule says so.
///
/// ## Why the kinds are these five
///
/// Each one is a different answer to "what makes this session uninteresting",
/// and none of them can be expressed as another:
///
/// - ``Kind/pathPrefix(_:)`` — a directory and everything under it. The
///   common case: a scratch tree, a vendored checkout, somebody else's repo.
/// - ``Kind/project(_:)`` — one project, however its sessions are placed. Not
///   the same as a path: a user project claims several roots, and a subagent
///   with no directory of its own still belongs to it.
/// - ``Kind/promptPrefix(_:)`` — every session that started with the same
///   words. This is how a scripted or scheduled agent is silenced without
///   silencing the harness that runs it.
/// - ``Kind/harness(_:)`` — a whole harness, for a machine where one of them
///   is somebody else's business.
/// - ``Kind/titleContains(_:)`` — the escape hatch, for the sessions that
///   share a word and nothing else.
public struct IgnoreRule: Codable, Sendable, Hashable, Identifiable {
    /// What the rule matches on.
    public enum Kind: Sendable, Hashable {
        /// A directory, matched against a session's worktree, git root, and
        /// working directory, component-wise.
        case pathPrefix(String)
        /// A project, by board key, by user-project id, or by display name.
        case project(String)
        /// The opening of the session's first prompt.
        case promptPrefix(String)
        /// Every session of one harness.
        case harness(Harness)
        /// A substring of the session's title, case-insensitive.
        case titleContains(String)

        /// The name shown in the rules list.
        public var label: String {
            switch self {
            case .pathPrefix: "Folder"
            case .project: "Project"
            case .promptPrefix: "Prompt starts with"
            case .harness: "Harness"
            case .titleContains: "Title contains"
            }
        }

        /// What the rule is about, as one string — a path, a project, a
        /// harness's full name.
        public var value: String {
            switch self {
            case .pathPrefix(let value), .project(let value),
                 .promptPrefix(let value), .titleContains(let value):
                value
            case .harness(let harness): harness.displayName
            }
        }

        /// The stored discriminator. Kept as a plain string so a rule of a
        /// kind a future build adds costs that rule rather than the file.
        var storedType: String {
            switch self {
            case .pathPrefix: "pathPrefix"
            case .project: "project"
            case .promptPrefix: "promptPrefix"
            case .harness: "harness"
            case .titleContains: "titleContains"
            }
        }

        /// A kind without its payload — what a picker offers and what a
        /// prefilled sheet is opened with.
        ///
        /// In Core rather than in the settings pane because the same five
        /// choices appear in three places (the pane's add row, the card's
        /// context menu, the sidebar's), and three lists of five would be
        /// three chances for one of them to be missing a kind.
        public enum Tag: String, CaseIterable, Sendable, Identifiable, Codable {
            case pathPrefix, project, promptPrefix, harness, titleContains

            public var id: String { rawValue }

            /// The picker's label.
            public var label: String {
                Kind.example(for: self).label
            }

            /// What the text field says when it is empty.
            public var placeholder: String {
                switch self {
                case .pathPrefix: "/Users/you/Code/vendor"
                case .project: "A project's name"
                case .promptPrefix: "chore:"
                case .harness: "A harness's name"
                case .titleContains: "nightly"
                }
            }

            /// One line saying what the rule will do, under the field.
            public var explanation: String {
                switch self {
                case .pathPrefix:
                    "Hides every session working in that folder or under it."
                case .project:
                    "Hides a whole project, however its sessions were placed."
                case .promptPrefix:
                    "Hides sessions whose first prompt starts with this."
                case .harness:
                    "Hides every session of one harness."
                case .titleContains:
                    "Hides sessions whose title contains this, ignoring case."
                }
            }
        }

        /// Which tag this kind is.
        public var tag: Tag {
            switch self {
            case .pathPrefix: .pathPrefix
            case .project: .project
            case .promptPrefix: .promptPrefix
            case .harness: .harness
            case .titleContains: .titleContains
            }
        }

        /// Builds a kind from a tag and a typed value. `nil` when the value is
        /// empty, or when a harness rule names a harness Auspex does not know.
        public static func make(tag: Tag, value: String) -> Kind? {
            let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { return nil }
            switch tag {
            case .pathPrefix: return .pathPrefix(ProjectPath.normalize(value))
            case .project: return .project(value)
            case .promptPrefix: return .promptPrefix(value)
            case .titleContains: return .titleContains(value)
            case .harness:
                if let harness = Harness(rawValue: value) { return .harness(harness) }
                guard let harness = Harness.allCases.first(where: {
                    $0.displayName.caseInsensitiveCompare(value) == .orderedSame
                }) else { return nil }
                return .harness(harness)
            }
        }

        /// A kind of each tag, for the label. Never shown.
        private static func example(for tag: Tag) -> Kind {
            switch tag {
            case .pathPrefix: .pathPrefix("")
            case .project: .project("")
            case .promptPrefix: .promptPrefix("")
            case .harness: .harness(.claudeCode)
            case .titleContains: .titleContains("")
            }
        }

        var storedValue: String {
            switch self {
            case .pathPrefix(let value), .project(let value),
                 .promptPrefix(let value), .titleContains(let value):
                value
            case .harness(let harness): harness.rawValue
            }
        }

        init?(storedType: String, storedValue: String) {
            switch storedType {
            case "pathPrefix": self = .pathPrefix(storedValue)
            case "project": self = .project(storedValue)
            case "promptPrefix": self = .promptPrefix(storedValue)
            case "titleContains": self = .titleContains(storedValue)
            case "harness":
                guard let harness = Harness(rawValue: storedValue) else { return nil }
                self = .harness(harness)
            default: return nil
            }
        }
    }

    public let id: UUID
    public var kind: Kind
    /// Switched off rather than deleted, so a rule can be tried and untried
    /// without being retyped.
    public var isEnabled: Bool
    public let createdAt: Date

    public init(
        id: UUID = UUID(),
        kind: Kind,
        isEnabled: Bool = true,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.kind = kind
        self.isEnabled = isEnabled
        self.createdAt = createdAt
    }

    // MARK: - Coding

    /// Flat on disk — `{"id":…, "type":"pathPrefix", "value":"/…", …}` —
    /// rather than Swift's nested enum encoding, because the file is one a
    /// person may open and edit.
    private enum CodingKeys: String, CodingKey {
        case id, type, value, enabled, createdAt
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        let type = try container.decode(String.self, forKey: .type)
        let value = try container.decode(String.self, forKey: .value)
        guard let kind = Kind(storedType: type, storedValue: value) else {
            throw DecodingError.dataCorruptedError(
                forKey: .type,
                in: container,
                debugDescription: "Unknown ignore rule kind \(type)."
            )
        }
        self.kind = kind
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(kind.storedType, forKey: .type)
        try container.encode(kind.storedValue, forKey: .value)
        try container.encode(isEnabled, forKey: .enabled)
        try container.encode(createdAt, forKey: .createdAt)
    }
}

/// The enabled rules, ready to be asked about a session.
///
/// A value rather than an array so the "is this hidden" question is answered in
/// one place, and so the *disabled* rules are dropped once per change instead
/// of once per session per frame.
public struct IgnoreRules: Sendable, Equatable {
    /// Every rule, enabled or not, in display order.
    public let all: [IgnoreRule]
    /// The ones that are on.
    public let active: [IgnoreRule]

    public static let none = IgnoreRules([])

    public init(_ rules: [IgnoreRule]) {
        all = rules
        active = rules.filter(\.isEnabled)
    }

    /// `true` when nothing is being hidden and the board can skip the filter.
    public var isEmpty: Bool { active.isEmpty }

    /// Whether a session matches any active rule.
    ///
    /// - Parameters:
    ///   - session: the session to judge.
    ///   - projectKey: the key the *board* placed it under, which is not
    ///     always a key the session could have produced on its own — a
    ///     subagent inherits its parent's, and a user project's claim replaces
    ///     whatever git said. Passing it in is what makes "ignore this
    ///     project" mean the same thing as the section header a person clicked.
    ///   - claims: the user layer, for resolving a rule that named a project by
    ///     id or by name rather than by key.
    public func matches(
        _ session: SessionSnapshot,
        projectKey: String?,
        claims: ProjectClaims = .empty
    ) -> Bool {
        active.contains { matches($0, session, projectKey, claims) }
    }

    private func matches(
        _ rule: IgnoreRule,
        _ session: SessionSnapshot,
        _ projectKey: String?,
        _ claims: ProjectClaims
    ) -> Bool {
        switch rule.kind {
        case .harness(let harness):
            return session.key.harness == harness

        case .pathPrefix(let prefix):
            let root = ProjectPath.normalize(prefix)
            guard !root.isEmpty else { return false }
            for path in [
                session.identity.worktreePath, session.identity.gitRoot, session.identity.cwd,
            ] {
                guard let path else { continue }
                if ProjectPath.contains(root, ProjectPath.normalize(path)) { return true }
            }
            return false

        case .project(let value):
            guard let projectKey else { return false }
            if projectKey == value { return true }
            if let project = claims.project(forKey: projectKey) {
                if project.id.uuidString.caseInsensitiveCompare(value) == .orderedSame {
                    return true
                }
                if project.name.caseInsensitiveCompare(value) == .orderedSame { return true }
            }
            let name = claims.name(forKey: projectKey)
                ?? BoardGrouping.projectName(forPath: projectKey)
            return name.caseInsensitiveCompare(value) == .orderedSame

        case .promptPrefix(let prefix):
            // The assignment as the person typed it. The title is the
            // fallback and not the answer: a harness that names its own
            // threads writes a summary there, and a session whose transcript
            // has not been read far enough yet has no brief at all — matching
            // its title is still the closest thing to what was asked, and it
            // stops being used the moment the first prompt arrives.
            let value = prefix.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { return false }
            guard let asked = session.brief.firstPrompt ?? session.identity.title
            else { return false }
            return asked
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
                .hasPrefix(value.lowercased())

        case .titleContains(let needle):
            let value = needle.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty, let title = session.identity.title else { return false }
            return title.localizedCaseInsensitiveContains(value)
        }
    }
}
