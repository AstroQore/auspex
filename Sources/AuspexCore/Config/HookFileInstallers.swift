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

/// Codex has two hook mechanisms, and which one this machine has is a fact
/// about its `config.toml` rather than about its version.
///
/// Every build has `notify`: one program, run when a turn ends, handled by
/// ``CodexNotifyInstaller``. Recent builds also have a hook *table* —
/// `~/.codex/hooks.json`, Claude Code's schema name for name — but only when
/// `hooks` is switched on under `[features]`. Off, the file is inert and
/// registering entries in it would be writing into somebody's directory to no
/// effect; on, it is strictly the better mechanism, because `notify` cannot say
/// anything about a permission prompt and `PermissionRequest` is the one fact no
/// transcript records.
///
/// So the row offers whichever one this machine will actually run, and uninstall
/// takes back both — a person who turned the feature on after installing the
/// wrapper would otherwise be left with a `notify` line nothing here admits to
/// having written.
///
/// One thing the table cannot promise and the wrapper can: Codex will not run a
/// hook it has not seen before. It records a `trusted_hash` per entry under
/// `[hooks.state]` in `config.toml` after asking, and Auspex does not write
/// there — granting yourself trust in the file whose whole job is to withhold it
/// would make the mechanism worthless. The entries land; Codex asks about them
/// at its next start; the person says yes. That sentence is in the plan's note
/// so the row can say it before anything is agreed to.
struct CodexHookInstaller: HookInstaller {
    let harness: Harness
    let home: URL
    let paths: AuspexPaths
    let binary: String

    var path: String { active.path }
    func plan() -> HookPlan { active.plan() }
    func status() -> HarnessInstaller.State { active.status() }
    func install() -> HarnessInstaller.Report { active.install() }

    /// Takes back both mechanisms.
    ///
    /// Cheap and safe when only one was ever written: the notify uninstall is a
    /// no-op on a `config.toml` with no fence of ours in it, and the table's is
    /// a no-op on a `hooks.json` that does not exist.
    func uninstall() -> HarnessInstaller.Report {
        let first = active.uninstall()
        let second = other.uninstall()
        guard second.didChange || second.failure != nil else { return first }
        return HarnessInstaller.Report(
            harness: harness,
            piece: .hooks,
            didChange: first.didChange || second.didChange,
            path: first.path,
            backupPath: first.backupPath ?? second.backupPath,
            failure: first.failure ?? second.failure
        )
    }

    /// The mechanism this machine will actually run.
    private var active: any HookInstaller { usesHookTable ? table : notify }
    /// The other one, which uninstall still has to be able to reach.
    private var other: any HookInstaller { usesHookTable ? notify : table }

    private var table: JSONHookTableInstaller {
        CodexHooksInstaller(harness: harness, home: home, paths: paths, binary: binary)
    }

    private var notify: CodexNotifyInstaller {
        CodexNotifyInstaller(harness: harness, home: home, paths: paths, binary: binary)
    }

    /// Whether `hooks` is on under `[features]` in `~/.codex/config.toml`.
    var usesHookTable: Bool {
        guard let text = try? String(contentsOfFile: notify.path, encoding: .utf8) else {
            return false
        }
        return Self.hooksFeatureEnabled(in: text)
    }

    /// A line scanner rather than a TOML parse, for the same reason
    /// ``ConfigTextEditors`` is one: this file is sixteen hundred lines of
    /// somebody else's settings on a working machine, and the question being
    /// asked is small enough that reading it as text cannot get it wrong in a
    /// way that matters. A false negative leaves the `notify` wrapper in place,
    /// which is the answer that was right before this existed.
    static func hooksFeatureEnabled(in text: String) -> Bool {
        var isInFeatures = false
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") {
                // Exactly `[features]`. A `[profiles.x.features]` is a
                // different table for a profile that may not be the one
                // running.
                isInFeatures = line.hasPrefix("[features]")
                continue
            }
            if isInFeatures, let value = Self.value(ofKey: "hooks", in: line) {
                return value.hasPrefix("true")
            }
            // The dotted spelling, which is legal at the top level and is what
            // a one-line edit tends to produce.
            if !isInFeatures, let value = Self.value(ofKey: "features.hooks", in: line) {
                return value.hasPrefix("true")
            }
        }
        return false
    }

    /// The right-hand side of `key = …`, when this line is that assignment.
    private static func value(ofKey key: String, in line: String) -> String? {
        guard line.hasPrefix(key) else { return nil }
        let rest = line.dropFirst(key.count).trimmingCharacters(in: .whitespaces)
        guard rest.hasPrefix("=") else { return nil }
        return rest.dropFirst().trimmingCharacters(in: .whitespaces)
    }
}

/// Codex's other mechanism: `notify`, one program, run when a turn ends.
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
