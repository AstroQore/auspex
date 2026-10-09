import AgentSessionKit
import AgentSessionLive
import Foundation

/// The working directories that say where a session *ran* rather than which
/// project it belongs to.
///
/// ``ProjectResolver`` answers "which repository is this directory in", and
/// for a directory in none it answers "the directory itself". That second
/// answer is right for `~/Code/notes` and wrong for a whole family of folders
/// nobody would call a project: the home directory a desktop app opens a chat
/// in, the per-conversation folder Claude Desktop makes and never reuses, a
/// container's `/workspace`, a clone in `/tmp`. Each of those became a row in
/// `projects` and a heading in the sidebar, and a week of desktop chats was
/// enough to bury the real repositories under them.
///
/// So these are asked *before* the resolver. A directory that matches is
/// placed as scratch — ``ProjectPlacement/isProjectless`` — which means no
/// `projects` row and a section under the harness's own scratch heading
/// (``PseudoProject/scratchKey(for:)``). The session is still on the board;
/// only the project it would have invented is gone.
///
/// ## What is here, and what is not
///
/// Everything below is a string comparison against a home directory fixed at
/// construction, so this is safe to ask once per session per directory from
/// any actor. The one rule that needs the disk — a directory that is not on
/// this Mac — is ``missing(directory:)``, and it is the caller's job to have
/// asked the filesystem once: ``PlacementService`` does, and caches the answer.
///
/// A person's own project claims are not consulted here. They sit above every
/// automatic placement in ``BoardSnapshot/projectKey(for:)``, so a folder a
/// person filed in a project stays in it whatever this says.
public struct ScratchRules: Sendable, Equatable {
    /// Why a directory is scratch. The raw value becomes the placement's
    /// ``ProjectPlacement/placementNote``.
    public enum Reason: String, Sendable, Hashable, CaseIterable {
        /// A desktop app's per-conversation folder — Codex's
        /// `~/Documents/Codex/…`. The same note ``HarnessSandbox`` writes, so
        /// both layers name it alike.
        case conversation = "sandbox"
        /// Claude Desktop's
        /// `~/Library/Application Support/Claude/scratch-workspaces/…`.
        case desktopScratch = "desktop-scratch"
        /// The home directory itself: where a chat with no folder runs.
        case home = "home"
        /// A container's root — `/root`, `/workspace` — which on this Mac is
        /// either nothing or somebody else's mount.
        case container = "container"
        /// `/tmp` and `/private/tmp`.
        case temporary = "temporary"
        /// A directory that is not on this Mac at all.
        case missing = "missing"
        /// A folder the person marked as scratch in Settings.
        case userRule = "rule"
    }

    /// One directory found to be scratch.
    public struct Match: Sendable, Hashable {
        /// Which rule fired.
        public let reason: Reason
        /// The directory the scratch is *about* — for a conversation folder
        /// the folder, whatever the session later `cd`-ed into below it.
        public let directory: String
        /// What a card calls it, in place of a project name.
        public let name: String

        public init(reason: Reason, directory: String, name: String) {
            self.reason = reason
            self.directory = directory
            self.name = name
        }
    }

    /// The harnesses that make `~/Documents/Codex` — the Codex desktop app and
    /// its work-account twin. Only their sessions treat that whole tree as
    /// scratch; anyone else working there is working in a folder.
    public static let conversationHarnesses: Set<Harness> = [.codex, .chatgptWork]

    /// Below the home: Claude Desktop's per-conversation scratch.
    static let desktopScratchComponents = [
        "Library", "Application Support", "Claude", "scratch-workspaces",
    ]

    /// How deep a Claude Desktop scratch folder sits under its root:
    /// `<workspace>/<id>/scratch-<date>-<hex>`.
    static let desktopScratchDepth = 3

    /// Container roots. Nothing on a Mac lives there, so a session that
    /// reports one ran somewhere else.
    public static let containerRoots = ["/root", "/workspace"]

    /// Temporary roots, both spellings — `/tmp` is a link to `/private/tmp`
    /// and a session reports whichever its shell said.
    public static let temporaryRoots = ["/tmp", "/private/tmp"]

    /// The home directory the home-relative rules hang off, standardised.
    public let home: String
    /// The folders the person marked as scratch, normalised.
    public let userPrefixes: [String]

    /// `~/Documents/Codex` and its siblings, made absolute once.
    private let conversationRoots: [String]
    /// The Claude Desktop scratch root, made absolute once.
    private let desktopScratchRoot: String

    /// Creates the rule set.
    ///
    /// - Parameters:
    ///   - home: injected so a test — and the demo — can stand somewhere other
    ///     than the person's real home. Never `NSHomeDirectory()`: a spawned
    ///     agent's `HOME` is not where the stores are.
    ///   - userPrefixes: the person's own scratch folders, in any spelling
    ///     ``ProjectPath/normalize(_:)`` accepts.
    public init(
        home: String = AuspexPaths.realHomeDirectory().path,
        userPrefixes: [String] = []
    ) {
        let home = ProjectResolver.standardized(home)
        self.home = home
        self.userPrefixes = userPrefixes.map(ProjectPath.normalize).filter { !$0.isEmpty }
        conversationRoots = HarnessSandbox.roots.map {
            NSString.path(withComponents: [home] + $0.components)
        }
        desktopScratchRoot = NSString.path(withComponents: [home] + Self.desktopScratchComponents)
    }

    /// The scratch `cwd` is in, or `nil` when it is an ordinary directory and
    /// the resolver should decide.
    ///
    /// - Parameters:
    ///   - cwd: the session's working directory.
    ///   - harness: whose session it is. `nil` asks only the rules that hold
    ///     for every harness — what a store-wide pass knows about a project
    ///     row nobody is in.
    public func match(cwd: String, harness: Harness?) -> Match? {
        let directory = ProjectResolver.standardized(cwd)
        guard directory.hasPrefix("/") else { return nil }

        // The person's own word first: it is the most specific thing anybody
        // has said about this folder.
        if userPrefixes.contains(where: { ProjectPath.contains($0, directory) }) {
            return Match(reason: .userRule, directory: directory, name: Self.name(of: directory))
        }

        if !home.isEmpty, directory == home {
            return Match(reason: .home, directory: directory, name: "~")
        }

        // The dated conversation folders, for every harness: the shape alone
        // says what they are, and it names the thread.
        if let thread = HarnessSandbox.thread(forPath: directory, home: home) {
            return Match(reason: .conversation, directory: thread.directory, name: thread.name)
        }
        if let harness, Self.conversationHarnesses.contains(harness),
           conversationRoots.contains(where: { ProjectPath.contains($0, directory) }) {
            return Match(reason: .conversation, directory: directory, name: Self.name(of: directory))
        }

        if ProjectPath.contains(desktopScratchRoot, directory) {
            let thread = Self.prefix(
                of: directory,
                below: desktopScratchRoot,
                depth: Self.desktopScratchDepth
            )
            return Match(reason: .desktopScratch, directory: thread, name: Self.name(of: thread))
        }

        if Self.containerRoots.contains(where: { ProjectPath.contains($0, directory) }) {
            return Match(reason: .container, directory: directory, name: Self.name(of: directory))
        }
        if Self.temporaryRoots.contains(where: { ProjectPath.contains($0, directory) }) {
            return Match(reason: .temporary, directory: directory, name: Self.name(of: directory))
        }
        return nil
    }

    /// The match for a directory the caller found missing from disk.
    public static func missing(directory: String) -> Match {
        let directory = ProjectResolver.standardized(directory)
        return Match(reason: .missing, directory: directory, name: name(of: directory))
    }

    /// What a card shows for a scratch directory: its last component.
    static func name(of directory: String) -> String {
        PathText.lastComponent(directory)
    }

    /// `directory` cut to at most `depth` components below `root`.
    private static func prefix(of directory: String, below root: String, depth: Int) -> String {
        let rootDepth = (root as NSString).pathComponents.count
        let components = (directory as NSString).pathComponents
        let kept = components.prefix(rootDepth + depth)
        return NSString.path(withComponents: Array(kept))
    }
}
