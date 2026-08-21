import AgentSessionLive
import Foundation

/// Brings a stored `snapshot_json` forward to event schema 3.
///
/// The same shape of problem ``SnapshotBriefMigration`` solved for schema 2,
/// and the same answer, because the answer is the right one: a blob is JSON,
/// and adding the key a newer decoder asks for is a migration rather than a
/// workaround.
///
/// Schema 3 added three fields to `SessionSnapshot`. Two of them —
/// `contextUsage` and `quota` — are optional, so a blob written before them
/// decodes with both `nil`, which is exactly the honest answer for a session
/// Auspex was watching before it knew to ask how full the window was. The
/// third, `compactions`, is a non-optional `Int`, and that one field is what
/// makes every schema-2 blob undecodable: the synthesized `init(from:)` asks
/// for a key that is not there and throws.
///
/// So the migration writes `"compactions": 0` and nothing else. Zero is not a
/// measurement and does not pretend to be one — the counter is folded from
/// `compaction` events, and the ones this session already had were folded into
/// a snapshot written by a build that had nowhere to put the total. Re-seeding
/// from the event log would recover it, and would also cascade away the tool
/// ledger and the trace of every session whose transcript has since rotated
/// away. A row that says "compacted zero times" and starts counting from the
/// next one is a smaller lie than a board that lost half its history.
enum SnapshotContextMigration {
    /// The key schema 3 added that a decoder cannot do without.
    static let compactionsKey = "compactions"

    /// `json` with `"compactions": 0` added, or `nil` when it already has the
    /// key — or is not a JSON object at all, which is a row nothing can
    /// rescue.
    ///
    /// Pure and total: no clock, no database, no throw. `nil` means "leave the
    /// row alone", so a caller can run it over every row without deciding
    /// first which ones need it.
    static func addingCompactions(to json: String) -> String? {
        guard var object = (try? JSONSerialization.jsonObject(with: Data(json.utf8)))
            as? [String: Any] else { return nil }
        guard object[compactionsKey] == nil else { return nil }
        object[compactionsKey] = 0
        guard let data = try? JSONSerialization.data(
            withJSONObject: object, options: [.sortedKeys]
        ) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}
