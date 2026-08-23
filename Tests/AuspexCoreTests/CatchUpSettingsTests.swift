import Foundation
import Testing

@testable import AuspexCore

@Suite("Catch-up settings")
struct CatchUpSettingsTests {
    @Test("an old settings file has no catch-up cursor")
    func legacyDecode() throws {
        let settings = try JSONDecoder().decode(AuspexSettings.self, from: Data("{}".utf8))
        #expect(settings.lastCatchUpAt == nil)
    }

    @Test("the cursor round trips through the editable settings file")
    func cursorRoundTrip() throws {
        let date = Date(timeIntervalSince1970: 1_900_000_000)
        let settings = AuspexSettings(lastCatchUpAt: date)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(settings)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(AuspexSettings.self, from: data)
        #expect(decoded.lastCatchUpAt == date)
        #expect(!decoded.isEmpty)
    }
}
