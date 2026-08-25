import AgentSessionKit
import AgentSessionLive
import Foundation

/// Folds a session's stored events into the steps, turns, and requests a
/// trajectory is drawn from.
///
/// ## Why it is a value that can be fed twice
///
/// The live board re-reads a session's event window on every frame that moved
/// it, and rebuilding a five-thousand-step trajectory four times a second is
/// the kind of cost that shows up as a warm laptop rather than as a dropped
/// frame. So this is a *resumable* fold: ``append(_:)`` takes only events it
/// has not seen and patches what is already there — a tool call's
/// finish reaches back into the step its start opened, a `usage` record lands
/// on the request it belongs to, and everything before the open turn is never
/// touched again.
///
/// Feeding the whole log at once and feeding it in pieces produce the same
/// value; `TrajectoryBuilderTests` asserts exactly that, because an
/// incremental fold that quietly diverges from the full one is a bug nobody
/// sees until a session has been open for an hour.
///
/// ## Nothing here is inferred
///
/// A step's `end` is set only where the log records an end. A request's TTFT
/// is the interval between two observed records, never a guess at one. Where a
/// harness reports no usage the value stays `nil` all the way to the
/// inspector, which prints an em dash — see `docs/ARCHITECTURE.md`, "No
/// inference of missing data".
public struct TrajectoryBuilder: Sendable {
    /// Every step, oldest first.
    public private(set) var steps: [TrajectoryStep] = []
    /// Every turn, oldest first. The last one may still be open.
    public private(set) var turns: [TrajectoryTurn] = []
    /// Every model request, oldest first. The last one may still be running.
    public private(set) var requests: [TrajectoryRequest] = []
    /// The highest event row id folded in so far, so a caller knows what to
    /// ask the store for next. `nil` before the first event.
    public private(set) var lastEventID: Int64?
    /// Durable ids already folded. Playback order is source-time order, so ids
    /// are not necessarily monotonic inside a batch spanning one task.
    private var seenEventIDs: Set<Int64> = []

    // MARK: Fold state

    private var turnIndex = 0
    /// The turn steps are currently landing in. It outlives its `turnEnded`,
    /// because a session's closing banner belongs to the last turn rather than
    /// to a turn of its own.
    private var turn: TurnAccumulator?
    /// Whether a prompt should reuse ``turn`` or open the next one.
    private var turnIsOpen = false
    private var request: RequestAccumulator?
    private var requestCount = 0
    private var openCallCount = 0
    /// Call id → step index, for a call that has not finished.
    private var openCalls: [String: Int] = [:]
    /// Call id → step index, kept for the whole session so a tool result body
    /// arriving after the finish still finds its row.
    private var callSteps: [String: Int] = [:]
    private var openPermissions: [String: Int] = [:]
    private var openSubagents: [String: Int] = [:]
    private var lastUserStep: Int?
    private var lastAssistantStep: Int?
    private var lastToolStep: Int?
    /// Request index → the assistant step its usage should land on.
    private var requestLastAssistant: [Int: Int] = [:]
    /// Every context reading, in the order they were observed. See
    /// ``TrajectoryContextReading``.
    public private(set) var contextReadings: [TrajectoryContextReading] = []
    /// The step index of each compaction, for the markers on the context line.
    public private(set) var compactionSteps: [Int] = []

    public init() {}

    /// Folds a whole log in one pass.
    public static func build(from events: [StoredEvent]) -> TrajectoryBuilder {
        var builder = TrajectoryBuilder()
        builder.append(events)
        return builder
    }

    /// Folds the next run of events in the order the presentation uses.
    /// Repeated durable ids are skipped, while ``lastEventID`` remains the
    /// highest persisted id so a caller can still tail the database by index.
    public mutating func append(_ events: [StoredEvent]) {
        guard !events.isEmpty else { return }
        steps.reserveCapacity(steps.count + events.count)
        for event in events {
            guard seenEventIDs.insert(event.id).inserted else { continue }
            lastEventID = max(lastEventID ?? event.id, event.id)
            fold(event)
        }
        publishTurn()
        publishRequest()
    }

    // MARK: - One event

    private mutating func fold(_ event: StoredEvent) {
        guard let kind = event.kind else { return }
        let at = event.timestamp

        switch kind {
        case .sessionStarted(let identity):
            emit(
                event,
                role: .system,
                title: "Session started",
                args: identity.cwd ?? identity.sourcePath
            )

        case .identityUpdated:
            // Identity arrives in dribs on every transcript line for some
            // harnesses. It is a fact about the session, not a step in it.
            break

        case .userPrompt(let preview):
            if !turnIsOpen { openTurn(at: at) }
            lastUserStep = emit(
                event,
                role: .user,
                title: preview.isEmpty ? "Prompt" : preview
            )
            if request == nil, openCallCount == 0 { openRequest(at: at) }

        case .turnStarted:
            openTurn(at: at)
            if openCallCount == 0 { openRequest(at: at) }

        case .thinking:
            noteAssistant(at: at, stepIndex: emit(event, role: .assistant, title: "Thinking"))

        case .assistantText(let preview):
            let index = emit(
                event,
                role: .assistant,
                title: preview.isEmpty ? "Assistant" : preview
            )
            noteAssistant(at: at, stepIndex: index)

        case .toolCallStarted(let id, let name, let toolKind, let target):
            if openCallCount == 0 { closeRequest(at: at) }
            openCallCount += 1
            let index = emit(
                event,
                role: .tool,
                title: name,
                args: target ?? label(for: toolKind),
                toolCallID: id
            )
            openCalls[id] = index
            callSteps[id] = index
            lastToolStep = index

        case .toolCallFinished(let id, let isError):
            if let index = openCalls.removeValue(forKey: id) {
                patch(index) { $0.closed(at: at, isError: isError) }
                if isError { turn?.hasError = true }
            } else {
                // A finish whose start fell outside the window. Dropping it
                // would hide a failure, so it keeps a step of its own.
                let index = emit(
                    event,
                    role: .tool,
                    title: isError ? "Tool failed" : "Tool finished",
                    args: id,
                    isError: isError,
                    toolCallID: id
                )
                callSteps[id] = index
                lastToolStep = index
            }
            openCallCount = max(0, openCallCount - 1)
            if openCallCount == 0, turnIsOpen, request == nil { openRequest(at: at) }

        case .permissionRequested(let id, let tool):
            openPermissions[id] = emit(
                event,
                role: .tool,
                title: "Permission",
                args: tool ?? "a tool"
            )

        case .permissionResolved(let id, let allowed):
            if let index = openPermissions.removeValue(forKey: id) {
                patch(index) { $0.closed(at: at, isError: !allowed) }
                if !allowed { turn?.hasError = true }
            } else {
                emit(
                    event,
                    role: .tool,
                    title: allowed ? "Permission allowed" : "Permission denied",
                    args: id,
                    isError: !allowed
                )
            }

        case .subagentStarted(let child, let agentType, _):
            openSubagents[child.description] = emit(
                event,
                role: .tool,
                title: agentType.map { "Subagent · \($0)" } ?? "Subagent",
                args: child.description
            )

        case .subagentFinished(let child):
            if let index = openSubagents.removeValue(forKey: child.description) {
                patch(index) { $0.closed(at: at, isError: false) }
            }

        case .turnEnded(let reason):
            closeRequest(at: at)
            if reason == .error { turn?.hasError = true }
            closeTurn(at: at)

        case .usage(_, let input, let output, let cached):
            apply(TrajectoryTokens(input: input, output: output, cached: cached))

        case .contextUsage(let used, let window, _, let source):
            // Not a step. Nothing happened when the harness wrote down how
            // full its window was — the same reasoning that keeps `usage` off
            // the timeline. It is a *reading* taken at a point in the
            // sequence, so it is anchored to the last step that did happen and
            // drawn as a line over the lanes rather than as a bar inside one.
            contextReadings.append(
                TrajectoryContextReading(
                    stepIndex: max(0, steps.count - 1),
                    used: used,
                    window: window,
                    at: at,
                    isDerived: source == .derived
                )
            )

        case .compaction:
            // The step *and* the marker. The step is what a reader clicks; the
            // marker is what makes the sawtooth in the context line legible as
            // a compaction rather than as a gap in the data.
            compactionSteps.append(emit(event, role: .system, title: "Context compacted"))

        case .quota:
            // What plan the session is billing against is a fact about an
            // account, not a step in a trajectory. The Harnesses page draws it.
            break

        case .sessionEnded(let reason):
            closeRequest(at: at)
            emit(
                event,
                role: .system,
                title: "Session ended",
                args: reason.rawValue,
                isError: reason == .killed
            )
            closeTurn(at: at)

        case .liveness:
            // A probe's verdict about a process. True, useful on a card, and
            // not a step the session took.
            break

        case .note(let text):
            emit(event, role: .system, title: "Note", args: text)

        case .textBody(let role, let text, let toolCallID):
            absorb(role: role, text: text, toolCallID: toolCallID)
        }
    }

    // MARK: - Steps

    @discardableResult
    private mutating func emit(
        _ event: StoredEvent,
        role: TrajectoryRole,
        title: String,
        args: String? = nil,
        isError: Bool = false,
        toolCallID: String? = nil
    ) -> Int {
        // Everything before the first turn opened is turn zero. A session
        // banner still belongs on the timeline, and a step in no turn at all
        // would have no column to be drawn in.
        if turn == nil { startTurn(index: 0, at: event.timestamp) }

        let index = steps.count
        steps.append(
            TrajectoryStep(
                id: event.id,
                index: index,
                session: event.session,
                turn: turn?.index ?? 0,
                request: request?.index ?? 0,
                role: role,
                start: event.timestamp,
                title: TrajectoryText.line(title),
                argsPreview: args.flatMap(TrajectoryText.firstLine(of:)),
                isError: isError,
                raw: event.rawPath.map { TrajectoryRawRef(path: $0, offset: event.rawOffset) },
                toolCallID: toolCallID
            )
        )
        if turn?.firstStep == nil { turn?.firstStep = index }
        turn?.lastStep = index
        if isError { turn?.hasError = true }
        return index
    }

    private mutating func patch(_ index: Int, _ transform: (TrajectoryStep) -> TrajectoryStep) {
        guard steps.indices.contains(index) else { return }
        steps[index] = transform(steps[index])
    }

    /// Folds a full text body into the step whose preview it restates.
    private mutating func absorb(role: TextBodyRole, text: String, toolCallID: String?) {
        switch role {
        case .user:
            guard let index = lastUserStep else { return }
            patch(index) { $0.carrying(body: text) }
        case .assistant:
            guard let index = lastAssistantStep else { return }
            patch(index) { $0.carrying(body: text) }
        case .toolResult:
            guard let index = toolCallID.flatMap({ callSteps[$0] }) ?? lastToolStep else { return }
            patch(index) { $0.carrying(result: TrajectoryText.firstLine(of: text), body: text) }
        }
    }

    private func label(for kind: ToolKind) -> String? {
        kind == .other ? nil : kind.rawValue
    }

    // MARK: - Turns

    private mutating func openTurn(at date: Date) {
        startTurn(index: turnIndex + 1, at: date)
    }

    private mutating func startTurn(index: Int, at date: Date) {
        publishTurn()
        turnIndex = index
        turn = TurnAccumulator(index: index, start: date)
        turnIsOpen = true
    }

    private mutating func closeTurn(at date: Date) {
        guard turn != nil else { return }
        if turn?.end == nil { turn?.end = date }
        turnIsOpen = false
        publishTurn()
    }

    /// Writes the current turn into ``turns``, replacing the entry it wrote
    /// last time rather than appending a second copy of the same turn.
    private mutating func publishTurn() {
        guard let value = turn?.materialise() else { return }
        if turns.last?.index == value.index {
            turns[turns.count - 1] = value
        } else {
            turns.append(value)
        }
    }

    // MARK: - Requests

    private mutating func openRequest(at date: Date) {
        closeRequest(at: nil)
        requestCount += 1
        request = RequestAccumulator(
            index: requestCount,
            turn: turn?.index ?? turnIndex,
            started: date
        )
        turn?.requestCount += 1
    }

    private mutating func closeRequest(at date: Date?) {
        guard request != nil else { return }
        if let date, request?.ended == nil { request?.ended = date }
        publishRequest()
        request = nil
    }

    private mutating func publishRequest() {
        guard let value = request?.materialise() else { return }
        if requests.last?.index == value.index {
            requests[requests.count - 1] = value
        } else {
            requests.append(value)
        }
    }

    private mutating func noteAssistant(at date: Date, stepIndex: Int) {
        lastAssistantStep = stepIndex
        guard let index = request?.index else { return }
        if request?.firstToken == nil { request?.firstToken = date }
        request?.lastToken = date
        requestLastAssistant[index] = stepIndex
    }

    /// Attributes billed tokens to the request they belong to.
    ///
    /// Usage usually arrives *after* the request it describes has closed — a
    /// harness writes the accounting record once the turn is over — so a
    /// record with no request open lands on the last one rather than being
    /// dropped.
    private mutating func apply(_ tokens: TrajectoryTokens) {
        if var accumulator = turn {
            accumulator.tokens = (accumulator.tokens ?? TrajectoryTokens()).adding(tokens)
            turn = accumulator
        }

        if var accumulator = request {
            accumulator.tokens = (accumulator.tokens ?? TrajectoryTokens()).adding(tokens)
            request = accumulator
            attach(tokens, toStepOfRequest: accumulator.index)
            return
        }
        guard let last = requests.indices.last else { return }
        let previous = requests[last]
        requests[last] = TrajectoryRequest(
            index: previous.index,
            turn: previous.turn,
            started: previous.started,
            firstToken: previous.firstToken,
            lastToken: previous.lastToken,
            ended: previous.ended,
            tokens: (previous.tokens ?? TrajectoryTokens()).adding(tokens)
        )
        attach(tokens, toStepOfRequest: previous.index)
    }

    private mutating func attach(_ tokens: TrajectoryTokens, toStepOfRequest index: Int) {
        guard let stepIndex = requestLastAssistant[index] else { return }
        patch(stepIndex) { $0.carrying(tokens: ($0.tokens ?? TrajectoryTokens()).adding(tokens)) }
    }
}

// MARK: - Accumulators

extension TrajectoryBuilder {
    private struct TurnAccumulator: Sendable {
        let index: Int
        let start: Date
        var end: Date?
        var requestCount = 0
        var tokens: TrajectoryTokens?
        var firstStep: Int?
        var lastStep: Int?
        var hasError = false

        /// `nil` for a turn that opened and has not produced a step yet — a
        /// turn with no rows has nothing to draw and no range to draw it in.
        func materialise() -> TrajectoryTurn? {
            guard let firstStep, let lastStep else { return nil }
            return TrajectoryTurn(
                index: index,
                start: start,
                end: end,
                requestCount: requestCount,
                tokens: tokens,
                stepRange: firstStep...max(firstStep, lastStep),
                hasError: hasError
            )
        }
    }

    private struct RequestAccumulator: Sendable {
        let index: Int
        let turn: Int
        let started: Date
        var firstToken: Date?
        var lastToken: Date?
        var ended: Date?
        var tokens: TrajectoryTokens?

        func materialise() -> TrajectoryRequest {
            TrajectoryRequest(
                index: index,
                turn: turn,
                started: started,
                firstToken: firstToken,
                lastToken: lastToken,
                ended: ended,
                tokens: tokens
            )
        }
    }
}

// MARK: - Patching a step

extension TrajectoryStep {
    /// This step with its call closed.
    func closed(at end: Date, isError: Bool) -> TrajectoryStep {
        rebuilt(end: max(start, end), isError: isError)
    }

    /// This step carrying the full text its preview was cut from.
    func carrying(body: String) -> TrajectoryStep {
        self.body == nil ? rebuilt(body: body) : self
    }

    /// This step carrying what its tool returned. The first body wins: a
    /// second result for one call id would be a different call's output.
    func carrying(result: String?, body: String) -> TrajectoryStep {
        guard resultPreview == nil, self.body == nil else { return self }
        return rebuilt(resultPreview: result, body: body)
    }

    /// This step carrying what the harness billed for it.
    func carrying(tokens: TrajectoryTokens) -> TrajectoryStep {
        rebuilt(tokens: tokens)
    }

    /// Rebuilds through the initialiser rather than mutating fields, so
    /// ``searchText`` can never drift from the text it indexes.
    private func rebuilt(
        end: Date?? = nil,
        resultPreview: String?? = nil,
        body: String?? = nil,
        isError: Bool? = nil,
        tokens: TrajectoryTokens?? = nil
    ) -> TrajectoryStep {
        TrajectoryStep(
            id: id,
            index: index,
            session: session,
            turn: turn,
            request: request,
            role: role,
            start: start,
            end: end ?? self.end,
            title: title,
            argsPreview: argsPreview,
            resultPreview: resultPreview ?? self.resultPreview,
            body: body ?? self.body,
            isError: isError ?? self.isError,
            tokens: tokens ?? self.tokens,
            raw: raw,
            toolCallID: toolCallID
        )
    }
}

// MARK: - Text

/// The two cuts a trajectory makes in a string, in one place so a row and a
/// tooltip never disagree about where a line ends.
enum TrajectoryText {
    /// The upper bound on a single line of row text. Long enough for a
    /// sentence, short enough that one row cannot become a paragraph.
    static let lineLimit = 200

    /// One line, capped.
    static func line(_ text: String) -> String {
        let flattened = text
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespaces)
        guard !flattened.isEmpty else { return "—" }
        return flattened.count > lineLimit
            ? String(flattened.prefix(lineLimit)) + "…"
            : flattened
    }

    /// The first line of a body, capped. `nil` when there is nothing on it.
    static func firstLine(of text: String) -> String? {
        let first = text
            .split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
            .first
            .map(String.init)?
            .trimmingCharacters(in: .whitespaces) ?? ""
        guard !first.isEmpty else { return nil }
        return first.count > lineLimit ? String(first.prefix(lineLimit)) + "…" : first
    }
}
