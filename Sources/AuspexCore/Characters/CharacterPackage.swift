import AgentSessionKit
import Foundation

/// Something wrong with a character package, as a value.
///
/// Loading art is not allowed to fail loudly. The scene has a procedural rig
/// behind every pose, so a package with a mistake in it should cost the person
/// who wrote it one wrong-looking pose and one sentence explaining why — never
/// a crash, and never a session that silently vanishes off the board. So every
/// check produces one of these and the package is still returned.
public struct CharacterProblem: Sendable, Equatable, Hashable, Identifiable {
    public enum Severity: String, Sendable, Equatable, Hashable, Comparable, CaseIterable {
        /// The package works; something in it is ignored or guessed at.
        case warning
        /// The package cannot be drawn as declared.
        case error

        public static func < (lhs: Severity, rhs: Severity) -> Bool {
            lhs == .warning && rhs == .error
        }
    }

    public var severity: Severity
    /// The pose this is about, when it is about one.
    public var pose: String?
    /// A sentence a person can act on.
    public var message: String

    public var id: String { "\(severity.rawValue)|\(pose ?? "-")|\(message)" }

    public init(severity: Severity, pose: String? = nil, message: String) {
        self.severity = severity
        self.pose = pose
        self.message = message
    }

    public static func warning(pose: String? = nil, _ message: String) -> CharacterProblem {
        CharacterProblem(severity: .warning, pose: pose, message: message)
    }

    public static func error(pose: String? = nil, _ message: String) -> CharacterProblem {
        CharacterProblem(severity: .error, pose: pose, message: message)
    }
}

/// A character package on disk: its manifest, its folder, and the strips that
/// actually exist inside it.
///
/// The distinction between *declared* and *present* is the whole reason this
/// type exists rather than the manifest being handed around on its own. Art
/// arrives one pose at a time — the handoff document is explicit that `blocked`
/// comes first — so a package whose manifest lists eight poses and whose folder
/// holds one is the normal state of things for weeks, and the loader has to
/// describe that difference rather than treat it as breakage.
public struct CharacterPackage: Sendable, Equatable, Identifiable {
    /// Where a package was found.
    public enum Source: String, Sendable, Equatable, CaseIterable {
        /// Inside `Auspex.app/Contents/Resources/Characters`.
        case builtIn
        /// Inside `~/.auspex/characters`.
        case user

        public var displayName: String {
            switch self {
            case .builtIn: "Built-in"
            case .user: "User"
            }
        }
    }

    /// One pose that exists as a file.
    public struct PoseFile: Sendable, Equatable {
        /// The pose's name, as spelled on disk.
        public var name: String
        /// The strip.
        public var url: URL
        /// The cell edge this strip was measured against, in pixels.
        public var cell: Int
        /// Frames the strip actually holds — width ÷ cell, not what the
        /// manifest claimed. The pixels are the truth.
        public var frames: Int
        /// Frames per second, from the manifest.
        public var fps: Double

        public init(name: String, url: URL, cell: Int, frames: Int, fps: Double) {
            self.name = name
            self.url = url
            self.cell = cell
            self.frames = frames
            self.fps = fps
        }

        /// The typed pose, when the name is one the scene knows.
        public var pose: CharacterPose? { CharacterPose(rawValue: name) }

        /// How long one frame stays on screen.
        public var timePerFrame: TimeInterval {
            fps > 0 ? 1 / fps : 1 / CharacterPoseSpec.defaultFPS
        }
    }

    public var manifest: CharacterManifest
    /// The package's own folder.
    public var directory: URL
    public var source: Source
    /// Poses that exist as files, keyed by pose name.
    public var poses: [String: PoseFile]
    /// Everything the loader wants to tell the person who wrote the package.
    public var problems: [CharacterProblem]

    public init(
        manifest: CharacterManifest,
        directory: URL,
        source: Source,
        poses: [String: PoseFile] = [:],
        problems: [CharacterProblem] = []
    ) {
        self.manifest = manifest
        self.directory = directory
        self.source = source
        self.poses = poses
        self.problems = problems
    }

    public var id: String { manifest.id }

    /// The name a person reads.
    public var displayName: String {
        manifest.displayName.isEmpty ? manifest.id : manifest.displayName
    }

    /// The harness this package is the default for.
    public var harness: Harness? { manifest.boundHarness }

    /// The square cell's edge, in pixels.
    public var cell: Int { manifest.cell }

    /// `true` when something in the package cannot be drawn as declared.
    public var hasErrors: Bool { problems.contains { $0.severity == .error } }

    /// `true` when at least one pose can be drawn. A package with no strips at
    /// all is still listed — a person who made the folder should see it — but
    /// nothing in the scene will ever choose it.
    public var isDrawable: Bool { !hasErrors && !poses.isEmpty }

    /// The strip for one pose, or `nil` when nobody has drawn it and the
    /// caller should fall back to the procedural rig.
    public func file(for pose: CharacterPose) -> PoseFile? { poses[pose.rawValue] }

    /// The pose a preview should use: `idle` when it exists, otherwise
    /// whichever core pose does, in the order a character is normally drawn.
    public var previewPose: PoseFile? {
        for pose in CharacterPose.core where poses[pose.rawValue] != nil {
            return poses[pose.rawValue]
        }
        return poses.values.sorted { $0.name < $1.name }.first
    }

    /// Core poses with no file, for the Settings pane's "still to draw" line.
    public var missingCorePoses: [CharacterPose] {
        CharacterPose.core.filter { poses[$0.rawValue] == nil }
    }
}
