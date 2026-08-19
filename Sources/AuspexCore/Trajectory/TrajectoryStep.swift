import AgentSessionKit
import AgentSessionLive
import Foundation

/// Who produced a step.
///
/// Four roles rather than one per event case, because the question a
/// trajectory answers is *whose turn was it* — a person, the model, a tool, or
/// the harness itself. Everything else is detail hanging off one of those four.
public enum TrajectoryRole: String, CaseIterable, Sendable, Hashable, Codable {
    /// The harness talking about itself: the session opening, a compaction, a
    /// note only that harness has a word for.
    case system
    /// What a person typed.
    case user
    /// What the model produced — reasoning or prose.
    case assistant
    /// A tool call, a permission prompt, or a delegation.
    case tool

    /// The chip's text. Uppercase is applied by the view, not baked in here.
    public var label: String {
        switch self {
        case .system: "System"
        case .user: "User"
        case .assistant: "Assistant"
        case .tool: "Tool"
        }
    }

    /// Which lane of the waterfall this role is drawn in.
    public var lane: TrajectoryLane {
        switch self {
        case .system, .user: .input
        case .assistant: .model
        case .tool: .tools
        }
    }
}

/// One row of the waterfall at the top of the trajectory.
///
/// Three lanes and no more. A lane per role would put `system` on a line of
/// its own that is empty for the whole of most sessions, and a lane a reader
/// learns to ignore is a lane that costs height for nothing.
public enum TrajectoryLane: String, CaseIterable, Identifiable, Sendable, Hashable, Codable {
    /// Prompts and the harness's own banners — everything that went *in*.
    case input
    /// Model generations.
    case model
    /// Tool calls, permission waits, delegations.
    case tools

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .input: "Input"
        case .model: "Model"
        case .tools: "Tools"
        }
    }
}

/// Token accounting for one step, request, or turn.
///
/// A struct rather than three loose `Int`s so that "this step billed nothing"
/// and "this harness does not report usage" stay different answers: the whole
/// value is `nil` in the second case, and no field is ever filled with a zero
/// standing in for *unknown*.
public struct TrajectoryTokens: Hashable, Sendable, Codable {
    public let input: Int
    public let output: Int
    public let cached: Int

    public init(input: Int = 0, output: Int = 0, cached: Int = 0) {
        self.input = input
        self.output = output
        self.cached = cached
    }

    public var total: Int { input + output }

    public func adding(_ other: TrajectoryTokens) -> TrajectoryTokens {
        TrajectoryTokens(
            input: input + other.input,
            output: output + other.output,
            cached: cached + other.cached
        )
    }
}

/// Where the record behind a step can be read again.
///
/// Kept as the pair the store holds rather than as a resolved handle: the
/// source may be rewritten, compacted, or deleted between the observation and
/// the click, and the Raw tab has to be able to say so rather than to promise
/// a record it cannot produce.
public struct TrajectoryRawRef: Hashable, Sendable {
    /// The file or database the event was read from.
    public let path: String
    /// The locator within ``path`` — a byte offset for a file-backed source, a
    /// row id for a SQLite-backed one.
    public let offset: Int64?

    public init(path: String, offset: Int64?) {
        self.path = path
        self.offset = offset
    }
}

/// One step of a session: something that happened, who did it, and when.
///
/// This is the trajectory's atom. It is deliberately *flatter* than
/// ``TraceEntry``: the trace is a live feed a person scans, so its rows carry a
/// glyph and a category for filtering; a trajectory is something a person
/// *investigates*, so its steps carry timing, tokens, and a way back to the
/// original record.
///
/// Nothing here is inferred. A field a harness does not record stays `nil`,
/// and the inspector prints an em dash rather than a plausible number — see
/// `docs/ARCHITECTURE.md`, "No inference of missing data".
public struct TrajectoryStep: Identifiable, Hashable, Sendable {
    /// The event row id this step was built from. Stable for the life of the
    /// database, which is what lets a list keep its scroll position while new
    /// steps arrive.
    public let id: Int64
    /// Position in the whole trajectory, from zero.
    public let index: Int
    /// Which turn this belongs to. `0` for everything before the first turn
    /// opened.
    public let turn: Int
    /// Which model request this belongs to, from one. `0` for a step that
    /// happened outside any request — a session banner, a prompt.
    public let request: Int
    public let role: TrajectoryRole
    /// The source's own timestamp.
    public let start: Date
    /// When the step closed, where the log records a close: a tool call's
    /// finish, a permission's resolution, a subagent's exit. `nil` for
    /// everything instantaneous and for a call still running.
    public let end: Date?
    /// The one-line content. Never empty. For a prompt or a message it is the
    /// text; for a tool it is the tool's own name.
    public let title: String
    /// What the call was aimed at — a command, a path, a server — or the
    /// detail a system step carries.
    public let argsPreview: String?
    /// The first line of what came back, when the harness recorded a result
    /// body. `nil` is normal: several harnesses log no tool output at all.
    public let resultPreview: String?
    /// The full text, when one was recorded. Shown in the inspector's Preview
    /// tab, never in a row.
    public let body: String?
    /// A failed tool call, a denied permission, or a turn that ended in error.
    public let isError: Bool
    /// Usage billed against this step. Only ever set on the assistant step
    /// that closed a request the harness reported usage for.
    public let tokens: TrajectoryTokens?
    /// Where to read the original record.
    public let raw: TrajectoryRawRef?
    /// The harness's own call id, for the steps that have one.
    public let toolCallID: String?
    /// Everything a search matches against, lowercased once here so a query
    /// over five thousand steps is five thousand substring checks and not
    /// five thousand case foldings.
    public let searchText: String

    /// How long the step took, where the log closed it.
    public var duration: TimeInterval? {
        end.map { max(0, $0.timeIntervalSince(start)) }
    }

    public init(
        id: Int64,
        index: Int,
        turn: Int,
        request: Int,
        role: TrajectoryRole,
        start: Date,
        end: Date? = nil,
        title: String,
        argsPreview: String? = nil,
        resultPreview: String? = nil,
        body: String? = nil,
        isError: Bool = false,
        tokens: TrajectoryTokens? = nil,
        raw: TrajectoryRawRef? = nil,
        toolCallID: String? = nil
    ) {
        self.id = id
        self.index = index
        self.turn = turn
        self.request = request
        self.role = role
        self.start = start
        self.end = end
        self.title = title
        self.argsPreview = argsPreview
        self.resultPreview = resultPreview
        self.body = body
        self.isError = isError
        self.tokens = tokens
        self.raw = raw
        self.toolCallID = toolCallID
        self.searchText = Self.searchText(
            title: title,
            args: argsPreview,
            result: resultPreview,
            role: role
        )
    }

    private static func searchText(
        title: String,
        args: String?,
        result: String?,
        role: TrajectoryRole
    ) -> String {
        var text = role.label
        text += " "
        text += title
        if let args { text += " " + args }
        if let result { text += " " + result }
        return text.lowercased()
    }

    /// Whether this step matches a query. The query must already be
    /// lowercased; the caller does it once per keystroke rather than once per
    /// step.
    public func matches(lowercasedQuery query: String) -> Bool {
        query.isEmpty || searchText.contains(query)
    }
}

/// One turn: a prompt and everything the model did about it.
///
/// Turns are the unit a person remembers ("it went wrong on the second thing I
/// asked for"), which is why they get their own markers in the gutter and
/// their own scale on the timeline.
public struct TrajectoryTurn: Identifiable, Hashable, Sendable {
    /// The turn number, from one. Turn `0` is the run of steps before any turn
    /// opened.
    public let index: Int
    public let start: Date
    /// When the turn closed. `nil` while it is still going.
    public let end: Date?
    /// How many model requests the turn took. A turn that called three tools
    /// took four requests.
    public let requestCount: Int
    /// Usage summed over the turn's requests, or `nil` when the harness
    /// reported none.
    public let tokens: TrajectoryTokens?
    /// The first and last step indices in this turn, so the gutter can mark a
    /// turn without scanning.
    public let stepRange: ClosedRange<Int>
    /// Whether anything in the turn failed.
    public let hasError: Bool

    public var id: Int { index }

    public init(
        index: Int,
        start: Date,
        end: Date?,
        requestCount: Int,
        tokens: TrajectoryTokens?,
        stepRange: ClosedRange<Int>,
        hasError: Bool
    ) {
        self.index = index
        self.start = start
        self.end = end
        self.requestCount = requestCount
        self.tokens = tokens
        self.stepRange = stepRange
        self.hasError = hasError
    }
}

/// One model request inside a turn.
///
/// A turn is not one call to a model. A prompt goes up, the model answers with
/// a tool call, the tool's result goes back up, and the model is asked again —
/// so a turn with three tool calls is four requests, and *request* is the unit
/// the timing numbers belong to. TTFT measured across a whole turn would be
/// measuring the first of four answers and calling it the turn's latency.
///
/// A request opens when the turn opens and again whenever the last open tool
/// call finishes; it closes when a tool call starts, when the turn ends, or
/// when the session does.
public struct TrajectoryRequest: Identifiable, Hashable, Sendable {
    /// The request number within the session, from one.
    public let index: Int
    public let turn: Int
    /// When the model was handed the floor.
    public let started: Date
    /// The first assistant event of this request — reasoning or prose.
    /// `nil` when the request produced nothing before it closed.
    public let firstToken: Date?
    /// The last assistant event of this request.
    public let lastToken: Date?
    /// When the request closed. `nil` while it is still running.
    public let ended: Date?
    /// What the harness billed for it, or `nil` when it reported nothing.
    public let tokens: TrajectoryTokens?

    public var id: Int { index }

    /// Start to close.
    public var duration: TimeInterval? {
        ended.map { max(0, $0.timeIntervalSince(started)) }
    }

    /// Time to first token: the floor being handed over, to the first thing
    /// the model said.
    public var timeToFirstToken: TimeInterval? {
        firstToken.map { max(0, $0.timeIntervalSince(started)) }
    }

    /// First to last chunk. `nil` when only one chunk was ever observed —
    /// a single-chunk generation has no measurable span, and reporting zero
    /// would make the throughput below it infinite.
    public var generation: TimeInterval? {
        guard let firstToken, let lastToken else { return nil }
        let span = lastToken.timeIntervalSince(firstToken)
        return span > 0 ? span : nil
    }

    /// Output tokens per second, when both halves of the fraction are known.
    public var throughput: Double? {
        guard let generation, generation > 0, let output = tokens?.output, output > 0 else {
            return nil
        }
        return Double(output) / generation
    }

    public init(
        index: Int,
        turn: Int,
        started: Date,
        firstToken: Date?,
        lastToken: Date?,
        ended: Date?,
        tokens: TrajectoryTokens?
    ) {
        self.index = index
        self.turn = turn
        self.started = started
        self.firstToken = firstToken
        self.lastToken = lastToken
        self.ended = ended
        self.tokens = tokens
    }
}
