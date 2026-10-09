import AgentSessionKit
import AgentSessionLive
import Foundation
import GRDB

/// Removes, once, the `projects` rows earlier builds wrote for directories
/// that are scratch.
///
/// Until ``ScratchRules`` existed, every working directory became a project
/// row — the home directory, every Codex desktop chat folder, every Claude
/// Desktop scratch workspace, every container path. The live path no longer
/// writes them, but the rows it already wrote stay until something removes
/// them, and they keep their names in the sidebar's name map and their
/// sessions pointing at them.
///
/// ## What goes, and what stays
///
/// A row goes when the same rules a live placement asks would call its
/// directory scratch — with the harnesses of the sessions in it, because the
/// Codex desktop tree is scratch only for the two harnesses that make it — or
/// when the directory is not on this Mac. The sessions in it stay: their
/// `project_id` is set to `NULL`, which is also what the foreign key does on
/// its own, and is done explicitly so the answer does not depend on a pragma.
///
/// A row a person's own project claims stays, whatever the rules say. A
/// project made in the Projects page is a statement about that folder, and a
/// clean-up is not entitled to overrule it.
///
/// ## Why once
///
/// The rules are the live path's from here on; this only catches up with what
/// was written before them. Finished is recorded in `meta` under
/// ``StoreMetaKey/scratchProjectsPurged``, so every later launch costs one
/// indexed read. A folder a person marks as scratch later loses its sessions'
/// assignments through the live path, and its row is harmless.
public struct ScratchProjectPurge: Sendable {
    /// What a pass did.
    public struct Report: Sendable, Equatable {
        /// `projects` rows removed.
        public var projectsRemoved: Int
        /// Sessions that pointed at one of them and now point at none.
        public var sessionsUnassigned: Int

        public init(projectsRemoved: Int = 0, sessionsUnassigned: Int = 0) {
            self.projectsRemoved = projectsRemoved
            self.sessionsUnassigned = sessionsUnassigned
        }
    }

    public let dbWriter: any DatabaseWriter

    public init(dbWriter: any DatabaseWriter) {
        self.dbWriter = dbWriter
    }

    public init(store: AuspexStore) {
        self.dbWriter = store.dbWriter
    }

    /// Whether this store has already been purged.
    public func hasRun() async throws -> Bool {
        try await dbWriter.read { db in
            try String.fetchOne(
                db,
                sql: "SELECT value FROM meta WHERE key = ?",
                arguments: [StoreMetaKey.scratchProjectsPurged]
            ) != nil
        }
    }

    /// Removes every scratch project row, unless this store already has.
    ///
    /// - Parameters:
    ///   - rules: the rules the live path places with.
    ///   - protectedRoots: the roots of the person's own projects. A row at or
    ///     under one of them is kept.
    ///   - directoryExists: asked once per remaining row, off the writer.
    ///   - now: what the stamp records.
    /// - Returns: what went, or `nil` when the pass had already run.
    @discardableResult
    public func runIfNeeded(
        rules: ScratchRules,
        protectedRoots: [String],
        directoryExists: @Sendable (String) -> Bool = PlacementService.directoryExists,
        now: Date = Date()
    ) async throws -> Report? {
        guard try await !hasRun() else { return nil }

        let candidates = try await dbWriter.read { db in try Self.candidates(db) }
        let protected = protectedRoots.map(ProjectPath.normalize).filter { !$0.isEmpty }
        // Decided before the write, so the filesystem is never asked while
        // the writer is held.
        let doomed = candidates.filter { row in
            guard !protected.contains(where: { ProjectPath.contains($0, row.rootPath) }) else {
                return false
            }
            return Self.isScratch(row, rules: rules, directoryExists: directoryExists)
        }.map(\.id)

        return try await dbWriter.write { db in
            var report = Report()
            for id in doomed {
                try db.execute(
                    sql: """
                        UPDATE sessions SET project_id = NULL, worktree_id = NULL
                        WHERE project_id = ?
                        """,
                    arguments: [id]
                )
                report.sessionsUnassigned += db.changesCount
                try db.execute(sql: "DELETE FROM worktrees WHERE project_id = ?", arguments: [id])
                try db.execute(sql: "DELETE FROM projects WHERE id = ?", arguments: [id])
                report.projectsRemoved += db.changesCount
            }
            try db.execute(
                sql: """
                    INSERT INTO meta (key, value) VALUES (?, ?)
                    ON CONFLICT(key) DO UPDATE SET value = excluded.value
                    """,
                arguments: [StoreMetaKey.scratchProjectsPurged, String(now.timeIntervalSince1970)]
            )
            return report
        }
    }

    // MARK: - Deciding

    /// One `projects` row, with the harnesses of the sessions in it.
    struct Candidate: Sendable {
        let id: Int64
        let rootPath: String
        let harnesses: Set<Harness>
    }

    private static func candidates(_ db: Database) throws -> [Candidate] {
        var harnesses: [Int64: Set<Harness>] = [:]
        let pairs = try Row.fetchAll(db, sql: """
            SELECT DISTINCT project_id, harness FROM sessions WHERE project_id IS NOT NULL
            """)
        for row in pairs {
            guard let id = row["project_id"] as Int64?,
                  let raw = row["harness"] as String?,
                  let harness = Harness(rawValue: raw)
            else { continue }
            harnesses[id, default: []].insert(harness)
        }
        return try Row.fetchAll(db, sql: "SELECT id, root_path FROM projects").compactMap { row in
            guard let id = row["id"] as Int64?, let root = row["root_path"] as String? else {
                return nil
            }
            return Candidate(id: id, rootPath: root, harnesses: harnesses[id] ?? [])
        }
    }

    /// Whether a row's directory is scratch for every harness that has a
    /// session in it — or, for a row nobody is in, for any harness at all.
    static func isScratch(
        _ row: Candidate,
        rules: ScratchRules,
        directoryExists: (String) -> Bool
    ) -> Bool {
        let matched: Bool
        if row.harnesses.isEmpty {
            matched = rules.match(cwd: row.rootPath, harness: nil) != nil
        } else {
            matched = row.harnesses.allSatisfy { rules.match(cwd: row.rootPath, harness: $0) != nil }
        }
        if matched { return true }
        // A row whose directory is gone names nothing on this Mac. A root is
        // either a repository or a plain directory, and either way the live
        // path would place a session there as scratch now.
        return row.rootPath.hasPrefix("/") && !directoryExists(row.rootPath)
    }
}
