import AgentSessionKit
import AgentSessionLive
import Foundation

/// The source adapters Auspex runs, and the stores they read.
///
/// One list, in one file, because it is the answer to two questions a reader
/// will ask separately: *what does this app actually open on my disk*, and
/// *why is my harness not on the board*. Keeping the roots next to the
/// adapters means the empty state can tell the truth about both without a
/// second table to keep in sync.
enum AuspexAdapters {
    /// Every adapter the ingest coordinator should tail — one per harness
    /// Auspex observes. Order is display order for the empty state and for
    /// tie-breaks; the coordinator itself does not care.
    ///
    /// Each adapter owns its own discovery, tailing, and liveness probing.
    /// Nothing else in the app names a harness: `installed` is derived from
    /// this list, the empty state reads `installed`, and the coordinator
    /// discovers, tails, and re-seeds on its own.
    static var all: [any SourceAdapter] {
        [
            ClaudeLiveAdapter(),
            CodexLiveAdapter(),
            CursorLiveAdapter(),
            GrokLiveAdapter(),
            AntigravityLiveAdapter(),
        ]
    }

    /// The harnesses ``all`` actually covers. Derived rather than declared, so
    /// the empty state cannot claim to be watching something no adapter reads.
    static var installed: Set<Harness> {
        Set(all.map(\.harness))
    }

    /// The directories each adapter actually watches, by harness.
    ///
    /// Asked of the adapters rather than derived from
    /// ``storeDescription(for:)``, because the Harnesses page says whether a
    /// store *exists on this Mac* — and a detection answer about a path no
    /// tailer opens would be worse than no answer. A harness with several roots
    /// keeps all of them: it counts as detected if any one is there.
    static func watchRoots(home: String) -> [Harness: [URL]] {
        var roots: [Harness: [URL]] = [:]
        for adapter in all {
            roots[adapter.harness, default: []].append(contentsOf: adapter.watchRoots(home: home))
        }
        return roots
    }

    /// Where each harness keeps the sessions Auspex would read, for display.
    ///
    /// Descriptive, not operational: the real roots come from each adapter's
    /// `watchRoots(home:)`, and nothing here is ever opened. It exists so the
    /// empty state can say which directories the app is interested in before
    /// any adapter exists to open them — "watching nothing" is a much worse
    /// answer than "here is what I will watch, and here is why I cannot yet".
    static func storeDescription(for harness: Harness) -> String {
        switch harness {
        case .claudeCode: "~/.claude/projects"
        case .claudeCowork: "~/Library/Application Support/Claude"
        case .codex: "~/.codex/sessions"
        case .chatgptWork: "~/.codex/sessions"
        case .cursor: "~/.cursor/chats"
        case .grokBuild: "~/.grok/sessions"
        case .antigravity: "~/.gemini/antigravity"
        case .geminiCLI: "~/.gemini/tmp"
        }
    }

    /// The harnesses the board's empty state lists, in display order.
    ///
    /// The five a person is likely to be running. The other three in the
    /// catalog — Claude Cowork, ChatGPT Work, Gemini CLI — are variants that
    /// share a store with one of these, and listing all eight turns a status
    /// panel into a specification.
    static let featured: [Harness] = [.claudeCode, .codex, .cursor, .grokBuild, .antigravity]
}
