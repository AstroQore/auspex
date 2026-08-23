import AgentSessionLive
import Foundation
import GRDB

extension TaskRepository {
    // MARK: - Claims

    /// Takes a task, recording who took it and for what.
    ///
    /// One writer transaction: two workers handed the same id race here, and
    /// the second sees the first's committed holder before it can write. A
    /// re-claim by the *same* session is allowed and updates the scope — a
    /// worker refining what it took is not a conflict.
    ///
    /// `projectKey` is the claiming session's project. It is applied only to a
    /// task that has none yet: a task inherits its project from whoever first
    /// takes it, and a task that already knows where it lives is not moved by
    /// somebody picking it up from a worktree next door.
    ///
    /// - Throws: ``TaskLedgerError/alreadyClaimed(_:)`` when somebody else
    ///   holds it.
    @discardableResult
    public func claimTask(
        id: Int64,
        role: String,
        scope: String?,
        by session: SessionKey?,
        projectKey: String? = nil,
        expectedVersion: Int64? = nil,
        now: Date = Date()
    ) throws -> AuspexTask {
        try dbWriter.write { db in
            guard let existing = try Self.task(id: id, in: db) else {
                throw TaskLedgerError.notFound("task \(id)")
            }
            try Self.assertVersion(expectedVersion, of: existing)
            if let holder = existing.claimedBy, holder != session {
                throw TaskLedgerError.alreadyClaimed(holder.description)
            }
            let nextProject = existing.projectKey ?? projectKey
            let nextStatus: AuspexTaskStatus = existing.status == .todo ? .doing : existing.status
            guard existing.claimRole != role
                    || existing.claimScope != scope
                    || existing.claimedBy != session
                    || existing.projectKey != nextProject
                    || existing.status != nextStatus
            else { return existing }
            try db.execute(
                sql: """
                    UPDATE tasks
                       SET claim_role = ?, claim_scope = ?, claimed_by_key = ?,
                           claimed_at = ?, updated_at = ?,
                           project_key = COALESCE(project_key, ?),
                           status = CASE WHEN status = 'todo' THEN 'doing' ELSE status END,
                           version = version + 1
                     WHERE id = ?
                    """,
                arguments: [
                    role, scope, session?.description,
                    now.timeIntervalSince1970, now.timeIntervalSince1970, projectKey, id
                ]
            )
            if existing.projectKey == nil, let projectKey {
                try Self.adoptProject(projectKey, forPlan: existing.planID, in: db)
            }
            if let session {
                try Self.link(taskID: id, session: session, kind: .claim, at: now, in: db)
            }
            try Self.appendLog(
                taskID: id,
                actor: session,
                kind: "claimed",
                message: [role, scope].compactMap { $0 }.joined(separator: " · "),
                at: now,
                in: db
            )
            try Self.touchPlan(existing.planID, at: now, in: db)
            guard let task = try Self.task(id: id, in: db) else {
                throw TaskLedgerError.notFound("task \(id)")
            }
            return task
        }
    }

    /// Claims an available task, or records a takeover request when another
    /// session holds it.
    ///
    /// This is the MCP path. The lower-level ``claimTask`` keeps its strict
    /// refusal for existing callers, while a protocol-aware agent leaves a
    /// durable request a person can approve or reject. The two decisions are
    /// made in one transaction, so a holder cannot disappear between the
    /// conflict check and the request being filed.
    public func claimOrRequestTask(
        id: Int64,
        role: String,
        scope: String?,
        reason: String?,
        by session: SessionKey,
        projectKey: String? = nil,
        expectedVersion: Int64? = nil,
        now: Date = Date()
    ) throws -> ClaimOutcome {
        try dbWriter.write { db in
            guard let existing = try Self.task(id: id, in: db) else {
                throw TaskLedgerError.notFound("task \(id)")
            }
            try Self.assertVersion(expectedVersion, of: existing)

            // Releasing the holder does not turn an earlier request into an
            // implicit grant. Even an explicit retry stays pending: otherwise
            // `tasks.claim` would be a self-approval button by another name.
            if existing.claimedBy == nil,
               let pending = try Self.pendingClaimRequest(
                    taskID: id, requester: session, in: db
               ) {
                return .pending(task: existing, request: pending)
            }

            guard let holder = existing.claimedBy, holder != session else {
                let task = try Self.claimTask(
                    existing: existing,
                    role: role,
                    scope: scope,
                    by: session,
                    projectKey: projectKey,
                    now: now,
                    in: db
                )
                return .claimed(task)
            }

            if let pending = try Self.pendingClaimRequest(
                taskID: id, requester: session, in: db
            ), pending.role == role, pending.scope == scope, pending.reason == reason,
               pending.holder == holder {
                return .pending(task: existing, request: pending)
            }

            let nextVersion = existing.version + 1
            if let pending = try Self.pendingClaimRequest(
                taskID: id, requester: session, in: db
            ) {
                try db.execute(
                    sql: """
                        UPDATE task_claim_requests
                           SET holder_key = ?, claim_role = ?, claim_scope = ?, reason = ?,
                               task_version = ?, requested_at = ?
                         WHERE id = ?
                        """,
                    arguments: [
                        holder.description, role, scope, reason, nextVersion,
                        now.timeIntervalSince1970, pending.id
                    ]
                )
            } else {
                try db.execute(
                    sql: """
                        INSERT INTO task_claim_requests
                            (task_id, requester_key, holder_key, claim_role, claim_scope,
                             reason, task_version, status, requested_at, resolved_at)
                        VALUES (?, ?, ?, ?, ?, ?, ?, 'pending', ?, NULL)
                        """,
                    arguments: [
                        id, session.description, holder.description, role, scope, reason,
                        nextVersion, now.timeIntervalSince1970
                    ]
                )
            }
            // A second requester changes the review queue, not the holder the
            // person is deciding about. Keep every request from this same
            // claim epoch approvable at the new task version; a real task or
            // holder mutation still leaves them stale.
            try Self.refreshPendingClaimVersions(
                taskID: id, holder: holder, to: nextVersion, in: db
            )
            try db.execute(
                sql: "UPDATE tasks SET updated_at = ?, version = ? WHERE id = ?",
                arguments: [now.timeIntervalSince1970, nextVersion, id]
            )
            try Self.appendLog(
                taskID: id,
                actor: session,
                kind: "takeover_requested",
                message: [role, scope, reason].compactMap { $0 }.joined(separator: " · "),
                at: now,
                in: db
            )
            try Self.touchPlan(existing.planID, at: now, in: db)
            guard let task = try Self.task(id: id, in: db),
                  let request = try Self.pendingClaimRequest(
                    taskID: id, requester: session, in: db
                  )
            else { throw TaskLedgerError.notFound("takeover request for task \(id)") }
            return .pending(task: task, request: request)
        }
    }

    /// Releases a claim without closing the task — the honest thing for a
    /// worker that is giving up, as opposed to one that finished.
    ///
    /// The UI keeps `requireHolder` false: a person has to be able to clear an
    /// orphan whose process is gone. MCP passes true, and the holder check and
    /// release happen in this one transaction so another claimer cannot slip in
    /// between a read and the write.
    @discardableResult
    public func releaseTask(
        id: Int64,
        by session: SessionKey?,
        reason: String? = nil,
        requireHolder: Bool = false,
        expectedVersion: Int64? = nil,
        now: Date = Date()
    ) throws -> AuspexTask {
        try dbWriter.write { db in
            guard let existing = try Self.task(id: id, in: db) else {
                throw TaskLedgerError.notFound("task \(id)")
            }
            try Self.assertVersion(expectedVersion, of: existing)
            if requireHolder, existing.claimedBy != session {
                throw TaskLedgerError.notClaimHolder(existing.claimedBy?.description)
            }
            guard existing.isClaimed else { return existing }
            try db.execute(
                sql: """
                    UPDATE tasks
                       SET claim_role = NULL, claim_scope = NULL, claimed_by_key = NULL,
                           claimed_at = NULL, updated_at = ?,
                           status = CASE WHEN status = 'doing' THEN 'todo' ELSE status END,
                           version = version + 1
                     WHERE id = ?
                    """,
                arguments: [now.timeIntervalSince1970, id]
            )
            try Self.appendLog(
                taskID: id, actor: session, kind: "released", message: reason, at: now, in: db
            )
            try Self.touchPlan(existing.planID, at: now, in: db)
            guard let task = try Self.task(id: id, in: db) else {
                throw TaskLedgerError.notFound("task \(id)")
            }
            return task
        }
    }

    // MARK: - Claim takeover requests

    /// Requests awaiting a person's decision, oldest first.
    public func claimRequests(
        taskID: Int64? = nil,
        status: TaskClaimRequest.Status? = .pending
    ) throws -> [TaskClaimRequest] {
        try dbWriter.read { db in
            var clauses: [String] = []
            var arguments = StatementArguments()
            if let taskID {
                clauses.append("task_id = ?")
                arguments += [taskID]
            }
            if let status {
                clauses.append("status = ?")
                arguments += [status.rawValue]
            }
            var sql = "SELECT * FROM task_claim_requests"
            if !clauses.isEmpty { sql += " WHERE " + clauses.joined(separator: " AND ") }
            sql += " ORDER BY requested_at ASC, id ASC"
            return try Row.fetchAll(db, sql: sql, arguments: arguments)
                .compactMap(TaskClaimRequest.init(row:))
        }
    }

    /// Approves or rejects one takeover request. There is intentionally no
    /// MCP tool for this method: the decision belongs to the person looking at
    /// the task detail page.
    @discardableResult
    public func resolveClaimRequest(
        id requestID: Int64,
        approve: Bool,
        now: Date = Date()
    ) throws -> (task: AuspexTask, request: TaskClaimRequest) {
        try dbWriter.write { db in
            guard let request = try Row.fetchOne(
                db,
                sql: "SELECT * FROM task_claim_requests WHERE id = ?",
                arguments: [requestID]
            ).flatMap(TaskClaimRequest.init(row:)) else {
                throw TaskLedgerError.notFound("claim request \(requestID)")
            }
            guard request.status == .pending else {
                throw TaskLedgerError.claimRequestResolved(requestID)
            }
            guard let existing = try Self.task(id: request.taskID, in: db) else {
                throw TaskLedgerError.notFound("task \(request.taskID)")
            }

            // Approval is a compare-and-swap against the exact claim the
            // person reviewed. A release, another claim, or any intervening
            // task mutation makes the old request historical evidence, never
            // authority to displace the current holder.
            if approve,
               existing.version != request.taskVersion || existing.claimedBy != request.holder {
                try db.execute(
                    sql: """
                        UPDATE task_claim_requests
                           SET status = 'expired', resolved_at = ?
                         WHERE id = ? AND status = 'pending'
                        """,
                    arguments: [now.timeIntervalSince1970, requestID]
                )
                let nextVersion = existing.version + 1
                try db.execute(
                    sql: "UPDATE tasks SET updated_at = ?, version = ? WHERE id = ?",
                    arguments: [now.timeIntervalSince1970, nextVersion, request.taskID]
                )
                // Expiring an old holder's request must not invalidate a
                // newer holder's already-reviewed pending requests.
                try Self.refreshPendingClaimVersions(
                    taskID: request.taskID,
                    holder: existing.claimedBy,
                    to: nextVersion,
                    in: db
                )
                try Self.appendLog(
                    taskID: request.taskID,
                    actor: nil,
                    kind: "takeover_expired",
                    message: "request v\(request.taskVersion) no longer matches current v\(existing.version)",
                    at: now,
                    in: db
                )
                try Self.touchPlan(existing.planID, at: now, in: db)
                guard let task = try Self.task(id: request.taskID, in: db),
                      let expired = try Row.fetchOne(
                        db,
                        sql: "SELECT * FROM task_claim_requests WHERE id = ?",
                        arguments: [requestID]
                      ).flatMap(TaskClaimRequest.init(row:))
                else { throw TaskLedgerError.notFound("claim request \(requestID)") }
                return (task, expired)
            }

            let resolution: TaskClaimRequest.Status = approve ? .approved : .rejected
            try db.execute(
                sql: """
                    UPDATE task_claim_requests
                       SET status = ?, resolved_at = ?
                     WHERE id = ? AND status = 'pending'
                    """,
                arguments: [resolution.rawValue, now.timeIntervalSince1970, requestID]
            )
            if approve {
                // One winner. Other requests stay in the audit trail but are
                // resolved so a later click cannot displace the person just
                // approved.
                try db.execute(
                    sql: """
                        UPDATE task_claim_requests
                           SET status = 'rejected', resolved_at = ?
                         WHERE task_id = ? AND status = 'pending'
                        """,
                    arguments: [now.timeIntervalSince1970, request.taskID]
                )
                try db.execute(
                    sql: """
                        UPDATE tasks
                           SET claim_role = ?, claim_scope = ?, claimed_by_key = ?,
                               claimed_at = ?, updated_at = ?,
                               status = CASE WHEN status = 'todo' THEN 'doing' ELSE status END,
                               version = version + 1
                         WHERE id = ?
                        """,
                    arguments: [
                        request.role, request.scope, request.requester.description,
                        now.timeIntervalSince1970, now.timeIntervalSince1970, request.taskID
                    ]
                )
                try Self.link(
                    taskID: request.taskID, session: request.requester,
                    kind: .claim, at: now, in: db
                )
            } else {
                let nextVersion = existing.version + 1
                try db.execute(
                    sql: "UPDATE tasks SET updated_at = ?, version = ? WHERE id = ?",
                    arguments: [now.timeIntervalSince1970, nextVersion, request.taskID]
                )
                // Rejecting one candidate changes the queue, not the claim.
                // Keep the remaining candidates for the current holder in
                // the same approvable epoch regardless of decision order.
                try Self.refreshPendingClaimVersions(
                    taskID: request.taskID,
                    holder: existing.claimedBy,
                    to: nextVersion,
                    in: db
                )
            }
            try Self.appendLog(
                taskID: request.taskID,
                actor: nil,
                kind: approve ? "takeover_approved" : "takeover_rejected",
                message: [
                    request.requester.description, request.role, request.scope, request.reason
                ]
                    .compactMap { $0 }.joined(separator: " · "),
                at: now,
                in: db
            )
            try Self.touchPlan(existing.planID, at: now, in: db)
            guard let task = try Self.task(id: request.taskID, in: db),
                  let resolved = try Row.fetchOne(
                    db,
                    sql: "SELECT * FROM task_claim_requests WHERE id = ?",
                    arguments: [requestID]
                  ).flatMap(TaskClaimRequest.init(row:))
            else { throw TaskLedgerError.notFound("claim request \(requestID)") }
            return (task, resolved)
        }
    }

    private static func refreshPendingClaimVersions(
        taskID: Int64,
        holder: SessionKey?,
        to version: Int64,
        in db: Database
    ) throws {
        try db.execute(
            sql: """
                UPDATE task_claim_requests
                   SET task_version = ?
                 WHERE task_id = ? AND status = 'pending' AND holder_key IS ?
                """,
            arguments: [version, taskID, holder?.description]
        )
    }

    // MARK: - Shared claim statements

    /// The claim write shared by the strict repository call and the MCP
    /// claim-or-request transaction. The caller has already checked the
    /// current holder and expected version.
    static func claimTask(
        existing: AuspexTask,
        role: String,
        scope: String?,
        by session: SessionKey,
        projectKey: String?,
        now: Date,
        in db: Database
    ) throws -> AuspexTask {
        let nextProject = existing.projectKey ?? projectKey
        let nextStatus: AuspexTaskStatus = existing.status == .todo ? .doing : existing.status
        guard existing.claimRole != role
                || existing.claimScope != scope
                || existing.claimedBy != session
                || existing.projectKey != nextProject
                || existing.status != nextStatus
        else { return existing }
        try db.execute(
            sql: """
                UPDATE tasks
                   SET claim_role = ?, claim_scope = ?, claimed_by_key = ?,
                       claimed_at = ?, updated_at = ?,
                       project_key = COALESCE(project_key, ?),
                       status = CASE WHEN status = 'todo' THEN 'doing' ELSE status END,
                       version = version + 1
                 WHERE id = ?
                """,
            arguments: [
                role, scope, session.description, now.timeIntervalSince1970,
                now.timeIntervalSince1970, projectKey, existing.id
            ]
        )
        if existing.projectKey == nil, let projectKey {
            try adoptProject(projectKey, forPlan: existing.planID, in: db)
        }
        try link(taskID: existing.id, session: session, kind: .claim, at: now, in: db)
        try appendLog(
            taskID: existing.id, actor: session, kind: "claimed",
            message: [role, scope].compactMap { $0 }.joined(separator: " · "),
            at: now, in: db
        )
        try touchPlan(existing.planID, at: now, in: db)
        guard let task = try task(id: existing.id, in: db) else {
            throw TaskLedgerError.notFound("task \(existing.id)")
        }
        return task
    }

    static func pendingClaimRequest(
        taskID: Int64,
        requester: SessionKey,
        in db: Database
    ) throws -> TaskClaimRequest? {
        try Row.fetchOne(
            db,
            sql: """
                SELECT * FROM task_claim_requests
                 WHERE task_id = ? AND requester_key = ? AND status = 'pending'
                 ORDER BY id DESC LIMIT 1
                """,
            arguments: [taskID, requester.description]
        ).flatMap(TaskClaimRequest.init(row:))
    }
}
