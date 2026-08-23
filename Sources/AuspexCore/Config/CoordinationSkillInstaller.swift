import AgentSessionKit
import Foundation

/// Installs one versioned skill into a directory Auspex owns in full.
///
/// Unlike a fenced note, a skill is a directory. The ownership marker records
/// every file plus a hash over its bytes. That lets Auspex distinguish three
/// cases without guessing:
///
/// - a current or older *unaltered* Auspex package, which is safe to update or
///   remove;
/// - a directory somebody else already made, which is left alone;
/// - an Auspex package somebody edited, which is also left alone.
struct CoordinationSkillInstaller: Sendable {
    static let markerName = ".auspex-owned.json"
    static let owner = "com.astroqore.auspex"

    let harness: Harness
    let destination: URL
    let package: CoordinationSkillPackage
    let paths: AuspexPaths

    func status(fileManager: FileManager = .default) -> HarnessInstaller.State {
        guard fileManager.fileExists(atPath: destination.path) else { return .absent }
        do {
            let installed = try inspect(destination, fileManager: fileManager)
            if installed.marker.version == package.version,
               installed.marker.contentHash != package.contentHash
            {
                return .unreadable(
                    "The installed coordination skill has this build's version but different bytes. "
                        + "Auspex will not overwrite it."
                )
            }
            if installed.marker.version == package.version,
               installed.marker.contentHash == package.contentHash
            {
                return .installed
            }
            return .installedElsewhere("coordination skill v\(installed.marker.version)")
        } catch {
            return .unreadable(Self.failureDescription(error))
        }
    }

    func install(fileManager: FileManager = .default) -> HarnessInstaller.Report {
        let state = status(fileManager: fileManager)
        switch state {
        case .installed:
            return report(didChange: false)
        case let .unavailable(reason), let .unreadable(reason):
            return report(didChange: false, failure: reason)
        case .absent, .installedElsewhere:
            break
        }

        var backupPath: String?
        do {
            let parent = destination.deletingLastPathComponent()
            try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)

            if fileManager.fileExists(atPath: destination.path) {
                // Re-inspect at the last possible moment. Status is a display
                // snapshot; another process may have edited the skill after it.
                _ = try inspect(destination, fileManager: fileManager)
                backupPath = try backup(fileManager: fileManager)
            }

            let stage = parent.appendingPathComponent(
                ".\(CoordinationSkillPackage.name).auspex-install-\(UUID().uuidString)",
                isDirectory: true
            )
            defer { try? fileManager.removeItem(at: stage) }
            try package.write(to: stage, fileManager: fileManager)
            try writeMarker(to: stage)
            let staged = try inspect(stage, fileManager: fileManager)
            guard staged.marker.version == package.version,
                  staged.marker.contentHash == package.contentHash
            else { throw InstallError.stagingVerificationFailed }

            if fileManager.fileExists(atPath: destination.path) {
                try replaceWithStage(stage, fileManager: fileManager)
            } else {
                try fileManager.moveItem(at: stage, to: destination)
                do {
                    let installed = try inspect(destination, fileManager: fileManager)
                    guard installed.marker.version == package.version,
                          installed.marker.contentHash == package.contentHash
                    else { throw InstallError.installVerificationFailed }
                } catch {
                    // No previous directory existed. Removing the package we
                    // just created is the exact rollback for a failed readback.
                    try? fileManager.removeItem(at: destination)
                    throw error
                }
            }
            return report(didChange: true, backupPath: backupPath)
        } catch {
            return report(
                didChange: false,
                backupPath: backupPath,
                failure: Self.failureDescription(error)
            )
        }
    }

    func uninstall(fileManager: FileManager = .default) -> HarnessInstaller.Report {
        guard fileManager.fileExists(atPath: destination.path) else {
            return report(didChange: false)
        }

        var backupPath: String?
        do {
            // This is the deletion gate. `inspect` verifies the owner, exact
            // file list and recorded hash; a hand edit or extra file refuses.
            _ = try inspect(destination, fileManager: fileManager)
            backupPath = try backup(fileManager: fileManager)
            _ = try inspect(destination, fileManager: fileManager)
            try fileManager.removeItem(at: destination)
            return report(didChange: true, backupPath: backupPath)
        } catch {
            return report(
                didChange: false,
                backupPath: backupPath,
                failure: Self.failureDescription(error)
            )
        }
    }

    private func replaceWithStage(_ stage: URL, fileManager: FileManager) throws {
        let rollback = destination.deletingLastPathComponent().appendingPathComponent(
            ".\(CoordinationSkillPackage.name).auspex-rollback-\(UUID().uuidString)",
            isDirectory: true
        )
        _ = try inspect(destination, fileManager: fileManager)
        try fileManager.moveItem(at: destination, to: rollback)
        do {
            try fileManager.moveItem(at: stage, to: destination)
            let installed = try inspect(destination, fileManager: fileManager)
            guard installed.marker.version == package.version,
                  installed.marker.contentHash == package.contentHash
            else { throw InstallError.installVerificationFailed }
            try fileManager.removeItem(at: rollback)
        } catch {
            try? fileManager.removeItem(at: destination)
            try? fileManager.moveItem(at: rollback, to: destination)
            throw error
        }
    }

    private func backup(fileManager: FileManager) throws -> String {
        let directory = try paths.ensureDirectory(
            paths.baseDirectory.appendingPathComponent("backups", isDirectory: true),
            fileManager: fileManager
        )
        let stamp = Self.stampFormatter.string(from: Date())
        let target = directory.appendingPathComponent(
            "\(harness.rawValue)-\(CoordinationSkillPackage.name)-\(stamp)-"
                + "\(UUID().uuidString.prefix(8)).backup",
            isDirectory: true
        )
        try fileManager.copyItem(at: destination, to: target)
        return target.path
    }

    private func writeMarker(to directory: URL) throws {
        let marker = Marker(
            schemaVersion: 1,
            owner: Self.owner,
            name: CoordinationSkillPackage.name,
            version: package.version,
            contentHash: package.contentHash,
            files: package.files.map(\.relativePath)
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(marker)
        data.append(0x0A)
        try data.write(
            to: directory.appendingPathComponent(Self.markerName),
            options: .atomic
        )
    }

    private func inspect(
        _ directory: URL,
        fileManager: FileManager
    ) throws -> InstalledPackage {
        let rootValues = try directory.resourceValues(
            forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
        )
        guard rootValues.isSymbolicLink != true, rootValues.isDirectory == true else {
            throw InstallError.notADirectory
        }

        let markerURL = directory.appendingPathComponent(Self.markerName)
        guard fileManager.fileExists(atPath: markerURL.path) else {
            throw InstallError.foreignDirectory
        }
        let marker: Marker
        do {
            marker = try JSONDecoder().decode(Marker.self, from: Data(contentsOf: markerURL))
        } catch {
            throw InstallError.invalidMarker
        }
        guard marker.schemaVersion == 1,
              marker.owner == Self.owner,
              marker.name == CoordinationSkillPackage.name
        else { throw InstallError.foreignMarker }
        guard !marker.files.isEmpty,
              Set(marker.files).count == marker.files.count,
              marker.files.contains(CoordinationSkillPackage.entrypoint)
        else { throw InstallError.invalidMarker }
        for relativePath in marker.files {
            do {
                try CoordinationSkillPackage.validate(relativePath: relativePath)
            } catch {
                throw InstallError.invalidMarker
            }
        }

        let contents = try directoryContents(directory, fileManager: fileManager)
        let expectedFiles = Set(marker.files).union([Self.markerName])
        guard contents.files == expectedFiles else {
            throw InstallError.fileListChanged
        }
        let expectedDirectories = Self.parentDirectories(of: marker.files)
        guard contents.directories == expectedDirectories else {
            throw InstallError.fileListChanged
        }

        let files = try marker.files.map { relativePath in
            CoordinationSkillPackage.File(
                relativePath: relativePath,
                contents: try Data(contentsOf: directory.appendingPathComponent(relativePath))
            )
        }
        let actualHash = CoordinationSkillPackage.hash(files: files)
        guard actualHash == marker.contentHash else { throw InstallError.contentChanged }
        return InstalledPackage(marker: marker)
    }

    private func directoryContents(
        _ directory: URL,
        fileManager: FileManager
    ) throws -> (files: Set<String>, directories: Set<String>) {
        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey],
            options: []
        ) else { throw InstallError.unreadableDirectory }

        var files = Set<String>()
        var directories = Set<String>()
        let basePath = directory.resolvingSymlinksInPath().standardizedFileURL.path
        for case let url as URL in enumerator {
            let values = try url.resourceValues(
                forKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey]
            )
            guard values.isSymbolicLink != true else { throw InstallError.symbolicLink }
            let itemPath = url.resolvingSymlinksInPath().standardizedFileURL.path
            guard itemPath.hasPrefix(basePath + "/") else {
                throw InstallError.unsupportedItem
            }
            let relative = String(itemPath.dropFirst(basePath.count + 1))
            if values.isRegularFile == true {
                files.insert(relative)
            } else if values.isDirectory == true {
                directories.insert(relative)
            } else {
                throw InstallError.unsupportedItem
            }
        }
        return (files, directories)
    }

    private static func parentDirectories(of files: [String]) -> Set<String> {
        var directories = Set<String>()
        for file in files {
            var components = file.split(separator: "/").map(String.init)
            _ = components.popLast()
            while !components.isEmpty {
                directories.insert(components.joined(separator: "/"))
                _ = components.popLast()
            }
        }
        return directories
    }

    private func report(
        didChange: Bool,
        backupPath: String? = nil,
        failure: String? = nil
    ) -> HarnessInstaller.Report {
        HarnessInstaller.Report(
            harness: harness,
            piece: .coordinationSkill,
            didChange: didChange,
            path: destination.path,
            backupPath: backupPath,
            failure: failure
        )
    }

    private static func failureDescription(_ error: Error) -> String {
        String(describing: error)
    }

    private struct InstalledPackage {
        let marker: Marker
    }

    private struct Marker: Codable {
        let schemaVersion: Int
        let owner: String
        let name: String
        let version: String
        let contentHash: String
        let files: [String]

        enum CodingKeys: String, CodingKey {
            case schemaVersion = "schema_version"
            case owner
            case name
            case version
            case contentHash = "content_hash"
            case files
        }
    }

    private enum InstallError: Error, CustomStringConvertible {
        case notADirectory
        case foreignDirectory
        case invalidMarker
        case foreignMarker
        case unreadableDirectory
        case fileListChanged
        case contentChanged
        case symbolicLink
        case unsupportedItem
        case stagingVerificationFailed
        case installVerificationFailed

        var description: String {
            switch self {
            case .notADirectory:
                "The coordination skill path exists but is not a directory. Auspex left it alone."
            case .foreignDirectory:
                "The coordination skill directory is not owned by Auspex. Auspex left it alone."
            case .invalidMarker:
                "The coordination skill ownership marker is invalid. Auspex left it alone."
            case .foreignMarker:
                "The coordination skill ownership marker belongs to something else. Auspex left it alone."
            case .unreadableDirectory:
                "The coordination skill directory could not be read. Auspex left it alone."
            case .fileListChanged:
                "The coordination skill contains added, removed, or renamed files. Auspex left it alone."
            case .contentChanged:
                "The coordination skill was modified after Auspex installed it. Auspex left it alone."
            case .symbolicLink:
                "The coordination skill contains a symbolic link. Auspex left it alone."
            case .unsupportedItem:
                "The coordination skill contains an unsupported filesystem item. Auspex left it alone."
            case .stagingVerificationFailed:
                "The coordination skill could not be verified before installation."
            case .installVerificationFailed:
                "The coordination skill could not be verified after installation."
            }
        }
    }

    private static let stampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter
    }()
}
