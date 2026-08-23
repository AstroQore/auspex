import Foundation
import Testing

@testable import AuspexCore

@Suite("Launch at login setting")
struct LaunchAtLoginSettingsTests {
    @Test("old settings files remain opted out")
    func oldSettingsDecodeOff() throws {
        let settings = try JSONDecoder().decode(AuspexSettings.self, from: Data("{}".utf8))
        #expect(!settings.launchAtLogin)
        #expect(settings.loginItemRegistration == nil)
        #expect(settings.isEmpty)
    }

    @Test("the confirmed system state and bundle receipt round trip")
    func roundTrip() throws {
        var settings = AuspexSettings()
        settings.launchAtLogin = true
        settings.loginItemRegistration = LoginItemRegistrationReceipt(
            bundleIdentifier: "com.example.Auspex",
            bundlePath: "/Applications/Auspex.app",
            shortVersion: "1.0.0",
            buildVersion: "10"
        )
        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(AuspexSettings.self, from: data)
        #expect(decoded.launchAtLogin)
        #expect(decoded.loginItemRegistration == settings.loginItemRegistration)
        #expect(!decoded.isEmpty)
    }

    @Test("replacement proof requires the same app and path with a new version")
    func replacementProof() {
        let old = LoginItemRegistrationReceipt(
            bundleIdentifier: "com.example.Auspex",
            bundlePath: "/Applications/Auspex.app",
            shortVersion: "1.0.0",
            buildVersion: "10"
        )
        let update = LoginItemRegistrationReceipt(
            bundleIdentifier: "com.example.Auspex",
            bundlePath: "/Applications/Auspex.app",
            shortVersion: "1.1.0",
            buildVersion: "11"
        )
        let moved = LoginItemRegistrationReceipt(
            bundleIdentifier: "com.example.Auspex",
            bundlePath: "/Applications/Utilities/Auspex.app",
            shortVersion: "1.1.0",
            buildVersion: "11"
        )

        #expect(old.provesInPlaceReplacement(by: update))
        #expect(!old.provesInPlaceReplacement(by: old))
        #expect(!old.provesInPlaceReplacement(by: moved))
    }
}
