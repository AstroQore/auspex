import AgentSessionKit
import AgentSessionLive
import Foundation
import GRDB

/// Rebuilds the brief of every session Auspex recorded before it knew to ask.
///
/// ``SessionBrief`` is folded from a live event stream, so it only exists for
/// sessions Auspex was watching *while they ran*. Everything recorded before
/// the brief did shows no "asked for" line at all — which is precisely the set
/// of sessions a person has forgotten about, and the reason the ledger exists.
///
/// Nothing is invented to fix that. The store already holds the material the
/// reducer would have folded, in two places:
///
/// - `messages`, the full-text index: one row per text-bearing record, with the
///   **whole** body, the role, and the source's own timestamp.
/// - `events`, the log: `userPrompt` and `assistantText` carry the adapter's
///   preview in `detail_json`, and `turnEnded` is the only record of a turn
///   closing.
///
/// `messages` is preferred because it holds the full text rather than a
/// 200-character preview; `events` is the fallback for a session whose text was
/// never indexed — a harness excluded from the index by ``RetentionPolicy``, or
/// one whose messages have aged out while its events have not.
///
/// ## What it will not do
///
/// Every string that reaches a brief goes through the kit's own filters:
/// ``SessionBrief/instruction(_:)`` for prompts, so a `<system-reminder>` or a
/// bare `/clear` never becomes an assignment, and ``EventText/preview(_:max:)``
/// for replies. The pass reuses those rather than reimplementing them, because
/// a second copy of that list is a second copy to keep current.
///
/// The fold itself is the kit's too: derived material is recorded into the
/// *stored* brief through ``SessionBrief/record(prompt:at:)`` and its siblings,
/// so every ordering guard the live path has — an earlier prompt may displace
/// the assignment, a later one may not; `lastTurnEndedAt` only moves forward —
/// holds here without being restated. That is also what makes the pass
/// idempotent: running it twice folds the same values in the same order and
/// lands on the same brief.
public struct BriefBackfill: Sendable {
    /// The database this pass reads and writes.
    public let dbWriter: any DatabaseWriter

    public init(dbWriter: any DatabaseWriter) {
        self.dbWriter = dbWriter
    }

    public init(store: AuspexStore) {
        self.dbWriter = store.dbWriter
    }

    /// Sessions per write transaction.
    ///
    /// The pass runs next to a live ingest pipeline that commits every 250 ms,
    /// and both go through the same writer. One transaction over seven hundred
    /// sessions would hold that writer for the length of the whole pass; two
    /// hundred is small enough that a burst of events waits milliseconds, and
    /// large enough that the per-transaction overhead is not what the pass
    /// spends its time on.
    public static let defaultBatchSize = 200

    /// How recently a session must have been active to stay *unread* when the
    /// first pass seeds `session_views`.
    ///
    /// The backfill fills `lastTurnEndedAt` for hundreds of sessions at once,
    /// and every one of them then satisfies "a turn closed, and you have not
    /// looked at it since". Without this the first launch after the pass opens
    /// on seven hundred rows in the *done unseen* bucket — and a board that
    /// flags everything flags nothing.
    ///
    /// Two days is the line between *this week's work, which somebody may
    /// genuinely have forgotten* and *history, which they lived through*.
    /// Anything quiet for longer is marked read at the moment it last did
    /// something, which is the honest claim to make on their behalf: they were
    /// at the machine when it happened. Anything newer is left alone, because
    /// those are exactly the sessions the ledger was built to surface.
    public static let unreadWindow: TimeInterval = 48 * 60 * 60

    /// What this pass knows how to fill in, versioned apart from the event
    /// schema.
    ///
    /// Bumped when the pass itself learns to do something new — seeding
    /// `session_views` was the second thing it learned — so a store stamped by
    /// a build that did less runs again rather than being taken for finished.
    public static let passVersion = 2

    /// What a completed pass stamps into `meta`.
    ///
    /// Both halves matter and for different reasons: the event schema because
    /// a bump can change what the same rows fold into, the pass version because
    /// a bump means there is more to fold.
    public static var stamp: String {
        "\(passVersion).\(AgentSessionLive.eventSchemaVersion)"
    }

    // MARK: - Running

    /// Runs the pass unless this store has already had this one.
    ///
    /// The first pass is also the only one that seeds `session_views` — see
    /// ``markStaleSessionsSeen(now:)``. That is deliberately tied to the same
    /// stamp rather than run on every launch: deciding on somebody's behalf
    /// that they have read something is a thing to do once, while repairing
    /// history, and never again afterwards.
    public func runIfNeeded(
        batchSize: Int = defaultBatchSize,
        now: Date = Date()
    ) throws -> BriefBackfillReport {
        let stamp = Self.stamp
        let recorded = try dbWriter.read { db in
            try String.fetchOne(
                db,
                sql: "SELECT value FROM meta WHERE key = ?",
                arguments: [StoreMetaKey.briefBackfill]
            )
        }
        guard recorded != stamp else { return BriefBackfillReport() }

        var report = try run(batchSize: batchSize)
        // After the briefs, never before: the cutoff reads `last_turn_ended_at`,
        // and for most of these sessions that column is something this pass has
        // only just written.
        report.markedSeen = try markStaleSessionsSeen(now: now)
        try dbWriter.write { db in
            try db.execute(
                sql: """
                    INSERT INTO meta (key, value) VALUES (?, ?)
                    ON CONFLICT(key) DO UPDATE SET value = excluded.value
                    """,
                arguments: [StoreMetaKey.briefBackfill, stamp]
            )
        }
        report.didRun = true
        return report
    }

    /// Marks every session that went quiet longer ago than ``unreadWindow`` as
    /// read, at the moment it last did anything.
    ///
    /// ## What this is still for, now that a bucket is something said
    ///
    /// It used to be load-bearing. `done unseen` was inferred from a closed
    /// turn nobody had opened, so a store full of last week's sessions arrived
    /// with several hundred of them in the board's second-loudest bucket, and
    /// this pass was what stopped that being the first thing a new install
    /// showed. The bucket is gone — see ``AttentionState`` — and with it the
    /// reason this had to exist.
    ///
    /// What is left is the faint reply dot on a card, and the pass is kept
    /// because it is still right about that: a session that went quiet three
    /// days ago is not a reply anybody is waiting to read. Nothing depends on
    /// it any more, and a store where it never ran now differs by a handful of
    /// dots rather than by a wrong number in the header.
    ///
    /// Three properties, and each is one clause of the statement:
    ///
    /// - **The stamp is the session's own clock**, `lastTurnEndedAt` falling
    ///   back to `lastEventAt` — not `now`. Recording "read at this instant"
    ///   for a session that ended in March would be a claim about today that is
    ///   not true, and it would survive into every later comparison.
    /// - **An existing row is never touched.** `session_views` is the one table
    ///   that holds a fact about the *person* rather than about a harness, and a
    ///   repair pass has no business editing it. `DO NOTHING`, not `DO UPDATE`.
    /// - **A session with no clock at all is skipped**, rather than marked read
    ///   at the epoch.
    ///
    /// - Returns: how many sessions were marked.
    @discardableResult
    public func markStaleSessionsSeen(now: Date = Date()) throws -> Int {
        let cutoff = now.addingTimeInterval(-Self.unreadWindow).timeIntervalSince1970
        return try dbWriter.write { db in
            try db.execute(sql: """
                INSERT INTO session_views (session_key, last_seen_at)
                SELECT key, COALESCE(last_turn_ended_at, last_event_at)
                  FROM sessions
                 WHERE COALESCE(last_turn_ended_at, last_event_at) IS NOT NULL
                   AND COALESCE(last_turn_ended_at, last_event_at) < ?
                ON CONFLICT(session_key) DO NOTHING
                """, arguments: [cutoff])
            return db.changesCount
        }
    }

    /// Runs the pass over every session whose brief is missing something,
    /// whether or not one has run before.
    ///
    /// - Returns: what was written, and the briefs that changed — so a caller
    ///   holding the same sessions in memory can apply them rather than
    ///   re-reading the store.
    public func run(batchSize: Int = defaultBatchSize) throws -> BriefBackfillReport {
        var report = BriefBackfillReport()
        report.didRun = true

        let keys = try candidateKeys()
        report.considered = keys.count
        guard !keys.isEmpty else { return report }

        let size = max(1, batchSize)
        var index = keys.startIndex
        while index < keys.endIndex {
            let end = keys.index(index, offsetBy: size, limitedBy: keys.endIndex) ?? keys.endIndex
            let batch = Array(keys[index..<end])
            index = end

            // Derived outside the write transaction: the scan over `messages`
            // and `events` is the expensive half, and holding the writer for it
            // would stall the ingest pipeline's own commits for no reason. A
            // row written between the two is not lost — the live reducer owns
            // that session's brief and is folding the same record into it.
            let material = try dbWriter.read { db in
                try Self.material(for: batch, in: db)
            }
            guard !material.isEmpty else { continue }

            report.batches += 1
            try dbWriter.write { db in
                try apply(material, to: batch, into: &report, in: db)
            }
        }
        return report
    }

    /// Derives briefs for named sessions without writing anything.
    ///
    /// The read-only half of the pass, for a surface that needs an answer now:
    /// a card or a trace header whose session still carries an empty brief, on
    /// a board that has not been backfilled. Returns only the sessions that had
    /// material — a key that is absent has nothing to say, which is different
    /// from an empty brief and worth being able to tell apart when caching.
    public func derivedBriefs(for keys: [SessionKey]) throws -> [SessionKey: SessionBrief] {
        guard !keys.isEmpty else { return [:] }
        let strings = keys.map(\.description)
        let material = try dbWriter.read { db in
            try Self.material(for: strings, in: db)
        }
        var briefs: [SessionKey: SessionBrief] = [:]
        briefs.reserveCapacity(material.count)
        for (string, found) in material {
            guard let key = SessionKey(string: string) else { continue }
            let brief = found.folded(into: SessionBrief())
            guard !brief.isEmpty else { continue }
            briefs[key] = brief
        }
        return briefs
    }

    /// The sessions worth looking at: every one whose brief is missing a field
    /// this pass can fill.
    ///
    /// Newest activity first, so that a pass cut short by a quit has already
    /// done the sessions a person is most likely to open.
    func candidateKeys() throws -> [String] {
        try dbWriter.read { db in
            try String.fetchAll(db, sql: """
                SELECT key FROM sessions
                 WHERE first_prompt IS NULL
                    OR latest_prompt IS NULL
                    OR latest_assistant IS NULL
                    OR last_turn_ended_at IS NULL
                 ORDER BY last_event_at DESC, key ASC
                """)
        }
    }

    /// Folds derived material into the stored briefs of one batch and writes
    /// the rows back.
    ///
    /// The blob is re-read here rather than carried in from the derivation
    /// pass, and that is the whole reason this is safe to run beside a live
    /// pipeline: the read and the write are in one transaction, GRDB serialises
    /// writers, so the snapshot this rewrites is the newest committed one and a
    /// concurrent flush cannot be lost under it.
    private func apply(
        _ material: [String: BriefMaterial],
        to batch: [String],
        into report: inout BriefBackfillReport,
        in db: Database
    ) throws {
        let decoder = StoreJSON.makeDecoder()
        let repository = SessionRepository(dbWriter: dbWriter)

        let rows = try Row.fetchAll(db, sql: """
            SELECT key, snapshot_json FROM sessions WHERE key IN (\(Self.placeholders(batch.count)))
            """, arguments: StatementArguments(batch))

        var updated: [SessionSnapshot] = []
        for row in rows {
            guard let key = row["key"] as String?,
                  let found = material[key],
                  let json = row["snapshot_json"] as String?,
                  var snapshot = try? StoreJSON.decode(
                      SessionSnapshot.self, from: json, using: decoder
                  )
            else { continue }

            let folded = found.folded(into: snapshot.brief)
            guard folded != snapshot.brief else { continue }
            if snapshot.brief.firstPrompt == nil, folded.firstPrompt != nil {
                report.firstPrompts += 1
            }
            if snapshot.brief.lastTurnEndedAt == nil, folded.lastTurnEndedAt != nil {
                report.turnEnds += 1
            }
            snapshot.brief = folded
            updated.append(snapshot)
            report.briefs[snapshot.key] = folded
        }

        guard !updated.isEmpty else { return }
        // Through the repository, so `snapshot_json` and the four projected
        // columns are written from one value in one place — the same bargain
        // every other write to `sessions` makes.
        try repository.upsert(snapshots: updated, in: db)
        report.updated += updated.count
    }

    // MARK: - Derivation

    /// The material a brief can be rebuilt from, for a batch of sessions.
    ///
    /// Keyed by `SessionKey.description` — the column value — because that is
    /// what every query returns and what the write pass looks rows up by;
    /// parsing each one back into a ``SessionKey`` happens once, at the edge.
    static func material(for keys: [String], in db: Database) throws -> [String: BriefMaterial] {
        guard !keys.isEmpty else { return [:] }
        var material: [String: BriefMaterial] = [:]
        material.reserveCapacity(keys.count)

        try collectIndexedPrompts(keys, into: &material, in: db)
        try collectIndexedReplies(keys, into: &material, in: db)

        // The event log is the fallback, not a second opinion: it carries the
        // adapter's 200-character preview where `messages` carries the whole
        // body, so mixing the two would mean a board line whose length depended
        // on which table happened to answer first.
        let withoutPrompt = keys.filter { material[$0]?.firstPrompt == nil }
        try collectLoggedPrompts(withoutPrompt, into: &material, in: db)
        let withoutReply = keys.filter { material[$0]?.latestAssistant == nil }
        try collectLoggedReplies(withoutReply, into: &material, in: db)

        try collectTurnEnds(keys, into: &material, in: db)
        return material.filter { !$0.value.isEmpty }
    }

    /// The full-text index's user messages.
    private static func collectIndexedPrompts(
        _ keys: [String],
        into material: inout [String: BriefMaterial],
        in db: Database
    ) throws {
        guard !keys.isEmpty else { return }
        let cursor = try Row.fetchCursor(db, sql: """
            SELECT session_key, ts, content FROM messages
             WHERE role = ? AND session_key IN (\(placeholders(keys.count)))
            """, arguments: StatementArguments([MessageRole.user.rawValue]) + StatementArguments(keys))
        while let row = try cursor.next() {
            guard let key = row["session_key"] as String?,
                  let ts = row["ts"] as Double?,
                  let content = row["content"] as String?,
                  // The kit's meta filter, not a copy of it: a slash-command
                  // envelope, a hook's output and an injected skill preamble
                  // are all recorded as user messages, and none of them is a
                  // person asking for anything.
                  let instruction = SessionBrief.instruction(content)
            else { continue }
            material[key, default: BriefMaterial()]
                .record(prompt: DatedText(text: instruction, at: Date(timeIntervalSince1970: ts)))
        }
    }

    /// The full-text index's assistant messages.
    private static func collectIndexedReplies(
        _ keys: [String],
        into material: inout [String: BriefMaterial],
        in db: Database
    ) throws {
        guard !keys.isEmpty else { return }
        let cursor = try Row.fetchCursor(db, sql: """
            SELECT session_key, ts, content FROM messages
             WHERE role = ? AND session_key IN (\(placeholders(keys.count)))
            """, arguments: StatementArguments([MessageRole.assistant.rawValue])
                + StatementArguments(keys))
        while let row = try cursor.next() {
            guard let key = row["session_key"] as String?,
                  let ts = row["ts"] as Double?,
                  let content = row["content"] as String?
            else { continue }
            // Previewed on the way in rather than on the way out, so a 40 KB
            // reply is 280 characters for the rest of the pass.
            let preview = EventText.preview(content, max: SessionBrief.previewLimit)
            guard !preview.isEmpty else { continue }
            material[key, default: BriefMaterial()]
                .record(reply: DatedText(text: preview, at: Date(timeIntervalSince1970: ts)))
        }
    }

    /// `userPrompt` events, for a session whose text was never indexed.
    private static func collectLoggedPrompts(
        _ keys: [String],
        into material: inout [String: BriefMaterial],
        in db: Database
    ) throws {
        try collectLogged(keys, kind: "userPrompt", into: &material, in: db) { kind, at, material in
            guard case .userPrompt(let preview) = kind,
                  let instruction = SessionBrief.instruction(preview) else { return }
            material.record(prompt: DatedText(text: instruction, at: at))
        }
    }

    /// `assistantText` events, for a session whose text was never indexed.
    private static func collectLoggedReplies(
        _ keys: [String],
        into material: inout [String: BriefMaterial],
        in db: Database
    ) throws {
        try collectLogged(keys, kind: "assistantText", into: &material, in: db) { kind, at, material in
            guard case .assistantText(let preview) = kind else { return }
            let text = EventText.preview(preview, max: SessionBrief.previewLimit)
            guard !text.isEmpty else { return }
            material.record(reply: DatedText(text: text, at: at))
        }
    }

    /// Walks one kind of event, decoding each payload once.
    private static func collectLogged(
        _ keys: [String],
        kind: String,
        into material: inout [String: BriefMaterial],
        in db: Database,
        fold: (AgentEventKind, Date, inout BriefMaterial) -> Void
    ) throws {
        guard !keys.isEmpty else { return }
        let decoder = StoreJSON.makeDecoder()
        let cursor = try Row.fetchCursor(db, sql: """
            SELECT session_key, ts, detail_json FROM events
             WHERE kind = ? AND session_key IN (\(placeholders(keys.count)))
            """, arguments: StatementArguments([kind]) + StatementArguments(keys))
        while let row = try cursor.next() {
            guard let key = row["session_key"] as String?,
                  let ts = row["ts"] as Double?,
                  let detail = row["detail_json"] as String?,
                  let decoded = try? StoreJSON.decode(
                      AgentEventKind.self, from: detail, using: decoder
                  )
            else { continue }
            var entry = material[key] ?? BriefMaterial()
            fold(decoded, Date(timeIntervalSince1970: ts), &entry)
            material[key] = entry
        }
    }

    /// When each session last closed a turn.
    private static func collectTurnEnds(
        _ keys: [String],
        into material: inout [String: BriefMaterial],
        in db: Database
    ) throws {
        guard !keys.isEmpty else { return }
        let rows = try Row.fetchAll(db, sql: """
            SELECT session_key, MAX(ts) AS ts FROM events
             WHERE kind = 'turnEnded' AND session_key IN (\(placeholders(keys.count)))
             GROUP BY session_key
            """, arguments: StatementArguments(keys))
        for row in rows {
            guard let key = row["session_key"] as String?, let ts = row["ts"] as Double? else {
                continue
            }
            material[key, default: BriefMaterial()].lastTurnEndedAt =
                Date(timeIntervalSince1970: ts)
        }
    }

    private static func placeholders(_ count: Int) -> String {
        Array(repeating: "?", count: count).joined(separator: ", ")
    }
}

// MARK: - Material

/// A dated line of text on its way into a brief. Already previewed.
struct DatedText: Hashable, Sendable {
    var text: String
    var at: Date
}

/// What one session's brief can be rebuilt from.
///
/// Deliberately not a ``SessionBrief``: this is *evidence*, and turning it into
/// a brief is a fold that has to consider what the stored brief already says.
/// Keeping the two apart is what lets ``folded(into:)`` be the only place the
/// kit's ordering rules are applied.
struct BriefMaterial: Hashable, Sendable {
    var firstPrompt: DatedText?
    var latestPrompt: DatedText?
    var latestAssistant: DatedText?
    var lastTurnEndedAt: Date?

    /// `true` when the store had nothing to say about this session.
    var isEmpty: Bool {
        firstPrompt == nil && latestPrompt == nil && latestAssistant == nil
            && lastTurnEndedAt == nil
    }

    /// Keeps the earliest and the latest instruction seen so far.
    ///
    /// Rows are compared rather than assumed to arrive in order: a harness
    /// flushes a whole turn at once and the index is written in flush order,
    /// which is not always timestamp order.
    mutating func record(prompt: DatedText) {
        if firstPrompt == nil || prompt.at < firstPrompt!.at { firstPrompt = prompt }
        if latestPrompt == nil || prompt.at >= latestPrompt!.at { latestPrompt = prompt }
    }

    /// Keeps the latest reply seen so far.
    mutating func record(reply: DatedText) {
        if latestAssistant == nil || reply.at >= latestAssistant!.at { latestAssistant = reply }
    }

    /// This material folded into an existing brief.
    ///
    /// Every field goes in through the kit's own recording methods, so the
    /// guards that make a live fold safe apply unchanged: the assignment yields
    /// only to a prompt stamped *earlier* than the one on record, the latest
    /// fields only to one stamped at or after theirs, and `lastTurnEndedAt`
    /// only ever moves forward. Nothing already recorded is overwritten by
    /// something older, which is what makes a second pass a no-op.
    func folded(into brief: SessionBrief) -> SessionBrief {
        var folded = brief
        if let firstPrompt { folded.record(prompt: firstPrompt.text, at: firstPrompt.at) }
        if let latestPrompt { folded.record(prompt: latestPrompt.text, at: latestPrompt.at) }
        if let latestAssistant {
            folded.record(reply: latestAssistant.text, at: latestAssistant.at)
        }
        if let lastTurnEndedAt {
            folded.recordTurnEnded(at: lastTurnEndedAt)
        } else if let latestAssistant {
            // No `turnEnded` was ever recorded for this session — several
            // harnesses do not write one, and the ones that do only began
            // lately. The last thing the model said is then the last evidence
            // there is that the session stopped talking, which is the question
            // "done, and you have not looked at it" is actually asking.
            folded.recordTurnEnded(at: latestAssistant.at)
        }
        return folded
    }
}

// MARK: - Report

/// What one backfill pass did.
public struct BriefBackfillReport: Sendable {
    /// `false` when the pass was skipped because this store has already had
    /// one for the event schema it is on.
    public var didRun: Bool = false
    /// Sessions whose brief was missing something the pass could fill.
    public var considered: Int = 0
    /// Sessions whose brief actually changed.
    public var updated: Int = 0
    /// Write transactions committed.
    public var batches: Int = 0
    /// Sessions that gained an assignment they did not have.
    public var firstPrompts: Int = 0
    /// Sessions that gained a "when the turn closed" they did not have.
    public var turnEnds: Int = 0
    /// Sessions marked read on the person's behalf because they had been quiet
    /// for longer than ``BriefBackfill/unreadWindow``.
    public var markedSeen: Int = 0
    /// The briefs that changed, so a registry holding the same sessions in
    /// memory can apply them instead of re-reading the store.
    public var briefs: [SessionKey: SessionBrief] = [:]

    public init() {}

    /// A line for a log or a notice. Counts only — never a word of a prompt.
    public var summary: String {
        "backfilled \(updated) of \(considered) sessions in \(batches) batches "
            + "(\(firstPrompts) assignments, \(turnEnds) turn ends), "
            + "and marked \(markedSeen) long-quiet sessions read"
    }
}

extension SessionBrief {
    /// This brief with everything `other` knows folded in.
    ///
    /// The merge a caller needs when two copies of one session's brief exist —
    /// the registry's live one and the one a backfill derived. Neither wins
    /// wholesale: each field goes in through the kit's recording methods, so
    /// the older of two assignments is kept and the newer of two replies is.
    public func folding(_ other: SessionBrief) -> SessionBrief {
        var folded = self
        if let prompt = other.firstPrompt, let at = other.firstPromptAt {
            folded.record(prompt: prompt, at: at)
        }
        if let prompt = other.latestPrompt, let at = other.lastPromptAt {
            folded.record(prompt: prompt, at: at)
        }
        if let reply = other.latestAssistant, let at = other.lastAssistantAt {
            folded.record(reply: reply, at: at)
        }
        if let ended = other.lastTurnEndedAt {
            folded.recordTurnEnded(at: ended)
        }
        return folded
    }
}
