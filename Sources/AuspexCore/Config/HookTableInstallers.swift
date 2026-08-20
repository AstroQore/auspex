import AgentSessionKit
import Foundation

/// The harnesses that keep a JSON hook table other tools also write into.
///
/// Claude Code, Cursor and Codex differ only in what one entry looks like and
/// what their events are called, so they are one installer with two spellings
/// rather than three installers with one algorithm. Grok uses Claude's schema in
/// a file of its own and is handled by ``GrokHookInstaller``.
struct JSONHookTableInstaller: HookInstaller {
    /// How one entry is written, and where.
    enum Style: Sendable {
        /// `{"matcher": "*", "hooks": [{"type": "command", "command": "…"}]}`
        case claude
        /// `{"command": "…"}`
        case cursor
    }

    let harness: Harness
    let target: HookTarget
    let style: Style
    let path: String
    let paths: AuspexPaths
    /// The Auspex binary the entries run.
    let binary: String
    /// The harness's event names, in the order they are written.
    let events: [String]
    /// The events whose entries carry a `"matcher"`. Claude's tool-shaped
    /// events take one; its lifecycle events do not, and a matcher on one of
    /// those is a field the harness has no use for.
    let matchedEvents: Set<String>
    /// What the file looks like when Auspex has to create it.
    let scaffold: String
    /// One sentence about what this harness will do with the entries, when
    /// there is something a person could otherwise be surprised by.
    var note: String?

    // MARK: - Reading

    func plan() -> HookPlan {
        HookPlan(
            path: path,
            events: events,
            command: HookCommand.text(binary: binary, target: target),
            note: note
        )
    }

    func status() -> HarnessInstaller.State {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
            return FileManager.default.fileExists(atPath: path)
                ? .unreadable("The file exists but could not be read as UTF-8.")
                : .absent
        }
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .absent }
        guard let data = text.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return .unreadable("The file is not a JSON object.") }

        let table = root["hooks"] as? [String: Any] ?? [:]
        let wanted = HookCommand.text(binary: binary, target: target)
        var registered: Set<String> = []
        var foreign: String?
        for event in events {
            guard let entries = table[event] as? [Any] else { continue }
            for entry in entries {
                guard let command = command(in: entry), HookCommand.isOurs(command, target: target)
                else { continue }
                if command == wanted {
                    registered.insert(event)
                } else {
                    foreign = command
                }
            }
        }
        if let foreign { return .installedElsewhere(binaryName(in: foreign)) }
        if registered.isEmpty { return .absent }
        return registered.count == events.count
            ? .installed
            : .installedElsewhere("an older Auspex's set of events")
    }

    // MARK: - Writing

    func install() -> HarnessInstaller.Report {
        report(writer().edit(path: path, verify: ConfigFileWriter.isStillJSON) { text in
            var document = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? scaffold
                : text
            document = try withTable(document) { $0 }
            for event in events {
                document = try registered(event, in: document)
            }
            return document
        })
    }

    func uninstall() -> HarnessInstaller.Report {
        guard (try? String(contentsOfFile: path, encoding: .utf8)) != nil else {
            return report(ConfigFileWriter.Outcome(didChange: false))
        }
        let outcome = writer().edit(path: path, verify: ConfigFileWriter.isStillJSON) { text in
            var document = text
            for event in events {
                document = try withdrawn(event, from: document)
            }
            return document
        }
        // A file that now holds nothing but the empty scaffold Auspex created
        // is a file Auspex created. Leaving it would be leaving litter with our
        // name on it in somebody else's directory.
        if isEmptyScaffold(), outcome.failure == nil {
            let removal = writer().remove(path: path)
            return report(ConfigFileWriter.Outcome(
                didChange: outcome.didChange || removal.didChange,
                backupPath: removal.backupPath ?? outcome.backupPath,
                failure: removal.failure
            ))
        }
        return report(outcome)
    }

    // MARK: - The transforms

    /// Makes sure there is a `hooks` object, and hands its contents to `body`.
    private func withTable(_ text: String, _ body: (String) throws -> String) throws -> String {
        guard let root = JSONTextEditor.topLevelObjectStart(in: text) else {
            throw HookInstallError.notAnObject
        }
        if JSONTextEditor.valueStart(ofMemberNamed: "hooks", in: text, objectAt: root) == nil {
            guard let updated = JSONTextEditor.upsert(
                member: "hooks", value: "{\n}", in: text, objectAt: root
            ) else { throw HookInstallError.unparsable }
            return try body(updated)
        }
        return try body(text)
    }

    /// The document with our entry in `event`'s list, and no second copy of it.
    private func registered(_ event: String, in text: String) throws -> String {
        let element = entry(for: event)
        var document = try withoutOurEntries(event, in: text) { existing in
            // Already exactly right: leave the bytes alone, so installing twice
            // produces the same file the second time as the first.
            existing.count == 1 && existing[0] == element
        }
        if document == text, hasEntry(element, event: event, in: text) { return text }

        guard let table = tableStart(in: document) else { throw HookInstallError.unparsable }
        if let list = JSONTextEditor.valueStart(ofMemberNamed: event, in: document, objectAt: table) {
            guard document[list] == "[" else { throw HookInstallError.unparsable }
            guard let updated = JSONArrayEditor.append(element, in: document, arrayAt: list)
            else { throw HookInstallError.unparsable }
            document = updated
        } else {
            guard let updated = JSONTextEditor.upsert(
                member: event, value: "[\n  \(element)\n]", in: document, objectAt: table
            ) else { throw HookInstallError.unparsable }
            document = updated
        }
        return document
    }

    /// The document with our entries taken out of `event`'s list, and the list
    /// itself taken out when nothing else was in it.
    private func withdrawn(_ event: String, from text: String) throws -> String {
        var document = try withoutOurEntries(event, in: text) { _ in false }
        guard let table = tableStart(in: document),
              let list = JSONTextEditor.valueStart(
                  ofMemberNamed: event, in: document, objectAt: table
              ),
              document[list] == "[",
              let remaining = JSONArrayEditor.elements(in: document, arrayAt: list),
              remaining.isEmpty
        else { return document }
        // An empty list is not a hook table entry, it is the hole one left.
        guard let updated = JSONTextEditor.remove(member: event, in: document, objectAt: table)
        else { return document }
        document = updated
        return document
    }

    /// Removes every entry of ours from one event's list.
    ///
    /// - Parameter keep: given the text of the entries that are ours, whether
    ///   to leave them exactly as they are.
    private func withoutOurEntries(
        _ event: String,
        in text: String,
        keep: ([String]) -> Bool
    ) throws -> String {
        guard let table = tableStart(in: text) else { throw HookInstallError.unparsable }
        guard let list = JSONTextEditor.valueStart(ofMemberNamed: event, in: text, objectAt: table)
        else { return text }
        guard text[list] == "[" else { throw HookInstallError.unparsable }
        guard let elements = JSONArrayEditor.elements(in: text, arrayAt: list) else {
            throw HookInstallError.unparsable
        }
        let ours = elements.filter { isOurs(String(text[$0])) }
        guard !ours.isEmpty else { return text }
        if keep(ours.map { String(text[$0]) }) { return text }
        guard let updated = JSONArrayEditor.remove(elements: ours, in: text, arrayAt: list) else {
            throw HookInstallError.unparsable
        }
        return updated
    }

    private func tableStart(in text: String) -> String.Index? {
        guard let root = JSONTextEditor.topLevelObjectStart(in: text),
              let hooks = JSONTextEditor.valueStart(
                  ofMemberNamed: "hooks", in: text, objectAt: root
              ),
              text[hooks] == "{"
        else { return nil }
        return hooks
    }

    private func hasEntry(_ element: String, event: String, in text: String) -> Bool {
        guard let table = tableStart(in: text),
              let list = JSONTextEditor.valueStart(ofMemberNamed: event, in: text, objectAt: table),
              text[list] == "[",
              let elements = JSONArrayEditor.elements(in: text, arrayAt: list)
        else { return false }
        return elements.contains { String(text[$0]) == element }
    }

    // MARK: - One entry

    /// One entry, on one line.
    ///
    /// Single-line on purpose: an entry Auspex can compare as a string is an
    /// entry Auspex can leave alone when it is already right, and that is what
    /// makes installing twice a no-op at the byte level rather than a rewrite
    /// that moves the entry to the end of the list.
    func entry(for event: String) -> String {
        let command = JSONTextEditor.escaped(HookCommand.text(binary: binary, target: target))
        switch style {
        case .claude:
            let inner = "{\"type\": \"command\", \"command\": \"\(command)\", \"timeout\": \(Self.timeout)}"
            return matchedEvents.contains(event)
                ? "{\"matcher\": \"*\", \"hooks\": [\(inner)]}"
                : "{\"hooks\": [\(inner)]}"
        case .cursor:
            return "{\"command\": \"\(command)\"}"
        }
    }

    /// Seconds the harness waits before giving up on the hook.
    ///
    /// A backstop rather than the mechanism: ``HookIngress`` gives itself 200
    /// milliseconds and exits 0 either way. This is what catches the case where
    /// the process cannot even be started — a binary on a volume that has been
    /// unmounted, most plausibly — and it is short because every second here is
    /// a second the agent is not working.
    static let timeout = 5

    /// Whether one entry's text is ours.
    private func isOurs(_ element: String) -> Bool {
        guard let command = command(in: decoded(element)) else { return false }
        return HookCommand.isOurs(command, target: target)
    }

    private func decoded(_ element: String) -> Any? {
        guard let data = element.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    }

    /// The command an entry runs, whichever of the two shapes it is in.
    private func command(in entry: Any?) -> String? {
        guard let object = entry as? [String: Any] else { return nil }
        if let command = object["command"] as? String { return command }
        guard let nested = object["hooks"] as? [[String: Any]] else { return nil }
        return nested.compactMap { $0["command"] as? String }.first
    }

    /// Whether the file is now nothing but the scaffold Auspex would create.
    private func isEmptyScaffold() -> Bool {
        guard let data = FileManager.default.contents(atPath: path),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return false }
        let table = root["hooks"] as? [String: Any]
        guard table?.isEmpty ?? false else { return false }
        return Set(root.keys).isSubset(of: ["hooks", "version"])
    }

    private func writer() -> ConfigFileWriter {
        ConfigFileWriter(paths: paths, harness: harness)
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

    /// A foreign entry, named by the binary it runs rather than by its whole
    /// command line — which is what a person needs to tell "my other Auspex"
    /// from "something else entirely".
    private func binaryName(in command: String) -> String {
        HookCommand.tokenize(command).first ?? command
    }
}

enum HookInstallError: Error, CustomStringConvertible {
    case notAnObject
    case unparsable
    case notify(String)

    var description: String {
        switch self {
        case .notAnObject: "The file is not a JSON object."
        case .unparsable: "The file could not be read closely enough to edit safely."
        case let .notify(reason): reason
        }
    }
}

// MARK: - Claude Code

/// Claude Code's hooks, in `~/.claude/settings.json`.
///
/// The event list is chosen for what a transcript cannot say:
///
/// - `PermissionRequest` is the whole reason hooks exist here. Claude asks for
///   approval in its own UI and writes nothing until the answer arrives, so
///   from outside, "waiting for you" and "thinking" are the same silence.
/// - `PostToolUse` closes it. Without it the card would stay red from the
///   approval until the end of the turn, which is the wrong answer for most of
///   the time it would be shown.
/// - `SessionStart` / `SessionEnd` put a session on the board the instant it
///   exists rather than when its transcript is first written to.
/// - `SubagentStart` / `SubagentStop` bound a child whose transcript file does
///   not exist until it has said something.
/// - `Stop` is the end of a turn, and the backstop that clears a permission
///   whose answer was never seen.
/// - `Notification` is the harness's own sentence about why it wants a person.
func ClaudeHookInstaller(home: URL, paths: AuspexPaths, binary: String) -> JSONHookTableInstaller {
    JSONHookTableInstaller(
        harness: .claudeCode,
        target: .claude,
        style: .claude,
        path: home.appendingPathComponent(".claude/settings.json").path,
        paths: paths,
        binary: binary,
        events: [
            "SessionStart", "SessionEnd", "PermissionRequest", "PostToolUse",
            "Stop", "SubagentStart", "SubagentStop", "Notification"
        ],
        matchedEvents: ["SessionStart", "PermissionRequest", "PostToolUse", "Notification"],
        scaffold: "{\n}\n"
    )
}

// MARK: - Cursor

/// Cursor's hooks, in `~/.cursor/hooks.json`.
///
/// Only the events that cannot change what Cursor does. Cursor's `before…`
/// hooks are permission gates — their output can allow or deny the call — and
/// while an empty answer is no opinion, an observer has no business standing on
/// that path at all. `beforeShellExecution` would also be a poor permission
/// signal: it fires for every command, approved or not, so reading it as
/// "waiting for a person" would paint an auto-running agent red.
///
/// What is left is lifecycle and activity, which is exactly what Cursor's store
/// is worst at: it is a content-addressed SQLite DAG that has to be polled, so
/// a session start and a stop arriving as events is the difference between a
/// poll interval and now.
func CursorHookInstaller(home: URL, paths: AuspexPaths, binary: String) -> JSONHookTableInstaller {
    JSONHookTableInstaller(
        harness: .cursor,
        target: .cursor,
        style: .cursor,
        path: home.appendingPathComponent(".cursor/hooks.json").path,
        paths: paths,
        binary: binary,
        events: [
            "sessionStart", "sessionEnd", "stop", "beforeSubmitPrompt",
            "afterFileEdit", "subagentStop"
        ],
        matchedEvents: [],
        scaffold: "{\n  \"version\": 1\n}\n"
    )
}

// MARK: - Codex, when its hook table exists

/// Codex's hooks, in `~/.codex/hooks.json`.
///
/// Codex grew a hook engine that is Claude Code's, name for name: the file is
/// `{"hooks": {"<Event>": [{"hooks": [{"type": "command", …}]}]}}`, the payload
/// on stdin carries `hook_event_name`, `session_id`, `cwd`, `transcript_path`,
/// `tool_name` and `tool_use_id`, and the events are spelled in the same
/// PascalCase. So this is ``JSONHookTableInstaller`` in Claude's style with a
/// different path and a shorter event list, and the router reads the payload
/// with the same vocabulary.
///
/// What is *not* registered matters as much as what is:
///
/// - **`PreToolUse` is a gate.** Its output can allow or deny the call, and an
///   observer has no business standing on that path — the same reason Cursor's
///   `before…` hooks are left alone.
/// - **`SubagentStart` / `SubagentStop` are left out.** A Codex sub-agent is a
///   rollout thread of its own, keyed by its thread id, and the payload's
///   `agent_id` is an agent id rather than that thread id. Registering them
///   would cost a process per sub-agent to learn nothing the linker in
///   `CodexSubagentLinker` does not already work out.
/// - **`PreCompact` / `PostCompact` / `UserPromptSubmit`** are activity the
///   rollout describes better a moment later.
///
/// No `matcher` on any entry, either. An absent matcher matches everything,
/// which is what an observer wants, and it avoids guessing at how Codex reads a
/// `"*"` in the two places (tool names, session sources) where its matchers mean
/// different things.
func CodexHooksInstaller(
    harness: Harness, home: URL, paths: AuspexPaths, binary: String
) -> JSONHookTableInstaller {
    JSONHookTableInstaller(
        harness: harness,
        target: .codex,
        style: .claude,
        path: home.appendingPathComponent(".codex/hooks.json").path,
        paths: paths,
        binary: binary,
        events: ["SessionStart", "SessionEnd", "PermissionRequest", "PostToolUse", "Stop"],
        matchedEvents: [],
        scaffold: "{\n}\n",
        note: "Codex asks you to review a new hook the next time it starts."
    )
}
