import Foundation
import Testing

@testable import AuspexCore

/// The interface language a person picks, and what "follow the Mac" resolves
/// to. The words are the app's business; the choice, and the file it is kept
/// in, are Core's.
@Suite("Interface language")
struct AppLanguageTests {
    @Test("the Mac's language list picks a shipped catalogue by language and script")
    func bestMatch() {
        #expect(AppLanguage.bestMatch(for: ["zh-Hans-US", "en-US"]) == "zh-Hans")
        #expect(AppLanguage.bestMatch(for: ["en-GB"]) == "en")
        #expect(AppLanguage.bestMatch(for: ["zh"]) == "zh-Hans")
        // Traditional is a different catalogue; English beats the wrong one.
        #expect(AppLanguage.bestMatch(for: ["zh-Hant-TW", "en-US"]) == "en")
        #expect(AppLanguage.bestMatch(for: ["fr-FR", "de-DE"]) == nil)
    }

    @Test("System resolves through the list, and to English when nothing matches")
    func resolution() {
        #expect(AppLanguage.system.resolvedLocaleCode(preferred: ["zh-Hans-CN"]) == "zh-Hans")
        #expect(AppLanguage.system.resolvedLocaleCode(preferred: ["fr-FR"]) == "en")
        #expect(AppLanguage.english.resolvedLocaleCode(preferred: ["zh-Hans"]) == "en")
        #expect(AppLanguage.simplifiedChinese.resolvedLocaleCode(preferred: ["en"]) == "zh-Hans")
    }

    @Test("the choice lives in settings.json, and a bad value costs only itself")
    func settingsRoundTrip() throws {
        #expect(AuspexSettings().language == .system)
        #expect(AuspexSettings().isEmpty)

        var settings = AuspexSettings()
        settings.language = .simplifiedChinese
        #expect(!settings.isEmpty)
        let data = try JSONEncoder().encode(settings)
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains("\"language\":\"zh-Hans\""))
        #expect(try JSONDecoder().decode(AuspexSettings.self, from: data).language == .simplifiedChinese)

        // Written before the setting existed: follow the Mac.
        let old = Data(#"{"showsIgnored":true}"#.utf8)
        let decodedOld = try JSONDecoder().decode(AuspexSettings.self, from: old)
        #expect(decodedOld.language == .system)
        #expect(decodedOld.showsIgnored)

        // A typo in one hand-edited word costs that word, not the file.
        let typo = Data(#"{"language":"klingon","showsIgnored":true}"#.utf8)
        let decodedTypo = try JSONDecoder().decode(AuspexSettings.self, from: typo)
        #expect(decodedTypo.language == .system)
        #expect(decodedTypo.showsIgnored)
    }
}
