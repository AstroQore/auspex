import AgentSessionKit
import AgentSessionLive
import Foundation
import GRDB

/// Reads and writes everything about a session: the reducer's snapshot, the
/// event log behind it, the tool calls it made, and the searchable text it
/// produced.
///
/// A value over a `DatabaseWriter`, so it is cheap to make one wherever it is
/// needed and there is no shared mutable state to protect. Every method is
/// synchronous and does its own transaction; ``SessionRegistry`` batches
/// instead, calling the `write(_:)` overloads that take a `Database` so a
/// quarter-second of ingest lands as one commit.
public struct SessionRepository: Sendable {
    /// The database this repository writes through.
    public let dbWriter: any DatabaseWriter

    public init(dbWriter: any DatabaseWriter) {
        self.dbWriter = dbWriter
    }

    public init(store: AuspexStore) {
        self.dbWriter = store.dbWriter
    }

    // MARK: - Sessions

    /// Inserts or updates the row for `snapshot`.
    public func upsert(snapshot: SessionSnapshot) throws {
        try upsert(snapshots: [snapshot])
    }

    /// Inserts or updates a batch of snapshots in one transaction.
    public func upsert(snapshots: [SessionSnapshot]) throws {
        guard !snapshots.isEmpty else { return }
        try dbWriter.write { db in
            try upsert(snapshots: snapshots, in: db)
        }
    }

    /// Batch upsert inside a caller-owned transaction.
    ///
    /// Callers that also write events must use this and insert the sessions
    /// first: `events.session_key` is a foreign key.
    public func upsert(snapshots: [SessionSnapshot], in db: Database) throws {
        let encoder = StoreJSON.makeEncoder()
        for snapshot in snapshots {
            try SessionRow(snapshot: snapshot, encoder: encoder).upsert(db)
        }
    }

    /// Every stored session, newest activity first.
    ///
    /// - Parameters:
    ///   - activeOnly: when `true`, only sessions believed to be running —
    ///     alive and not ended. A stale session still counts as active: a long
    ///     `swift build` is silent, not finished.
    ///   - limit: caps the result. `nil` returns everything.
    public func fetchAll(activeOnly: Bool = false, limit: Int? = nil) throws -> [SessionSnapshot] {
        var sql = "SELECT snapshot_json FROM sessions"
        if activeOnly {
            sql += " WHERE is_alive = 1 AND state <> 'ended'"
        }
        // NULL sorts lowest in SQLite, so DESC already puts never-seen
        // sessions last, which is where a board wants them.
        sql += " ORDER BY last_event_at DESC, key ASC"
        var arguments = StatementArguments()
        if let limit {
            sql += " LIMIT ?"
            arguments += [limit]
        }
        return try dbWriter.read { db in
            let json = try String.fetchAll(db, sql: sql, arguments: arguments)
            let decoder = StoreJSON.makeDecoder()
            return try json.map { try StoreJSON.decode(SessionSnapshot.self, from: $0, using: decoder) }
        }
    }

    /// The snapshot for one session, or `nil` when it has never been stored.
    public func fetch(key: SessionKey) throws -> SessionSnapshot? {
        try dbWriter.read { db in
            guard let json = try String.fetchOne(
                db,
                sql: "SELECT snapshot_json FROM sessions WHERE key = ?",
                arguments: [key.description]
            ) else { return nil }
            return try StoreJSON.decode(
                SessionSnapshot.self,
                from: json,
                using: StoreJSON.makeDecoder()
            )
        }
    }

    /// How many sessions are stored.
    public func sessionCount() throws -> Int {
        try dbWriter.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM sessions") ?? 0
        }
    }

    // MARK: - Events

    /// Appends events in a single transaction.
    ///
    /// The session rows must already exist — `events.session_key` is a foreign
    /// key, and a batch referencing an unknown session fails as a whole rather
    /// than silently dropping rows.
    ///
    /// - Returns: the number of rows written.
    @discardableResult
    public func insertEvents(_ events: [AgentEvent]) throws -> Int {
        guard !events.isEmpty else { return 0 }
        return try dbWriter.write { db in
            try insertEvents(events, in: db)
        }
    }

    /// Appends events inside a caller-owned transaction.
    @discardableResult
    public func insertEvents(_ events: [AgentEvent], in db: Database) throws -> Int {
        guard !events.isEmpty else { return 0 }
        let encoder = StoreJSON.makeEncoder()
        let statement = try db.makeStatement(sql: """
            INSERT INTO events
                (session_key, ts, observed_at, seq, kind, tool_call_id, tool_name,
                 detail_json, raw_path, raw_offset)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """)
        for event in events {
            let detail = try StoreJSON.encodeToString(event.kind, using: encoder)
            statement.setUncheckedArguments([
                event.session.description,
                event.timestamp.timeIntervalSince1970,
                event.observedAt.timeIntervalSince1970,
                event.sequence,
                event.kind.columnValue,
                event.kind.toolCallIDColumnValue,
                event.kind.toolNameColumnValue,
                detail,
                event.raw?.path,
                // A file-backed source locates a record by byte offset and a
                // SQLite-backed one by row id; the column holds whichever the
                // adapter recorded. Which it is follows from the harness.
                event.raw?.byteOffset ?? event.raw?.rowID
            ])
            try statement.execute()
        }
        return events.count
    }

    /// The most recent `limit` events for a session, oldest first.
    ///
    /// Returned in chronological order because that is how a trace view reads,
    /// even though the window is taken from the newest end.
    public func recentEvents(key: SessionKey, limit: Int = 200) throws -> [StoredEvent] {
        guard limit > 0 else { return [] }
        return try dbWriter.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT * FROM (
                    SELECT id, session_key, ts, observed_at, seq, kind,
                           tool_call_id, tool_name, detail_json, raw_path, raw_offset
                    FROM events
                    WHERE session_key = ?
                    ORDER BY id DESC
                    LIMIT ?
                ) ORDER BY id ASC
                """, arguments: [key.description, limit])
            let decoder = StoreJSON.makeDecoder()
            return rows.compactMap { StoredEvent(row: $0, decoder: decoder) }
        }
    }

    /// How many events are stored for a session.
    public func eventCount(key: SessionKey) throws -> Int {
        try dbWriter.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM events WHERE session_key = ?",
                arguments: [key.description]
            ) ?? 0
        }
    }

    // MARK: - Tool calls

    /// Records a tool call, or updates the one already recorded.
    ///
    /// A `nil` timestamp or error flag means "no news", not "clear it": the
    /// start and the finish of a call arrive as two separate events, and the
    /// second must not erase what the first recorded.
    public func upsertToolCall(
        sessionKey: SessionKey,
        callID: String,
        name: String,
        kind: ToolKind,
        target: String? = nil,
        startedAt: Date? = nil,
        endedAt: Date? = nil,
        isError: Bool? = nil
    ) throws {
        try dbWriter.write { db in
            try upsertToolCall(
                sessionKey: sessionKey,
                callID: callID,
                name: name,
                kind: kind,
                target: target,
                startedAt: startedAt,
                endedAt: endedAt,
                isError: isError,
                in: db
            )
        }
    }

    /// Tool-call upsert inside a caller-owned transaction.
    public func upsertToolCall(
        sessionKey: SessionKey,
        callID: String,
        name: String,
        kind: ToolKind,
        target: String?,
        startedAt: Date?,
        endedAt: Date?,
        isError: Bool?,
        in db: Database
    ) throws {
        try db.execute(sql: """
            INSERT INTO tool_calls
                (session_key, call_id, name, kind, target, started_at, ended_at, is_error)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(session_key, call_id) DO UPDATE SET
                name = excluded.name,
                kind = excluded.kind,
                target = COALESCE(excluded.target, tool_calls.target),
                started_at = COALESCE(excluded.started_at, tool_calls.started_at),
                ended_at = COALESCE(excluded.ended_at, tool_calls.ended_at),
                is_error = COALESCE(excluded.is_error, tool_calls.is_error)
            """, arguments: [
                sessionKey.description,
                callID,
                name,
                kind.rawValue,
                target,
                startedAt?.timeIntervalSince1970,
                endedAt?.timeIntervalSince1970,
                isError
            ])
    }

    /// Closes a tool call, recording when it ended and whether it failed.
    ///
    /// Separate from ``upsertToolCall(sessionKey:callID:name:kind:target:startedAt:endedAt:isError:in:)``
    /// because a `toolCallFinished` event names only the call id: writing it
    /// through the same upsert would set the name and kind columns from
    /// whatever stand-in the caller had. Here they are used only if the row
    /// does not exist at all — a finish whose start was never observed still
    /// belongs in the ledger.
    public func finishToolCall(
        sessionKey: SessionKey,
        callID: String,
        fallbackName: String,
        endedAt: Date,
        isError: Bool,
        in db: Database
    ) throws {
        try db.execute(sql: """
            INSERT INTO tool_calls
                (session_key, call_id, name, kind, target, started_at, ended_at, is_error)
            VALUES (?, ?, ?, ?, NULL, NULL, ?, ?)
            ON CONFLICT(session_key, call_id) DO UPDATE SET
                ended_at = excluded.ended_at,
                is_error = excluded.is_error
            """, arguments: [
                sessionKey.description,
                callID,
                fallbackName,
                ToolKind.other.rawValue,
                endedAt.timeIntervalSince1970,
                isError
            ])
    }

    /// Closes a tool call in its own transaction.
    public func finishToolCall(
        sessionKey: SessionKey,
        callID: String,
        fallbackName: String,
        endedAt: Date,
        isError: Bool
    ) throws {
        try dbWriter.write { db in
            try finishToolCall(
                sessionKey: sessionKey,
                callID: callID,
                fallbackName: fallbackName,
                endedAt: endedAt,
                isError: isError,
                in: db
            )
        }
    }

    /// Every tool call recorded for a session, oldest first.
    public func toolCalls(key: SessionKey) throws -> [StoredToolCall] {
        try dbWriter.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT session_key, call_id, name, kind, target, started_at, ended_at, is_error
                FROM tool_calls
                WHERE session_key = ?
                ORDER BY started_at ASC, call_id ASC
                """, arguments: [key.description])
            return rows.compactMap(StoredToolCall.init(row:))
        }
    }

    // MARK: - Full-text index

    /// Adds one message to the search index.
    ///
    /// Only text-bearing records belong here — a person's prompt, the model's
    /// prose, a tool result. The **full** text passed in is stored: the caller
    /// decides what is worth indexing, because only the adapter knows whether
    /// it is holding a 200-character board preview or the whole body.
    public func indexMessage(
        session: SessionKey,
        harness: Harness,
        role: MessageRole,
        ts: Date,
        content: String
    ) throws {
        try indexMessages([
            IndexedMessage(session: session, harness: harness, role: role, ts: ts, content: content)
        ])
    }

    /// Adds a batch of messages to the search index in one transaction.
    public func indexMessages(_ messages: [IndexedMessage]) throws {
        guard !messages.isEmpty else { return }
        try dbWriter.write { db in
            try indexMessages(messages, in: db)
        }
    }

    /// Batch index inside a caller-owned transaction.
    public func indexMessages(_ messages: [IndexedMessage], in db: Database) throws {
        guard !messages.isEmpty else { return }
        let statement = try db.makeStatement(sql: """
            INSERT INTO messages (session_key, harness, role, ts, content)
            VALUES (?, ?, ?, ?, ?)
            """)
        for message in messages {
            statement.setUncheckedArguments([
                message.session.description,
                message.harness.rawValue,
                message.role.rawValue,
                message.ts.timeIntervalSince1970,
                message.content
            ])
            try statement.execute()
        }
    }

    /// Searches indexed message bodies across every harness at once.
    ///
    /// The query is matched as a literal substring, not as words: the index
    /// uses FTS5's trigram tokenizer, so `sionRegis` finds `SessionRegistry`
    /// and a Chinese phrase is found without any word segmentation. Two
    /// consequences follow, and both are properties of trigram indexing rather
    /// than choices made here:
    ///
    /// - A query shorter than three characters matches nothing. Rather than
    ///   returning a confusing empty result from SQLite, this returns `[]`
    ///   without touching the database.
    /// - The query is quoted before it reaches FTS5, so `-`, `*`, `(` and the
    ///   rest of the MATCH operators are searched for rather than obeyed.
    ///   Search is a text box, not an expression language.
    public func search(
        query: String,
        harnesses: [Harness] = [],
        limit: Int = 50
    ) throws -> [SearchHit] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= Self.minimumSearchLength, limit > 0 else { return [] }

        var sql = """
            SELECT m.id, m.session_key, m.harness, m.role, m.ts,
                   snippet(messages_fts, 0, '\(Self.snippetOpen)', '\(Self.snippetClose)', '…', 12) AS snippet,
                   bm25(messages_fts) AS rank
            FROM messages_fts
            JOIN messages m ON m.id = messages_fts.rowid
            WHERE messages_fts MATCH ?
            """
        var arguments: StatementArguments = [Self.ftsPhrase(trimmed)]
        if !harnesses.isEmpty {
            let placeholders = Array(repeating: "?", count: harnesses.count).joined(separator: ", ")
            sql += "\n  AND m.harness IN (\(placeholders))"
            arguments += StatementArguments(harnesses.map(\.rawValue))
        }
        sql += "\nORDER BY rank, m.ts DESC\nLIMIT ?"
        arguments += [limit]

        return try dbWriter.read { db in
            try Row.fetchAll(db, sql: sql, arguments: arguments).compactMap(SearchHit.init(row:))
        }
    }

    /// Shortest query the trigram index can answer.
    public static let minimumSearchLength = 3

    /// Delimiters `snippet()` wraps a match in. Bracket characters rather than
    /// HTML tags: the result is rendered as text, never as markup.
    static let snippetOpen = "\u{2039}"
    static let snippetClose = "\u{203A}"

    /// Wraps a user's query as one FTS5 phrase, escaping the quote character
    /// by doubling it — the only escape FTS5's string literals have.
    static func ftsPhrase(_ query: String) -> String {
        "\"" + query.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}

// MARK: - Row types

/// The `sessions` row: the reducer's snapshot plus the columns projected out
/// of it so the board can sort and filter in SQL.
struct SessionRow: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "sessions"
    static let databaseColumnEncodingStrategy = DatabaseColumnEncodingStrategy.convertToSnakeCase
    static let databaseColumnDecodingStrategy = DatabaseColumnDecodingStrategy.convertFromSnakeCase

    var key: String
    var harness: String
    var sessionId: String
    var variant: String?
    var parentKey: String?
    var rootKey: String?
    var parentLink: String?
    var cwd: String?
    var projectId: Int64?
    var worktreeId: Int64?
    var gitBranch: String?
    var pid: Int64?
    var procStart: Double?
    var title: String?
    var model: String?
    var entrypoint: String?
    var sourcePath: String
    var startedAt: Double?
    var lastEventAt: Double?
    var endedAt: Double?
    var state: String
    var stateDetail: String?
    var isAlive: Bool
    var isStale: Bool
    var turnCount: Int
    var toolCallCount: Int
    var tokensIn: Int
    var tokensOut: Int
    var tokensCached: Int
    var snapshotJson: String

    init(snapshot: SessionSnapshot, encoder: JSONEncoder) throws {
        let identity = snapshot.identity
        self.key = identity.key.description
        self.harness = identity.key.harness.rawValue
        self.sessionId = identity.key.sessionID
        self.variant = identity.variant
        self.parentKey = identity.parent?.description
        // A session with no parent is its own root, which is the answer for
        // most rows and costs nothing to record now. A child's root needs the
        // whole delegation chain walked, so it stays NULL until M2's tree
        // builder rather than being guessed at as "the parent".
        self.rootKey = identity.parent == nil ? identity.key.description : nil
        self.parentLink = identity.parentLink?.columnValue
        self.cwd = identity.cwd
        // Project and worktree resolution is M2; the foreign keys stay null
        // rather than pointing at a guess.
        self.projectId = nil
        self.worktreeId = nil
        self.gitBranch = identity.gitBranch
        self.pid = identity.pid.map(Int64.init)
        self.procStart = identity.procStart?.timeIntervalSince1970
        self.title = identity.title
        self.model = identity.model
        self.entrypoint = identity.entrypoint
        self.sourcePath = identity.sourcePath
        self.startedAt = snapshot.startedAt?.timeIntervalSince1970
        self.lastEventAt = snapshot.lastEventAt?.timeIntervalSince1970
        self.endedAt = snapshot.endedAt?.timeIntervalSince1970
        self.state = snapshot.state.columnValue
        self.stateDetail = snapshot.state.detailColumnValue
        self.isAlive = snapshot.isAlive
        self.isStale = snapshot.isStale
        self.turnCount = snapshot.turnCount
        self.toolCallCount = snapshot.toolCallCount
        self.tokensIn = snapshot.tokensIn
        self.tokensOut = snapshot.tokensOut
        self.tokensCached = snapshot.tokensCached
        self.snapshotJson = try StoreJSON.encodeToString(snapshot, using: encoder)
    }
}

/// One row of the event log, as stored.
///
/// ``kind`` is the decoded `AgentEventKind`, so a trace view gets the whole
/// event back rather than a label; it is `nil` only for a row written by an
/// older build whose payload this one cannot read.
public struct StoredEvent: Hashable, Sendable, Identifiable {
    /// The row id. Monotonic per database, and the order a trace reads in.
    public let id: Int64
    /// The session the event belongs to.
    public let session: SessionKey
    /// The source's own timestamp.
    public let timestamp: Date
    /// When Auspex read the record.
    public let observedAt: Date
    /// Order within one tailer's flush; `0` when the source offered none.
    public let sequence: Int64
    /// The case name, e.g. `"toolCallStarted"`.
    public let kindLabel: String
    /// The decoded event payload.
    public let kind: AgentEventKind?
    /// The harness's tool-call id, for the cases that carry one.
    public let toolCallID: String?
    /// The raw tool name, for the cases that carry one.
    public let toolName: String?
    /// The source file or database the record came from.
    public let rawPath: String?
    /// The locator within ``rawPath`` — a byte offset for a file-backed
    /// source, a row id for a SQLite-backed one.
    public let rawOffset: Int64?

    init?(row: Row, decoder: JSONDecoder) {
        guard let id = row["id"] as Int64?,
              let keyString = row["session_key"] as String?,
              let session = SessionKey(string: keyString),
              let ts = row["ts"] as Double?,
              let observedAt = row["observed_at"] as Double?,
              let kindLabel = row["kind"] as String?
        else { return nil }
        self.id = id
        self.session = session
        self.timestamp = Date(timeIntervalSince1970: ts)
        self.observedAt = Date(timeIntervalSince1970: observedAt)
        self.sequence = row["seq"] as Int64? ?? 0
        self.kindLabel = kindLabel
        if let detail = row["detail_json"] as String? {
            self.kind = try? StoreJSON.decode(AgentEventKind.self, from: detail, using: decoder)
        } else {
            self.kind = nil
        }
        self.toolCallID = row["tool_call_id"]
        self.toolName = row["tool_name"]
        self.rawPath = row["raw_path"]
        self.rawOffset = row["raw_offset"]
    }
}

/// One row of `tool_calls`: a call and, once it closed, how it ended.
public struct StoredToolCall: Hashable, Sendable, Identifiable {
    /// `"<session key>/<call id>"` — the composite primary key, flattened for
    /// `Identifiable`.
    public var id: String { "\(session.description)/\(callID)" }
    public let session: SessionKey
    public let callID: String
    public let name: String
    public let kind: ToolKind
    public let target: String?
    public let startedAt: Date?
    public let endedAt: Date?
    /// `nil` while the call is still open.
    public let isError: Bool?

    /// How long the call took, or `nil` while it is still open.
    public var duration: TimeInterval? {
        guard let startedAt, let endedAt else { return nil }
        return endedAt.timeIntervalSince(startedAt)
    }

    init?(row: Row) {
        guard let keyString = row["session_key"] as String?,
              let session = SessionKey(string: keyString),
              let callID = row["call_id"] as String?,
              let name = row["name"] as String?,
              let kindString = row["kind"] as String?
        else { return nil }
        self.session = session
        self.callID = callID
        self.name = name
        self.kind = ToolKind(rawValue: kindString) ?? .other
        self.target = row["target"]
        self.startedAt = (row["started_at"] as Double?).map(Date.init(timeIntervalSince1970:))
        self.endedAt = (row["ended_at"] as Double?).map(Date.init(timeIntervalSince1970:))
        self.isError = row["is_error"]
    }
}

/// Who produced an indexed message.
public enum MessageRole: String, Codable, Sendable, CaseIterable, Hashable {
    /// A person's prompt.
    case user
    /// The model's prose.
    case assistant
    /// The output of a tool call.
    case toolResult
    /// A system or harness-injected message.
    case system
}

extension MessageRole {
    /// The store's role for a live-layer ``TextBodyRole``.
    public init(_ role: TextBodyRole) {
        switch role {
        case .user: self = .user
        case .assistant: self = .assistant
        case .toolResult: self = .toolResult
        }
    }
}

/// One message on its way into the search index.
public struct IndexedMessage: Hashable, Sendable {
    public let session: SessionKey
    public let harness: Harness
    public let role: MessageRole
    public let ts: Date
    public let content: String

    public init(session: SessionKey, harness: Harness, role: MessageRole, ts: Date, content: String) {
        self.session = session
        self.harness = harness
        self.role = role
        self.ts = ts
        self.content = content
    }
}

/// One search result: where the match was, and enough context to show it.
public struct SearchHit: Hashable, Sendable, Identifiable {
    /// The `messages` row id.
    public let id: Int64
    public let session: SessionKey
    public let harness: Harness
    public let role: MessageRole
    public let timestamp: Date
    /// The matched region with its surroundings, delimited by
    /// ``SessionRepository/snippetOpen`` and ``SessionRepository/snippetClose``.
    public let snippet: String
    /// The BM25 score. Lower is a better match, which is why results are
    /// ordered ascending.
    public let rank: Double

    init?(row: Row) {
        guard let id = row["id"] as Int64?,
              let keyString = row["session_key"] as String?,
              let session = SessionKey(string: keyString),
              let harnessString = row["harness"] as String?,
              let harness = Harness(rawValue: harnessString),
              let roleString = row["role"] as String?,
              let role = MessageRole(rawValue: roleString),
              let ts = row["ts"] as Double?,
              let snippet = row["snippet"] as String?
        else { return nil }
        self.id = id
        self.session = session
        self.harness = harness
        self.role = role
        self.timestamp = Date(timeIntervalSince1970: ts)
        self.snippet = snippet
        self.rank = row["rank"] as Double? ?? 0
    }
}
