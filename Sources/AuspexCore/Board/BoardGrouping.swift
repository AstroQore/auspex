import AgentSessionKit
import AgentSessionLive
import Foundation

/// How the board divides its cards into sections.
///
/// A wall of forty cards is only readable if the reader can choose the axis
/// they are scanning along: "what is every agent doing" (``none``), "what is
/// Codex up to" (``harness``), "who is touching this repository"
/// (``project``), or "what did this one session set in motion" (``tree``).
public enum BoardGroupBy: String, CaseIterable, Identifiable, Sendable, Codable {
    /// One flat grid in board order.
    case none
    /// One section per harness.
    case harness
    /// One section per git root, falling back to the working directory.
    case project
    /// One section per delegation tree that has any delegation in it, with
    /// children nested under the session that spawned them.
    case tree

    public var id: String { rawValue }

    /// The segmented control's label.
    public var title: String {
        switch self {
        case .none: "None"
        case .harness: "Harness"
        case .project: "Project"
        case .tree: "Tree"
        }
    }
}

/// One session and everything it spawned, ready to render as nested rows.
///
/// ``SessionTree/Node`` already carries this shape in keys; this carries it in
/// snapshots, so a view can draw a subtree without a lookup per row on a board
/// that redraws twenty times a second.
public struct BoardTreeNode: Identifiable, Sendable, Equatable {
    /// The session this node is.
    public let session: SessionSnapshot
    /// How far below its root it sits. `0` for a root.
    public let depth: Int
    /// What it spawned, in board order.
    public let children: [BoardTreeNode]
    /// How many sessions are below this one, transitively — the "N children"
    /// badge on a card.
    public let descendantCount: Int

    public var id: SessionKey { session.key }

    public init(session: SessionSnapshot, depth: Int, children: [BoardTreeNode]) {
        self.session = session
        self.depth = depth
        self.children = children
        self.descendantCount = children.reduce(children.count) { $0 + $1.descendantCount }
    }

    /// This node and every node below it, depth first — the flat list a
    /// section's counts are tallied from.
    public var flattened: [SessionSnapshot] {
        [session] + children.flatMap(\.flattened)
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
    /// The delegation shape of ``sessions``, when the section has one.
    ///
    /// Non-`nil` only under ``BoardGroupBy/tree``. Everywhere else a section is
    /// a flat set of cards and a view that asked for nesting would be asking
    /// the wrong question.
    public let roots: [BoardTreeNode]?

    public init(
        id: String,
        title: String,
        subtitle: String? = nil,
        harness: Harness? = nil,
        sessions: [SessionSnapshot],
        roots: [BoardTreeNode]? = nil
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.harness = harness
        self.sessions = sessions
        self.counts = BoardSnapshot.Counts(sessions: sessions)
        self.roots = roots
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

    /// The section holding the roots that delegated to nobody. Always last
    /// under ``BoardGroupBy/tree``: a session that started nothing is not a
    /// tree, and giving each one its own header would bury the trees that are.
    public static let standaloneTitle = "Not delegating"

    /// Groups `snapshot` along `groupBy`, keeping only what survives the
    /// filters.
    ///
    /// - Parameters:
    ///   - snapshot: the frame to divide. Its sessions are already in board
    ///     order and that order is preserved inside every group.
    ///   - groupBy: the axis to divide along.
    ///   - harnessFilter: harnesses to keep. **Empty means keep everything** —
    ///     a filter that excluded all eight when nothing was ticked would make
    ///     the default state of the UI an empty board.
    ///   - projectFilter: the one project to keep, as the key
    ///     ``BoardSnapshot/projectKey(for:)`` answers with. `nil` keeps every
    ///     project. Applied on every axis, because a person who clicked a
    ///     project in the sidebar meant it whatever the board is grouped by.
    ///   - includesEnded: whether finished sessions belong in the sections.
    ///     `false` is what the board asks for: finished sessions leave the grid
    ///     entirely and collect in one collapsed section of their own — see
    ///     ``EndedSessions``. A section that ends up empty as a result is
    ///     dropped rather than drawn with a zero in it.
    /// - Returns: the sections, in display order. Empty when nothing survives
    ///   the filters, so a caller can distinguish "no sessions" from "one empty
    ///   section".
    public static func groups(
        for snapshot: BoardSnapshot,
        groupBy: BoardGroupBy,
        harnessFilter: Set<Harness> = [],
        projectFilter: String? = nil,
        includesEnded: Bool = true
    ) -> [BoardGroup] {
        var sessions = filtered(
            snapshot.sessions,
            harnessFilter: harnessFilter,
            projectFilter: projectFilter,
            in: snapshot
        )
        if !includesEnded {
            sessions = EndedSessions.split(sessions).active
        }
        guard !sessions.isEmpty else { return [] }

        switch groupBy {
        case .none:
            return [BoardGroup(id: "all", title: allSessionsTitle, sessions: sessions)]
        case .harness:
            return harnessGroups(sessions)
        case .project:
            return projectGroups(sessions, in: snapshot)
        case .tree:
            return treeGroups(sessions)
        }
    }

    /// Applies the filters. Separate so the counts in a toolbar can be taken
    /// from the same rule the grid uses.
    ///
    /// The project filter is answered against `snapshot` rather than against
    /// each session alone, because a delegated session frequently has no
    /// directory of its own and belongs to whatever its parent belongs to —
    /// filtering it out would empty a tree of everything below its root.
    public static func filtered(
        _ sessions: [SessionSnapshot],
        harnessFilter: Set<Harness>,
        projectFilter: String? = nil,
        in snapshot: BoardSnapshot? = nil
    ) -> [SessionSnapshot] {
        var kept = sessions
        if !harnessFilter.isEmpty {
            kept = kept.filter { harnessFilter.contains($0.key.harness) }
        }
        if let projectFilter {
            kept = kept.filter { session in
                (snapshot?.projectKey(for: session) ?? BoardSnapshot.projectKey(for: session))
                    == projectFilter
            }
        }
        return kept
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
    ///
    /// The key comes from the *snapshot*, not from the session: a delegated
    /// session often records no directory at all — a subagent has no process
    /// and no cwd line — and it is unambiguously working on whatever its parent
    /// is working on. Asking the frame is what puts it under its parent's
    /// project instead of into the residue.
    private static func projectGroups(
        _ sessions: [SessionSnapshot],
        in snapshot: BoardSnapshot
    ) -> [BoardGroup] {
        var order: [String] = []
        var byProject: [String: [SessionSnapshot]] = [:]
        var ungrouped: [SessionSnapshot] = []

        for session in sessions {
            guard let path = snapshot.projectKey(for: session) else {
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

    /// Delegation sections: one per root that actually delegated, then one
    /// holding every root that did not.
    ///
    /// The forest is rebuilt from the filtered sessions rather than taken from
    /// ``BoardSnapshot/tree``, because a harness filter can remove a parent
    /// while leaving its children — and a child whose parent is no longer on
    /// the board is a root, not a hidden row.
    ///
    /// Sections are ordered by the board rank of their root, so the tree that
    /// needs a person is at the top of the wall. A tree of one is not a tree,
    /// which is why the standalone roots share a single section instead of
    /// getting a header each.
    private static func treeGroups(_ sessions: [SessionSnapshot]) -> [BoardGroup] {
        let forest = SessionTreeBuilder.build(sessions)
        var bySession: [SessionKey: SessionSnapshot] = [:]
        for session in sessions { bySession[session.key] = session }

        var groups: [BoardGroup] = []
        var standalone: [SessionSnapshot] = []

        for root in forest.roots {
            guard let node = node(root, in: bySession) else { continue }
            guard !node.children.isEmpty else {
                standalone.append(node.session)
                continue
            }
            let flattened = node.flattened
            groups.append(
                BoardGroup(
                    id: "tree:\(node.session.key.description)",
                    title: treeTitle(for: node.session),
                    subtitle: "\(node.descendantCount) below",
                    sessions: flattened,
                    roots: [node]
                )
            )
        }

        if !standalone.isEmpty {
            groups.append(
                BoardGroup(
                    id: "tree:standalone",
                    title: standaloneTitle,
                    sessions: standalone,
                    roots: standalone.map { BoardTreeNode(session: $0, depth: 0, children: []) }
                )
            )
        }
        return groups
    }

    /// Rebuilds one subtree in snapshots. Total: a node naming a session that
    /// is not in the set is dropped along with everything under it, which
    /// cannot happen for a forest built from that same set.
    private static func node(
        _ node: SessionTree.Node,
        in sessions: [SessionKey: SessionSnapshot]
    ) -> BoardTreeNode? {
        guard let session = sessions[node.key] else { return nil }
        return BoardTreeNode(
            session: session,
            depth: node.depth,
            children: node.children.compactMap { self.node($0, in: sessions) }
        )
    }

    /// What a delegation section is called: the root's own title, or the
    /// project it is in, or its session id — the same ladder a card climbs, so
    /// a header and the card under it never disagree.
    private static func treeTitle(for session: SessionSnapshot) -> String {
        if let title = session.identity.title, !title.isEmpty { return title }
        if let project = projectName(for: session) { return project }
        return session.key.sessionID
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
