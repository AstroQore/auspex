import AgentSessionKit
import Foundation

/// Registers Auspex as a hook with one harness.
///
/// The same bargain ``HarnessInstaller`` makes — a person clicked, it goes in a
/// region Auspex owns, the file is backed up first and re-parsed after, and
/// uninstall takes back exactly what was written — applied to a different kind
/// of file. Hook tables are *lists* rather than named members, and other tools
/// append to the same lists, so the region Auspex owns is "the entries whose
/// command runs the Auspex binary with `--hook`" and nothing else in the file
/// is read or rewritten.
///
/// Five shapes, for the harnesses that have hooks at all:
///
/// | Harness | File | Shape |
/// | --- | --- | --- |
/// | Claude Code | `~/.claude/settings.json` | `hooks.<Event>[]`, matcher groups |
/// | Grok Build | `~/.grok/hooks/auspex.json` | a file of its own, Claude's schema |
/// | Cursor | `~/.cursor/hooks.json` | `hooks.<event>[]`, bare commands |
/// | Codex | `~/.codex/hooks.json` | Claude's schema, when the feature is on |
/// | Codex | `~/.codex/config.toml` | one `notify` program, wrapped if taken |
///
/// Codex has two because which one exists depends on the machine — see
/// ``CodexHookInstaller``.
///
/// AntiGravity and Gemini CLI have no hook mechanism, and Claude Cowork runs
/// inside Claude.app where its settings are not a file Auspex may name. Those
/// stay purely passive, which is what ``HookInstallers/installer(for:home:paths:command:)``
/// returning `nil` means.
public protocol HookInstaller: Sendable {
    /// Whose hooks these are.
    var harness: Harness { get }
    /// The file that would be written. Named before anything is agreed to:
    /// "adds a few entries" means nothing without "to this file".
    var path: String { get }
    /// What is there now.
    func status() -> HarnessInstaller.State
    /// What installing would register, in the harness's own vocabulary.
    func plan() -> HookPlan
    /// Writes it. Idempotent.
    func install() -> HarnessInstaller.Report
    /// Takes it back out and nothing else.
    func uninstall() -> HarnessInstaller.Report
}

/// What one harness's hook installation consists of.
public struct HookPlan: Sendable, Equatable {
    /// The file.
    public let path: String
    /// The harness's own event names, in the order they are written.
    public let events: [String]
    /// The command each entry runs.
    public let command: String
    /// One sentence about what the harness will then do, when there is
    /// something a person would otherwise be surprised by — Codex, for one,
    /// asks them to review a hook it has not seen before it will run it.
    public let note: String?

    public init(path: String, events: [String], command: String, note: String? = nil) {
        self.path = path
        self.events = events
        self.command = command
        self.note = note
    }

    /// One line for a settings row: what this actually costs the harness.
    public var summary: String {
        events.isEmpty
            ? "Runs Auspex when this harness has something to report."
            : "\(events.count) events: \(events.joined(separator: ", "))."
    }
}

// MARK: - Ownership

/// The command an entry runs, and how Auspex tells its own from everyone
/// else's.
///
/// Hook tables are shared. A working machine has entries from a statusline
/// tool, a notifier, whatever the user wrote themselves — and Auspex has to be
/// able to find its own among them without a fence, because JSON has no
/// comments to draw one with. The command *is* the fence: an entry belongs to
/// Auspex when it runs a binary called `Auspex` with `--hook <target>`, and
/// that test is deliberately narrow in both halves.
public enum HookCommand {
    /// The name the binary has to have for an entry to be Auspex's.
    ///
    /// Not the full path: a person who moves `Auspex.app` from `~/Downloads` to
    /// `/Applications`, or who runs a source build beside an installed one,
    /// must still be able to find and remove the entry the other one wrote.
    public static let executableName = "Auspex"

    /// The command an entry runs: the binary, quoted, then the flag.
    public static func text(binary: String, target: HookTarget) -> String {
        "\"\(binary)\" \(HookIngress.flag) \(target.rawValue)"
    }

    /// Whether this command is one Auspex wrote, for this target.
    public static func isOurs(_ command: String, target: HookTarget) -> Bool {
        let tokens = tokenize(command)
        guard let program = tokens.first,
              (program as NSString).lastPathComponent == executableName
        else { return false }
        guard let flag = tokens.firstIndex(of: HookIngress.flag), flag + 1 < tokens.count
        else { return false }
        return tokens[flag + 1] == target.rawValue
    }

    /// Splits a shell-ish command into tokens, honouring one level of quoting.
    ///
    /// Not a shell parser and not trying to be: the only commands it is asked
    /// about are ones Auspex wrote, and the only thing it has to get right is a
    /// quoted path with a space in it — which is every path under
    /// `~/Library/Application Support`.
    static func tokenize(_ command: String) -> [String] {
        var out: [String] = []
        var current = ""
        var quote: Character?
        for character in command {
            if let open = quote {
                if character == open { quote = nil } else { current.append(character) }
                continue
            }
            switch character {
            case "\"", "'":
                quote = character
            case " ", "\t":
                if !current.isEmpty { out.append(current); current = "" }
            default:
                current.append(character)
            }
        }
        if !current.isEmpty { out.append(current) }
        return out
    }
}

// MARK: - The catalogue

/// Which harnesses have an installer, and how to build one.
public enum HookInstallers {
    /// The installer for a harness, or `nil` when it has no hooks to install.
    public static func installer(
        for harness: Harness,
        home: URL,
        paths: AuspexPaths,
        command: String
    ) -> (any HookInstaller)? {
        switch harness {
        case .claudeCode:
            return ClaudeHookInstaller(home: home, paths: paths, binary: command)
        case .grokBuild:
            return GrokHookInstaller(home: home, paths: paths, binary: command)
        case .cursor:
            return CursorHookInstaller(home: home, paths: paths, binary: command)
        case .codex, .chatgptWork:
            return CodexHookInstaller(
                harness: harness, home: home, paths: paths, binary: command
            )
        case .claudeCowork, .antigravity, .geminiCLI, .grokBot:
            return nil
        }
    }

    /// Why a harness has no hook row, in the words a page shows.
    public static func reasonUnavailable(_ harness: Harness) -> String {
        switch harness {
        case .claudeCowork:
            "Cowork's hooks live inside Claude.app, not in a file Auspex can name."
        case .antigravity, .geminiCLI:
            "This harness has no hook mechanism, so Auspex watches it passively."
        case .grokBot:
            "Grok Bot runs on xAI's servers; there is nothing local to hook."
        default:
            "This harness has no hook mechanism Auspex knows about."
        }
    }
}
