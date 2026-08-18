import AgentSessionKit
import AgentSessionLive
import Foundation

/// One row of the session trace: a stored event rendered down to the handful
/// of strings and flags a row draws.
///
/// The trace view is a list of a few thousand of these, so every row is
/// computed once, here, rather than in a `body` that SwiftUI may call again on
/// every frame. Nothing in this type knows about SwiftUI: the glyph is a
/// semantic case that the view maps to an SF Symbol, which is what keeps the
/// summariser testable.
public struct TraceEntry: Identifiable, Hashable, Sendable {
    /// The event's row id — monotonic, and the order a trace reads in.
    public let id: Int64
    /// The source's own timestamp, which is what the gutter shows.
    public let timestamp: Date
    /// Which turn this row belongs to. `0` for everything before the first
    /// turn opened — a session's start banner, a liveness probe.
    public let turnIndex: Int
    /// What kind of thing this is, for the filter chips.
    public let category: Category
    /// Which icon to draw.
    public let glyph: Glyph
    /// The one-line summary. Never empty.
    public let title: String
    /// The second line, when the event carries a target, a preview, or a
    /// reason worth showing. `nil` when the title says everything.
    public let detail: String?
    /// The full text body, when a ``AgentEventKind/textBody(role:text:toolCallID:)``
    /// was folded into this row. Shown when the row is expanded.
    public let body: String?
    /// How long a tool call took, once its finish was seen. `nil` while the
    /// call is open, and for every row that is not a tool call.
    public let duration: TimeInterval?
    /// `true` for a failed tool call, a denied permission, or a turn that
    /// ended in error.
    public let isError: Bool
    /// The harness's tool-call id, for the rows that have one.
    public let toolCallID: String?
    /// The event payload, pretty-printed, for the disclosure a click opens.
    /// `nil` when the payload could not be decoded.
    public let detailJSON: String?

    /// Whether the row can be expanded to show more than its two lines.
    public var isExpandable: Bool {
        body != nil || detailJSON != nil
    }

    /// The axis the filter chips work along.
    ///
    /// Five buckets rather than one per event case: a chip row with fifteen
    /// chips is not a filter, it is a second problem.
    public enum Category: String, CaseIterable, Identifiable, Sendable, Hashable {
        /// Tool calls and the permission prompts they raise.
        case tools
        /// What a person typed.
        case prompts
        /// What the model said or thought.
        case text
        /// Token accounting.
        case usage
        /// Session and turn boundaries, delegation, liveness, notes.
        case lifecycle

        public var id: String { rawValue }

        public var title: String {
            switch self {
            case .tools: "Tools"
            case .prompts: "Prompts"
            case .text: "Text"
            case .usage: "Usage"
            case .lifecycle: "Lifecycle"
            }
        }
    }

    /// The semantic icon for a row. The view owns the symbol names; this owns
    /// the meaning.
    public enum Glyph: String, Sendable, Hashable, CaseIterable {
        case sessionStart
        case sessionEnd
        case turn
        case prompt
        case thinking
        case assistant
        case tool
        case shell
        case fileRead
        case fileWrite
        case search
        case web
        case mcp
        case subagent
        case permission
        case usage
        case compaction
        case liveness
        case note
    }
}

// MARK: - Building

extension TraceEntry {
    /// Renders a window of stored events into trace rows, oldest first.
    ///
    /// Three things happen that a straight one-row-per-event mapping would get
    /// wrong:
    ///
    /// - **Tool calls collapse.** A start and its finish are one thing that
    ///   happened, and a waterfall that shows them as two rows doubles the
    ///   length of every trace for no information. The finish folds into the
    ///   start's row as a duration and an error flag. A finish whose start
    ///   fell outside the window still gets its own row — dropping it would
    ///   hide a failure.
    /// - **Full bodies fold into their preview.** Adapters emit a `textBody`
    ///   alongside every text-bearing state event, so rendering both shows the
    ///   same sentence twice. When a `textBody` immediately follows a preview
    ///   it belongs to, it becomes that row's ``TraceEntry/body`` instead of a
    ///   row. Anything else — a tool result, an orphaned body — keeps its row.
    /// - **Turns are numbered.** `turnStarted` opens one; a `userPrompt`
    ///   arriving with no turn open opens one too, because not every harness
    ///   records the boundary.
    ///
    /// - Parameter events: stored events in chronological order, as
    ///   `SessionRepository.recentEvents(key:limit:)` returns them.
    public static func entries(from events: [StoredEvent]) -> [TraceEntry] {
        var rows: [TraceEntry] = []
        rows.reserveCapacity(events.count)
        // Row index of the still-open call, keyed by the harness's call id.
        var openRows: [String: Int] = [:]
        var turnIndex = 0
        var turnIsOpen = false
        let encoder = prettyEncoder()

        for event in events {
            guard let kind = event.kind else {
                rows.append(unreadable(event))
                continue
            }

            switch kind {
            case .turnStarted:
                turnIndex += 1
                turnIsOpen = true
            case .userPrompt where !turnIsOpen:
                turnIndex += 1
                turnIsOpen = true
            case .turnEnded:
                turnIsOpen = false
            default:
                break
            }

            // A finish closes the row its start opened, and emits nothing.
            if case .toolCallFinished(let id, let isError) = kind,
               let index = openRows.removeValue(forKey: id) {
                rows[index] = rows[index].closed(at: event.timestamp, isError: isError)
                continue
            }

            // A body that restates the preview immediately above it becomes
            // that row's full text instead of a row of its own.
            if case .textBody(let role, let text, let toolCallID) = kind,
               toolCallID == nil,
               let index = rows.indices.last,
               rows[index].body == nil,
               rows[index].absorbs(role: role, text: text) {
                rows[index] = rows[index].carrying(body: text)
                continue
            }

            let row = TraceEntry(
                event: event,
                kind: kind,
                turnIndex: turnIndex,
                encoder: encoder
            )
            if case .toolCallStarted(let id, _, _, _) = kind {
                openRows[id] = rows.count
            }
            rows.append(row)
        }
        return rows
    }

    /// Builds one row from one event.
    private init(
        event: StoredEvent,
        kind: AgentEventKind,
        turnIndex: Int,
        encoder: JSONEncoder
    ) {
        let summary = Summary(kind: kind)
        self.id = event.id
        self.timestamp = event.timestamp
        self.turnIndex = turnIndex
        self.category = summary.category
        self.glyph = summary.glyph
        self.title = summary.title
        self.detail = summary.detail
        self.body = nil
        self.duration = nil
        self.isError = summary.isError
        self.toolCallID = event.toolCallID
        self.detailJSON = try? Self.prettyJSON(kind, using: encoder)
    }

    /// A row for an event this build cannot decode. Rare — it means the
    /// payload was written by a newer schema — but a silent gap in a trace is
    /// worse than a row saying so.
    private static func unreadable(_ event: StoredEvent) -> TraceEntry {
        TraceEntry(
            id: event.id,
            timestamp: event.timestamp,
            turnIndex: 0,
            category: .lifecycle,
            glyph: .note,
            title: event.kindLabel,
            detail: "Payload written by a newer build; not readable here.",
            body: nil,
            duration: nil,
            isError: false,
            toolCallID: event.toolCallID,
            detailJSON: nil
        )
    }

    /// This row with its tool call closed.
    private func closed(at end: Date, isError: Bool) -> TraceEntry {
        TraceEntry(
            id: id,
            timestamp: timestamp,
            turnIndex: turnIndex,
            category: category,
            glyph: glyph,
            title: title,
            detail: detail,
            body: body,
            duration: max(0, end.timeIntervalSince(timestamp)),
            isError: isError,
            toolCallID: toolCallID,
            detailJSON: detailJSON
        )
    }

    /// This row carrying the full text its preview was cut from.
    private func carrying(body: String) -> TraceEntry {
        TraceEntry(
            id: id,
            timestamp: timestamp,
            turnIndex: turnIndex,
            category: category,
            glyph: glyph,
            title: title,
            detail: detail,
            body: body,
            duration: duration,
            isError: isError,
            toolCallID: toolCallID,
            detailJSON: detailJSON
        )
    }

    /// Whether a `textBody` of `role` restates what this row already shows.
    ///
    /// The preview an adapter emits is a prefix of the body it emits next, so
    /// a prefix match is the test — not equality, because the preview is
    /// truncated, and not a fuzzy match, because a wrong fold would attach one
    /// message's text to another message's row.
    private func absorbs(role: TextBodyRole, text: String) -> Bool {
        let expected: Category = switch role {
        case .user: .prompts
        case .assistant: .text
        case .toolResult: .tools
        }
        guard category == expected, expected != .tools else { return false }
        guard let shown = detail else { return false }
        let trimmed = shown.hasSuffix("…") ? String(shown.dropLast()) : shown
        guard !trimmed.isEmpty else { return false }
        return text.hasPrefix(trimmed)
    }

    private static func prettyEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static func prettyJSON(_ kind: AgentEventKind, using encoder: JSONEncoder) throws -> String {
        String(decoding: try encoder.encode(kind), as: UTF8.self)
    }
}

// MARK: - Summarising

extension TraceEntry {
    /// The per-case mapping from an event to what a row says about it.
    ///
    /// A struct rather than four parallel switches so that adding an
    /// ``AgentEventKind`` case forces every field to be answered at once.
    private struct Summary {
        var category: Category
        var glyph: Glyph
        var title: String
        var detail: String?
        var isError: Bool = false

        init(kind: AgentEventKind) {
            switch kind {
            case .sessionStarted(let identity):
                category = .lifecycle
                glyph = .sessionStart
                title = "Session started"
                detail = identity.cwd ?? identity.sourcePath

            case .identityUpdated(let patch):
                category = .lifecycle
                glyph = .note
                title = "Identity updated"
                detail = Summary.describe(patch)

            case .userPrompt(let preview):
                category = .prompts
                glyph = .prompt
                title = "Prompt"
                detail = preview

            case .turnStarted:
                category = .lifecycle
                glyph = .turn
                title = "Turn started"
                detail = nil

            case .thinking:
                category = .text
                glyph = .thinking
                title = "Thinking"
                detail = nil

            case .assistantText(let preview):
                category = .text
                glyph = .assistant
                title = "Assistant"
                detail = preview

            case .toolCallStarted(_, let name, let kind, let target):
                category = .tools
                glyph = Summary.glyph(for: kind)
                title = name
                detail = target

            case .toolCallFinished(let id, let isError):
                // Only reached for a finish whose start was never seen; the
                // paired case never builds a row.
                category = .tools
                glyph = .tool
                title = isError ? "Tool failed" : "Tool finished"
                detail = id
                self.isError = isError

            case .permissionRequested(_, let tool):
                category = .tools
                glyph = .permission
                title = "Permission requested"
                detail = tool

            case .permissionResolved(_, let allowed):
                category = .tools
                glyph = .permission
                title = allowed ? "Permission allowed" : "Permission denied"
                detail = nil
                isError = !allowed

            case .subagentStarted(let child, let agentType, _):
                category = .lifecycle
                glyph = .subagent
                title = agentType.map { "Subagent · \($0)" } ?? "Subagent started"
                detail = child.description

            case .subagentFinished(let child):
                category = .lifecycle
                glyph = .subagent
                title = "Subagent finished"
                detail = child.description

            case .turnEnded(let reason):
                category = .lifecycle
                glyph = .turn
                title = "Turn ended"
                detail = reason == .complete ? nil : reason.rawValue
                isError = reason == .error

            case .usage(let model, let input, let output, let cached):
                category = .usage
                glyph = .usage
                title = "Usage"
                detail = Summary.describeUsage(
                    model: model, input: input, output: output, cached: cached
                )

            case .compaction:
                category = .lifecycle
                glyph = .compaction
                title = "Context compacted"
                detail = nil

            case .sessionEnded(let reason):
                category = .lifecycle
                glyph = .sessionEnd
                title = "Session ended"
                detail = reason.rawValue
                isError = reason == .killed

            case .liveness(let alive):
                category = .lifecycle
                glyph = .liveness
                title = alive ? "Process alive" : "Process gone"
                detail = nil

            case .note(let text):
                category = .lifecycle
                glyph = .note
                title = "Note"
                detail = text

            case .textBody(let role, let text, let toolCallID):
                // Only reached for a body that did not fold into a preview.
                switch role {
                case .user:
                    category = .prompts
                    glyph = .prompt
                    title = "Prompt"
                case .assistant:
                    category = .text
                    glyph = .assistant
                    title = "Assistant"
                case .toolResult:
                    category = .tools
                    glyph = .tool
                    title = toolCallID.map { "Tool result · \($0)" } ?? "Tool result"
                }
                detail = Summary.firstLine(of: text)
            }
        }

        static func glyph(for kind: ToolKind) -> Glyph {
            switch kind {
            case .shell: .shell
            case .fileRead: .fileRead
            case .fileWrite: .fileWrite
            case .search: .search
            case .web: .web
            case .mcp: .mcp
            case .subagent: .subagent
            case .plan: .note
            case .other: .tool
            }
        }

        /// The first line of a body, capped, so one row cannot be a paragraph.
        static func firstLine(of text: String) -> String? {
            let line = text
                .split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
                .first
                .map(String.init)?
                .trimmingCharacters(in: .whitespaces) ?? ""
            guard !line.isEmpty else { return nil }
            return line.count > 160 ? String(line.prefix(160)) + "…" : line
        }

        static func describe(_ patch: SessionIdentityPatch) -> String? {
            var parts: [String] = []
            if let cwd = patch.cwd { parts.append("cwd \(cwd)") }
            if let branch = patch.gitBranch { parts.append("branch \(branch)") }
            if let title = patch.title { parts.append("title \(title)") }
            if let model = patch.model { parts.append("model \(model)") }
            if let pid = patch.pid { parts.append("pid \(pid)") }
            if let entrypoint = patch.entrypoint { parts.append("from \(entrypoint)") }
            if let variant = patch.variant { parts.append("variant \(variant)") }
            return parts.isEmpty ? nil : parts.joined(separator: " · ")
        }

        static func describeUsage(
            model: String?, input: Int, output: Int, cached: Int
        ) -> String {
            var parts = ["\(TokenFormat.compact(input)) in", "\(TokenFormat.compact(output)) out"]
            if cached > 0 { parts.append("\(TokenFormat.compact(cached)) cached") }
            if let model { parts.append(model) }
            return parts.joined(separator: " · ")
        }
    }
}

/// Token counts, short enough for a card footer.
///
/// Its own type because the board, the trace, and the session header all show
/// the same numbers, and three different roundings of `12_400` would read as
/// three different numbers.
public enum TokenFormat {
    /// `843`, `12.4k`, `1.2M`. Never more than five characters.
    public static func compact(_ value: Int) -> String {
        let magnitude = abs(value)
        switch magnitude {
        case ..<1_000:
            return "\(value)"
        case ..<1_000_000:
            let thousands = Double(value) / 1_000
            return thousands < 10
                ? String(format: "%.1fk", thousands)
                : String(format: "%.0fk", thousands)
        default:
            let millions = Double(value) / 1_000_000
            return millions < 10
                ? String(format: "%.1fM", millions)
                : String(format: "%.0fM", millions)
        }
    }
}

/// Durations, at the precision each surface can use.
public enum DurationFormat {
    /// `0.4s`, `12.1s`, `3m 07s`, `1h 04m`. For a tool call's badge and the
    /// elapsed-in-state readout.
    public static func short(_ interval: TimeInterval) -> String {
        let seconds = max(0, interval)
        switch seconds {
        case ..<10:
            return String(format: "%.1fs", seconds)
        case ..<60:
            return String(format: "%.0fs", seconds)
        case ..<3_600:
            return String(format: "%dm %02ds", Int(seconds) / 60, Int(seconds) % 60)
        default:
            return String(format: "%dh %02dm", Int(seconds) / 3_600, (Int(seconds) % 3_600) / 60)
        }
    }

    /// `00:42`, `07:13`, `1:04:22` — a stopwatch, for the card's
    /// elapsed-in-state readout where the digits should not change width.
    public static func clock(_ interval: TimeInterval) -> String {
        let total = Int(max(0, interval))
        let hours = total / 3_600
        let minutes = (total % 3_600) / 60
        let seconds = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, seconds)
            : String(format: "%02d:%02d", minutes, seconds)
    }
}
