import AgentSessionKit
import AgentSessionLive
import Foundation

/// One frame, twice: as the pipeline produced it, and as the person asked to
/// see it.
///
/// The whole point of the type is that there is *one* filtered frame and every
/// surface renders that one. The wall, the scene, the crew, the sidebar's
/// counts and the menu bar's title all read ``board``; nothing downstream
/// re-applies a rule, so nothing downstream can forget to.
public struct VisibleBoard: Sendable, Equatable {
    /// What the app draws: the frame with the ignored sessions taken out and
    /// the user's projects applied.
    public let board: BoardSnapshot
    /// The sessions an ignore rule matched, whether or not they are in
    /// ``board`` — with "show ignored" on they are drawn, dimmed, and this is
    /// what says which ones to dim.
    public let ignored: Set<SessionKey>

    /// How many sessions the rules are hiding. The number in the header's
    /// toggle.
    public var ignoredCount: Int { ignored.count }

    public init(board: BoardSnapshot, ignored: Set<SessionKey>) {
        self.board = board
        self.ignored = ignored
    }
}

/// Applies the user layer to a frame: claims first, then the ignore rules.
///
/// Claims first because a rule may name a project, and the project a session
/// belongs to is a question only the claims can answer.
public enum BoardFilter {
    /// The visible frame for one raw frame.
    ///
    /// - Parameters:
    ///   - board: the frame as it arrived from the registry.
    ///   - claims: the user's projects.
    ///   - rules: the ignore rules.
    ///   - showsIgnored: when `true` nothing is removed and the ignored set is
    ///     still reported, so the board can draw them dimmed rather than
    ///     making a person delete a rule to remember what it was hiding.
    public static func apply(
        to board: BoardSnapshot,
        claims: ProjectClaims,
        rules: IgnoreRules,
        showsIgnored: Bool = false
    ) -> VisibleBoard {
        let placed = board.applying(claims: claims)
        guard !rules.isEmpty else { return VisibleBoard(board: placed, ignored: []) }

        var ignored: Set<SessionKey> = []
        for session in placed.sessions
        where rules.matches(
            session,
            projectKey: placed.projectKey(for: session),
            claims: claims
        ) {
            ignored.insert(session.key)
        }

        // A session hidden by a rule takes its subagents with it. They are
        // *its* work — a Claude subagent has no directory, no process and no
        // title of its own — so leaving them on the board would answer the
        // request to hide a folder with a row that says nothing about where it
        // is running.
        if !ignored.isEmpty {
            for root in placed.tree.roots { mark(root, isIgnored: false, into: &ignored, placed) }
        }

        guard !ignored.isEmpty, !showsIgnored else {
            return VisibleBoard(board: placed, ignored: ignored)
        }
        return VisibleBoard(
            board: placed.filtered { !ignored.contains($0.key) },
            ignored: ignored
        )
    }

    /// Walks one subtree, spreading a hidden ancestor down over its
    /// descendants.
    private static func mark(
        _ node: SessionTree.Node,
        isIgnored: Bool,
        into ignored: inout Set<SessionKey>,
        _ board: BoardSnapshot
    ) {
        let hidden = isIgnored || ignored.contains(node.key)
        if hidden { ignored.insert(node.key) }
        for child in node.children { mark(child, isIgnored: hidden, into: &ignored, board) }
    }
}
