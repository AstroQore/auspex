import Foundation

/// The directories a harness makes one of per *thread* rather than per
/// project.
///
/// The Codex desktop app opens every conversation in a scratch directory of
/// its own: `~/Documents/Codex/<YYYY-MM-DD>/<name>`, where `<name>` is a slug
/// of the first thing the person said — `zhe`, `zai-b`, `new-chat`. Older
/// builds flattened the same idea into `~/Documents/Codex/<YYYY-MM-DD>-<name>`.
/// Both are working directories, so both reach a session's `cwd`, and a board
/// that groups by `cwd` therefore grows one project per conversation: a week
/// of desktop threads becomes a week of one-session projects with names that
/// mean nothing a day later, crowding out the repositories a person opened
/// the sidebar to read.
///
/// They are not projects. They are the harness's own scratch space, and the
/// honest placement for a session in one is *no project* — under the harness,
/// with the folder as the only thing worth saying about which scratch it is.
///
/// ## A table, not a special case
///
/// ChatGPT Work is the same desktop app signed in to a work account, and it
/// writes the same tree under its own name. Claude Cowork runs its sessions in
/// an isolated container that has the same character, and would belong here if
/// it ever reached a `cwd` — the kit currently replaces it with the external
/// directory the tools actually touched, so it does not. Adding a root is a
/// row in ``roots``.
///
/// One shape is matched, and it is the shape all of these have: a root
/// directory whose children are dated buckets, one conversation below that.
/// A root organised some other way is a change to ``thread(forPath:home:)``
/// as well as a row, and pretending otherwise here would be a table that
/// silently mis-files whatever was added to it.
public enum HarnessSandbox {
    /// A directory tree whose contents are threads.
    public struct Root: Sendable, Hashable {
        /// Path components below the home directory: `["Documents", "Codex"]`.
        public let components: [String]
        /// One word for *why* a session in here has no project, carried on the
        /// placement so a reader who asks can be told rather than left to
        /// wonder where their project went.
        public let note: String

        public init(components: [String], note: String = HarnessSandbox.sandboxNote) {
            self.components = components
            self.note = note
        }
    }

    /// The note every root carries today.
    public static let sandboxNote = "sandbox"

    /// Every scratch root Auspex knows about.
    ///
    /// `Documents/ChatGPT` is listed on the same evidence as its sibling —
    /// the two are one app under two accounts — and costs nothing on a machine
    /// that has no such directory: a root nothing resolves under never
    /// matches.
    public static let roots: [Root] = [
        Root(components: ["Documents", "Codex"]),
        Root(components: ["Documents", "ChatGPT"]),
    ]

    /// One conversation's scratch directory.
    public struct Thread: Sendable, Hashable {
        /// The directory the harness made for this thread — the deepest one
        /// that is still about a single conversation, whatever the session
        /// later `cd`-ed into below it.
        public let directory: String
        /// What to call it: the folder, without the date bucket that only
        /// records when it was made.
        public let name: String
        /// The owning root's ``Root/note``.
        public let note: String

        public init(directory: String, name: String, note: String) {
            self.directory = directory
            self.name = name
            self.note = note
        }
    }

    /// The thread `path` belongs to, or `nil` when it is an ordinary
    /// directory.
    ///
    /// The date bucket is what makes this safe. A person who keeps a real
    /// repository at `~/Documents/Codex/notes` still gets a project: only a
    /// child named `2026-08-21`, or `2026-08-21-something`, is read as one of
    /// the app's own buckets.
    public static func thread(
        forPath path: String,
        home: String = AuspexPaths.realHomeDirectory().path
    ) -> Thread? {
        let directory = ProjectResolver.standardized(path)
        let home = ProjectResolver.standardized(home)
        guard !home.isEmpty, directory.hasPrefix(home + "/") else { return nil }
        let homeDepth = (home as NSString).pathComponents.count
        let relative = Array((directory as NSString).pathComponents.dropFirst(homeDepth))

        for root in roots {
            guard relative.count > root.components.count,
                  Array(relative.prefix(root.components.count)) == root.components
            else { continue }
            let rest = Array(relative.dropFirst(root.components.count))
            guard let bucket = rest.first, let date = datePrefix(of: bucket) else { continue }

            var directoryComponents = [home] + root.components + [bucket]
            var name = String(bucket.dropFirst(date.count))
                .trimmingCharacters(in: CharacterSet(charactersIn: "-_ "))
            if name.isEmpty {
                // `<date>/<name>`: the bucket is only the day, and the
                // conversation is the directory under it. A session sitting in
                // the bucket itself has no name to show, which is honest — it
                // has no conversation folder either.
                if rest.count > 1 {
                    directoryComponents.append(rest[1])
                    name = rest[1]
                } else {
                    name = bucket
                }
            }
            return Thread(
                directory: NSString.path(withComponents: directoryComponents),
                name: name,
                note: root.note
            )
        }
        return nil
    }

    /// Whether `path` is inside somebody's per-thread scratch.
    public static func isThread(
        path: String,
        home: String = AuspexPaths.realHomeDirectory().path
    ) -> Bool {
        thread(forPath: path, home: home) != nil
    }

    /// The `YYYY-MM-DD` a bucket name opens with, or `nil` when it opens with
    /// something else.
    ///
    /// Deliberately not a `DateFormatter`: this is asked of every directory
    /// component of every working directory a board resolves, and the question
    /// is about the *shape* of the name rather than about whether the day
    /// exists. `2026-13-45` is still one of the app's buckets.
    static func datePrefix(of component: String) -> String? {
        let characters = Array(component)
        guard characters.count >= dateLength else { return nil }
        for (index, character) in characters.prefix(dateLength).enumerated() {
            let isSeparator = index == 4 || index == 7
            if isSeparator ? character != "-" : !character.isNumber { return nil }
        }
        return String(characters.prefix(dateLength))
    }

    /// `YYYY-MM-DD`.
    static let dateLength = 10
}
