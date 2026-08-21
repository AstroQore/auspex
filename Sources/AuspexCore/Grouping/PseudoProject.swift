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
/// ## Scratch is the same argument again
///
/// A Codex desktop thread runs in `~/Documents/Codex/<date>/<name>` — a
/// directory the app made for that one conversation and will never reuse. Its
/// directory is not missing either, and it is not a project; it is the
/// harness's own scratch space. So those get a section too, and a separate one
/// from the harness's plain pseudo project, because "this harness records no
/// directory" and "this session was run somewhere disposable" are different
/// facts and a reader acts on them differently. See ``HarnessSandbox``.
///
/// ## The keys
///
/// `harness:<raw value>` and `scratch:<raw value>`. A real project key is
/// `gitRoot ?? cwd`, both absolute paths, so a key that does not begin with
/// `/` cannot collide with one. Callers should treat both as opaque and ask
/// ``name(forKey:)`` rather than take a last path component.
public enum PseudoProject {
    /// What a harness-with-no-directory key begins with.
    public static let prefix = "harness:"
    /// What a per-thread-scratch key begins with.
    public static let scratchPrefix = "scratch:"

    /// The suffix a scratch section's name carries, so a reader can tell
    /// "Codex" the harness from "Codex · scratch" the throwaway directories.
    public static let scratchSuffix = " · scratch"

    /// The pseudo project key for a harness with no working directory.
    public static func key(for harness: Harness) -> String {
        prefix + harness.rawValue
    }

    /// The pseudo project key for a harness's per-thread scratch directories.
    public static func scratchKey(for harness: Harness) -> String {
        scratchPrefix + harness.rawValue
    }

    /// The harness a pseudo key of either kind names, or `nil` when `key` is a
    /// real path.
    public static func harness(forKey key: String) -> Harness? {
        for prefix in [prefix, scratchPrefix] where key.hasPrefix(prefix) {
            return Harness(rawValue: String(key.dropFirst(prefix.count)))
        }
        return nil
    }

    /// `true` when `key` names a harness's scratch rather than the harness
    /// itself.
    public static func isScratch(_ key: String) -> Bool {
        key.hasPrefix(scratchPrefix) && harness(forKey: key) != nil
    }

    /// What to call the section a pseudo key heads — the harness's own full
    /// name, and for a scratch key that name plus what kind of section it is.
    /// `nil` for a real path, which has a name of its own.
    public static func name(forKey key: String) -> String? {
        guard let harness = harness(forKey: key) else { return nil }
        return isScratch(key) ? harness.displayName + scratchSuffix : harness.displayName
    }

    /// `true` when `key` stands in for a harness rather than naming a
    /// directory. A view uses this to leave the path subtitle off, because
    /// there is no path to show.
    public static func isPseudo(_ key: String) -> Bool {
        harness(forKey: key) != nil
    }
}
