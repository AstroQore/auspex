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

/// The stand-in project for every session that is in no project: the
/// **Projectless** section.
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
/// ## One section, not one per harness
///
/// Both of those used to be a section *per harness* — "Codex · scratch",
/// "Cursor · scratch", "Grok Bot" — beside a "No project" residue for the
/// sessions with no directory at all. Four headings for one fact, and the
/// fact a reader acts on is the same for all of them: *this is not a
/// project*. So every one of them now files under ``projectlessKey``, one
/// section called "Projectless", which sits after the real projects on every
/// surface. Which harness a row belongs to is what its badge says; which
/// folder a scratch thread ran in is a label on its row, not a heading.
///
/// ## The keys
///
/// ``projectlessKey`` is what the board groups by. `harness:<raw value>` and
/// `scratch:<raw value>` are the keys earlier builds wrote into the task
/// ledger; they still read as Projectless, and ``canonical(_:)`` folds them
/// into it. A real project key is `gitRoot ?? cwd`, both absolute paths, so a
/// key that does not begin with `/` cannot collide with one. Callers should
/// treat all of them as opaque and ask ``name(forKey:)`` rather than take a
/// last path component.
public enum PseudoProject {
    /// What a harness-with-no-directory key begins with.
    public static let prefix = "harness:"
    /// What a per-thread-scratch key begins with.
    public static let scratchPrefix = "scratch:"

    /// The one section every session outside a project is filed under.
    public static let projectlessKey = "scratch:all"

    /// What the Projectless section is called. English, like every name Core
    /// gives a section; the app says it again from the catalogue.
    public static let projectlessName = "Projectless"

    /// The suffix a scratch section's name carried, so a reader could tell
    /// "Codex" the harness from "Codex · scratch" the throwaway directories.
    /// Kept for the app's vocabulary of names earlier builds wrote down.
    public static let scratchSuffix = " · scratch"

    /// The pseudo project key earlier builds gave a harness with no working
    /// directory. Reads as ``projectlessKey``.
    public static func key(for harness: Harness) -> String {
        prefix + harness.rawValue
    }

    /// The pseudo project key earlier builds gave a harness's per-thread
    /// scratch directories. Reads as ``projectlessKey``.
    public static func scratchKey(for harness: Harness) -> String {
        scratchPrefix + harness.rawValue
    }

    /// The harness a per-harness pseudo key names, or `nil` when `key` is a
    /// real path or ``projectlessKey``, which names no harness.
    public static func harness(forKey key: String) -> Harness? {
        for prefix in [prefix, scratchPrefix] where key.hasPrefix(prefix) {
            return Harness(rawValue: String(key.dropFirst(prefix.count)))
        }
        return nil
    }

    /// `true` when `key` files a session under Projectless: the key itself,
    /// or one of the per-harness keys that came before it.
    public static func isProjectless(_ key: String) -> Bool {
        key == projectlessKey || harness(forKey: key) != nil
    }

    /// `true` when `key` names scratch — today that is Projectless.
    public static func isScratch(_ key: String) -> Bool {
        isProjectless(key)
    }

    /// `key`, with every spelling of Projectless folded into
    /// ``projectlessKey``. A real path is returned as it is.
    public static func canonical(_ key: String) -> String {
        isProjectless(key) ? projectlessKey : key
    }

    /// `keys` in the same order, with Projectless moved after everything
    /// else: it is what is left over once the projects are drawn, and a
    /// section that moved to the top of the wall because one scratch thread
    /// asked for permission would bury the repositories under it.
    public static func projectlessLast(_ keys: [String]) -> [String] {
        let projectless = keys.filter(isProjectless)
        guard !projectless.isEmpty else { return keys }
        return keys.filter { !isProjectless($0) } + projectless
    }

    /// What to call the section a pseudo key heads. `nil` for a real path,
    /// which has a name of its own.
    public static func name(forKey key: String) -> String? {
        isProjectless(key) ? projectlessName : nil
    }

    /// `true` when `key` stands in for no directory rather than naming one. A
    /// view uses this to leave the path subtitle off, because there is no
    /// path to show.
    public static func isPseudo(_ key: String) -> Bool {
        isProjectless(key)
    }
}
