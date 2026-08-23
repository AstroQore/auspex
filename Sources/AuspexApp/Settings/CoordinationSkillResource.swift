import AuspexCore
import Foundation

/// Resolves the checked-in coordination skill without trusting SwiftPM's
/// compiler-path fallback in a packaged application.
///
/// `build_app.sh` puts `Auspex_AuspexApp.bundle` in `Contents/Resources`.
/// SwiftPM's generated `Bundle.module` accessor first looks beside the app and
/// then at an absolute path on the build machine, so calling it from a shipped
/// archive can fatal-error before the installer page appears. A packaged app
/// therefore resolves its resource bundle explicitly. Source/test processes,
/// whose main bundle is not an `.app`, may safely use `Bundle.module`.
enum CoordinationSkillResource {
    static func load() -> CoordinationSkillPackage? {
        try? package()
    }

    static func package() throws -> CoordinationSkillPackage {
        let bundle = AppResourceBundle.bundle
        guard let root = bundle.resourceURL?.appendingPathComponent(
            "Skills/\(CoordinationSkillPackage.name)",
            isDirectory: true
        ), FileManager.default.fileExists(atPath: root.path) else {
            throw ResourceError.missingSkill
        }
        return try CoordinationSkillPackage(contentsOf: root)
    }

    enum ResourceError: Error, CustomStringConvertible {
        case missingSkill

        var description: String {
            switch self {
            case .missingSkill: "The packaged auspex-coordination resource is missing."
            }
        }
    }
}
