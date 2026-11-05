import AgentSessionKit
import AgentSessionLive
import Foundation

/// Which project a working directory belongs to, when it may not be in a
/// repository at all.
///
/// ## Why "the directory itself" was the wrong answer
///
/// ``ProjectResolver`` answers "which repository is this directory in", and for
/// a directory in none it used to answer "the directory itself". A scheduled
/// job that runs in a fresh dated folder every hour — `~/work/reports/.runs/
/// 2026-09-30/…` — then became a project per run, and a folder of revisions
/// became a project per revision: hundreds of rows, each with a name nobody
/// would look up, and none of them next to the work they were part of.
///
/// So a plain directory is filed under the **workspace** it sits in: the folder
/// two levels below the home (`~/work/reports`), or two levels below a volume.
/// That is the depth people keep projects at, and the one level above it is
/// where they keep *groups* of projects.
///
/// ## The rules, in order
///
/// 1. **A repository** places the directory, as it always has — unless the
///    directory is scratch (rule 4): a desktop conversation that ran `git
///    init` in its own throwaway folder is still a conversation, which is what
///    the board did before this type existed.
/// 2. **A person's own project** claims a directory at or under any of its
///    roots, deepest root first. It is how a person pins a folder below the
///    workspace depth as a project of its own.
/// 3. **Scratch** — ``ScratchRules`` — is not a project at all.
/// 4. **Anything else** rolls up to its workspace root:
///    - cut at the first path segment that starts with `.`, so a hidden run
///      folder belongs to the directory that holds it;
///    - then keep at most two components below the base the path hangs off —
///      the home directory, another account's `/Users/<name>`, a mounted
///      `/Volumes/<name>`, or `/` for everything else.
///
///    A cut that leaves nothing below the base — `~/.config/x`, `/Volumes/x`
///    itself — names no project.
/// 5. **A workspace root that is not on this Mac** names no project either.
///    The directory itself may be gone — a run folder cleaned up after it
///    finished — and that alone is no reason to lose the workspace it was in.
///
/// Pure: string arithmetic over the inputs, and one existence question asked
/// through the closure it is given.
public enum ProjectRollup {
    /// Where a directory belongs.
    public enum Outcome: Sendable, Hashable {
        /// Inside a repository; the repository is the project.
        case repository(gitRoot: String)
        /// At or under a root of one of the person's own projects.
        case userProject(root: String)
        /// Not a project. The match says why.
        case projectless(ScratchRules.Match)
        /// A plain directory, filed under the workspace that holds it.
        case workspace(root: String)

        /// The project root this outcome names, when it names one.
        public var root: String? {
            switch self {
            case .repository(let root), .userProject(let root), .workspace(let root): root
            case .projectless: nil
            }
        }
    }

    /// How many directories below its base a workspace root sits.
    public static let workspaceDepth = 2

    /// Places one directory.
    ///
    /// - Parameters:
    ///   - directory: the session's working directory, standardised or not.
    ///   - gitRoot: the repository ``ProjectResolver`` found around it, or
    ///     `nil` for a directory in none.
    ///   - harness: whose session it is, for the scratch rules that hold for
    ///     only some harnesses. `nil` asks the ones that hold for all.
    ///   - userRoots: the roots of the person's own projects — including the
    ///     deeper folders they pinned as projects of their own.
    ///   - rules: what is scratch.
    ///   - directoryExists: asked about the workspace root, at most once.
    public static func place(
        directory: String,
        gitRoot: String?,
        harness: Harness?,
        userRoots: [String],
        rules: ScratchRules,
        directoryExists: (String) -> Bool
    ) -> Outcome {
        let directory = ProjectResolver.standardized(directory)
        let scratch = rules.match(cwd: directory, harness: harness)
        if let gitRoot, scratch == nil { return .repository(gitRoot: gitRoot) }
        if let root = userRoot(containing: directory, among: userRoots) {
            return .userProject(root: root)
        }
        if let scratch { return .projectless(scratch) }
        guard let root = workspaceRoot(of: directory, home: rules.home) else {
            return .projectless(unplaceable(directory, home: rules.home))
        }
        // The workspace root can be scratch where the directory was not — a
        // run folder hidden under the home itself rolls up to the home.
        if let scratch = rules.match(cwd: root, harness: harness) { return .projectless(scratch) }
        guard directoryExists(root) else { return .projectless(ScratchRules.missing(directory: root)) }
        return .workspace(root: root)
    }

    /// The deepest of `roots` that `directory` is at or under.
    ///
    /// Deepest, because a person who made `~/work` a project and then pinned
    /// `~/work/reports/special` as another meant the second for everything
    /// under it.
    public static func userRoot(containing directory: String, among roots: [String]) -> String? {
        var best: String?
        for root in roots where ProjectPath.contains(root, directory) {
            if best.map({ root.count > $0.count }) ?? true { best = root }
        }
        return best
    }

    /// The workspace a plain directory rolls up to, or `nil` when the cut
    /// leaves nothing below the base — see the type's rule 4.
    public static func workspaceRoot(of directory: String, home: String) -> String? {
        let directory = ProjectResolver.standardized(directory)
        guard directory.hasPrefix("/") else { return nil }
        var components = (directory as NSString).pathComponents
        // The first hidden segment, and everything below it, belongs to the
        // directory that holds it. Index 0 is the root `/`.
        if let hidden = components.indices.dropFirst().first(where: { components[$0].hasPrefix(".") }) {
            components = Array(components[..<hidden])
        }
        let baseDepth = Self.baseDepth(of: components, home: home)
        guard components.count > baseDepth else { return nil }
        let kept = Array(components.prefix(baseDepth + workspaceDepth))
        return PathText.native(NSString.path(withComponents: kept))
    }

    /// How many leading components of a path are its base: the home, another
    /// account's home, a mounted volume, or the filesystem root.
    private static func baseDepth(of components: [String], home: String) -> Int {
        let path = NSString.path(withComponents: components)
        if !home.isEmpty, home != "/", ProjectPath.contains(home, path) {
            return (home as NSString).pathComponents.count
        }
        // `/Users/<name>` and `/Volumes/<name>`: one more component than the
        // directory they sit in, which is a list of homes or of disks rather
        // than a place anybody works.
        if components.count >= 2, ["Users", "Volumes"].contains(components[1]) {
            return min(3, components.count)
        }
        return 1
    }

    /// The match for a directory that is a base, or a hidden folder directly
    /// under one: the home is the home rule; anything else is a root.
    private static func unplaceable(_ directory: String, home: String) -> ScratchRules.Match {
        if !home.isEmpty, ProjectPath.contains(home, directory) {
            return ScratchRules.Match(reason: .home, directory: home, name: "~")
        }
        return ScratchRules.Match(
            reason: .root, directory: directory, name: PathText.lastComponent(directory)
        )
    }
}
