import Foundation

/// Which language Auspex's own interface is drawn in.
///
/// The words themselves live in the `auspex-i18n` catalogue and are reached
/// from the app target through its generated `L10n`; Core holds only the
/// choice, because the choice is a setting and settings are Core's. Core
/// never says anything in a language other than English: what it says is read
/// by agents over MCP and by tests, and both of those parse it.
///
/// ## Why it is here and not in `@AppStorage`
///
/// For the same reason as ``AppearanceMode``: it changes what every surface
/// *is*, the file is the one a person can read and fix by hand, and the
/// offscreen renderers have to be able to take it without a window. Every
/// write goes through `AuspexSettingsStore`, under `~/.auspex/`.
public enum AppLanguage: String, Sendable, Codable, Hashable, CaseIterable, Identifiable {
    /// Whatever the Mac's language list puts first that Auspex ships.
    case system
    case english = "en"
    case simplifiedChinese = "zh-Hans"

    public var id: String { rawValue }

    /// What a fresh install gets, and what an unset or unrecognised key means.
    public static let standard = AppLanguage.system

    /// The catalogue locale this choice names, or `nil` for ``system``, which
    /// has none of its own until it is matched against the Mac's languages.
    public var localeCode: String? {
        self == .system ? nil : rawValue
    }

    /// The language's own name for itself. A picker that labels 简体中文 as
    /// "Simplified Chinese" can only be read by somebody who already reads the
    /// language they are trying to leave, so the two explicit cases are never
    /// translated. ``system`` has no endonym; the app labels it from the
    /// catalogue.
    public var endonym: String? {
        switch self {
        case .system: nil
        case .english: "English"
        case .simplifiedChinese: "简体中文"
        }
    }

    /// The catalogue locale a list of preferred languages selects, among
    /// `supported`, or `nil` when none of them is shipped.
    ///
    /// Matched on language *and* script rather than on the whole tag, because
    /// macOS hands over region-qualified spellings (`zh-Hans-US`, `en-GB`) that
    /// no catalogue is named after. A `zh-Hant` reader is deliberately not
    /// matched onto `zh-Hans`: Traditional and Simplified are different
    /// catalogues, and serving the wrong one is worse than serving English.
    public static func bestMatch(
        for preferred: [String],
        among supported: [String] = AppLanguage.allCases.compactMap(\.localeCode)
    ) -> String? {
        let table: [(code: String, language: String, script: String?)] = supported.map {
            let language = Locale.Language(identifier: $0)
            return ($0, language.languageCode?.identifier ?? $0, language.script?.identifier)
        }
        for tag in preferred {
            let candidate = Locale.Language(identifier: tag)
            guard let code = candidate.languageCode?.identifier else { continue }
            // `zh` with no script is ambiguous in principle, but it is what a
            // Simplified reader's Mac reports in practice; only an explicit
            // script that disagrees rules a catalogue out.
            let script = candidate.script?.identifier
            if let hit = table.first(where: {
                $0.language == code && ($0.script == nil || script == nil || $0.script == script)
            }) {
                return hit.code
            }
        }
        return nil
    }

    /// The catalogue locale actually in force: the explicit choice, or the
    /// first of `preferred` that is shipped, or English.
    public func resolvedLocaleCode(preferred: [String] = Locale.preferredLanguages) -> String {
        localeCode ?? Self.bestMatch(for: preferred) ?? AppLanguage.english.rawValue
    }
}
