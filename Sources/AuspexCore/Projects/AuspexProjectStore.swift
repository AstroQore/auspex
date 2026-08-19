import Foundation

/// `~/.auspex/projects.json` — the projects a person made.
///
/// Reading never fails. A missing file is "no projects yet", a corrupt one is
/// the same, and a single unreadable entry costs that entry rather than the
/// file: a board that refused to draw because one project row has a stray
/// comma in it would be a board broken by its own preferences. Writing does
/// throw, because somebody who just made a project and silently did not get it
/// saved is owed the error.
public struct AuspexProjectStore: Sendable {
    private let paths: AuspexPaths

    public init(paths: AuspexPaths = .default) {
        self.paths = paths
    }

    public var url: URL { paths.projectsURL }

    /// The stored projects, oldest first.
    public func load() -> [AuspexProject] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        guard let file = try? Self.decoder().decode(File.self, from: data) else { return [] }
        return file.projects.sorted { lhs, rhs in
            if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
            return lhs.id.uuidString < rhs.id.uuidString
        }
    }

    /// Replaces the file with `projects`.
    public func save(_ projects: [AuspexProject]) throws {
        try paths.ensureBaseDirectory()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(File(projects: projects))
        // Atomic, because the app reloads this file whenever it changes and a
        // half-written array read mid-save would empty the board's project
        // layer for a frame.
        try data.write(to: url, options: [.atomic])
    }

    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    /// The file's shape. An object rather than a bare array so a later version
    /// can add a key beside the projects without the file changing type.
    struct File: Codable {
        var projects: [AuspexProject]

        init(projects: [AuspexProject]) {
            self.projects = projects
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            projects = (try container.decodeIfPresent(
                [Lenient<AuspexProject>].self,
                forKey: .projects
            ) ?? []).compactMap(\.value)
        }
    }
}

/// One element that decodes to `nil` rather than failing its container.
///
/// The point is per-entry leniency: a project or a rule written by a newer
/// build, or hand-edited into something undecodable, costs itself and nothing
/// else. Decoding only — a value that could not be read is dropped on the next
/// save rather than re-encoded from nothing.
struct Lenient<Value: Decodable & Sendable>: Decodable, Sendable {
    let value: Value?

    init(from decoder: any Decoder) throws {
        value = try? Value(from: decoder)
    }
}
