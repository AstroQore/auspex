import Foundation

/// Build identity for Auspex.
///
/// `marketingVersion` and `buildNumber` mirror `CFBundleShortVersionString`
/// and `CFBundleVersion` in `Resources/Info.plist`; keep the three in sync
/// when cutting a release.
public enum AuspexVersion {
    /// Semantic version shown in the UI and reported over MCP.
    public static let marketingVersion = "0.0.1"

    /// Monotonic build number.
    public static let buildNumber = "1"

    /// Reverse-DNS bundle identifier of the packaged app.
    public static let bundleIdentifier = "com.astroqore.auspex"

    /// Human-readable one-liner, e.g. `Auspex 0.0.1 (1)`.
    public static var displayString: String {
        "Auspex \(marketingVersion) (\(buildNumber))"
    }
}
