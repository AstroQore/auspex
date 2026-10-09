import AgentSessionKit
import AgentSessionLive
import AuspexLocalization
import Foundation
import Testing

@testable import AuspexApp
@testable import AuspexCore

/// The strings the app shows, read from the catalogue it ships.
///
/// Three questions, each of which used to be answered by a screenshot and is
/// cheaper to answer here: is every key in both languages, is the bundle the
/// app packages actually carrying Simplified Chinese, and do the words Core
/// builds into a frame still match the ones the app recognises and
/// translates.
///
/// Nothing here moves `L10n.localeOverride` off English — that switch is
/// process-wide and other suites run beside this one. Chinese is read straight
/// out of the zh-Hans table instead.
@Suite("Localization")
struct LocalizationTests {
    init() { pinEnglishInterface() }

    // MARK: The catalogue, in both languages

    @Test("every catalogue key has a value in English and in Simplified Chinese")
    func everyKeyInBothLanguages() throws {
        let tables = try CatalogueTables.load()
        #expect(tables.english.count >= 1_000, "the catalogue shrank to \(tables.english.count) keys")
        #expect(Set(tables.english.keys) == Set(tables.chinese.keys))
        for (key, value) in tables.english {
            #expect(!value.isEmpty, "en: \(key) is empty")
        }
        for (key, value) in tables.chinese {
            #expect(!value.isEmpty, "zh-Hans: \(key) is empty")
            #expect(value != key, "zh-Hans: \(key) is its own identifier")
        }
    }

    @Test("the resource bundle the app packages carries zh-Hans, with real words in it")
    func bundleCarriesSimplifiedChinese() throws {
        let tables = try CatalogueTables.load()
        #expect(tables.bundle.lastPathComponent == "auspex-i18n_AuspexLocalization.bundle")
        // View names are product names and stay English in every language;
        // the proof of a real translation is a key that is actually worded.
        #expect(tables.chinese["viewMode.now"] == "Now")
        #expect(tables.english["viewMode.now"] == "Now")
        #expect(tables.chinese["now.needsYou"] == "需要你")
        #expect(tables.chinese["now.mayNeedYou"] == "可能需要你")
    }

    // MARK: Reading through L10n

    @Test("plurals and several values land in the right place")
    func formattedStrings() {
        #expect(L10n.Board.Window.hours(count: 1) == "1 hour")
        #expect(L10n.Board.Window.hours(count: 6) == "6 hours")
        #expect(L10n.Settings.Ignore.rulesOn(count: 3, active: 1) == "3 rules, 1 of them on.")
        #expect(L10n.Now.status(time: "17:31", live: 14, working: 7) == "17:31 · 14 live · 7 working")
        // A per-cent sign in a value with an argument survives formatting.
        #expect(L10n.Now.Watch.contextPressure(percent: 90) == "context over 90% used")
    }

    // MARK: The Language setting

    @Test("an explicit choice names its catalogue; System follows the diagnostic hook")
    func languageResolution() {
        #expect(AppLocalization.resolvedCode(for: .english) == "en")
        #expect(AppLocalization.resolvedCode(for: .simplifiedChinese) == "zh-Hans")
        #expect(
            AppLocalization.resolvedCode(for: .system, environment: ["AUSPEX_LANGUAGE": "zh-Hans"])
                == "zh-Hans"
        )
        // The hook stands in for "follow the system" only.
        #expect(
            AppLocalization.resolvedCode(for: .english, environment: ["AUSPEX_LANGUAGE": "zh-Hans"])
                == "en"
        )
        // A tag the catalogue does not ship is ignored, not obeyed.
        let fallback = AppLanguage.system.resolvedLocaleCode()
        #expect(
            AppLocalization.resolvedCode(for: .system, environment: ["AUSPEX_LANGUAGE": "fr"])
                == fallback
        )
    }

    @Test("the two explicit languages are named in themselves")
    func endonyms() {
        #expect(AppLanguage.english.endonym == "English")
        #expect(AppLanguage.simplifiedChinese.endonym == "简体中文")
        #expect(AppLanguage.system.endonym == nil)
    }

    // MARK: Core's fixed words

    /// The app recognises Core's English nameplates and says them again from
    /// the catalogue. If Core renames one, the app would quietly draw the new
    /// English word on a Chinese screen — this is where that shows up instead.
    @Test("Core's room names are the words the app recognises")
    func roomNames() {
        #expect(CoreVocabulary.localized(SceneBreakKind.garden.title) == L10n.Settings.Scene.garden)
        #expect(CoreVocabulary.localized(SceneBreakKind.teaRoom.title) == L10n.Settings.Scene.teaRoom)
        #expect(CoreVocabulary.localized(SceneBreakKind.lounge.title) == L10n.Settings.Scene.lounge)
        #expect(CoreVocabulary.localized(SceneLayout.meetingTitle) == L10n.Aviary.Room.meetingRoom)
        #expect(CoreVocabulary.localized(SceneLayout.meetingRoomsTitle) == L10n.Settings.Scene.meetingRooms)
        #expect(CoreVocabulary.localized("3 below") == L10n.Board.Group.below(count: 3))
        #expect(CoreVocabulary.localized("a project of somebody's") == "a project of somebody's")
    }

    @Test("Core's account of a permission prompt is recognised and translated")
    func harnessReason() {
        let permission = AttentionState.needsYou(
            reason: AttentionState.harnessReason(tool: "Bash"), source: .harness
        )
        #expect(permission.localizedMessage == L10n.Attention.waitingPermission(tool: "Bash"))
        let question = AttentionState.needsYou(
            reason: AttentionState.harnessReason(tool: nil), source: .harness
        )
        #expect(question.localizedMessage == L10n.Now.waitingAnswer)
        // An agent's own words are its words, in whatever language it wrote.
        let agent = AttentionState.needsYou(reason: "Which branch?", source: .agent)
        #expect(agent.localizedMessage == "Which branch?")
    }
}

/// The two `Localizable` tables, read as files from the resource bundle
/// SwiftPM built for `auspex-i18n` — the same bundle `Scripts/build_app.sh`
/// copies into `Auspex.app/Contents/Resources`.
struct CatalogueTables {
    let bundle: URL
    let english: [String: String]
    let chinese: [String: String]

    static func load() throws -> CatalogueTables {
        let bundle = try resourceBundle()
        let english = try table(in: bundle, tag: "en")
        let chinese = try table(in: bundle, tag: "zh-Hans")
        return CatalogueTables(bundle: bundle, english: english, chinese: chinese)
    }

    /// Walks up from the `.lproj` the catalogue resolved to.
    private static func resourceBundle() throws -> URL {
        var url = L10n.bundle.bundleURL
        while url.pathExtension != "bundle", url.pathComponents.count > 1 {
            url.deleteLastPathComponent()
        }
        guard url.pathExtension == "bundle" else { throw Missing.bundle(L10n.bundle.bundleURL.path) }
        return url
    }

    /// Plain strings and plural keys together: a plural key's value is its
    /// format key, which is what a translator wrote.
    private static func table(in bundle: URL, tag: String) throws -> [String: String] {
        let roots = [bundle.appendingPathComponent("Contents/Resources"), bundle]
        for root in roots {
            for spelling in [tag, tag.lowercased()] {
                let lproj = root.appendingPathComponent("\(spelling).lproj")
                let strings = lproj.appendingPathComponent("Localizable.strings")
                guard let plain = NSDictionary(contentsOf: strings) as? [String: String] else { continue }
                var merged = plain
                let plurals = lproj.appendingPathComponent("Localizable.stringsdict")
                if let dict = NSDictionary(contentsOf: plurals) as? [String: [String: Any]] {
                    for (key, entry) in dict {
                        merged[key] = entry["NSStringLocalizedFormatKey"] as? String ?? ""
                    }
                }
                return merged
            }
        }
        throw Missing.table(tag)
    }

    enum Missing: Error {
        case bundle(String)
        case table(String)
    }
}
