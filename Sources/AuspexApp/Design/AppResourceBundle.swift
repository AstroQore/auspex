import Foundation

/// The SwiftPM resource bundle, wherever this copy of Auspex is running.
///
/// SwiftPM's generated `Bundle.module` accessor looks beside the main bundle
/// and then at an absolute build-machine path. That is correct for `swift run`
/// and tests, but a macOS application has to put resource bundles under
/// `Contents/Resources`. A release archive therefore cannot call
/// `Bundle.module` directly: on another Mac neither of the generated paths
/// exists, and the accessor traps before a fallback image can be drawn.
///
/// Packaged applications use the conventional app resource directory first.
/// Only a SwiftPM/test process without that packaged bundle evaluates
/// `Bundle.module`.
enum AppResourceBundle {
    static let bundleName = "Auspex_AuspexApp.bundle"

    enum Source: String, Sendable {
        case application
        case swiftPackage
    }

    struct Resolution: @unchecked Sendable {
        let bundle: Bundle
        let source: Source
    }

    /// Resolved once. In a packaged app this must return before touching the
    /// generated accessor, because the accessor's build path belongs to the
    /// machine that produced the archive, not the one running it.
    static let resolution: Resolution = {
        if let url = packagedBundleURL(in: Bundle.main.resourceURL),
           let bundle = Bundle(url: url)
        {
            return Resolution(bundle: bundle, source: .application)
        }
        // A damaged packaged app must degrade to missing-resource fallbacks,
        // not evaluate SwiftPM's fatal accessor. The release smoke still
        // rejects it because `verifyCriticalResources()` cannot find the
        // files in `Bundle.main`.
        if isPackagedApplication(Bundle.main.bundleURL) {
            return Resolution(bundle: Bundle.main, source: .application)
        }
        return Resolution(bundle: Bundle.module, source: .swiftPackage)
    }()

    static var bundle: Bundle { resolution.bundle }

    /// Pure path selection, split out so the release layout can be asserted
    /// without manufacturing a second process-wide main bundle in a test.
    static func packagedBundleURL(
        in mainResourceURL: URL?,
        fileManager: FileManager = .default
    ) -> URL? {
        guard let mainResourceURL else { return nil }
        let candidate = mainResourceURL.appendingPathComponent(bundleName, isDirectory: true)
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: candidate.path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else { return nil }
        return candidate
    }

    static func isPackagedApplication(_ bundleURL: URL) -> Bool {
        bundleURL.pathExtension.caseInsensitiveCompare("app") == .orderedSame
    }

    static func url(
        forResource name: String,
        withExtension extensionName: String,
        subdirectory: String
    ) -> URL? {
        bundle.url(
            forResource: name,
            withExtension: extensionName,
            subdirectory: subdirectory
        )
    }

    /// Opens every identity asset whose absence would make a release
    /// unreadable. Used by the archive smoke test after the original SwiftPM
    /// build bundle has been hidden, so a build-machine fallback cannot make a
    /// broken `.app` look healthy.
    static func verifyCriticalResources() throws -> [URL] {
        try criticalResources.map { resource in
            guard let url = url(
                forResource: resource.name,
                withExtension: resource.extensionName,
                subdirectory: resource.subdirectory
            ) else {
                throw VerificationError.missing(resource.path)
            }
            let data = try Data(contentsOf: url, options: [.mappedIfSafe])
            guard !data.isEmpty else { throw VerificationError.empty(resource.path) }
            return url
        }
    }

    private struct CriticalResource: Sendable {
        let name: String
        let extensionName: String
        let subdirectory: String

        var path: String { "\(subdirectory)/\(name).\(extensionName)" }
    }

    private static let criticalResources: [CriticalResource] = [
        .init(name: "ProviderIcon-antigravity", extensionName: "svg", subdirectory: "ProviderIcons"),
        .init(name: "ProviderIcon-claude", extensionName: "svg", subdirectory: "ProviderIcons"),
        .init(name: "ProviderIcon-codex", extensionName: "svg", subdirectory: "ProviderIcons"),
        .init(name: "ProviderIcon-cursor", extensionName: "svg", subdirectory: "ProviderIcons"),
        .init(name: "ProviderIcon-gemini", extensionName: "svg", subdirectory: "ProviderIcons"),
        .init(name: "ProviderIcon-grok", extensionName: "svg", subdirectory: "ProviderIcons"),
        .init(name: "auspex-mark-32", extensionName: "png", subdirectory: "Brand"),
        .init(name: "auspex-mark-64", extensionName: "png", subdirectory: "Brand"),
        .init(name: "menubar-template", extensionName: "pdf", subdirectory: "Brand"),
    ]

    enum VerificationError: LocalizedError, Equatable {
        case missing(String)
        case empty(String)

        var errorDescription: String? {
            switch self {
            case let .missing(path): "Missing app resource: \(path)"
            case let .empty(path): "Empty app resource: \(path)"
            }
        }
    }
}
