import AgentSessionKit
import AgentSessionLive
import Foundation

/// What a harness's people — or one session's agent — are drawn as.
///
/// Three answers, and the middle one is why this is an enum rather than an
/// optional package id. "Nothing chosen" and "the built-in rig chosen" look
/// identical in a file of ids and mean opposite things: the first says *pick
/// for me, and keep picking*, so the day a Codex package is installed the Codex
/// desks wear it; the second says *these pixel people are what I want*, which
/// no amount of art arriving is allowed to overrule.
public enum CharacterChoice: Sendable, Equatable, Hashable {
    /// Whatever the catalog picks: the package that claims the harness, and
    /// the built-in rig when none does. The default, and the only choice whose
    /// meaning changes when a folder is dropped into `~/.auspex/characters`.
    case automatic
    /// Auspex's own procedural figures — the sixteen-pixel people composed in
    /// code from the harness's accent. Always installed, never missing a pose.
    case builtIn
    /// One package, by id. Honoured while that package is installed and
    /// drawable, and ignored rather than obeyed once it is neither.
    case package(String)

    /// What ``builtIn`` is written as in `character-selection.json`.
    ///
    /// `@` opens a namespace no package should take. Every other value in that
    /// file is a package id, so the rig needs a spelling that cannot collide
    /// with a folder somebody made — and one a person reading the file can see
    /// is not a folder.
    public static let builtInToken = "@built-in"

    /// The name a person reads for the rig, everywhere it is named.
    public static let builtInDisplayName = "Auspex built-in"

    /// Reads one stored value.
    ///
    /// A missing or empty value is ``automatic``, which is what makes a
    /// selection file written before the rig was selectable still mean exactly
    /// what it meant when it was written.
    public init(stored: String?) {
        guard let stored, !stored.isEmpty else {
            self = .automatic
            return
        }
        self = stored == Self.builtInToken ? .builtIn : .package(stored)
    }

    /// What to write, or `nil` when the key should not be there at all.
    public var stored: String? {
        switch self {
        case .automatic: nil
        case .builtIn: Self.builtInToken
        case .package(let id): id
        }
    }

    /// The package id this names, when it names one.
    public var packageID: String? {
        if case .package(let id) = self { return id }
        return nil
    }

    public var isAutomatic: Bool { self == .automatic }
}

/// Who wears what.
///
/// Two levels, and the second one is why this is a type rather than a
/// dictionary. A harness default answers "draw every Codex session as this
/// person", which is the setting almost everybody will ever touch. A session
/// override answers "this one long-running agent is the one I keep losing on
/// the wall, give it the cat" — a per-desk exception that has to survive a
/// relaunch without becoming a second way of setting the default.
///
/// Both halves are keyed by strings rather than by `Harness` or `SessionKey`
/// so the file on disk is a flat JSON object a person can read and edit, and so
/// a harness Auspex no longer knows about does not make the file undecodable.
public struct CharacterSelection: Codable, Sendable, Equatable {
    /// Harness raw name → character id, or ``CharacterChoice/builtInToken``.
    /// A harness with no entry is on ``CharacterChoice/automatic``.
    public var defaultsByHarness: [String: String]
    /// `"<harness>:<session id>"` → character id, or
    /// ``CharacterChoice/builtInToken``.
    public var overridesBySession: [String: String]

    public init(
        defaultsByHarness: [String: String] = [:],
        overridesBySession: [String: String] = [:]
    ) {
        self.defaultsByHarness = defaultsByHarness
        self.overridesBySession = overridesBySession
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        defaultsByHarness = try container
            .decodeIfPresent([String: String].self, forKey: .defaultsByHarness) ?? [:]
        overridesBySession = try container
            .decodeIfPresent([String: String].self, forKey: .overridesBySession) ?? [:]
    }

    public var isEmpty: Bool { defaultsByHarness.isEmpty && overridesBySession.isEmpty }

    // MARK: Harness defaults

    public func choice(for harness: Harness) -> CharacterChoice {
        CharacterChoice(stored: defaultsByHarness[harness.rawValue])
    }

    /// Sets a harness's default. ``CharacterChoice/automatic`` removes the key
    /// rather than storing a word for "no answer", which is what keeps the
    /// file readable and keeps an untouched harness indistinguishable from one
    /// somebody set back to automatic.
    public mutating func setChoice(_ choice: CharacterChoice, for harness: Harness) {
        defaultsByHarness[harness.rawValue] = choice.stored
    }

    // MARK: Session overrides

    public func choice(for key: SessionKey) -> CharacterChoice {
        CharacterChoice(stored: overridesBySession[key.description])
    }

    public mutating func setChoice(_ choice: CharacterChoice, for key: SessionKey) {
        overridesBySession[key.description] = choice.stored
    }

    /// Drops every reference to a character that no longer exists, so a
    /// deleted package does not leave the file pointing at nothing.
    ///
    /// The built-in token survives every prune: it names no package, so no
    /// package going missing can strand it.
    public mutating func prune(keeping ids: Set<String>) {
        func survives(_ stored: String) -> Bool {
            stored == CharacterChoice.builtInToken || ids.contains(stored)
        }
        defaultsByHarness = defaultsByHarness.filter { survives($0.value) }
        overridesBySession = overridesBySession.filter { survives($0.value) }
    }
}

/// `~/.auspex/character-selection.json`, read and written through
/// ``AuspexPaths``.
///
/// Reading never fails: a missing file is an empty selection, and so is a
/// corrupt one. The alternative — refusing to draw the office because a
/// preferences file has a stray comma in it — is not a trade any board should
/// make. Writing does throw, because a person who just picked a character and
/// silently did not get it saved is owed the error.
public struct CharacterSelectionStore: Sendable {
    private let paths: AuspexPaths

    public init(paths: AuspexPaths = .default) {
        self.paths = paths
    }

    public var url: URL { paths.characterSelectionURL }

    public func load() -> CharacterSelection {
        guard let data = try? Data(contentsOf: paths.characterSelectionURL),
              let selection = try? JSONDecoder().decode(CharacterSelection.self, from: data)
        else { return CharacterSelection() }
        return selection
    }

    public func save(_ selection: CharacterSelection) throws {
        try paths.ensureBaseDirectory()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(selection)
        // Atomic: the scene reloads this file whenever the folder it watches
        // changes, and a half-written JSON object read mid-save would blank
        // every choice on the board for a frame.
        try data.write(to: paths.characterSelectionURL, options: [.atomic])
    }
}
