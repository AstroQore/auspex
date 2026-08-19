import AgentSessionKit
import AgentSessionLive
import Foundation
import ImageIO

/// Everything Auspex can draw an agent as, resolved from two folders.
///
/// ## The two roots, and why the user's wins
///
/// ```text
/// Auspex.app/Contents/Resources/Characters/<id>/   shipped with the app
/// ~/.auspex/characters/<id>/                       the person's own
/// ```
///
/// A user package with the same id as a built-in *replaces* it rather than
/// sitting beside it. That is what makes "I want a different Claude Code
/// person" a two-minute job: copy the folder, edit the pixels, keep the id.
/// The built-in is remembered in ``CharacterCatalog/shadowed`` so the Settings
/// pane can say the replacement happened, because a person who forgets they
/// once put a folder there deserves to be told why the shipped art is gone.
///
/// ## Nothing here throws
///
/// The scene has a procedural rig behind every pose. A package that cannot be
/// read has to degrade to that rig plus an explanation, never to an error path
/// the UI has to handle — so every check produces a ``CharacterProblem`` value
/// and scanning always returns a catalog.
public struct CharacterLibrary: Sendable {
    /// Where the app's own packages live, if this build has any.
    public let builtInDirectory: URL?
    /// `~/.auspex/characters`.
    public let userDirectory: URL

    public init(builtInDirectory: URL?, userDirectory: URL) {
        self.builtInDirectory = builtInDirectory
        self.userDirectory = userDirectory
    }

    public init(paths: AuspexPaths = .default, builtInDirectory: URL? = nil) {
        self.init(builtInDirectory: builtInDirectory, userDirectory: paths.charactersDirectory)
    }

    /// Reads both roots and resolves the overrides.
    public func scan(fileManager: FileManager = .default) -> CharacterCatalog {
        var byID: [String: CharacterPackage] = [:]
        var shadowed: [CharacterPackage] = []

        for package in Self.packages(in: builtInDirectory, source: .builtIn, fileManager: fileManager) {
            byID[package.id] = package
        }
        for package in Self.packages(in: userDirectory, source: .user, fileManager: fileManager) {
            if let replaced = byID[package.id], replaced.source == .builtIn {
                shadowed.append(replaced)
            }
            byID[package.id] = package
        }

        let packages = byID.values.sorted {
            ($0.displayName.lowercased(), $0.id) < ($1.displayName.lowercased(), $1.id)
        }
        return CharacterCatalog(packages: packages, shadowed: shadowed)
    }

    // MARK: Reading a root

    private static func packages(
        in root: URL?,
        source: CharacterPackage.Source,
        fileManager: FileManager
    ) -> [CharacterPackage] {
        guard let root,
              let entries = try? fileManager.contentsOfDirectory(
                  at: root,
                  includingPropertiesForKeys: [.isDirectoryKey],
                  options: [.skipsHiddenFiles]
              )
        else { return [] }

        return entries
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .compactMap { load(packageAt: $0, source: source, fileManager: fileManager) }
    }

    /// Reads one folder as a package, or returns `nil` when the folder is not
    /// one — no manifest and no strips means somebody put an unrelated
    /// directory here, and inventing a broken character for it would be noise.
    public static func load(
        packageAt directory: URL,
        source: CharacterPackage.Source,
        fileManager: FileManager = .default
    ) -> CharacterPackage? {
        let folderName = directory.lastPathComponent
        let manifestURL = directory.appendingPathComponent("character.json", isDirectory: false)
        let strips = pngFiles(in: directory, fileManager: fileManager)

        var problems: [CharacterProblem] = []
        var manifest: CharacterManifest

        if let data = try? Data(contentsOf: manifestURL) {
            do {
                manifest = try JSONDecoder().decode(CharacterManifest.self, from: data)
            } catch {
                guard !strips.isEmpty else { return nil }
                problems.append(
                    .error("character.json could not be read: \(Self.describe(error))")
                )
                manifest = CharacterManifest(id: folderName)
            }
        } else {
            guard !strips.isEmpty else { return nil }
            problems.append(.error("No character.json in this folder."))
            manifest = CharacterManifest(id: folderName)
        }

        if manifest.id.isEmpty {
            problems.append(.warning("character.json has no id; using the folder name."))
            manifest.id = folderName
            if manifest.displayName.isEmpty { manifest.displayName = folderName }
        }
        if manifest.id != folderName {
            problems.append(
                .warning(
                    "The id is \"\(manifest.id)\" but the folder is named \"\(folderName)\". "
                        + "The id is what overrides a built-in, not the folder."
                )
            )
        }
        if manifest.displayName.isEmpty { manifest.displayName = manifest.id }
        if manifest.id == CharacterChoice.builtInToken {
            problems.append(
                .warning(
                    "\"\(CharacterChoice.builtInToken)\" is reserved for Auspex's own "
                        + "built-in figures, so this package can be automatic for a harness "
                        + "but can never be picked by hand. Give it another id."
                )
            )
        }

        if !CharacterManifest.supportedCells.contains(manifest.cell) {
            let supported = CharacterManifest.supportedCells.sorted()
                .map(String.init).joined(separator: " or ")
            problems.append(
                .error("cell is \(manifest.cell); it has to be \(supported).")
            )
        }
        if let harness = manifest.harness, Harness(rawValue: harness) == nil {
            problems.append(
                .warning(
                    "\"\(harness)\" is not a harness Auspex watches, so this character is "
                        + "never a default. It can still be chosen by hand."
                )
            )
        }
        if let accent = manifest.accent, !Self.isHexColour(accent) {
            problems.append(.warning("accent \"\(accent)\" is not a #RRGGBB colour."))
        }
        for name in manifest.unknownPoseNames {
            problems.append(
                .warning(pose: name, "\"\(name)\" is not a pose the scene draws; it is ignored.")
            )
        }

        let (poses, poseProblems) = readPoses(
            strips: strips,
            manifest: manifest,
            fileManager: fileManager
        )
        problems.append(contentsOf: poseProblems)

        for pose in CharacterPose.core where poses[pose.rawValue] == nil {
            problems.append(
                .warning(
                    pose: pose.rawValue,
                    "No \(pose.rawValue).png; that pose uses the built-in figures."
                )
            )
        }

        return CharacterPackage(
            manifest: manifest,
            directory: directory,
            source: source,
            poses: poses,
            problems: problems
        )
    }

    /// Measures every strip and reconciles it with what the manifest claimed.
    ///
    /// The pixels win. A manifest that says four frames over a six-frame strip
    /// is a stale manifest, and playing four frames of a six-frame walk cycle
    /// looks broken in a way that is hard to trace back to a JSON file — so the
    /// measured count is used and the discrepancy is reported.
    private static func readPoses(
        strips: [String: URL],
        manifest: CharacterManifest,
        fileManager: FileManager
    ) -> ([String: CharacterPackage.PoseFile], [CharacterProblem]) {
        var poses: [String: CharacterPackage.PoseFile] = [:]
        var problems: [CharacterProblem] = []
        let cell = manifest.cell

        for name in strips.keys.sorted() {
            guard let url = strips[name] else { continue }
            guard CharacterPose(rawValue: name) != nil else {
                problems.append(
                    .warning(pose: name, "\(name).png is not a pose the scene draws; it is ignored.")
                )
                continue
            }
            guard let size = imagePixelSize(at: url) else {
                problems.append(.error(pose: name, "\(name).png could not be read as an image."))
                continue
            }
            guard size.height == cell else {
                problems.append(
                    .error(
                        pose: name,
                        "\(name).png is \(size.width)×\(size.height); a strip is one row "
                            + "\(cell) pixels tall."
                    )
                )
                continue
            }
            guard size.width > 0, size.width % cell == 0 else {
                problems.append(
                    .error(
                        pose: name,
                        "\(name).png is \(size.width) pixels wide, which is not a whole number "
                            + "of \(cell)-pixel frames."
                    )
                )
                continue
            }

            let measured = size.width / cell
            let declared = manifest.poses[name]
            if let declared, declared.frames != measured {
                problems.append(
                    .warning(
                        pose: name,
                        "character.json declares \(declared.frames) frames for \(name); the "
                            + "strip holds \(measured). Using \(measured)."
                    )
                )
            } else if declared == nil {
                problems.append(
                    .warning(
                        pose: name,
                        "\(name).png is not listed in character.json; playing \(measured) "
                            + "frame\(measured == 1 ? "" : "s") at "
                            + "\(Int(CharacterPoseSpec.defaultFPS)) fps."
                    )
                )
            }

            poses[name] = CharacterPackage.PoseFile(
                name: name,
                url: url,
                cell: cell,
                frames: measured,
                fps: declared?.fps ?? CharacterPoseSpec.defaultFPS
            )
        }

        for (name, _) in manifest.poses where strips[name] == nil {
            guard CharacterPose(rawValue: name) != nil else { continue }
            // Reported once, by the core-pose sweep in `load`, for the eight
            // that matter. An optional pose declared but not drawn is worth a
            // line of its own.
            if CharacterPose(rawValue: name)?.isOptional == true {
                problems.append(
                    .warning(pose: name, "character.json lists \(name) but there is no \(name).png.")
                )
            }
        }

        return (poses, problems)
    }

    /// Every `<pose>.png` in a folder, keyed by the name without its extension.
    private static func pngFiles(in directory: URL, fileManager: FileManager) -> [String: URL] {
        guard let entries = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        ) else { return [:] }

        var result: [String: URL] = [:]
        for url in entries where url.pathExtension.lowercased() == "png" {
            result[url.deletingPathExtension().lastPathComponent] = url
        }
        return result
    }

    /// A PNG's pixel dimensions, read from its header rather than by decoding
    /// it. Scanning happens on every hot reload and a folder of forty strips
    /// should not cost forty full decodes.
    static func imagePixelSize(at url: URL) -> (width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int
        else { return nil }
        return (width, height)
    }

    private static func isHexColour(_ value: String) -> Bool {
        guard value.hasPrefix("#") else { return false }
        let digits = value.dropFirst()
        guard digits.count == 6 || digits.count == 8 else { return false }
        return digits.allSatisfy(\.isHexDigit)
    }

    private static func describe(_ error: any Error) -> String {
        if let error = error as? DecodingError {
            switch error {
            case .keyNotFound(let key, _): return "missing key \"\(key.stringValue)\""
            case .typeMismatch(_, let context), .valueNotFound(_, let context):
                let path = context.codingPath.map(\.stringValue).joined(separator: ".")
                return path.isEmpty ? context.debugDescription : "\(path): \(context.debugDescription)"
            case .dataCorrupted(let context):
                return context.debugDescription
            @unknown default:
                return "it is not valid JSON"
            }
        }
        return "it is not valid JSON"
    }
}

/// Every character Auspex can draw right now.
public struct CharacterCatalog: Sendable, Equatable {
    /// The resolved list: one package per id, the user's copy where there is
    /// one, sorted by the name a person reads.
    public var packages: [CharacterPackage]
    /// Built-ins a user package replaced, so the Settings pane can say so.
    public var shadowed: [CharacterPackage]

    public init(packages: [CharacterPackage] = [], shadowed: [CharacterPackage] = []) {
        self.packages = packages
        self.shadowed = shadowed
    }

    public var isEmpty: Bool { packages.isEmpty }

    public func package(id: String) -> CharacterPackage? {
        packages.first { $0.id == id }
    }

    /// Every package that names this harness, plus every package that names no
    /// harness at all — a pet is a legal choice for any desk.
    public func packages(for harness: Harness) -> [CharacterPackage] {
        packages.filter { $0.harness == harness || $0.harness == nil }
    }

    /// The package that claims `harness` on its own, ignoring every choice —
    /// what ``CharacterChoice/automatic`` resolves to.
    ///
    /// The conventional `<harness>-default` id wins when more than one package
    /// claims the harness, so a person experimenting with a second Codex
    /// character does not silently displace the shipped one. `nil` means
    /// nobody has drawn this harness yet.
    public func automaticPackage(for harness: Harness) -> CharacterPackage? {
        let claimed = packages.filter { $0.harness == harness && $0.isDrawable }
        let conventional = "\(harness.rawValue)-default"
        return claimed.first { $0.id == conventional } ?? claimed.first
    }

    /// The package a harness's people are drawn as.
    ///
    /// `nil` means the scene draws its procedural rig — either because that is
    /// what was *chosen*, or because nobody has drawn this harness. The scene
    /// treats the two identically, which is exactly why the choice has to be
    /// remembered as more than the absence of a package.
    public func package(for harness: Harness, selection: CharacterSelection) -> CharacterPackage? {
        switch selection.choice(for: harness) {
        case .builtIn:
            return nil
        case .package(let id):
            // A choice pointing at a package that has since been deleted — or
            // one that cannot be drawn — is ignored, not obeyed. Falling back
            // to automatic rather than to the rig keeps a broken folder from
            // looking like a deliberate preference for rectangles.
            if let package = package(id: id), package.isDrawable { return package }
            return automaticPackage(for: harness)
        case .automatic:
            return automaticPackage(for: harness)
        }
    }

    /// The package one session's agent is drawn as: its own override if it has
    /// one, otherwise its harness's.
    public func package(
        for key: SessionKey,
        selection: CharacterSelection
    ) -> CharacterPackage? {
        switch selection.choice(for: key) {
        case .builtIn:
            return nil
        case .package(let id):
            if let package = package(id: id), package.isDrawable { return package }
            return package(for: key.harness, selection: selection)
        case .automatic:
            return package(for: key.harness, selection: selection)
        }
    }

    /// What a harness actually ends up wearing, with
    /// ``CharacterChoice/automatic`` resolved to the answer it stands for.
    /// Never ``CharacterChoice/automatic`` itself.
    public func resolvedChoice(
        for harness: Harness,
        selection: CharacterSelection
    ) -> CharacterChoice {
        package(for: harness, selection: selection).map { .package($0.id) } ?? .builtIn
    }

    /// What one session's agent ends up wearing.
    public func resolvedChoice(
        for key: SessionKey,
        selection: CharacterSelection
    ) -> CharacterChoice {
        package(for: key, selection: selection).map { .package($0.id) } ?? .builtIn
    }
}
