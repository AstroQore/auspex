import AgentSessionKit
import AgentSessionLive
import Foundation
import GRDB
import Testing

@testable import AuspexCore

/// A store shaped like one Auspex kept before the brief existed: sessions with
/// empty briefs, and the messages and events they were recorded from.
///
/// Every prompt and reply here is written for the test. Nothing is captured
/// from a real transcript, and every path is under `/Users/example`.
private struct BackfilledStore {
    let store: AuspexStore
    let repository: SessionRepository

    init() throws {
        self.store = try AuspexStore(inMemory: true)
        self.repository = store.sessions
    }

    /// Records a session with an empty brief — the state the v2 migration left
    /// every pre-brief row in.
    @discardableResult
    func session(_ key: SessionKey, state: SessionState = .idle) throws -> SessionSnapshot {
        var snapshot = Fixtures.snapshot(key: key, state: state)
        snapshot.brief = SessionBrief()
        try repository.upsert(snapshot: snapshot)
        return snapshot
    }

    func index(_ key: SessionKey, _ role: MessageRole, _ text: String, at offset: TimeInterval) throws {
        try repository.indexMessage(
            session: key,
            harness: key.harness,
            role: role,
            ts: Fixtures.date(offset),
            content: text
        )
    }

    func log(_ key: SessionKey, _ kind: AgentEventKind, at offset: TimeInterval) throws {
        try repository.insertEvents([Fixtures.event(kind, key: key, at: offset)])
    }

    func brief(_ key: SessionKey) throws -> SessionBrief {
        try #require(try repository.fetch(key: key)).brief
    }

    /// The projected columns, which must never disagree with the blob.
    func columns(_ key: SessionKey) throws -> Row {
        try #require(try store.dbWriter.read { db in
            try Row.fetchOne(db, sql: """
                SELECT first_prompt, latest_prompt, latest_assistant, last_turn_ended_at
                  FROM sessions WHERE key = ?
                """, arguments: [key.description])
        })
    }
}

@Suite("BriefBackfill · rebuilding what was never folded")
struct BriefBackfillTests {
    private let assignment = "Make the resizer stop snapping back"
    private let followUp = "Now cover it with a test"
    private let reply = "The snap-back was a stale layout pass."

    @Test("a v1-era session gets the brief its own messages already prove")
    func derivesFromIndexedMessages() throws {
        let fixture = try BackfilledStore()
        let key = Fixtures.key()
        try fixture.session(key)
        try fixture.index(key, .user, assignment, at: 1)
        try fixture.index(key, .user, followUp, at: 60)
        try fixture.index(key, .assistant, reply, at: 90)
        try fixture.log(key, .turnEnded(reason: .complete), at: 120)

        let report = try BriefBackfill(store: fixture.store).run()

        #expect(report.updated == 1)
        #expect(report.firstPrompts == 1)
        #expect(report.turnEnds == 1)

        let brief = try fixture.brief(key)
        #expect(brief.firstPrompt == assignment)
        #expect(brief.firstPromptAt == Fixtures.date(1))
        #expect(brief.latestPrompt == followUp)
        #expect(brief.lastPromptAt == Fixtures.date(60))
        #expect(brief.latestAssistant == reply)
        #expect(brief.lastTurnEndedAt == Fixtures.date(120))

        // The caller gets the same brief back, so a registry holding this
        // session in memory does not have to re-read the store for it.
        #expect(report.briefs[key] == brief)
    }

    @Test("the projected columns are written with the blob, not after it")
    func writesTheProjection() throws {
        let fixture = try BackfilledStore()
        let key = Fixtures.key()
        try fixture.session(key)
        try fixture.index(key, .user, assignment, at: 1)
        try fixture.index(key, .assistant, reply, at: 90)
        try fixture.log(key, .turnEnded(reason: .complete), at: 120)

        _ = try BriefBackfill(store: fixture.store).run()

        let columns = try fixture.columns(key)
        #expect(columns["first_prompt"] as String? == assignment)
        #expect(columns["latest_prompt"] as String? == assignment)
        #expect(columns["latest_assistant"] as String? == reply)
        #expect(columns["last_turn_ended_at"] as Double? == Fixtures.date(120).timeIntervalSince1970)
    }

    @Test("what a harness injected is not what a person asked for")
    func skipsMetaPrompts() throws {
        let fixture = try BackfilledStore()
        let key = Fixtures.key()
        try fixture.session(key)
        // All three are recorded as user messages by one harness or another,
        // and none of them is somebody talking.
        try fixture.index(key, .user, "<system-reminder>Be concise.</system-reminder>", at: 0)
        try fixture.index(key, .user, "<command-name>/compact</command-name>", at: 1)
        try fixture.index(key, .user, "/clear", at: 2)
        try fixture.index(key, .user, assignment, at: 3)
        try fixture.index(key, .user, "<system-reminder>Budget is low.</system-reminder>", at: 4)

        _ = try BriefBackfill(store: fixture.store).run()

        let brief = try fixture.brief(key)
        #expect(brief.firstPrompt == assignment)
        #expect(brief.latestPrompt == assignment)
    }

    @Test("a session nobody ever talked to keeps an empty brief")
    func noMaterialLeavesItEmpty() throws {
        let fixture = try BackfilledStore()
        let key = Fixtures.key()
        try fixture.session(key)

        let report = try BriefBackfill(store: fixture.store).run()

        #expect(report.considered == 1)
        #expect(report.updated == 0)
        #expect(report.briefs.isEmpty)
        #expect(try fixture.brief(key).isEmpty)
    }

    @Test("a session with only meta prompts gets no assignment")
    func metaOnlyLeavesNoAssignment() throws {
        let fixture = try BackfilledStore()
        let key = Fixtures.key()
        try fixture.session(key)
        try fixture.index(key, .user, "<system-reminder>Be concise.</system-reminder>", at: 0)

        _ = try BriefBackfill(store: fixture.store).run()

        #expect(try fixture.brief(key).firstPrompt == nil)
    }

    @Test("a reply with no turn end still says when the session stopped talking")
    func fallsBackToTheLastReply() throws {
        let fixture = try BackfilledStore()
        let key = Fixtures.key()
        try fixture.session(key)
        try fixture.index(key, .assistant, reply, at: 90)

        _ = try BriefBackfill(store: fixture.store).run()

        let brief = try fixture.brief(key)
        #expect(brief.firstPrompt == nil)
        #expect(brief.latestAssistant == reply)
        // Several harnesses never write a `turnEnded`. The last thing the model
        // said is the only evidence left that the session stopped.
        #expect(brief.lastTurnEndedAt == Fixtures.date(90))
    }

    @Test("a real turn end beats the reply that came before it")
    func prefersTheRecordedTurnEnd() throws {
        let fixture = try BackfilledStore()
        let key = Fixtures.key()
        try fixture.session(key)
        try fixture.index(key, .assistant, reply, at: 90)
        try fixture.log(key, .turnEnded(reason: .complete), at: 95)
        try fixture.log(key, .turnEnded(reason: .complete), at: 130)

        _ = try BriefBackfill(store: fixture.store).run()

        #expect(try fixture.brief(key).lastTurnEndedAt == Fixtures.date(130))
    }

    @Test("a session whose text was never indexed is read from the event log")
    func fallsBackToTheEventLog() throws {
        let fixture = try BackfilledStore()
        let key = Fixtures.key(.codex, "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")
        try fixture.session(key)
        // What a harness excluded from the full-text index leaves behind: the
        // state events, carrying the adapter's preview, and nothing in
        // `messages` at all.
        try fixture.log(key, .userPrompt(preview: "<system-reminder>ignore me</system-reminder>"), at: 0)
        try fixture.log(key, .userPrompt(preview: assignment), at: 1)
        try fixture.log(key, .userPrompt(preview: followUp), at: 60)
        try fixture.log(key, .assistantText(preview: reply), at: 90)

        _ = try BriefBackfill(store: fixture.store).run()

        let brief = try fixture.brief(key)
        #expect(brief.firstPrompt == assignment)
        #expect(brief.latestPrompt == followUp)
        #expect(brief.latestAssistant == reply)
    }

    @Test("the index wins over the log, so one board line is one length")
    func prefersTheIndexOverTheLog() throws {
        let fixture = try BackfilledStore()
        let key = Fixtures.key()
        try fixture.session(key)
        try fixture.index(key, .user, assignment, at: 1)
        try fixture.log(key, .userPrompt(preview: "a truncated preview of the same thing…"), at: 1)

        _ = try BriefBackfill(store: fixture.store).run()

        #expect(try fixture.brief(key).firstPrompt == assignment)
    }

    @Test("running it twice changes nothing the first pass did not")
    func isIdempotent() throws {
        let fixture = try BackfilledStore()
        let key = Fixtures.key()
        try fixture.session(key)
        try fixture.index(key, .user, assignment, at: 1)
        try fixture.index(key, .assistant, reply, at: 90)

        let backfill = BriefBackfill(store: fixture.store)
        _ = try backfill.run()
        let afterFirst = try fixture.brief(key)

        let second = try backfill.run()
        #expect(second.updated == 0)
        #expect(second.briefs.isEmpty)
        #expect(try fixture.brief(key) == afterFirst)
    }

    @Test("a brief the live pipeline already folded is not overwritten")
    func doesNotDisplaceALiveBrief() throws {
        let fixture = try BackfilledStore()
        let key = Fixtures.key()
        var snapshot = Fixtures.snapshot(key: key)
        snapshot.brief = SessionBrief(
            firstPrompt: assignment,
            firstPromptAt: Fixtures.date(1),
            latestPrompt: followUp,
            lastPromptAt: Fixtures.date(60)
        )
        try fixture.repository.upsert(snapshot: snapshot)
        // The index also holds an *older* prompt this session was seeded past,
        // and a newer one that arrived after the live brief was folded.
        try fixture.index(key, .user, "An earlier instruction nobody saw", at: -30)
        try fixture.index(key, .assistant, reply, at: 90)

        _ = try BriefBackfill(store: fixture.store).run()

        let brief = try fixture.brief(key)
        // A cold start seeds from the tail, so the store can know an earlier
        // assignment than the live fold ever saw — and that is the one case
        // where displacing it is right.
        #expect(brief.firstPrompt == "An earlier instruction nobody saw")
        #expect(brief.firstPromptAt == Fixtures.date(-30))
        // The latest prompt is newer than anything the index holds, so it
        // stands.
        #expect(brief.latestPrompt == followUp)
        #expect(brief.lastPromptAt == Fixtures.date(60))
        #expect(brief.latestAssistant == reply)
    }

    @Test("batches commit as they go, and every session lands")
    func writesInBatches() throws {
        let fixture = try BackfilledStore()
        let keys = (0..<5).map { Fixtures.key(.claudeCode, "session-\($0)") }
        for (offset, key) in keys.enumerated() {
            try fixture.session(key)
            try fixture.index(key, .user, "\(assignment) \(offset)", at: TimeInterval(offset))
        }

        let report = try BriefBackfill(store: fixture.store).run(batchSize: 2)

        #expect(report.considered == 5)
        #expect(report.updated == 5)
        // Two, two, one — a transaction per batch rather than one over the lot,
        // so a live ingest waits milliseconds rather than the whole pass.
        #expect(report.batches == 3)
        for (offset, key) in keys.enumerated() {
            #expect(try fixture.brief(key).firstPrompt == "\(assignment) \(offset)")
        }
    }

    @Test("a batch size of zero is a batch of one, not a division by it")
    func clampsTheBatchSize() throws {
        let fixture = try BackfilledStore()
        let key = Fixtures.key()
        try fixture.session(key)
        try fixture.index(key, .user, assignment, at: 1)

        let report = try BriefBackfill(store: fixture.store).run(batchSize: 0)
        #expect(report.updated == 1)
    }

    @Test("a blob nothing can decode costs one row, not the pass")
    func skipsUndecodableRows() throws {
        let fixture = try BackfilledStore()
        let key = Fixtures.key()
        try fixture.session(key)
        try fixture.index(key, .user, assignment, at: 1)
        try fixture.store.dbWriter.write { db in
            try db.execute(sql: """
                INSERT INTO sessions
                    (key, harness, session_id, source_path, state, is_alive, is_stale,
                     turn_count, tool_call_count, tokens_in, tokens_out, tokens_cached,
                     snapshot_json)
                VALUES ('claudeCode:broken', 'claudeCode', 'broken', '/Users/example/x',
                        'idle', 1, 0, 0, 0, 0, 0, 0, 'not a snapshot')
                """)
            try db.execute(sql: """
                INSERT INTO messages (session_key, harness, role, ts, content)
                VALUES ('claudeCode:broken', 'claudeCode', 'user', 1, 'Rescue me')
                """)
        }

        let report = try BriefBackfill(store: fixture.store).run()
        #expect(report.updated == 1)
        #expect(try fixture.brief(key).firstPrompt == assignment)
    }

    @Test("the pass runs once per event schema, and says when it did not")
    func runIfNeededStampsTheSchema() throws {
        let fixture = try BackfilledStore()
        let key = Fixtures.key()
        try fixture.session(key)
        try fixture.index(key, .user, assignment, at: 1)

        let backfill = BriefBackfill(store: fixture.store)
        let first = try backfill.runIfNeeded()
        #expect(first.didRun)
        #expect(first.updated == 1)
        #expect(try fixture.store.metaValue(forKey: StoreMetaKey.briefBackfill)
            == String(AgentSessionLive.eventSchemaVersion))

        let second = try backfill.runIfNeeded()
        #expect(!second.didRun)
        #expect(second.considered == 0)
    }

    @Test("a schema bump asks for the pass again")
    func runIfNeededRerunsOnASchemaBump() throws {
        let fixture = try BackfilledStore()
        let key = Fixtures.key()
        try fixture.session(key)
        try fixture.index(key, .user, assignment, at: 1)
        // A store stamped by a build whose event model this one no longer
        // shares: what the same rows fold into may have changed.
        try fixture.store.setMetaValue("0", forKey: StoreMetaKey.briefBackfill)

        let report = try BriefBackfill(store: fixture.store).runIfNeeded()
        #expect(report.didRun)
        #expect(report.updated == 1)
    }

    @Test("a brief can be derived without writing anything")
    func derivesWithoutWriting() throws {
        let fixture = try BackfilledStore()
        let key = Fixtures.key()
        let silent = Fixtures.key(.codex, "never-said-anything")
        try fixture.session(key)
        try fixture.session(silent)
        try fixture.index(key, .user, assignment, at: 1)

        let briefs = try BriefBackfill(store: fixture.store).derivedBriefs(for: [key, silent])

        #expect(briefs[key]?.firstPrompt == assignment)
        // A key with nothing to say is absent rather than mapped to an empty
        // brief, so a cache can tell "no material" from "not looked up yet".
        #expect(briefs[silent] == nil)
        // Read-only: the store still holds the empty brief it started with.
        #expect(try fixture.brief(key).isEmpty)
    }
}

@Suite("SessionBrief · folding two copies of one brief together")
struct SessionBriefFoldingTests {
    @Test("an earlier assignment displaces a later one, a later reply wins")
    func foldsByTheKitsRules() {
        let live = SessionBrief(
            firstPrompt: "The first thing it saw",
            firstPromptAt: Fixtures.date(100),
            latestPrompt: "The newest instruction",
            lastPromptAt: Fixtures.date(200),
            latestAssistant: "An old reply",
            lastAssistantAt: Fixtures.date(150),
            lastTurnEndedAt: Fixtures.date(210)
        )
        let derived = SessionBrief(
            firstPrompt: "The first thing anybody said",
            firstPromptAt: Fixtures.date(10),
            latestPrompt: "Something from the middle",
            lastPromptAt: Fixtures.date(120),
            latestAssistant: "A newer reply",
            lastAssistantAt: Fixtures.date(300),
            lastTurnEndedAt: Fixtures.date(50)
        )

        let folded = live.folding(derived)

        #expect(folded.firstPrompt == "The first thing anybody said")
        #expect(folded.latestPrompt == "The newest instruction")
        #expect(folded.latestAssistant == "A newer reply")
        // Monotonic: a turn end from before the one on record cannot move it
        // backwards.
        #expect(folded.lastTurnEndedAt == Fixtures.date(210))
    }

    @Test("folding an empty brief in changes nothing")
    func foldingNothingIsANoOp() {
        let live = SessionBrief(
            firstPrompt: "Make the resizer stop snapping back",
            firstPromptAt: Fixtures.date(1)
        )
        #expect(live.folding(SessionBrief()) == live)
    }
}
