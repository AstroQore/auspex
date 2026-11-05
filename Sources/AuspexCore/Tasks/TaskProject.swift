import AgentSessionKit
import AgentSessionLive
import Foundation

/// Which project a task belongs to, answered with the *board's* key space.
///
/// ## One resolver, two readers
///
/// A session's project comes from ``BoardSnapshot/projectKey(for:)``: the
/// folder a person claimed, then the session's own git root or working
/// directory, then its parent's, then a ``PseudoProject`` key for a harness
/// that records no directory at all. A task's project is the same string,
/// resolved by the same function, because the two are the same fact — *where
/// this work is happening* — and a task board keyed on anything else could not
/// be joined to the wall without a translation table nobody would maintain.
///
/// That is the whole of why "Unfiled" is gone. A task filed over MCP by an
/// agent that named no project is filed under the project that agent is
/// working in, which Auspex already knows and the agent should not have to
/// repeat.
public enum TaskProject {
    // MARK: - The last resort

    /// The key earlier builds gave a task when there was nothing at all to
    /// resolve it from: no project named, no session on the other end of the
    /// socket, no directory anywhere in the chain.
    ///
    /// Such a task is now filed under ``PseudoProject/projectlessKey`` — the
    /// same Projectless section the board files a session with no project
    /// under, because "this work is in no project" is one fact whoever is
    /// asking. Ledger rows that still carry this key read as Projectless, and
    /// ``canonicalKey(_:)`` folds them into it.
    public static let scratchKey = "auspex-scratch"

    /// What the scratch key was called on screen.
    public static let scratchName = "Scratch"

    /// Whether a key is the old scratch project.
    public static func isScratch(_ key: String) -> Bool { key == scratchKey }

    /// Whether a key files a task under Projectless — the key itself, the old
    /// scratch key, or a per-harness key an earlier build wrote.
    public static func isProjectless(_ key: String) -> Bool {
        isScratch(key) || PseudoProject.isProjectless(key)
    }

    /// `key` with every spelling of Projectless folded into
    /// ``PseudoProject/projectlessKey``, and an empty key read as one too. A
    /// real project key is returned unchanged.
    public static func canonicalKey(_ key: String?) -> String {
        guard let key, !key.isEmpty else { return PseudoProject.projectlessKey }
        return isProjectless(key) ? PseudoProject.projectlessKey : key
    }

    // MARK: - Naming

    /// What to call a project key on the Tasks page and the Projects page.
    ///
    /// Defers to the frame for everything real — a person's own name for the
    /// project, a harness's display name for a pseudo key, the last path
    /// component otherwise — and only answers for the one key a board can
    /// never produce.
    public static func displayName(forKey key: String, in board: BoardSnapshot) -> String {
        isProjectless(key) ? PseudoProject.projectlessName : board.projectDisplayName(forKey: key)
    }

    /// The path to show under the name, or `nil` when the key is not one.
    ///
    /// A pseudo key stands for a harness and the scratch key stands for
    /// nothing; showing either as a path would be showing a path that does not
    /// exist.
    public static func subtitle(forKey key: String) -> String? {
        guard !isProjectless(key) else { return nil }
        return key
    }

    // MARK: - Resolving

    /// The project key a task should be filed under.
    ///
    /// - Parameters:
    ///   - explicit: what a caller named, if anything — a path, a project key,
    ///     or the name of a project on the board. An orchestrator filing work
    ///     for somebody else needs this; a worker filing its own does not.
    ///   - session: the session doing the filing, when Auspex worked out which
    ///     one that is.
    ///   - board: the frame both answers come from.
    /// - Returns: a key, always. ``PseudoProject/projectlessKey`` when nothing
    ///   else resolved: a named place, never a `NULL`.
    public static func resolve(
        explicit: String?,
        session: SessionKey?,
        board: BoardSnapshot
    ) -> String {
        if let explicit, let named = key(named: explicit, in: board) { return named }
        if let session, let snapshot = board.session(for: session),
           let key = board.projectKey(for: snapshot) {
            return key
        }
        // A session Auspex cannot see, or nothing at all: the task is still
        // filed somewhere a person can find it and move it out of.
        return PseudoProject.projectlessKey
    }

    /// The board key a caller's `project` argument names, or `nil` when
    /// nothing on the board answers to it.
    ///
    /// Four spellings, in the order they are unambiguous:
    ///
    /// 1. A ``PseudoProject`` key or the old scratch key, as Projectless — the
    ///    one non-path key the board produces on its own.
    /// 2. A path, absolute or `~`-relative. Normalised and then run through
    ///    the claims, so naming a folder inside a project a person made files
    ///    the task in *that* project rather than in a second one alongside it.
    /// 3. A user project's id, which is what a caller holding an
    ///    ``AuspexProject`` has to hand.
    /// 4. A project's display name, case-insensitively — what a person types.
    ///    Last, because a name is the only one of the four that two projects
    ///    can share; an ambiguous name resolves to the first on the board,
    ///    which is board order, which is the one the reader is looking at.
    public static func key(named reference: String, in board: BoardSnapshot) -> String? {
        let trimmed = reference.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if isProjectless(trimmed) { return PseudoProject.projectlessKey }
        if trimmed.caseInsensitiveCompare(PseudoProject.projectlessName) == .orderedSame {
            return PseudoProject.projectlessKey
        }

        if trimmed.hasPrefix("/") || trimmed.hasPrefix("~") {
            let path = ProjectPath.normalize(trimmed)
            guard !path.isEmpty else { return nil }
            return board.claims.key(forPath: path) ?? path
        }

        if let project = board.claims.projects.first(where: {
            $0.id.uuidString.caseInsensitiveCompare(trimmed) == .orderedSame
        }) {
            return project.key
        }

        // Every project the frame knows a name for: the person's own first,
        // then whatever the board resolved for the sessions on it.
        if let project = board.claims.projects.first(where: {
            $0.name.caseInsensitiveCompare(trimmed) == .orderedSame
        }) {
            return project.key
        }
        var seen: Set<String> = []
        for session in board.sessions {
            guard let key = board.projectKey(for: session), seen.insert(key).inserted else {
                continue
            }
            if board.projectDisplayName(forKey: key).caseInsensitiveCompare(trimmed)
                == .orderedSame {
                return key
            }
        }
        return nil
    }
}
