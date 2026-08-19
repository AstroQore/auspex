import AgentSessionKit
import AgentSessionLive
import Foundation

public extension Harness {
    /// Whether this harness's store records the directory its work happened
    /// in.
    ///
    /// True for every harness that runs on this Mac, because every one of them
    /// is started in a directory and writes it down. False for Grok Bot alone:
    /// its conversations run on xAI's servers, the desktop client only
    /// replicates them, and the one path in its store is a directory inside
    /// the remote sandbox. There is no local working directory to record, and
    /// a board that invented one would be inventing the project it belongs to.
    ///
    /// This is a fact about the *store*, not about a session. A session of a
    /// harness that does record a directory can still be missing one — a
    /// subagent has no process and no `cwd` line — and that is a gap to fill
    /// from its parent, not a harness without a home.
    var recordsWorkingDirectory: Bool {
        switch self {
        case .grokBot: false
        case .claudeCode, .claudeCowork, .codex, .chatgptWork,
             .cursor, .grokBuild, .antigravity, .geminiCLI: true
        }
    }
}

/// A stand-in project for the sessions of a harness that has no project.
///
/// ## Why a section rather than the residue
///
/// The board groups by `gitRoot ?? cwd`, and everything with neither lands
/// under "No project". That is the right home for a session whose directory is
/// *missing* — a subagent whose parent has aged off the board, a rollout whose
/// header has not been written yet — because the answer really is unknown and
/// the residue says so.
///
/// It is the wrong home for every Grok Bot conversation on the machine. Their
/// directory is not missing; it does not exist, and it never will. Filing a
/// dozen bots under a heading that means "could not be placed" tells a reader
/// something false about the store and buries the sessions that genuinely
/// could not be placed underneath them.
///
/// So a harness whose store has no working directory gets a section of its
/// own, named after the harness. It is not a directory, nothing resolves it,
/// and it never reaches the `projects` table — placements are only ever
/// written for a session that reported a `cwd`, which these never do.
///
/// ## The key
///
/// `harness:<raw value>`. A real project key is `gitRoot ?? cwd`, both
/// absolute paths, so a key that does not begin with `/` cannot collide with
/// one. Callers should treat it as opaque and ask ``name(forKey:)`` rather
/// than take its last path component.
public enum PseudoProject {
    /// What every pseudo key begins with.
    public static let prefix = "harness:"

    /// The pseudo project key for a harness.
    public static func key(for harness: Harness) -> String {
        prefix + harness.rawValue
    }

    /// The harness a pseudo key names, or `nil` when `key` is a real path.
    public static func harness(forKey key: String) -> Harness? {
        guard key.hasPrefix(prefix) else { return nil }
        return Harness(rawValue: String(key.dropFirst(prefix.count)))
    }

    /// What to call the section a pseudo key heads — the harness's own full
    /// name. `nil` for a real path, which has a name of its own.
    public static func name(forKey key: String) -> String? {
        harness(forKey: key)?.displayName
    }

    /// `true` when `key` stands in for a harness rather than naming a
    /// directory. A view uses this to leave the path subtitle off, because
    /// there is no path to show.
    public static func isPseudo(_ key: String) -> Bool {
        harness(forKey: key) != nil
    }
}
