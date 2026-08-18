import AgentSessionKit
import AgentSessionLive
import Foundation

/// How the board divides its cards into sections.
///
/// A wall of forty cards is only readable if the reader can choose the axis
/// they are scanning along: "what is every agent doing" (``none``), "what is
/// Codex up to" (``harness``), or "who is touching this repository"
/// (``project``).
public enum BoardGroupBy: String, CaseIterable, Identifiable, Sendable, Codable {
    /// One flat grid in board order.
    case none
    /// One section per harness.
    case harness
    /// One section per git root, falling back to the working directory.
    case project

    public var id: String { rawValue }

    /// The segmented control's label.
    public var title: String {
        switch self {
        case .none: "None"
        case .harness: "Harness"
        case .project: "Project"
        }
    }
}

/// One section of the board: what to title it, which sessions are under it,
/// and the tallies its header shows.
///
/// The counts are computed here rather than in the header view because the
/// same numbers feed the section header, the sidebar badge, and the menu bar,
/// and three call sites recomputing them is three chances to disagree.
public struct BoardGroup: Identifiable, Sendable, Equatable {
    /// Stable across frames, so SwiftUI keeps section state while the board
    /// churns underneath it.
    public let id: String
    /// The header's label — a harness display name, a project basename, or
    /// ``BoardGrouping/allSessionsTitle``.
    public let title: String
    /// The full path behind ``title`` when the title is an abbreviation of
    /// one. `nil` for every other grouping.
    public let subtitle: String?
    /// The harness this section is about, when grouping by harness. Lets a
    /// header show the harness's accent without re-deriving it from a
    /// session.
    public let harness: Harness?
    /// The sessions in this section, still in board order.
    public let sessions: [SessionSnapshot]
    /// The tallies for ``sessions``.
    public let counts: BoardSnapshot.Counts

    public init(
        id: String,
        title: String,
        subtitle: String? = nil,
        harness: Harness? = nil,
        sessions: [SessionSnapshot]
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.harness = harness
        self.sessions = sessions
        self.counts = BoardSnapshot.Counts(sessions: sessions)
    }
}

/// Turns a ``BoardSnapshot`` into the sections the board renders.
///
/// Pure and total: every session in the snapshot lands in exactly one group,
/// and the same snapshot always produces the same sections in the same order.
/// That last property is what keeps a board from reshuffling under the
/// reader's cursor at 20 Hz.
public enum BoardGrouping {
    /// The single section's title when nothing is grouped.
    public static let allSessionsTitle = "All sessions"

    /// The section for sessions whose adapter has recorded neither a git root
    /// nor a working directory. Always last: it is a residue, not a project.
    public static let noProjectTitle = "No project"

    /// Groups `snapshot` along `groupBy`, keeping only the harnesses in
    /// `harnessFilter`.
    ///
    /// - Parameters:
    ///   - snapshot: the frame to divide. Its sessions are already in board
    ///     order and that order is preserved inside every group.
    ///   - groupBy: the axis to divide along.
    ///   - harnessFilter: harnesses to keep. **Empty means keep everything** —
    ///     a filter that excluded all eight when nothing was ticked would make
    ///     the default state of the UI an empty board.
    /// - Returns: the sections, in display order. Empty when nothing survives
    ///   the filter, so a caller can distinguish "no sessions" from "one empty
    ///   section".
    public static func groups(
        for snapshot: BoardSnapshot,
        groupBy: BoardGroupBy,
        harnessFilter: Set<Harness> = []
    ) -> [BoardGroup] {
        let sessions = filtered(snapshot.sessions, harnessFilter: harnessFilter)
        guard !sessions.isEmpty else { return [] }

        switch groupBy {
        case .none:
            return [BoardGroup(id: "all", title: allSessionsTitle, sessions: sessions)]
        case .harness:
            return harnessGroups(sessions)
        case .project:
            return projectGroups(sessions)
        }
    }

    /// Applies the harness filter. Separate so the counts in a toolbar can be
    /// taken from the same rule the grid uses.
    public static func filtered(
        _ sessions: [SessionSnapshot],
        harnessFilter: Set<Harness>
    ) -> [SessionSnapshot] {
        guard !harnessFilter.isEmpty else { return sessions }
        return sessions.filter { harnessFilter.contains($0.key.harness) }
    }

    /// Harness sections in `Harness.allCases` order — the declaration order,
    /// which groups harnesses by the company that owns them.
    ///
    /// Fixed rather than urgency-ordered on purpose: a reader learns where
    /// "Codex" sits on the wall, and a section that moves because one of its
    /// sessions hit a permission prompt destroys that. Urgency still shows,
    /// inside the section, where the sort already puts it.
    private static func harnessGroups(_ sessions: [SessionSnapshot]) -> [BoardGroup] {
        let byHarness = Dictionary(grouping: sessions) { $0.key.harness }
        return Harness.allCases.compactMap { harness in
            guard let group = byHarness[harness], !group.isEmpty else { return nil }
            return BoardGroup(
                id: "harness:\(harness.rawValue)",
                title: harness.displayName,
                harness: harness,
                sessions: group
            )
        }
    }

    /// Project sections ordered by the board rank of their first session, so
    /// the repository that needs a person is at the top of the wall.
    ///
    /// Unlike harnesses there is no natural order to fall back on — an
    /// alphabetical wall would bury the blocked session under `zzz-scratch` —
    /// and the order is still deterministic because the board order it is
    /// derived from is.
    private static func projectGroups(_ sessions: [SessionSnapshot]) -> [BoardGroup] {
        var order: [String] = []
        var byProject: [String: [SessionSnapshot]] = [:]
        var ungrouped: [SessionSnapshot] = []

        for session in sessions {
            guard let path = BoardSnapshot.projectKey(for: session) else {
                ungrouped.append(session)
                continue
            }
            if byProject[path] == nil {
                byProject[path] = []
                order.append(path)
            }
            byProject[path]?.append(session)
        }

        var groups = order.map { path in
            BoardGroup(
                id: "project:\(path)",
                title: projectName(forPath: path),
                subtitle: path,
                sessions: byProject[path] ?? []
            )
        }
        if !ungrouped.isEmpty {
            groups.append(
                BoardGroup(id: "project:none", title: noProjectTitle, sessions: ungrouped)
            )
        }
        return groups
    }

    /// The short name a card and a section header show for a project: the
    /// last path component of the git root, or of the working directory when
    /// no root is known.
    ///
    /// `nil` when the session has neither, because a made-up name on a card is
    /// worse than a blank one.
    public static func projectName(for session: SessionSnapshot) -> String? {
        BoardSnapshot.projectKey(for: session).map(projectName(forPath:))
    }

    /// The last path component of `path`, with the path itself as the answer
    /// when it has no components worth taking — `/` most obviously.
    public static func projectName(forPath path: String) -> String {
        let trimmed = path.hasSuffix("/") && path.count > 1 ? String(path.dropLast()) : path
        let name = (trimmed as NSString).lastPathComponent
        return name.isEmpty ? trimmed : name
    }
}
