import Foundation
import Testing

@testable import AuspexCore

@Suite("AuspexPaths")
struct AuspexPathsTests {
    /// A fresh temporary directory standing in for the user's home.
    private func makeTemporaryHome() throws -> URL {
        let home = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("auspex-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        return home
    }

    @Test("every owned path is rooted at the injected home")
    func pathsAreRootedAtInjectedHome() throws {
        let home = try makeTemporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let paths = AuspexPaths(homeDirectory: home)

        #expect(paths.baseDirectory == home.appendingPathComponent(".auspex", isDirectory: true))
        #expect(paths.databaseURL.lastPathComponent == "auspex.db")
        #expect(paths.settingsURL.lastPathComponent == "settings.json")
        #expect(paths.socketURL.lastPathComponent == "mcp.sock")
        #expect(paths.socketPath == paths.socketURL.path)

        for url in [paths.databaseURL, paths.settingsURL, paths.socketURL, paths.logsDirectory] {
            #expect(paths.contains(url), "\(url.lastPathComponent) escaped the base directory")
            #expect(url.path.hasPrefix(home.path))
        }
    }

    @Test("the base directory is created lazily with 0700")
    func baseDirectoryIsCreatedWithOwnerOnlyPermissions() throws {
        let home = try makeTemporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let paths = AuspexPaths(homeDirectory: home)
        #expect(!FileManager.default.fileExists(atPath: paths.baseDirectory.path))

        try paths.ensureBaseDirectory()

        var isDirectory: ObjCBool = false
        #expect(
            FileManager.default.fileExists(
                atPath: paths.baseDirectory.path,
                isDirectory: &isDirectory
            )
        )
        #expect(isDirectory.boolValue)

        let attributes = try FileManager.default.attributesOfItem(atPath: paths.baseDirectory.path)
        let mode = attributes[.posixPermissions] as? NSNumber
        #expect(mode?.intValue == AuspexPaths.directoryPermissions)
    }

    @Test("ensuring the base directory twice is not an error")
    func ensureBaseDirectoryIsIdempotent() throws {
        let home = try makeTemporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let paths = AuspexPaths(homeDirectory: home)
        try paths.ensureBaseDirectory()
        try paths.ensureBaseDirectory()
        try paths.ensureLogsDirectory()

        #expect(FileManager.default.fileExists(atPath: paths.logsDirectory.path))
    }

    @Test("directories outside ~/.auspex are refused")
    func directoriesOutsideBaseAreRefused() throws {
        let home = try makeTemporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let paths = AuspexPaths(homeDirectory: home)
        // Standing in for another harness's store: Auspex must never create
        // or write anything there.
        let foreign = home.appendingPathComponent(".claude/projects", isDirectory: true)

        #expect(!paths.contains(foreign))
        #expect(throws: AuspexPathsError.self) {
            try paths.ensureDirectory(foreign)
        }
        #expect(!FileManager.default.fileExists(atPath: foreign.path))
    }

    @Test("the default home resolves to a real absolute directory")
    func defaultHomeIsAbsolute() {
        let home = AuspexPaths.realHomeDirectory()
        #expect(home.path.hasPrefix("/"))
        #expect(AuspexPaths.default.baseDirectory.path.hasSuffix("/.auspex"))
    }
}
