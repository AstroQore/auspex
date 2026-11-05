import Foundation
import GRDB

/// Keeps the task ledger legible on its own: sets aside what nobody picked
/// up, files away milestones whose work has settled, and says which reviews
/// have been waiting longer than anybody will remember them.
///
/// ## Why the ledger needs a janitor
///
/// Agents file tasks far more readily than they finish them, and nothing in
/// the protocol ever retires a task nobody claimed. Left alone, a ledger that
/// has been in use for six weeks is two hundred unclaimed `todo`s, a hundred
/// and fifty reviews nobody closed, and eighty milestones all marked active —
/// and the Tasks page has to draw every one of them to say anything at all.
///
/// ## The three rules
///
/// 1. **Stale.** A `todo` nobody has ever claimed, filed more than
///    ``staleAfter`` ago and untouched since, is marked stale in
///    `task_hygiene`. Its status does not change. It stops appearing on the
///    Tasks page, on the board, and in `tasks.list` unless somebody asks for
///    it (`include_stale`), and the mark stops counting the moment anybody
///    claims the task, moves it, or keeps it — see ``AuspexTask/isStale`` and
///    ``TaskRepository/keepTask(id:by:now:)``.
/// 2. **Settled milestones.** An active milestone, quiet for
///    ``settledMilestoneAfter``, whose every task is `done`, stale, or in
///    `review` since before that cutoff, is archived. Archiving a milestone
///    never closes a task under it.
/// 3. **Old reviews.** A `review` older than ``oldReviewAfter`` whose claimer
///    is no longer running is *not* closed — `done` is a person's word — but
///    the Tasks page folds it into an "Old reviews" group with one button to
///    close the lot. That rule is a predicate rather than a write, because
///    whether a session is still running is a fact about the board, not the
///    store: see ``isOldReview(_:claimerIsLive:now:)``.
///
/// ## How it runs
///
/// From ``StoreMaintenance``, every six hours. Every rule is idempotent, so
/// the first pass on an old store is simply the one with the most to do — and
/// it does it ``batchSize`` rows per transaction, so marking a backlog of a
/// few thousand never holds the writer long enough for ingest to notice.
public struct LedgerHygiene: Sendable {
    /// How long a `todo` nobody claimed may sit before it is set aside.
    public static let staleAfter: TimeInterval = 7 * 86_400
    /// How long a milestone has to have been quiet before it can be filed.
    public static let settledMilestoneAfter: TimeInterval = 7 * 86_400
    /// How long a review can wait before it is an old one.
    public static let oldReviewAfter: TimeInterval = 14 * 86_400
    public static let defaultBatchSize = 200

    /// What one pass did.
    public struct Report: Sendable, Equatable {
        /// Tasks newly marked stale.
        public var markedStale = 0
        /// Marks cleared because the task moved on since it was marked.
        public var cleared = 0
        /// Milestones archived.
        public var archivedMilestones = 0
        /// Reviews older than ``LedgerHygiene/oldReviewAfter`` whose claimer
        /// has no live session in the store. Counted, never written.
        public var oldReviews = 0

        public init(markedStale: Int = 0, cleared: Int = 0, archivedMilestones: Int = 0, oldReviews: Int = 0) {
            self.markedStale = markedStale
            self.cleared = cleared
            self.archivedMilestones = archivedMilestones
            self.oldReviews = oldReviews
        }

        /// Whether the pass changed anything a reader of the ledger would see.
        public var didChange: Bool { markedStale + cleared + archivedMilestones > 0 }
    }

    public let dbWriter: any DatabaseWriter
    public let batchSize: Int

    public init(store: AuspexStore, batchSize: Int = defaultBatchSize) {
        self.dbWriter = store.dbWriter
        self.batchSize = max(1, batchSize)
    }

    public init(dbWriter: any DatabaseWriter, batchSize: Int = defaultBatchSize) {
        self.dbWriter = dbWriter
        self.batchSize = max(1, batchSize)
    }

    /// One pass of all three rules, in the order they depend on each other:
    /// clear marks that no longer hold, mark the stale, then archive the
    /// milestones that the marks may just have settled.
    @discardableResult
    public func runPass(now: Date = Date()) throws -> Report {
        var report = Report()
        report.cleared = try clearMovedOn()
        report.markedStale = try markStale(now: now)
        report.archivedMilestones = try archiveSettledMilestones(now: now)
        report.oldReviews = try countOldReviews(now: now)
        return report
    }

    // MARK: - The rules

    /// Whether a review has waited long enough, with nobody left to answer
    /// for it, to be folded away.
    ///
    /// Measured from when the work was finished — `completedAt`, which
    /// `tasks.complete` stamps — and from the last touch for a task somebody
    /// dragged into Review by hand. A review with no claimer at all has
    /// nobody left by definition.
    public static func isOldReview(_ task: AuspexTask, claimerIsLive: Bool, now: Date) -> Bool {
        guard task.status == .review, !claimerIsLive else { return false }
        let since = task.completedAt ?? task.updatedAt
        return now.timeIntervalSince(since) > oldReviewAfter
    }

    /// Clears every mark whose task has been claimed, moved out of `todo`, or
    /// touched since it was marked. One statement: the marks are a few hundred
    /// rows at most, and each check is a primary-key lookup.
    func clearMovedOn() throws -> Int {
        try dbWriter.write { db in
            try db.execute(sql: """
                DELETE FROM task_hygiene
                 WHERE task_id IN (
                    SELECT h.task_id FROM task_hygiene h
                      JOIN tasks t ON t.id = h.task_id
                     WHERE t.status != 'todo'
                        OR t.claimed_by_key IS NOT NULL
                        OR t.claim_role IS NOT NULL
                        OR t.updated_at > h.stale_at
                 )
                """)
            return db.changesCount
        }
    }

    /// Marks, in batches, every `todo` nobody has ever claimed that was filed
    /// and last touched before the cutoff.
    ///
    /// "Ever claimed" is read from the history rather than from the claim
    /// columns, because a task that was claimed and released is a task
    /// somebody has worked on — and that is not what stale means.
    func markStale(now: Date) throws -> Int {
        let cutoff = now.addingTimeInterval(-Self.staleAfter).timeIntervalSince1970
        var total = 0
        while true {
            let marked = try dbWriter.write { db -> Int in
                let ids = try Int64.fetchAll(db, sql: """
                    SELECT t.id FROM tasks t
                     WHERE t.status = 'todo'
                       AND t.claimed_by_key IS NULL AND t.claim_role IS NULL
                       AND t.created_at < ? AND t.updated_at < ?
                       AND NOT EXISTS (SELECT 1 FROM task_hygiene h WHERE h.task_id = t.id)
                       AND NOT EXISTS (
                           SELECT 1 FROM task_log l WHERE l.task_id = t.id AND l.kind = 'claimed'
                       )
                     ORDER BY t.id
                     LIMIT ?
                    """, arguments: [cutoff, cutoff, batchSize])
                for id in ids {
                    try db.execute(
                        sql: "INSERT INTO task_hygiene (task_id, stale_at) VALUES (?, ?)",
                        arguments: [id, now.timeIntervalSince1970]
                    )
                }
                return ids.count
            }
            total += marked
            if marked < batchSize { return total }
        }
    }

    /// Archives, in batches, every active milestone that has been quiet since
    /// the cutoff and has nothing left in it that anybody is doing.
    ///
    /// "Quiet" is the milestone's own `updated_at`, which every write to a
    /// task under it touches — so a milestone whose last task was closed
    /// yesterday stays on the board for a week, where the person who closed
    /// it can still see it.
    func archiveSettledMilestones(now: Date) throws -> Int {
        let cutoff = now.addingTimeInterval(-Self.settledMilestoneAfter).timeIntervalSince1970
        var total = 0
        while true {
            let archived = try dbWriter.write { db -> Int in
                let ids = try Int64.fetchAll(db, sql: """
                    SELECT p.id FROM plans p
                     WHERE p.status = 'active'
                       AND p.created_at < ? AND p.updated_at < ?
                       AND NOT EXISTS (
                           SELECT 1 FROM tasks t
                             LEFT JOIN task_hygiene h ON h.task_id = t.id
                            WHERE t.plan_id = p.id
                              AND NOT (
                                  (t.status IN ('done', 'review')
                                    AND COALESCE(t.completed_at, t.updated_at) < ?)
                                  OR (t.status = 'todo' AND h.task_id IS NOT NULL
                                      AND t.claimed_by_key IS NULL AND t.claim_role IS NULL)
                              )
                       )
                     ORDER BY p.id
                     LIMIT ?
                    """, arguments: [cutoff, cutoff, cutoff, batchSize])
                for id in ids {
                    try db.execute(
                        sql: """
                            UPDATE plans SET status = 'archived', archived_at = ?, updated_at = ?
                             WHERE id = ?
                            """,
                        arguments: [now.timeIntervalSince1970, now.timeIntervalSince1970, id]
                    )
                }
                return ids.count
            }
            total += archived
            if archived < batchSize { return total }
        }
    }

    /// How many reviews are old by ``isOldReview(_:claimerIsLive:now:)``,
    /// asking the store whether each claimer still has a live session.
    func countOldReviews(now: Date) throws -> Int {
        let cutoff = now.addingTimeInterval(-Self.oldReviewAfter).timeIntervalSince1970
        return try dbWriter.read { db in
            try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM tasks t
                 WHERE t.status = 'review'
                   AND COALESCE(t.completed_at, t.updated_at) < ?
                   AND NOT EXISTS (
                       SELECT 1 FROM sessions s
                        WHERE s.key = t.claimed_by_key AND s.is_alive = 1 AND s.ended_at IS NULL
                   )
                """, arguments: [cutoff]) ?? 0
        }
    }
}
