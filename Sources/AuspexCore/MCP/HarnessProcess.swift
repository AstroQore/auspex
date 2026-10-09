import AgentSessionKit
import AgentSessionLive
import Foundation

/// A harness's own process, recognised from what the kernel says about it.
///
/// ## Why Auspex needs to recognise one at all
///
/// Two questions about identity are really questions about *which kind* of
/// program a pid is:
///
/// - **May a hook teach a session its pid?** A hook's parent is the harness
///   that ran it — unless something stood in between, in which case the pid
///   names a shell or a wrapper and recording it would make a session "alive"
///   for as long as that unrelated process lived.
/// - **Which harness does an MCP bridge belong to?** Walking up from the
///   bridge, the first harness process is the one that spawned it. Anything
///   further up is an *outer* harness — the Claude Code session that launched
///   a Codex worker — and attributing the worker's call there is the most
///   expensive mistake the resolver can make, because it looks like success.
///
/// ## What it reads
///
/// The short name and the executable path, which the app's process table
/// always carries for the person's own processes, and argv when the table was
/// built to read it (the app's is not: some harnesses put credentials there).
/// The answer is a basename from a fixed list, so ``executable`` is safe to
/// show and to log; nothing here ever surfaces a path or a command line.
///
/// The table is deliberately small. A process it does not recognise is not
/// evidence of anything, and every caller treats "unrecognised" as "carry on
/// as before" rather than as a refusal.
public struct HarnessProcess: Sendable, Equatable {
    /// The process.
    public let pid: pid_t
    /// When it started, from the same table read.
    public let startTime: Date
    /// The executable name that matched, from ``signatures``. Never a path.
    public let executable: String
    /// The harnesses whose sessions this program runs. Codex's binary serves
    /// both Codex and ChatGPT Work, which share `~/.codex`.
    public let harnesses: Set<Harness>
    /// One process serving many sessions at once, so its pid says nothing
    /// about which of them is calling.
    ///
    /// The Codex binary a desktop host starts as `codex app-server` is the
    /// case that matters: ChatGPT keeps one of them up for every thread it has
    /// open, and every thread's MCP bridge is its direct child.
    public let isMultiSession: Bool

    public init(
        pid: pid_t,
        startTime: Date,
        executable: String,
        harnesses: Set<Harness>,
        isMultiSession: Bool
    ) {
        self.pid = pid
        self.startTime = startTime
        self.executable = executable
        self.harnesses = harnesses
        self.isMultiSession = isMultiSession
    }

    /// Executable names that launch a harness, and the harnesses each serves.
    ///
    /// The same five names the kit's process linker launches harnesses by.
    /// Basenames only: a Homebrew `codex`, the standalone one, and the copy
    /// inside a desktop app's bundle are one harness.
    public static let signatures: [(executable: String, harnesses: Set<Harness>)] = [
        ("claude", [.claudeCode]),
        ("codex", [.codex, .chatgptWork]),
        ("cursor-agent", [.cursor]),
        ("grok", [.grokBuild]),
        ("agy", [.antigravity])
    ]

    /// Subcommands that turn the Codex binary into a server for many threads.
    static let multiSessionSubcommands: Set<String> = ["app-server", "mcp-server", "exec-server"]

    /// Set by the desktop hosts that run Codex as a thread server — ChatGPT,
    /// the Codex app, the editor extensions — and by nothing a terminal user
    /// types. Only its presence is read.
    static let hostedOriginatorVariable = "CODEX_INTERNAL_ORIGINATOR_OVERRIDE"

    /// Recognises a process, or `nil` when it is not a harness Auspex knows.
    ///
    /// - Parameters:
    ///   - record: the process.
    ///   - table: consulted only for a Codex process, and only for whether its
    ///     environment names a desktop host. `nil` skips that check.
    public static func recognize(
        _ record: ProcessRecord,
        table: (any ProcessTableReading)? = nil
    ) -> HarnessProcess? {
        guard let match = signature(of: record) else { return nil }
        var multiSession = false
        if match.harnesses.contains(.codex) {
            if record.argv.contains(where: multiSessionSubcommands.contains) {
                multiSession = true
            } else if let environment = table?.environment(pid: record.pid),
                      environment[hostedOriginatorVariable] != nil {
                multiSession = true
            }
        }
        return HarnessProcess(
            pid: record.pid,
            startTime: record.startTime,
            executable: match.executable,
            harnesses: match.harnesses,
            isMultiSession: multiSession
        )
    }

    /// The signature a record matches, by name, by executable, or by the
    /// versioned install directory a self-updating CLI runs out of.
    static func signature(of record: ProcessRecord) -> (executable: String, harnesses: Set<Harness>)? {
        let path = record.executablePath
        var names = [record.name]
        if !path.isEmpty { names.append((path as NSString).lastPathComponent) }
        if let first = record.argv.first, !first.isEmpty {
            names.append((first as NSString).lastPathComponent)
        }

        for signature in signatures {
            for name in names where matches(name, signature.executable) {
                return signature
            }
            // Claude Code's native installer runs
            // `…/claude/versions/2.1.0`, and `cursor-agent` runs a bundled
            // `node` out of `…/cursor-agent/versions/<build>/`: the basename
            // is a version or an interpreter, and the directory is the name.
            if path.contains("/\(signature.executable)/versions/") {
                return signature
            }
        }
        return nil
    }

    /// `codex`, or a downloaded build named for it — `grok-1.0.46-macos-…` —
    /// but not a sibling tool such as `codex-code-mode-host`.
    private static func matches(_ name: String, _ executable: String) -> Bool {
        if name == executable { return true }
        let prefix = executable + "-"
        guard name.hasPrefix(prefix) else { return false }
        return name.dropFirst(prefix.count).first?.isNumber == true
    }
}
