import AgentSessionLive
import Foundation

/// Brings a stored `snapshot_json` forward when the event model gains a field.
///
/// `sessions.snapshot_json` holds a `SessionSnapshot` encoded structurally, and
/// `AgentSessionLive.eventSchemaVersion` exists precisely because that makes it
/// brittle: adding a *non-optional* field to the snapshot makes every blob
/// written before it undecodable, because the synthesized `init(from:)` asks
/// for a key that is not there.
///
/// Schema 2 added ``SessionBrief``. Every one of its fields is optional, so a
/// blob that carries `"brief": {}` decodes into an empty brief — which is the
/// honest answer for a session Auspex recorded before it knew to ask what the
/// session had been told to do. The next tail of that transcript fills it in.
///
/// The alternative was to drop the rows and re-seed from the transcripts. That
/// loses the event log and the tool-call ledger to a cascade, for sessions
/// whose transcripts may have been rotated away, and it does it silently. A
/// blob is JSON; adding a key to it is a migration, not a workaround.
enum SnapshotBriefMigration {
    /// The key schema 2 added.
    static let briefKey = "brief"

    /// `json` with an empty `brief` object added, or `nil` when it already has
    /// one — or is not an object at all, which is a row nothing can rescue.
    ///
    /// Pure and total: no clock, no database, no throw. `nil` means "leave the
    /// row alone", which is why the caller can run it over every row without
    /// deciding first which ones need it.
    static func addingBrief(to json: String) -> String? {
        guard var object = (try? JSONSerialization.jsonObject(with: Data(json.utf8)))
            as? [String: Any] else { return nil }
        guard object[briefKey] == nil else { return nil }
        object[briefKey] = [String: Any]()
        guard let data = try? JSONSerialization.data(
            withJSONObject: object, options: [.sortedKeys]
        ) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}

/// The `meta` keys Auspex stores about the shape of what it wrote.
public enum StoreMetaKey {
    /// The ``AgentSessionLive/eventSchemaVersion`` the stored snapshots were
    /// written by.
    ///
    /// Recorded so that a mismatch is a fact the app can read rather than a
    /// decode error it has to infer from. A bump still needs its own migration
    /// — this is the diagnostic, not the mechanism.
    public static let eventSchemaVersion = "event_schema_version"

    /// The event schema the last ``BriefBackfill`` pass ran under.
    ///
    /// A version rather than a boolean, because a schema bump can change what
    /// the same rows fold into and a store stamped "done" would never find out.
    /// Absent on a store that has never had a pass.
    public static let briefBackfill = "brief_backfill_schema_version"
}
