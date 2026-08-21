import Foundation
import Testing

@testable import AuspexCore

/// The appearance setting, and the file it lives in.
///
/// The interesting cases are both about *absence*: a settings file written
/// while the window was forced dark has no `appearance` key at all, and what
/// it opens on decides whether the whole feature reaches the people it is for.
@Suite("Appearance mode")
struct AppearanceModeTests {
    @Test("A fresh install follows the system")
    func defaultIsSystem() {
        #expect(AppearanceMode.standard == .system)
        #expect(AuspexSettings().appearance == .system)
        #expect(AuspexSettings().translucentSidebar)
        #expect(AuspexSettings().isEmpty)
    }

    @Test("Every mode has a name and a sentence, and no two share either")
    func everyModeIsNameable() {
        let titles = AppearanceMode.allCases.map(\.title)
        let details = AppearanceMode.allCases.map(\.detail)
        #expect(titles.allSatisfy { !$0.isEmpty })
        #expect(details.allSatisfy { !$0.isEmpty })
        #expect(Set(titles).count == titles.count)
        #expect(Set(details).count == details.count)
    }

    @Test("A mode round-trips through JSON")
    func modeRoundTripsThroughSettings() throws {
        // It lives in `~/.auspex/settings.json`, so a renamed case is a
        // migration rather than a silent reset to the default.
        for mode in AppearanceMode.allCases {
            var settings = AuspexSettings()
            settings.appearance = mode
            settings.translucentSidebar = mode == .dark
            let data = try JSONEncoder().encode(settings)
            let read = try JSONDecoder().decode(AuspexSettings.self, from: data)
            #expect(read.appearance == mode)
            #expect(read.translucentSidebar == (mode == .dark))
        }
    }

    @Test("A settings file written while the window was forced dark opens on system")
    func absentKeyFollowsTheSystem() throws {
        let data = Data(#"{"ignoreRules":[],"showsIgnored":true}"#.utf8)
        let settings = try JSONDecoder().decode(AuspexSettings.self, from: data)
        // Not `.dark`: the whole point of the setting is that people who never
        // open it get the appearance their Mac is set to, and inferring "they
        // must have wanted dark, they were using the dark-only version" is how
        // a default silently keeps a feature from the people it is for.
        #expect(settings.appearance == .system)
        #expect(settings.translucentSidebar)
    }

    @Test("Both settings survive a round trip through ~/.auspex/settings.json")
    func roundTripsThroughTheFile() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("auspex-appearance-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let store = AuspexSettingsStore(paths: AuspexPaths(homeDirectory: home))

        #expect(store.load().isEmpty)
        #expect(store.load().appearance == .system)

        var settings = AuspexSettings()
        settings.appearance = .light
        settings.translucentSidebar = false
        try store.save(settings)

        let reloaded = store.load()
        #expect(reloaded.appearance == .light)
        #expect(!reloaded.translucentSidebar)
        #expect(!reloaded.isEmpty)
    }

    @Test("An unknown mode in the file is the default, not a crash")
    func unknownModeFallsBack() throws {
        // Somebody hand-editing the file — which is the reason it is a file —
        // must not be able to make the app unable to read its own settings.
        let data = Data(#"{"ignoreRules":[],"appearance":"sepia"}"#.utf8)
        let settings = try? JSONDecoder().decode(AuspexSettings.self, from: data)
        #expect(settings?.appearance == .system)
    }
}
