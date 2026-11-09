@_exported import AuspexLocalization
import AuspexCore
import Foundation

/// Which language the app shows, and the one place that tells the catalogue.
///
/// The words live in `auspex-i18n` and are read through its generated `L10n`
/// (re-exported here, so every file in the app sees it without an import).
/// This type only decides the language — the Settings choice, or the Mac's
/// language list matched by ``AppLanguage/bestMatch(for:among:)`` — and pushes
/// the answer into `L10n.localeOverride` explicitly, every time. The
/// package's own system-language matching is looser than ours (a bare `zh`
/// prefix would hand a Traditional reader Simplified), so it is never asked.
///
/// **Why plain `String`s rather than `LocalizedStringKey`.** SwiftUI's
/// automatic lookup goes through the view's bundle and the *system's*
/// language, which would make the in-app choice unimplementable without a
/// relaunch. `L10n` returns a `String` that is already localized, and every
/// SwiftUI initializer renders a `String` verbatim.
///
/// **What does not go through the catalogue**: harness, company and product
/// names (the catalogue's `_glossary.json`), MCP tool descriptions and
/// results, `--help` and diagnostics, log lines, and everything Auspex writes
/// into a harness's files. `Scripts/lint_localization.py` enforces the split.
@MainActor
enum AppLocalization {
    /// The choice in force, so a repeated assignment is free.
    private(set) static var language: AppLanguage = .standard

    /// Install a choice. Called once at launch and on every change in
    /// Settings; takes effect on the next read of any `L10n` member. Views
    /// that already drew are redrawn by the roots, which key themselves on
    /// ``language`` — see `RootView`.
    static func apply(_ language: AppLanguage) {
        self.language = language
        let code = resolvedCode(for: language)
        if L10n.localeOverride != code {
            L10n.localeOverride = code
        }
    }

    /// The catalogue locale for a choice.
    ///
    /// `AUSPEX_LANGUAGE` is a diagnostic hook, not a feature: it lets a demo
    /// launch or the packaged-app smoke test prove a translation resolves
    /// without writing a setting into anybody's `~/.auspex/`. It only stands
    /// in for "follow the system" — an explicit choice always wins.
    nonisolated static func resolvedCode(
        for language: AppLanguage,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String {
        if language == .system,
           let forced = environment["AUSPEX_LANGUAGE"].flatMap(AppLanguage.init(rawValue:)),
           let code = forced.localeCode {
            return code
        }
        return language.resolvedLocaleCode()
    }
}

/// Display formatting in the app's language rather than the process's.
///
/// `Locale.current` is the Mac's language; the Language setting may say
/// otherwise, and a time formatted against the wrong one drops "3:04:05 PM"
/// into the middle of a Chinese screen. Fixed machine formats (`HH:mm:ss` on
/// `en_US_POSIX`) do not need this and do not use it.
enum AppLocale {
    /// The locale every user-facing format uses.
    static var current: Locale { Locale(identifier: L10n.resolvedLocale) }

    /// A wall-clock time, `.standard` precision, in the app's language.
    static func time(_ date: Date) -> String {
        date.formatted(Date.FormatStyle(date: .omitted, time: .standard).locale(current))
    }

    /// "2 hours ago", in the app's language.
    static func relativeDateTimeFormatter(
        unitsStyle: RelativeDateTimeFormatter.UnitsStyle = .full
    ) -> RelativeDateTimeFormatter {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = unitsStyle
        formatter.locale = current
        return formatter
    }
}
