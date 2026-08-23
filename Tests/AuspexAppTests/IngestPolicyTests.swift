import Foundation
import Testing

@testable import AuspexApp

@MainActor
@Suite("Live ingest performance policy")
struct IngestPolicyTests {
    @Test("SQLite polling is a slow safety net behind the live watcher")
    func databaseSafetyNet() {
        let policy = AppEnvironment.liveIngestConfiguration
        #expect(policy.databaseDebounce == .milliseconds(250))
        #expect(policy.sqlitePollEvery == .seconds(30))
        #expect(policy.watcherLatency == 0.1)
    }
}
