import AuspexLocalization

/// Pins the interface language to English for a suite that asserts on the
/// English words the catalogue serves.
///
/// Called from those suites' `init`, so it runs before every one of their
/// tests. Only ever "en": no test in this target sets any other language on
/// the process, so suites running in parallel cannot see one another's choice
/// — a test that needs Simplified Chinese reads the zh-Hans table directly
/// (see `LocalizationTests`) instead of moving this process-wide switch.
func pinEnglishInterface() {
    L10n.localeOverride = "en"
}
