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
            ClaudeCoworkLiveAdapter(),
            CodexLiveAdapter(),
            CursorLiveAdapter(),
            GrokLiveAdapter(),
            GrokBotLiveAdapter(),
            AntigravityLiveAdapter(),
        ]
    }

    /// The harnesses ``all`` actually covers. Derived rather than declared, so
    /// the empty state cannot claim to be watching something no adapter reads.
    ///
    /// `handledHarnesses` rather than `harness`: `CodexLiveAdapter` reads one
    /// store that carries two harnesses, and keying off its primary alone
    /// would have this page claim ChatGPT Work is unwatched while its sessions
    /// are on the board.
    static var installed: Set<Harness> {
        Set(all.flatMap(\.handledHarnesses))
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
            for harness in adapter.handledHarnesses {
                roots[harness, default: []].append(contentsOf: adapter.watchRoots(home: home))
            }
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
        case .claudeCowork: "~/Library/Application Support/Claude/local-agent-mode-sessions"
        case .codex: "~/.codex/sessions"
        case .chatgptWork: "~/.codex/sessions"
        case .cursor: "~/.cursor/chats"
        case .grokBuild: "~/.grok/sessions"
        case .antigravity: "~/.gemini/antigravity"
        case .geminiCLI: "~/.gemini/tmp"
        case .grokBot: "~/Library/Application Support/Grok Bot/sand-client-persistence"
        }
    }

    /// A one-line note about a store two harnesses share, or `nil` when the
    /// harness has a store to itself.
    ///
    /// Two rows on the Harnesses page name the same directory, which looks
    /// like a bug until it is explained. It is not: `~/.codex/sessions` holds
    /// both Codex and ChatGPT Work rollouts, told apart only by each
    /// rollout's `originator`. Saying so on the row is cheaper than a person
    /// discovering it from a duplicate path.
    static func storeNote(for harness: Harness) -> String? {
        switch harness {
        case .codex:
            "shares ~/.codex/sessions; every originator except ChatGPT Work"
        case .chatgptWork:
            "shares ~/.codex/sessions; originator ChatGPT Work"
        default:
            nil
        }
    }

    /// The harnesses the board's empty state and the Harnesses page list, in
    /// display order.
    ///
    /// The eight a person can actually be running on this Mac, grouped by
    /// vendor. Claude Cowork and ChatGPT Work are here because they are
    /// harnesses in their own right — Cowork has its own store inside
    /// Claude.app, and ChatGPT Work is a different plan on a shared one — and
    /// folding either into its sibling would attribute its work to the wrong
    /// row. Grok Bot sits after Grok Build for the same reason and a stronger
    /// one: they share a company, a mark, and nothing else, and a person
    /// running the desktop bot client is running something Grok Build cannot
    /// account for. Gemini CLI is the one left out: it is deprecated, it has
    /// no live adapter, and a status panel that listed every case in the
    /// catalog would be a specification rather than a status panel.
    static let featured: [Harness] = [
        .claudeCode, .claudeCowork, .codex, .chatgptWork, .cursor,
        .grokBuild, .grokBot, .antigravity
    ]
}
