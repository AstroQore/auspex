import AgentSessionKit
import AgentSessionLive
import Foundation
import GRDB

/// Folds, once, the `projects` rows earlier builds wrote for plain directories
/// into the workspace each one belongs to.
///
/// Until ``ProjectRollup`` existed, a directory in no repository was its own
/// project, and a job that ran in a fresh folder every hour wrote a row per
/// run. The live path no longer does; this catches up with what it already
/// wrote. Afterwards `projects` holds three kinds of row and no others: git
/// repositories, the person's own project folders, and workspace roots.
///
/// ## What happens to a row
///
/// Each row is asked the question a live placement asks of a plain directory
/// — ``ProjectRollup/place(directory:gitRoot:harness:userRoots:rules:directoryExists:)``
/// with no repository, once per harness that has a session in it:
///
/// - **A repository row** (`git_root` set) is not touched.
/// - **A row at or under one of the person's project roots** is not touched.
///   A project made in the Projects page is a statement about that folder.
/// - **A row whose root is its own workspace root** is already what the live
///   path would write, and stays.
/// - **A row under a workspace root** is merged into that root's row, which
///   is created when there is none: its sessions point at the root, its
///   worktree rows (a plain directory has none, but nothing is dropped on that
///   assumption) move with them, and the row is deleted.
/// - **A row that is no project at all** — scratch for every harness in it,
///   or rolled up to a root that is not on this Mac — is deleted, and its
///   sessions point at no project. That is the Projectless section.
///
/// ## Tasks follow
///
/// A task or milestone filed under a merged row's root is refiled under the
/// workspace root, in the same transaction as the row it followed — so a pass
/// cut short never leaves a task pointing at a row that is gone. A task under
/// a row that became projectless keeps its key: the task is the person's or
/// an agent's record, and "no project" is not a better answer than the folder
/// it named. Keys earlier builds wrote for no project — the old scratch key and
/// the per-harness ones — are folded into ``PseudoProject/projectlessKey``,
/// which is where they were drawn already.
///
/// ## Why a job, in batches
///
/// The decision needs the disk — whether a workspace root is on this Mac — and
/// the filesystem is never asked while the writer is held. So every row is
/// decided first, off the writer, and the writes then go in short
/// transactions of ``defaultBatchSize`` rows each, with a yield between them
/// so the registry's own writes interleave. Finished is recorded in `meta`
/// under ``StoreMetaKey/projectsRolledUp``; a pass that is cancelled leaves
/// the stamp unwritten, and the next launch picks up what is left, because
/// every step is idempotent.
public struct ProjectRollupMigration: Sendable {
    /// Rows per transaction.
    public static let defaultBatchSize = 50

    /// What a pass did. Counts only.
    public struct Report: Sendable, Equatable {
        /// Rows folded into a workspace root's row.
        public var projectsMerged: Int
        /// Workspace-root rows the pass had to create.
        public var projectsCreated: Int
        /// Rows deleted because they named no project.
        public var projectsCleared: Int
        /// Sessions now pointing at a workspace root.
        public var sessionsMoved: Int
        /// Sessions now pointing at no project.
        public var sessionsUnassigned: Int
        /// Tasks refiled — under a workspace root, or into Projectless from a
        /// key an earlier build wrote for it.
        public var tasksMoved: Int
        /// Milestones refiled the same way.
        public var plansMoved: Int

        public init(
            projectsMerged: Int = 0,
            projectsCreated: Int = 0,
            projectsCleared: Int = 0,
            sessionsMoved: Int = 0,
            sessionsUnassigned: Int = 0,
            tasksMoved: Int = 0,
            plansMoved: Int = 0
        ) {
            self.projectsMerged = projectsMerged
            self.projectsCreated = projectsCreated
            self.projectsCleared = projectsCleared
            self.sessionsMoved = sessionsMoved
            self.sessionsUnassigned = sessionsUnassigned
            self.tasksMoved = tasksMoved
            self.plansMoved = plansMoved
        }

        /// Rows of `projects` that are gone.
        public var projectsRemoved: Int { projectsMerged + projectsCleared }

        /// Whether the pass changed anything at all.
        public var changedAnything: Bool {
            projectsRemoved > 0 || projectsCreated > 0 || tasksMoved > 0 || plansMoved > 0
        }
    }

    public let dbWriter: any DatabaseWriter

    public init(dbWriter: any DatabaseWriter) {
        self.dbWriter = dbWriter
    }

    public init(store: AuspexStore) {
        self.dbWriter = store.dbWriter
    }

    /// Whether this store has already been rolled up.
    public func hasRun() async throws -> Bool {
        try await dbWriter.read { db in
            try String.fetchOne(
                db,
                sql: "SELECT value FROM meta WHERE key = ?",
                arguments: [StoreMetaKey.projectsRolledUp]
            ) != nil
        }
    }

    /// Rolls every plain-directory row up to its workspace, unless this store
    /// already has.
    ///
    /// - Parameters:
    ///   - rules: the rules the live path places with.
    ///   - protectedRoots: the roots of the person's own projects. A row at or
    ///     under one of them is kept.
    ///   - directoryExists: asked about workspace roots, off the writer.
    ///   - batchSize: rows per transaction.
    ///   - now: what the stamp records.
    /// - Returns: what changed, or `nil` when the pass had already run.
    @discardableResult
    public func runIfNeeded(
        rules: ScratchRules,
        protectedRoots: [String],
        directoryExists: @Sendable (String) -> Bool = PlacementService.directoryExists,
        batchSize: Int = defaultBatchSize,
        now: Date = Date()
    ) async throws -> Report? {
        guard try await !hasRun() else { return nil }

        let candidates = try await dbWriter.read { db in try Self.candidates(db) }
        let protected = protectedRoots.map(ProjectPath.normalize).filter { !$0.isEmpty }
        // Decided before any write, so the filesystem is never asked while the
        // writer is held — and a root many rows share is asked about once.
        var known: [String: Bool] = [:]
        var plans: [Plan] = []
        for row in candidates {
            let plan = Self.plan(row, rules: rules, protectedRoots: protected) { path in
                if let answer = known[path] { return answer }
                let answer = directoryExists(path)
                known[path] = answer
                return answer
            }
            if let plan { plans.append(plan) }
        }

        var report = Report()
        let size = max(1, batchSize)
        var start = 0
        while start < plans.count {
            try Task.checkCancellation()
            let batch = Array(plans[start..<min(start + size, plans.count)])
            let stamp = now.timeIntervalSince1970
            let done = try await dbWriter.write { db in
                try Self.apply(batch, createdAt: stamp, in: db)
            }
            report.add(done)
            start += size
            await Task.yield()
        }

        try Task.checkCancellation()
        let folded = try await dbWriter.write { db -> Report in
            let folded = try Self.foldProjectlessKeys(in: db)
            try db.execute(
                sql: """
                    INSERT INTO meta (key, value) VALUES (?, ?)
                    ON CONFLICT(key) DO UPDATE SET value = excluded.value
                    """,
                arguments: [StoreMetaKey.projectsRolledUp, String(now.timeIntervalSince1970)]
            )
            return folded
        }
        report.add(folded)
        return report
    }

    // MARK: - Scratch task keys

    /// Refiles, once per store, every task and milestone still filed under a
    /// scratch folder — a dated chat folder, the home — into Projectless.
    ///
    /// A ledger row can outlive the `projects` row its key named: the scratch
    /// purge removed the row and left the key, and the Tasks page then drew a
    /// lane per chat folder beside the one Projectless lane the board files
    /// those sessions under. Only a key the rules call scratch for every
    /// harness moves; a key at or under one of the person's own project roots
    /// stays, and so does any other path — a folder that is merely missing is
    /// still the best name its task has.
    ///
    /// Separate from ``runIfNeeded(rules:protectedRoots:directoryExists:batchSize:now:)``
    /// and stamped under its own key, so a store the roll-up already ran over
    /// is caught up too. The filesystem is not asked.
    ///
    /// - Returns: what moved, or `nil` when the pass had already run.
    @discardableResult
    public func foldScratchTaskKeysIfNeeded(
        rules: ScratchRules,
        protectedRoots: [String],
        now: Date = Date()
    ) async throws -> Report? {
        let done = try await dbWriter.read { db in
            try String.fetchOne(
                db,
                sql: "SELECT value FROM meta WHERE key = ?",
                arguments: [StoreMetaKey.scratchTaskKeysFolded]
            ) != nil
        }
        guard !done else { return nil }
        let keys = try await dbWriter.read { db in
            try String.fetchAll(db, sql: """
                SELECT DISTINCT project_key FROM tasks WHERE project_key LIKE '/%'
                UNION
                SELECT DISTINCT project_key FROM plans WHERE project_key LIKE '/%'
                """)
        }
        let protected = protectedRoots.map(ProjectPath.normalize).filter { !$0.isEmpty }
        let scratch = keys.filter { key in
            let path = ProjectResolver.standardized(key)
            if protected.contains(where: { ProjectPath.contains($0, path) }) { return false }
            return rules.match(cwd: path, harness: nil) != nil
        }.sorted()
        return try await dbWriter.write { db -> Report in
            var report = Report()
            for key in scratch {
                try db.execute(
                    sql: "UPDATE tasks SET project_key = ? WHERE project_key = ?",
                    arguments: [PseudoProject.projectlessKey, key]
                )
                report.tasksMoved += db.changesCount
                try db.execute(
                    sql: "UPDATE plans SET project_key = ? WHERE project_key = ?",
                    arguments: [PseudoProject.projectlessKey, key]
                )
                report.plansMoved += db.changesCount
            }
            try db.execute(
                sql: """
                    INSERT INTO meta (key, value) VALUES (?, ?)
                    ON CONFLICT(key) DO UPDATE SET value = excluded.value
                    """,
                arguments: [StoreMetaKey.scratchTaskKeysFolded, String(now.timeIntervalSince1970)]
            )
            return report
        }
    }

    // MARK: - Deciding

    /// One `projects` row, with the harnesses of the sessions in it.
    struct Candidate: Sendable {
        let id: Int64
        let rootPath: String
        let gitRoot: String?
        let harnesses: Set<Harness>
    }

    /// What happens to one row.
    enum Plan: Sendable, Equatable {
        /// Fold row `id` into the row for `root`.
        case merge(id: Int64, from: String, into: String)
        /// Delete row `id`; its sessions are in no project.
        case clear(id: Int64)
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
        let sql = "SELECT id, root_path, git_root FROM projects ORDER BY id ASC"
        return try Row.fetchAll(db, sql: sql).compactMap { row in
            guard let id = row["id"] as Int64?, let root = row["root_path"] as String? else {
                return nil
            }
            return Candidate(
                id: id, rootPath: root, gitRoot: row["git_root"], harnesses: harnesses[id] ?? []
            )
        }
    }

    /// The plan for one row, or `nil` when it stays as it is.
    static func plan(
        _ row: Candidate,
        rules: ScratchRules,
        protectedRoots: [String],
        directoryExists: (String) -> Bool
    ) -> Plan? {
        // A repository is a project whatever else is true of its folder.
        if let gitRoot = row.gitRoot, !gitRoot.isEmpty { return nil }
        guard row.rootPath.hasPrefix("/") else { return nil }
        let root = ProjectResolver.standardized(row.rootPath)
        if protectedRoots.contains(where: { ProjectPath.contains($0, root) }) { return nil }

        // The question a live placement would ask, once per harness that has
        // a session here — the Codex desktop tree is scratch only for Codex.
        let harnesses: [Harness?] = row.harnesses.isEmpty
            ? [nil]
            : row.harnesses.sorted { $0.rawValue < $1.rawValue }.map(Optional.some)
        let outcomes = harnesses.map { harness in
            ProjectRollup.place(
                directory: root,
                gitRoot: nil,
                harness: harness,
                userRoots: protectedRoots,
                rules: rules,
                directoryExists: directoryExists
            )
        }
        // A project for any harness in it is a project for the row: the live
        // path re-places each session it sees, and a row is only removed when
        // nothing in it could have a project.
        guard let target = outcomes.lazy.compactMap(\.root).first else {
            return .clear(id: row.id)
        }
        if target == row.rootPath { return nil }
        return .merge(id: row.id, from: row.rootPath, into: target)
    }

    // MARK: - Writing

    private static func apply(_ plans: [Plan], createdAt: Double, in db: Database) throws -> Report {
        var report = Report()
        for plan in plans {
            switch plan {
            case .merge(let id, let from, let root):
                // The row may have gone already — a pass that was cut short
                // after this batch committed, then run again.
                guard try Int64.fetchOne(
                    db, sql: "SELECT id FROM projects WHERE id = ?", arguments: [id]
                ) != nil else { continue }
                try db.execute(
                    sql: """
                        INSERT INTO projects (root_path, git_root, name, created_at)
                        VALUES (?, NULL, ?, ?)
                        ON CONFLICT(root_path) DO NOTHING
                        """,
                    arguments: [root, PathText.lastComponent(root), createdAt]
                )
                report.projectsCreated += db.changesCount
                guard let target = try Int64.fetchOne(
                    db, sql: "SELECT id FROM projects WHERE root_path = ?", arguments: [root]
                ), target != id else { continue }
                try db.execute(
                    sql: "UPDATE sessions SET project_id = ? WHERE project_id = ?",
                    arguments: [target, id]
                )
                report.sessionsMoved += db.changesCount
                try db.execute(
                    sql: "UPDATE worktrees SET project_id = ? WHERE project_id = ?",
                    arguments: [target, id]
                )
                try db.execute(sql: "DELETE FROM projects WHERE id = ?", arguments: [id])
                report.projectsMerged += db.changesCount
                // The work filed under the folder follows it, in the same
                // transaction, so it can never point at a row that is gone.
                try db.execute(
                    sql: "UPDATE tasks SET project_key = ? WHERE project_key = ?",
                    arguments: [root, from]
                )
                report.tasksMoved += db.changesCount
                try db.execute(
                    sql: "UPDATE plans SET project_key = ? WHERE project_key = ?",
                    arguments: [root, from]
                )
                report.plansMoved += db.changesCount

            case .clear(let id):
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
                report.projectsCleared += db.changesCount
            }
        }
        return report
    }

    /// Refiles every task and milestone under a key an earlier build used
    /// for "no project" into ``PseudoProject/projectlessKey``.
    private static func foldProjectlessKeys(in db: Database) throws -> Report {
        var report = Report()
        let keys = Set(try String.fetchAll(db, sql: """
            SELECT DISTINCT project_key FROM tasks WHERE project_key IS NOT NULL
            UNION
            SELECT DISTINCT project_key FROM plans WHERE project_key IS NOT NULL
            """))
        let legacy = keys.filter { $0 != PseudoProject.projectlessKey && TaskProject.isProjectless($0) }
        for key in legacy.sorted() {
            try db.execute(
                sql: "UPDATE tasks SET project_key = ? WHERE project_key = ?",
                arguments: [PseudoProject.projectlessKey, key]
            )
            report.tasksMoved += db.changesCount
            try db.execute(
                sql: "UPDATE plans SET project_key = ? WHERE project_key = ?",
                arguments: [PseudoProject.projectlessKey, key]
            )
            report.plansMoved += db.changesCount
        }
        return report
    }
}

extension ProjectRollupMigration.Report {
    mutating func add(_ other: Self) {
        projectsMerged += other.projectsMerged
        projectsCreated += other.projectsCreated
        projectsCleared += other.projectsCleared
        sessionsMoved += other.sessionsMoved
        sessionsUnassigned += other.sessionsUnassigned
        tasksMoved += other.tasksMoved
        plansMoved += other.plansMoved
    }
}
