import Foundation
import Testing

@testable import AuspexCore

@Suite("Launch at login setting")
struct LaunchAtLoginSettingsTests {
    @Test("old settings files remain opted out")
    func oldSettingsDecodeOff() throws {
        let settings = try JSONDecoder().decode(AuspexSettings.self, from: Data("{}".utf8))
        #expect(!settings.launchAtLogin)
        #expect(settings.isEmpty)
    }

    @Test("the user intent round trips")
    func roundTrip() throws {
        var settings = AuspexSettings()
        settings.launchAtLogin = true
        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(AuspexSettings.self, from: data)
        #expect(decoded.launchAtLogin)
        #expect(!decoded.isEmpty)
    }
}
