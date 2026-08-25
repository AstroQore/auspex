import Foundation

/// Build identity for Auspex.
///
/// ## The bundle is the source of truth
///
/// `Resources/Info.plist` is what the release script bumps, what the tag is
/// checked against, and what Sparkle compares when it decides whether the
/// build in the feed is newer than this one. So this type *reads* the plist
/// rather than restating it: two hand-maintained copies of a version number is
/// two version numbers, and the one that goes stale is always the one nobody
/// looks at.
///
/// The literals below are the fallback for a run with no bundle behind it —
/// `swift test`, and `swift run` against `.build/debug/Auspex` — where there
/// is no `Info.plist` to read. Keep them matching the plist; `release_app.sh`
/// rewrites both, and refuses to release if they have drifted apart.
public enum AuspexVersion {
    /// What the plist says, for a build that has one.
    static let bundle = Bundle.main

    /// What `CFBundleShortVersionString` says, for a build with no bundle.
    ///
    /// Rewritten by `Scripts/release_app.sh`, which matches this exact line —
    /// keep the shape.
    static let fallbackMarketingVersion = "0.2.0"

    /// What `CFBundleVersion` says, for a build with no bundle. Same deal.
    static let fallbackBuildNumber = "4"

    /// Semantic version shown in the UI and reported over MCP.
    public static let marketingVersion = string(
        forKey: "CFBundleShortVersionString",
        fallback: fallbackMarketingVersion
    )

    /// Monotonic build number. Sparkle orders releases by this, not by
    /// ``marketingVersion``, so it must never go backwards.
    public static let buildNumber = string(
        forKey: "CFBundleVersion",
        fallback: fallbackBuildNumber
    )

    /// Reverse-DNS bundle identifier of the packaged app.
    public static let bundleIdentifier = "com.astroqore.auspex"

    /// Human-readable one-liner, e.g. `Auspex 0.0.1 (1)`.
    public static var displayString: String {
        "Auspex \(marketingVersion) (\(buildNumber))"
    }

    /// `0.0.1 (1)` — the version pair on its own, for a row that already says
    /// the app's name beside it.
    public static var versionDescription: String {
        "\(marketingVersion) (\(buildNumber))"
    }

    /// A plist string, or the compiled-in fallback.
    ///
    /// Empty is treated as absent: a plist key present but blank is a
    /// packaging mistake, and showing a person "Auspex  ()" tells them
    /// nothing they can act on.
    private static func string(forKey key: String, fallback: String) -> String {
        guard let value = bundle.object(forInfoDictionaryKey: key) as? String,
              !value.isEmpty
        else { return fallback }
        return value
    }
}
