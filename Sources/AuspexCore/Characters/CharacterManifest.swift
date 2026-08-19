import AgentSessionKit
import Foundation

/// What a character is. The two kinds share one format and differ only in how
/// they are drawn, which is the point: a person who would rather watch eight
/// cats than eight programmers should not need a second file format.
public enum CharacterKind: String, Codable, Sendable, CaseIterable {
    case person
    case pet

    /// The word the Settings pane shows.
    public var displayName: String {
        switch self {
        case .person: "Person"
        case .pet: "Pet"
        }
    }
}

/// Where a frame's origin sits.
///
/// One case today, and it is not an oversight: every character is drawn
/// standing or sitting on the bottom edge of its cell so that a 32-pixel
/// figure and a 48-pixel one land their feet on the same seat. The enum exists
/// so the manifest key means something rather than being a string nobody reads.
public enum CharacterAnchor: String, Codable, Sendable, CaseIterable {
    case bottomCenter
}

/// The scene's animation vocabulary, as it appears on disk.
///
/// Deliberately not the session state machine: `toolCalling` and `writingFile`
/// are both hands-on-keys, they differ in tempo. The eight in ``core`` are what
/// a complete character needs; the four in ``optional`` are for a scene that
/// moves people between desks, and a package without them is not incomplete.
public enum CharacterPose: String, Codable, Sendable, CaseIterable, Hashable {
    case idle
    case thinking
    case typing
    case writing
    case delegating
    case blocked
    case stale
    case ended
    case walkDown
    case walkRight
    case walkUp
    case spawn

    /// The poses every character is expected to carry.
    public static let core: [CharacterPose] = [
        .idle, .thinking, .typing, .writing, .delegating, .blocked, .stale, .ended
    ]

    /// The poses that are welcome but never missed.
    public static let optional: [CharacterPose] = [.walkDown, .walkRight, .walkUp, .spawn]

    /// Whether a package can omit this pose without being told about it.
    public var isOptional: Bool { Self.optional.contains(self) }
}

/// One animation's shape: how many frames the strip holds and how fast they
/// play.
public struct CharacterPoseSpec: Codable, Sendable, Equatable, Hashable {
    /// Frames in the strip, left to right.
    public var frames: Int
    /// Frames per second.
    public var fps: Double

    /// The frame rate used when a manifest entry omits `fps`.
    public static let defaultFPS: Double = 8

    public init(frames: Int, fps: Double = CharacterPoseSpec.defaultFPS) {
        self.frames = frames
        self.fps = fps
    }

    /// How long one frame stays on screen.
    public var timePerFrame: TimeInterval {
        fps > 0 ? 1 / fps : 1 / Self.defaultFPS
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // A strip with no declared frame count is a single-frame pose, which is
        // legal: `stale` and `ended` are often one drawing.
        frames = max(1, try container.decodeIfPresent(Int.self, forKey: .frames) ?? 1)
        fps = try container.decodeIfPresent(Double.self, forKey: .fps) ?? Self.defaultFPS
    }
}

/// `character.json` — the whole of a character package's declared shape.
///
/// The format is specified in `docs/CHARACTERS.md`; this type is that document
/// as code. Decoding is deliberately forgiving — a missing `kind`, `anchor`, or
/// `cell` takes the documented default rather than rejecting the package —
/// because the loader's contract is that a package a person can see in the
/// Settings pane is a package they can be told what is wrong with. Anything
/// actually wrong is reported by ``CharacterLibrary`` as a
/// ``CharacterProblem``, not thrown.
public struct CharacterManifest: Codable, Sendable, Equatable {
    /// Stable identity. A user package with the same id replaces the built-in.
    public var id: String
    /// The name a person reads. Falls back to ``id`` when the file omits it.
    public var displayName: String
    /// Person or pet.
    public var kind: CharacterKind
    /// The harness this character is the default for, as the harness's own
    /// raw name (`claudeCode`, `codex`, …). Absent for a character that is
    /// only ever chosen by hand.
    public var harness: String?
    /// The character's main colour, `#RRGGBB`. Used by surfaces outside the
    /// scene that name the character.
    public var accent: String?
    /// The square cell's edge, in pixels. 32 or 48.
    public var cell: Int
    /// Where the cell's origin sits.
    public var anchor: CharacterAnchor
    /// Pose name to strip shape. Keyed by the raw string rather than by
    /// ``CharacterPose`` so a name nobody recognises survives decoding and can
    /// be reported instead of silently dropped.
    public var poses: [String: CharacterPoseSpec]

    /// The cell sizes the scene knows how to place.
    public static let supportedCells: Set<Int> = [32, 48]

    /// The cell size assumed when the manifest omits one.
    public static let defaultCell = 32

    public init(
        id: String,
        displayName: String? = nil,
        kind: CharacterKind = .person,
        harness: String? = nil,
        accent: String? = nil,
        cell: Int = CharacterManifest.defaultCell,
        anchor: CharacterAnchor = .bottomCenter,
        poses: [String: CharacterPoseSpec] = [:]
    ) {
        self.id = id
        self.displayName = displayName ?? id
        self.kind = kind
        self.harness = harness
        self.accent = accent
        self.cell = cell
        self.anchor = anchor
        self.poses = poses
    }

    /// The harness this character is bound to, when the name is one Auspex
    /// watches.
    public var boundHarness: Harness? {
        harness.flatMap(Harness.init(rawValue:))
    }

    /// The declared shape of one pose, by enum rather than by string.
    public func spec(for pose: CharacterPose) -> CharacterPoseSpec? {
        poses[pose.rawValue]
    }

    /// Pose names in the file that the scene has no vocabulary for.
    public var unknownPoseNames: [String] {
        poses.keys.filter { CharacterPose(rawValue: $0) == nil }.sorted()
    }

    private enum CodingKeys: String, CodingKey {
        case id, displayName, kind, harness, accent, cell, anchor, poses
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = (try container.decodeIfPresent(String.self, forKey: .id) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let name = (try container.decodeIfPresent(String.self, forKey: .displayName) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        displayName = name.isEmpty ? id : name
        // An unrecognised `kind` or `anchor` is a typo in a hand-written file,
        // not a reason to make the character disappear from the list where a
        // person could see the typo.
        kind = (try container.decodeIfPresent(String.self, forKey: .kind))
            .flatMap(CharacterKind.init(rawValue:)) ?? .person
        harness = try container.decodeIfPresent(String.self, forKey: .harness)
        accent = try container.decodeIfPresent(String.self, forKey: .accent)
        cell = try container.decodeIfPresent(Int.self, forKey: .cell) ?? Self.defaultCell
        anchor = (try container.decodeIfPresent(String.self, forKey: .anchor))
            .flatMap(CharacterAnchor.init(rawValue:)) ?? .bottomCenter
        poses = try container.decodeIfPresent([String: CharacterPoseSpec].self, forKey: .poses) ?? [:]
    }
}
