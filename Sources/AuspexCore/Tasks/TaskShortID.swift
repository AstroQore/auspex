import Foundation

/// The handle a person reads, points at, and says out loud: `AUX-3f9k`.
///
/// ## Why a task needs one at all
///
/// A row id is a number that grows, and a number that grows is a name nobody
/// can hold in their head for the length of a sentence. Every board that has
/// ever worked has had a short opaque handle instead, and the reason is not
/// database hygiene — it is that "close AUX-3f9k" is a thing a person can type
/// into a palette and an agent can put in a brief, and "close task 147" is a
/// thing they get wrong on a board that has three hundred rows.
///
/// ## Why it is derived rather than stored
///
/// It exists for every row the ledger has ever written, including the ones
/// written before this type did, and it cannot drift from the row it names.
/// A stored handle would need a migration, a uniqueness constraint, and a
/// decision about what happens when two rows collide; a derived one needs none
/// of those because it is a *rendering* of the identity rather than a second
/// identity beside it.
///
/// The same function names an implicit unit — a delegation tree nobody filed a
/// task for — from its root session's key, which is what lets the board show
/// one vocabulary whether or not an agent registered its work.
///
/// ## Collisions
///
/// Four characters of a 32-character alphabet is about a million handles. Two
/// tasks on one machine sharing one is possible and harmless: the handle is a
/// label and a search term, never a key. Everything that has to be exact — the
/// store, the MCP surface, the drag payloads — uses the id.
public enum TaskShortID {
    /// The three letters in front. Auspex's own, so a handle pasted into a
    /// brief says which board it came from.
    public static let prefix = "AUX"

    /// Crockford's alphabet, which is the one that survives being read aloud
    /// and written down: no `i`, `l`, `o` or `u`, so nothing is mistaken for a
    /// digit and nothing accidentally spells a word.
    static let alphabet = Array("0123456789abcdefghjkmnpqrstvwxyz")

    /// How many characters after the dash.
    static let length = 4

    /// The handle for a ledger task.
    public static func forTask(_ id: Int64) -> String {
        make(seed: "task:\(id)")
    }

    /// The handle for a unit the board derived rather than an agent filed —
    /// see ``TaskUnit``. Keyed on the root session, so the handle survives the
    /// unit being promoted into a real task on any surface that keeps showing
    /// the old one.
    public static func forImplicit(_ rootKey: String) -> String {
        make(seed: "implicit:\(rootKey)")
    }

    /// The handle for any seed string.
    public static func make(seed: String) -> String {
        var hash = fnv1a(seed)
        var characters: [Character] = []
        characters.reserveCapacity(length)
        for _ in 0..<length {
            characters.append(alphabet[Int(hash % UInt64(alphabet.count))])
            hash /= UInt64(alphabet.count)
        }
        return prefix + "-" + String(characters)
    }

    /// Whether a string looks like one of these — what the command palette
    /// checks before it treats a query as a handle rather than as words.
    public static func looksLikeHandle(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count == prefix.count + 1 + length else { return false }
        guard trimmed.uppercased().hasPrefix(prefix + "-") else { return false }
        return trimmed.suffix(length).allSatisfy { alphabet.contains(Character($0.lowercased())) }
    }

    /// FNV-1a, 64-bit. Chosen because it is four lines, has no dependencies,
    /// and is stable across builds and architectures — which `Hasher` is
    /// explicitly not, and a handle that changed when the process restarted
    /// would be worse than no handle.
    static func fnv1a(_ text: String) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x1000_0000_01b3
        }
        return hash
    }
}
