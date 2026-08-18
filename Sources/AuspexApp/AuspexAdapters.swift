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
    /// Every adapter the ingest coordinator should tail.
    ///
    /// Empty today. `AgentSessionLive` defines `SourceAdapter` and the whole
    /// tailing pipeline, but the concrete Claude Code and Codex adapters are
    /// still landing in the kit; an empty array is legal and produces a
    /// coordinator that watches nothing, which is exactly the pre-adapter
    /// behaviour we want — the app runs, the board is honestly empty, and
    /// nothing pretends to observe a harness it cannot read.
    ///
    /// TODO(M1): append `ClaudeLiveAdapter()` and `CodexLiveAdapter()` here
    /// once they are on `agent-session-kit`'s main branch. Nothing else in
    /// the app has to change: `installed` is derived from this list, the empty
    /// state reads `installed`, and the coordinator discovers, tails, and
    /// re-seeds on its own.
    /// TODO(M2): Cursor, Grok Build, and AntiGravity follow.
    static var all: [any SourceAdapter] { [] }

    /// The harnesses ``all`` actually covers. Derived rather than declared, so
    /// the empty state cannot claim to be watching something no adapter reads.
    static var installed: Set<Harness> {
        Set(all.map(\.harness))
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
