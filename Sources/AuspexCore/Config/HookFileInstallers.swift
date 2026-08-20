import AgentSessionKit
import Foundation

// MARK: - Grok Build

/// Grok's hooks, in a file of Auspex's own.
///
/// Grok reads every `*.json` in `~/.grok/hooks/`, each one a Claude-shaped hook
/// table, which makes this the easiest of the four to be a good citizen in:
/// Auspex writes `auspex.json` and nothing else, so "uninstall restores exactly
/// what was there" is true by construction rather than by careful editing.
///
/// No permission event, and that is not an omission. Grok is the one harness
/// that records permission requests and resolutions in its own `events.jsonl`,
/// so the tailer already knows — and a hook that reported the same thing again
/// would be a second opinion about a fact that is not in doubt.
struct GrokHookInstaller: HookInstaller {
    let harness: Harness = .grokBuild
    let home: URL
    let paths: AuspexPaths
    let binary: String

    var path: String {
        home.appendingPathComponent(".grok/hooks/auspex.json").path
    }

    static let events = [
        "SessionStart", "SessionEnd", "Stop", "SubagentStart", "SubagentStop", "Notification"
    ]

    func plan() -> HookPlan {
        HookPlan(
            path: path,
            events: Self.events,
            command: HookCommand.text(binary: binary, target: .grok)
        )
    }

    func status() -> HarnessInstaller.State {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
            return FileManager.default.fileExists(atPath: path)
                ? .unreadable("The file exists but could not be read as UTF-8.")
                : .absent
        }
        if text == contents { return .installed }
        guard let data = text.data(using: .utf8),
              (try? JSONSerialization.jsonObject(with: data)) != nil
        else { return .unreadable("The file is not JSON.") }
        return .installedElsewhere("a hook file from another Auspex")
    }

    func install() -> HarnessInstaller.Report {
        report(
            ConfigFileWriter(paths: paths, harness: harness).edit(
                path: path, verify: ConfigFileWriter.isStillJSON
            ) { _ in contents }
        )
    }

    func uninstall() -> HarnessInstaller.Report {
        report(ConfigFileWriter(paths: paths, harness: harness).remove(path: path))
    }

    /// The whole file. Deterministic, so "is this ours and current" is a string
    /// comparison rather than a structural diff.
    var contents: String {
        let command = JSONTextEditor.escaped(HookCommand.text(binary: binary, target: .grok))
        let blocks = Self.events.map { event in
            """
                "\(event)": [
                  {
                    "hooks": [
                      {"type": "command", "command": "\(command)", "timeout": \(JSONHookTableInstaller.timeout)}
                    ]
                  }
                ]
            """
        }
        return """
            {
              "hooks": {
            \(blocks.joined(separator: ",\n"))
              }
            }

            """
    }

    private func report(_ outcome: ConfigFileWriter.Outcome) -> HarnessInstaller.Report {
        HarnessInstaller.Report(
            harness: harness,
            piece: .hooks,
            didChange: outcome.didChange,
            path: path,
            backupPath: outcome.backupPath,
            failure: outcome.failure
        )
    }
}

// MARK: - Codex

/// Codex has no hook table. It has `notify`: one program, run when a turn ends.
///
/// One slot means registering Auspex there is *displacing* whatever was in it —
/// on this machine, a computer-use client — and the only honest way to displace
/// a program is to keep running it. So the installed line puts Auspex in front
/// and hands the payload straight on:
///
/// ```toml
/// # >>> auspex-notify >>>
/// # was: notify = ["/old/notify", "turn-ended"]
/// notify = ["…/Auspex", "--hook", "codex-notify", "--then", "/old/notify", "turn-ended"]
/// # <<< auspex-notify <<<
/// ```
///
/// The `# was:` line is not a comment for a reader's benefit: it is how
/// uninstall puts the original line back byte for byte, which is the promise
/// that makes wrapping somebody else's program acceptable at all. Everything
/// else in `config.toml` — and on this machine that is sixteen hundred lines of
/// it — is never re-serialised.
///
/// A `notify` that spans several lines is refused rather than wrapped. It is a
/// legal spelling that Auspex's line-level scanner cannot rewrite safely, and a
/// refusal a person can read beats an edit they have to check.
struct CodexNotifyInstaller: HookInstaller {
    let harness: Harness
    let home: URL
    let paths: AuspexPaths
    let binary: String

    var path: String {
        home.appendingPathComponent(".codex/config.toml").path
    }

    /// A fence of its own, so the MCP registration and this can share a file
    /// without either one deciding it owns the other's block.
    static let fence = ConfigFence(comment: .hash, name: "auspex-notify")

    /// The marker the original line is kept behind.
    static let originalMarker = "# was: "

    func plan() -> HookPlan {
        HookPlan(
            path: path,
            events: ["agent-turn-complete"],
            command: HookCommand.text(binary: binary, target: .codexNotify)
        )
    }

    func status() -> HarnessInstaller.State {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
            return FileManager.default.fileExists(atPath: path)
                ? .unreadable("The file exists but could not be read as UTF-8.")
                : .absent
        }
        if let body = Self.fence.body(in: text) {
            guard let line = notifyLine(in: body), let arguments = Self.array(in: line.text) else {
                return .unreadable("Auspex's own notify block could not be read.")
            }
            return arguments.first == binary
                ? .installed
                : .installedElsewhere(arguments.first ?? "an unnamed command")
        }
        guard let existing = notifyLine(in: text) else { return .absent }
        return Self.array(in: existing.text) == nil
            ? .unreadable("The notify setting is spread over several lines; Auspex will not rewrite it.")
            : .absent
    }

    func install() -> HarnessInstaller.Report {
        report(ConfigFileWriter(paths: paths, harness: harness).edit(path: path) { text in
            // Already wrapped: rebuild from the original this block recorded,
            // so re-installing after moving the binary keeps the chain.
            if let range = Self.fence.range(in: text) {
                let original = self.original(in: String(text[range]))
                var out = text
                out.replaceSubrange(
                    range,
                    with: Self.trimmed(
                        Self.fence.block(block(wrapping: original)),
                        keepingNewline: text[range].hasSuffix("\n")
                    )
                )
                return out
            }
            guard let existing = notifyLine(in: text) else {
                return Self.fence.applying(block(wrapping: nil), to: text)
            }
            guard Self.array(in: existing.text) != nil else {
                throw HookInstallError.notify(
                    "The notify setting is spread over several lines; Auspex will not rewrite it."
                )
            }
            var out = text
            // The line's own newline goes with it, so the block that takes its
            // place ends exactly where it did — and uninstall can put the line
            // back with the same newline it had.
            out.replaceSubrange(
                existing.range,
                with: Self.trimmed(
                    Self.fence.block(block(wrapping: existing.text)),
                    keepingNewline: existing.endsWithNewline
                )
            )
            return out
        })
    }

    func uninstall() -> HarnessInstaller.Report {
        report(ConfigFileWriter(paths: paths, harness: harness).edit(path: path) { text in
            guard let range = Self.fence.range(in: text) else { return text }
            var out = text
            // Exactly what was there: the recorded line with the newline it
            // had, or nothing at all when the slot was empty before Auspex
            // took it.
            let newline = text[range].hasSuffix("\n") ? "\n" : ""
            let restored = self.original(in: String(text[range])).map { $0 + newline } ?? ""
            out.replaceSubrange(range, with: restored)
            if restored.isEmpty, out.hasSuffix("\n\n") { out.removeLast() }
            return out
        })
    }

    // MARK: - The block

    /// The body of the fence: the recorded original, then the wrapped line.
    func block(wrapping original: String?) -> String {
        let chained = original.flatMap(Self.array(in:)) ?? []
        var arguments = [binary, HookIngress.flag, HookTarget.codexNotify.rawValue]
        if !chained.isEmpty {
            arguments.append(HookIngress.chainFlag)
            arguments.append(contentsOf: chained)
        }
        let rendered = arguments
            .map { "\"\(JSONTextEditor.escaped($0))\"" }
            .joined(separator: ", ")
        var lines: [String] = []
        if let original {
            lines.append(Self.originalMarker + original)
        }
        lines.append("notify = [\(rendered)]")
        return lines.joined(separator: "\n")
    }

    /// The line the block replaced, when it replaced one.
    private func original(in block: String) -> String? {
        block
            .split(separator: "\n", omittingEmptySubsequences: false)
            .first { $0.hasPrefix(Self.originalMarker) }
            .map { String($0.dropFirst(Self.originalMarker.count)) }
    }

    /// One line of a config file, and the span it occupies including its own
    /// newline.
    private struct Line {
        let text: String
        let range: Range<String.Index>
        let endsWithNewline: Bool
    }

    /// The first top-level `notify = …` line, and where it is.
    ///
    /// "Top level" matters: `config.toml` on a working machine has a hundred
    /// `[…]` tables under it, and a `notify` inside one of them is a different
    /// setting that happens to share a name.
    private func notifyLine(in text: String) -> Line? {
        var cursor = text.startIndex
        var isTopLevel = true
        while cursor < text.endIndex {
            let end = text[cursor...].firstIndex(of: "\n") ?? text.endIndex
            let line = String(text[cursor..<end])
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[") {
                isTopLevel = false
            } else if isTopLevel, trimmed.hasPrefix("notify"),
                      trimmed.dropFirst("notify".count)
                        .trimmingCharacters(in: .whitespaces).hasPrefix("=") {
                let hasNewline = end < text.endIndex
                return Line(
                    text: line,
                    range: cursor..<(hasNewline ? text.index(after: end) : end),
                    endsWithNewline: hasNewline
                )
            }
            cursor = end < text.endIndex ? text.index(after: end) : text.endIndex
        }
        return nil
    }

    /// A block, with its trailing newline kept or dropped to match what it is
    /// replacing.
    private static func trimmed(_ block: String, keepingNewline: Bool) -> String {
        keepingNewline || !block.hasSuffix("\n") ? block : String(block.dropLast())
    }

    /// The strings in a single-line TOML array, or `nil` when the line does not
    /// hold one that opens and closes on itself.
    static func array(in line: String) -> [String]? {
        guard let open = line.firstIndex(of: "[") else { return nil }
        var out: [String] = []
        var current: String?
        var escaped = false
        var index = line.index(after: open)
        while index < line.endIndex {
            let character = line[index]
            if var value = current {
                if escaped {
                    value.append(character)
                    current = value
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                } else if character == "\"" {
                    out.append(value)
                    current = nil
                } else {
                    value.append(character)
                    current = value
                }
            } else if character == "\"" {
                current = ""
            } else if character == "]" {
                return current == nil ? out : nil
            } else if character == "#" {
                return nil
            }
            index = line.index(after: index)
        }
        return nil
    }

    private func report(_ outcome: ConfigFileWriter.Outcome) -> HarnessInstaller.Report {
        HarnessInstaller.Report(
            harness: harness,
            piece: .hooks,
            didChange: outcome.didChange,
            path: path,
            backupPath: outcome.backupPath,
            failure: outcome.failure
        )
    }
}
