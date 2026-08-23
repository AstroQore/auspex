import CryptoKit
import Foundation

/// The versioned, immutable payload installed as `auspex-coordination`.
///
/// The App target owns the bundled files. Core owns their validation and
/// fingerprint so the installer can be tested against synthetic packages
/// without reaching into a real application bundle or harness directory.
public struct CoordinationSkillPackage: Sendable, Equatable {
    public static let name = "auspex-coordination"
    public static let manifestName = "manifest.json"
    public static let entrypoint = "SKILL.md"

    public struct File: Sendable, Equatable {
        public let relativePath: String
        public let contents: Data

        public init(relativePath: String, contents: Data) {
            self.relativePath = relativePath
            self.contents = contents
        }
    }

    public let version: String
    public let files: [File]
    public let contentHash: String

    /// Builds a package from already-read bytes.
    ///
    /// Paths are deliberately constrained here rather than only when they are
    /// written. A resource is part of the application, but treating its
    /// manifest as untrusted keeps a packaging mistake from turning into a
    /// write outside the one skill directory a person agreed to manage.
    public init(version: String, files: [File]) throws {
        let cleanedVersion = version.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanedVersion.isEmpty else { throw PackageError.emptyVersion }
        guard !files.isEmpty else { throw PackageError.noFiles }

        var seen = Set<String>()
        for file in files {
            try Self.validate(relativePath: file.relativePath)
            guard file.relativePath != Self.manifestName else {
                throw PackageError.reservedPath(file.relativePath)
            }
            guard seen.insert(file.relativePath).inserted else {
                throw PackageError.duplicatePath(file.relativePath)
            }
        }
        guard seen.contains(Self.entrypoint) else { throw PackageError.missingEntrypoint }

        let ordered = files.sorted { $0.relativePath < $1.relativePath }
        self.version = cleanedVersion
        self.files = ordered
        self.contentHash = Self.hash(files: ordered)
    }

    /// Reads the checked-in resource manifest and exactly the files it names.
    /// Undeclared files make the resource invalid rather than silently joining
    /// the package: version and hash must describe all bytes Auspex installs.
    public init(contentsOf directory: URL, fileManager: FileManager = .default) throws {
        let manifestURL = directory.appendingPathComponent(Self.manifestName)
        let manifestData: Data
        do {
            manifestData = try Data(contentsOf: manifestURL)
        } catch {
            throw PackageError.unreadableManifest
        }

        let manifest: SourceManifest
        do {
            manifest = try JSONDecoder().decode(SourceManifest.self, from: manifestData)
        } catch {
            throw PackageError.invalidManifest
        }
        guard manifest.schemaVersion == 1 else {
            throw PackageError.unsupportedSchema(manifest.schemaVersion)
        }
        guard manifest.name == Self.name else {
            throw PackageError.wrongName(manifest.name)
        }

        let declared = Set(manifest.files)
        let actual = try Self.regularFiles(in: directory, fileManager: fileManager)
        let allowed = declared.union([Self.manifestName])
        guard actual == allowed else {
            throw PackageError.undeclaredFiles(
                actual.subtracting(allowed).sorted()
                    + allowed.subtracting(actual).map { "missing:\($0)" }.sorted()
            )
        }

        let files = try manifest.files.map { relativePath -> File in
            try Self.validate(relativePath: relativePath)
            let url = directory.appendingPathComponent(relativePath)
            return File(relativePath: relativePath, contents: try Data(contentsOf: url))
        }
        try self.init(version: manifest.version, files: files)
    }

    /// Writes only package content, not the ownership marker the installer
    /// creates after these bytes are safely staged.
    func write(to directory: URL, fileManager: FileManager = .default) throws {
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        for file in files {
            let destination = directory.appendingPathComponent(file.relativePath)
            try fileManager.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try file.contents.write(to: destination, options: .atomic)
        }
    }

    static func hash(files: [File]) -> String {
        var hasher = SHA256()
        for file in files.sorted(by: { $0.relativePath < $1.relativePath }) {
            update(&hasher, with: Data(file.relativePath.utf8))
            update(&hasher, with: file.contents)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func validate(relativePath: String) throws {
        guard !relativePath.isEmpty,
              !relativePath.hasPrefix("/"),
              !relativePath.hasSuffix("/"),
              !relativePath.contains("\0")
        else { throw PackageError.unsafePath(relativePath) }
        let components = relativePath.split(separator: "/", omittingEmptySubsequences: false)
        guard components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw PackageError.unsafePath(relativePath)
        }
    }

    private static func update(_ hasher: inout SHA256, with data: Data) {
        var size = UInt64(data.count).bigEndian
        withUnsafeBytes(of: &size) { hasher.update(bufferPointer: $0) }
        hasher.update(data: data)
    }

    private static func regularFiles(
        in directory: URL,
        fileManager: FileManager
    ) throws -> Set<String> {
        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey],
            options: []
        ) else { throw PackageError.unreadableDirectory }

        var files = Set<String>()
        let basePath = directory.resolvingSymlinksInPath().standardizedFileURL.path
        for case let url as URL in enumerator {
            let values = try url.resourceValues(
                forKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey]
            )
            guard values.isSymbolicLink != true else {
                throw PackageError.symbolicLink(url.lastPathComponent)
            }
            if values.isRegularFile == true {
                let itemPath = url.resolvingSymlinksInPath().standardizedFileURL.path
                guard itemPath.hasPrefix(basePath + "/") else {
                    throw PackageError.unsupportedItem(url.lastPathComponent)
                }
                let relative = String(itemPath.dropFirst(basePath.count + 1))
                files.insert(relative)
            } else if values.isDirectory != true {
                throw PackageError.unsupportedItem(url.lastPathComponent)
            }
        }
        return files
    }

    private struct SourceManifest: Decodable {
        let schemaVersion: Int
        let name: String
        let version: String
        let files: [String]

        enum CodingKeys: String, CodingKey {
            case schemaVersion = "schema_version"
            case name
            case version
            case files
        }
    }

    public enum PackageError: Error, CustomStringConvertible, Equatable {
        case emptyVersion
        case noFiles
        case missingEntrypoint
        case unsafePath(String)
        case reservedPath(String)
        case duplicatePath(String)
        case unreadableManifest
        case invalidManifest
        case unsupportedSchema(Int)
        case wrongName(String)
        case undeclaredFiles([String])
        case unreadableDirectory
        case symbolicLink(String)
        case unsupportedItem(String)

        public var description: String {
            switch self {
            case .emptyVersion: "The bundled coordination skill has no version."
            case .noFiles: "The bundled coordination skill has no files."
            case .missingEntrypoint: "The bundled coordination skill has no SKILL.md."
            case let .unsafePath(path): "The bundled coordination skill has an unsafe path: \(path)."
            case let .reservedPath(path): "The bundled coordination skill reserves \(path)."
            case let .duplicatePath(path): "The bundled coordination skill repeats \(path)."
            case .unreadableManifest: "The bundled coordination skill manifest could not be read."
            case .invalidManifest: "The bundled coordination skill manifest is not valid JSON."
            case let .unsupportedSchema(value):
                "The bundled coordination skill uses unsupported schema \(value)."
            case let .wrongName(value): "The bundled coordination skill is named \(value)."
            case let .undeclaredFiles(files):
                "The bundled coordination skill manifest does not match: \(files.joined(separator: ", "))."
            case .unreadableDirectory: "The bundled coordination skill directory could not be read."
            case let .symbolicLink(name): "The bundled coordination skill contains a symbolic link: \(name)."
            case let .unsupportedItem(name): "The bundled coordination skill contains an unsupported item: \(name)."
            }
        }
    }
}
