import Foundation
import Testing

@testable import AuspexApp

@MainActor
@Suite("Live ingest performance policy")
struct IngestPolicyTests {
    @Test("dormant sources are bounded without slowing live SQLite correctness")
    func activeSourceWindow() {
        let policy = AppEnvironment.liveIngestConfiguration
        #expect(policy.databaseDebounce == .milliseconds(250))
        #expect(policy.sqlitePollEvery == .seconds(2))
        #expect(policy.activeWindow == 2 * 60 * 60)
        #expect(policy.watcherLatency == 0.1)
    }
}
