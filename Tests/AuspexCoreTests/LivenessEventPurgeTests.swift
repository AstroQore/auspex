import AgentSessionKit
import AgentSessionLive
import Foundation
import GRDB
import Testing

@testable import AuspexCore

@Suite("LivenessEventPurge")
struct LivenessEventPurgeTests {
    private func makeStore(sessions keys: [SessionKey]) throws -> AuspexStore {
        let store = try AuspexStore(inMemory: true)
        try SessionRepository(store: store).upsert(snapshots: keys.map {
            SessionStateReducer.initialSnapshot(identity: Fixtures.identity(key: $0))
        })
        return store
    }

    @Test("every stored heartbeat goes, in batches, and nothing else does")
    func removesOnlyLiveness() async throws {
        let first = Fixtures.key(.claudeCode, "first")
        let second = Fixtures.key(.codex, "second")
        let store = try makeStore(sessions: [first, second])
        let repository = SessionRepository(store: store)

        // Interleaved, so a batch boundary always falls between a heartbeat
        // and a row that has to survive.
        var events: [AgentEvent] = []
        for index in 0..<25 {
            let key = index.isMultiple(of: 2) ? first : second
            events.append(Fixtures.event(.liveness(alive: true), key: key, at: TimeInterval(index)))
            events.append(Fixtures.event(.note("kept-\(index)"), key: key, at: TimeInterval(index)))
        }
        try repository.insertEvents(events)

        let purge = LivenessEventPurge(store: store)
        #expect(try await purge.hasRun() == false)
        let removed = try await purge.runIfNeeded(batchSize: 4, now: Fixtures.date(0))

        #expect(removed == 25)
        #expect(try await purge.hasRun())
        let remaining = try repository.recentEvents(key: first) + repository.recentEvents(key: second)
        #expect(remaining.count == 25)
        #expect(remaining.allSatisfy { $0.kindLabel == "note" })
    }

    @Test("a store that has been purged is not scanned again")
    func runsOnce() async throws {
        let key = Fixtures.key()
        let store = try makeStore(sessions: [key])
        let repository = SessionRepository(store: store)
        let purge = LivenessEventPurge(store: store)

        #expect(try await purge.runIfNeeded() == 0)
        // A heartbeat written after the pass is not this job's to find: the
        // stamp is what a later launch reads, and it says the work is done.
        try repository.insertEvents([Fixtures.event(.liveness(alive: false), key: key, at: 1)])
        #expect(try await purge.runIfNeeded() == nil)
        #expect(try repository.eventCount(key: key) == 1)
    }

    @Test("reclaiming space on a store with nothing to reclaim finishes at once")
    func reclaimTerminates() async throws {
        let store = try AuspexStore(inMemory: true)
        #expect(try await StoreSpace.reclaimFreePages(store.dbWriter) == 0)
        #expect(try StoreSpace.reclaimFreePagesNow(store.dbWriter) == 0)
    }

    @Test("freed pages go back to the filesystem in steps")
    func reclaimReleasesPages() async throws {
        let home = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("auspex-reclaim-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }

        let store = try AuspexStore(paths: AuspexPaths(homeDirectory: home))
        let key = Fixtures.key()
        let repository = SessionRepository(store: store)
        try repository.upsert(snapshot: SessionStateReducer.initialSnapshot(
            identity: Fixtures.identity(key: key)
        ))
        let filler = String(repeating: "x", count: 2_000)
        try repository.insertEvents((0..<400).map {
            Fixtures.event(.note("\(filler)-\($0)"), key: key, at: TimeInterval($0))
        })
        try await store.dbWriter.write { db in try db.execute(sql: "DELETE FROM events") }
        let free = try await store.dbWriter.read { db in
            try Int.fetchOne(db, sql: "PRAGMA freelist_count") ?? 0
        }
        #expect(free > 10)

        let released = try await StoreSpace.reclaimFreePages(store.dbWriter, pagesPerStep: 7)
        #expect(released == free)
        let after = try await store.dbWriter.read { db in
            try Int.fetchOne(db, sql: "PRAGMA freelist_count") ?? 0
        }
        #expect(after == 0)
    }
}
