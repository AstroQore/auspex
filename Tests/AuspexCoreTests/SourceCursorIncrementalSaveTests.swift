import AgentSessionKit
import AgentSessionLive
import Foundation
import Testing

@testable import AuspexCore

@Suite("Source cursor repository — incremental save")
struct SourceCursorIncrementalSaveTests {
    @Test("saving the changed subset leaves the untouched rows alone")
    func changedSubset() async throws {
        let store = try AuspexStore(inMemory: true)
        let repo = store.sourceCursors
        let a = SourceCursor.byteOffset(inode: 1, offset: 10)
        let b = SourceCursor.byteOffset(inode: 2, offset: 20)
        try await repo.save(["/Users/example/a.jsonl": a, "/Users/example/b.jsonl": b])

        // The coordinator's incremental path: one cursor moved, the store is
        // told about that one and shown the whole set for stores that need it.
        let a2 = SourceCursor.byteOffset(inode: 1, offset: 30)
        try await repo.save(
            changed: ["/Users/example/a.jsonl": a2],
            all: ["/Users/example/a.jsonl": a2, "/Users/example/b.jsonl": b]
        )

        let loaded = try await repo.load()
        #expect(loaded["/Users/example/a.jsonl"] == a2)
        #expect(loaded["/Users/example/b.jsonl"] == b)
        #expect(loaded.count == 2)
    }

    @Test("an empty changed set writes nothing and keeps everything")
    func emptyChanged() async throws {
        let store = try AuspexStore(inMemory: true)
        let repo = store.sourceCursors
        try await repo.save(["/Users/example/a.jsonl": .byteOffset(inode: 1, offset: 1)])
        try await repo.save(changed: [:], all: [:])
        let loaded = try await repo.load()
        #expect(loaded.count == 1)
    }
}
