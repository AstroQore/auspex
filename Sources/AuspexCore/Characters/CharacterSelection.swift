import AgentSessionKit
import AgentSessionLive
import Foundation

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
    /// Harness raw name → character id.
    public var defaultsByHarness: [String: String]
    /// `"<harness>:<session id>"` → character id.
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

    public func characterID(for harness: Harness) -> String? {
        defaultsByHarness[harness.rawValue]
    }

    /// Sets a harness's default, or clears it when `id` is `nil` — clearing
    /// means "whatever package claims this harness", not "no character".
    public mutating func setCharacterID(_ id: String?, for harness: Harness) {
        defaultsByHarness[harness.rawValue] = id
    }

    // MARK: Session overrides

    public func characterID(for key: SessionKey) -> String? {
        overridesBySession[key.description]
    }

    public mutating func setCharacterID(_ id: String?, for key: SessionKey) {
        overridesBySession[key.description] = id
    }

    /// Drops every reference to a character that no longer exists, so a
    /// deleted package does not leave the file pointing at nothing.
    public mutating func prune(keeping ids: Set<String>) {
        defaultsByHarness = defaultsByHarness.filter { ids.contains($0.value) }
        overridesBySession = overridesBySession.filter { ids.contains($0.value) }
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
