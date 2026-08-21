import AgentSessionKit
import AgentSessionLive
import Foundation

/// JSON coders for the columns that hold an encoded value type.
///
/// `sessions.snapshot_json`, `events.detail_json`, `source_cursors.cursor_json`
/// and the retention policy in `meta` all store a `Codable` from
/// `AgentSessionLive` verbatim, which keeps the schema from having to grow a
/// column every time the event model gains a case. All of them go through
/// these coders so the date strategy is the same on the way in and out — a
/// mismatch there silently shifts every timestamp by 31 years.
enum StoreJSON {
    /// Seconds since the Unix epoch, matching the `REAL` timestamp columns.
    static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        return encoder
    }

    static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }

    static func encodeToString(_ value: some Encodable, using encoder: JSONEncoder) throws -> String {
        let data = try encoder.encode(value)
        // `JSONEncoder` always emits UTF-8, so this cannot fail; the fallback
        // keeps the signature non-optional rather than expressing a real case.
        return String(decoding: data, as: UTF8.self)
    }

    static func decode<T: Decodable>(
        _ type: T.Type,
        from string: String,
        using decoder: JSONDecoder
    ) throws -> T {
        try decoder.decode(type, from: Data(string.utf8))
    }
}

// MARK: - Column projections

/// How a ``SessionState`` splits across the `state` / `state_detail` columns.
///
/// The board filters on the case and renders the payload, so they are stored
/// apart: `WHERE state = 'waitingPermission'` needs no `LIKE`, and the tool
/// name never has to be parsed back out of a label.
extension SessionState {
    /// The case name, e.g. `"toolCalling"`.
    var columnValue: String {
        switch self {
        case .idle: "idle"
        case .thinking: "thinking"
        case .toolCalling: "toolCalling"
        case .writingFile: "writingFile"
        case .delegating: "delegating"
        case .waitingPermission: "waitingPermission"
        case .ended: "ended"
        }
    }

    /// The case payload as text, or `nil` where the case carries none.
    var detailColumnValue: String? {
        switch self {
        case .idle, .thinking: nil
        case .toolCalling(let name): name
        case .writingFile(let path): path
        case .delegating(let children): String(children)
        case .waitingPermission(let tool): tool
        case .ended(let reason): reason.rawValue
        }
    }
}

/// The `events.kind` discriminator, so a query can select tool calls without
/// decoding every `detail_json`.
extension AgentEventKind {
    var columnValue: String {
        switch self {
        case .sessionStarted: "sessionStarted"
        case .identityUpdated: "identityUpdated"
        case .userPrompt: "userPrompt"
        case .turnStarted: "turnStarted"
        case .thinking: "thinking"
        case .assistantText: "assistantText"
        case .toolCallStarted: "toolCallStarted"
        case .toolCallFinished: "toolCallFinished"
        case .permissionRequested: "permissionRequested"
        case .permissionResolved: "permissionResolved"
        case .subagentStarted: "subagentStarted"
        case .subagentFinished: "subagentFinished"
        case .turnEnded: "turnEnded"
        case .usage: "usage"
        case .contextUsage: "contextUsage"
        case .compaction: "compaction"
        case .quota: "quota"
        case .sessionEnded: "sessionEnded"
        case .liveness: "liveness"
        case .note: "note"
        case .textBody: "textBody"
        }
    }

    /// The harness's own tool-call id, for the cases that name one. Projected
    /// into its own column so the detail pane can gather every event belonging
    /// to one call.
    var toolCallIDColumnValue: String? {
        switch self {
        case .toolCallStarted(let id, _, _, _): id
        case .toolCallFinished(let id, _): id
        case .permissionRequested(let id, _): id
        case .permissionResolved(let id, _): id
        case .subagentStarted(_, _, let toolUseID): toolUseID
        case .textBody(_, _, let toolCallID): toolCallID
        default: nil
        }
    }

    /// The raw tool name, for the cases that name one.
    var toolNameColumnValue: String? {
        switch self {
        case .toolCallStarted(_, let name, _, _): name
        case .permissionRequested(_, let tool): tool
        default: nil
        }
    }
}

/// The `parent_link` column: which evidence attached a child to its parent.
///
/// Stored as a bare case name rather than the encoded enum because the
/// associated `toolUseID` already travels in the event log, and a plain string
/// is what a `GROUP BY` on link confidence wants.
extension ParentLink {
    var columnValue: String {
        switch self {
        case .subagent: "subagent"
        case .spawnedProcess: "spawnedProcess"
        case .envInherited: "envInherited"
        case .manual: "manual"
        }
    }
}
