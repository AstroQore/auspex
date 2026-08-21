import Foundation
import Testing

@testable import AuspexCore

/// The update channel, and the file it lives in.
///
/// This is the setting where a wrong answer decides which binary lands on
/// somebody's Mac, so the cases worth pinning are the ones where the value is
/// *missing or wrong*: an old settings file, a typo somebody made by hand. Both
/// have to mean stable.
@Suite("Update channel")
struct UpdateChannelTests {
    @Test("A fresh install is on stable")
    func defaultIsStable() {
        #expect(UpdateChannel.standard == .main)
        #expect(AuspexSettings().updateChannel == .main)
        #expect(AuspexSettings().isEmpty)
    }

    @Test("Stable asks Sparkle for no channel by name; dev adds one")
    func allowedChannels() {
        // Emphatically *not* `["main"]`. No item in the feed is tagged `main`,
        // so naming it would filter the stable stream down to nothing and
        // stop stable users updating at all — a bug that only shows up as
        // silence, months later.
        #expect(UpdateChannel.main.additionalSparkleChannels.isEmpty)
        #expect(UpdateChannel.dev.additionalSparkleChannels == ["dev"])
    }

    @Test("Every channel has a name and a sentence, and no two share either")
    func everyChannelIsNameable() {
        let titles = UpdateChannel.allCases.map(\.title)
        let details = UpdateChannel.allCases.map(\.detail)
        #expect(titles.allSatisfy { !$0.isEmpty })
        #expect(details.allSatisfy { !$0.isEmpty })
        #expect(Set(titles).count == titles.count)
        #expect(Set(details).count == details.count)
    }

    @Test("A channel round-trips through JSON")
    func roundTripsThroughJSON() throws {
        for channel in UpdateChannel.allCases {
            var settings = AuspexSettings()
            settings.updateChannel = channel
            let data = try JSONEncoder().encode(settings)
            let read = try JSONDecoder().decode(AuspexSettings.self, from: data)
            #expect(read.updateChannel == channel)
        }
    }

    @Test("A settings file written before the channel existed is on stable")
    func absentKeyIsStable() throws {
        let data = Data(#"{"ignoreRules":[],"showsIgnored":true}"#.utf8)
        let settings = try JSONDecoder().decode(AuspexSettings.self, from: data)
        #expect(settings.updateChannel == .main)
    }

    @Test("An unrecognised channel in the file is stable, not a crash and not dev")
    func unknownChannelFallsBack() throws {
        // The file exists to be readable and editable by hand, so a typo has
        // to cost that one word. It must cost it in the safe direction: the
        // failure mode of guessing wrong here is installing a preview build on
        // somebody who never asked for one.
        let data = Data(#"{"ignoreRules":[],"updateChannel":"nightly"}"#.utf8)
        let settings = try JSONDecoder().decode(AuspexSettings.self, from: data)
        #expect(settings.updateChannel == .main)
    }

    @Test("The channel survives a round trip through ~/.auspex/settings.json")
    func roundTripsThroughTheFile() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("auspex-updates-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let store = AuspexSettingsStore(paths: AuspexPaths(homeDirectory: home))

        #expect(store.load().updateChannel == .main)

        var settings = AuspexSettings()
        settings.updateChannel = .dev
        try store.save(settings)

        let reloaded = store.load()
        #expect(reloaded.updateChannel == .dev)
        #expect(!reloaded.isEmpty)
    }

    @Test("The version the UI shows and the version reported over MCP are one value")
    func versionIsOneValue() {
        // `AuspexVersion` reads the bundle so that a release only has to bump
        // Info.plist. Under `swift test` there is no app bundle, so this is
        // the compiled-in fallback — and the point of the assertion is that
        // the three strings stay one string rather than three.
        #expect(!AuspexVersion.marketingVersion.isEmpty)
        #expect(!AuspexVersion.buildNumber.isEmpty)
        #expect(
            AuspexVersion.versionDescription
                == "\(AuspexVersion.marketingVersion) (\(AuspexVersion.buildNumber))"
        )
        #expect(AuspexVersion.displayString == "Auspex \(AuspexVersion.versionDescription)")
    }
}
