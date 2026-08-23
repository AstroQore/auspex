import AgentSessionLive
import Foundation
import GRDB

// MARK: - Row decoding

extension AuspexPlan {
    init?(row: Row) {
        guard let id = row["id"] as Int64?,
              let slug = row["slug"] as String?,
              let title = row["title"] as String?,
              let statusRaw = row["status"] as String?,
              let status = Status(rawValue: statusRaw),
              let createdAt = row["created_at"] as Double?,
              let updatedAt = row["updated_at"] as Double?
        else { return nil }
        self.init(
            id: id,
            slug: slug,
            title: title,
            summary: row["summary"],
            status: status,
            projectID: row["project_id"],
            projectKey: row["project_key"],
            createdBy: (row["created_by_key"] as String?).flatMap(SessionKey.init(string:)),
            createdAt: Date(timeIntervalSince1970: createdAt),
            updatedAt: Date(timeIntervalSince1970: updatedAt),
            archivedAt: (row["archived_at"] as Double?).map(Date.init(timeIntervalSince1970:))
        )
    }
}

extension AuspexTask {
    init?(row: Row) {
        guard let id = row["id"] as Int64?,
              let title = row["title"] as String?,
              let statusRaw = row["status"] as String?,
              let createdAt = row["created_at"] as Double?,
              let updatedAt = row["updated_at"] as Double?
        else { return nil }
        self.init(
            id: id,
            version: row["version"] as Int64? ?? 1,
            planID: row["plan_id"],
            title: title,
            body: row["body"],
            // A row written before the four columns settled reads as `todo`
            // rather than sinking the whole query.
            status: AuspexTaskStatus(rawValue: statusRaw) ?? .todo,
            priority: row["priority"] as Int? ?? 0,
            projectID: row["project_id"],
            projectKey: row["project_key"],
            createdBy: (row["created_by_key"] as String?).flatMap(SessionKey.init(string:)),
            claimRole: row["claim_role"],
            claimScope: row["claim_scope"],
            claimedBy: (row["claimed_by_key"] as String?).flatMap(SessionKey.init(string:)),
            claimedAt: (row["claimed_at"] as Double?).map(Date.init(timeIntervalSince1970:)),
            completedAt: (row["completed_at"] as Double?).map(Date.init(timeIntervalSince1970:)),
            result: row["result"],
            source: row["source"],
            kind: (row["kind"] as String?).flatMap(TaskKind.init(rawValue:)),
            labels: TaskLabels.decode(row["labels"]),
            createdAt: Date(timeIntervalSince1970: createdAt),
            updatedAt: Date(timeIntervalSince1970: updatedAt)
        )
    }
}

extension TaskClaimRequest {
    init?(row: Row) {
        guard let id = row["id"] as Int64?,
              let taskID = row["task_id"] as Int64?,
              let requesterRaw = row["requester_key"] as String?,
              let requester = SessionKey(string: requesterRaw),
              let role = row["claim_role"] as String?,
              let taskVersion = row["task_version"] as Int64?,
              let statusRaw = row["status"] as String?,
              let status = Status(rawValue: statusRaw),
              let requestedAt = row["requested_at"] as Double?
        else { return nil }
        self.init(
            id: id,
            taskID: taskID,
            requester: requester,
            holder: (row["holder_key"] as String?).flatMap(SessionKey.init(string:)),
            role: role,
            scope: row["claim_scope"],
            reason: row["reason"],
            taskVersion: taskVersion,
            status: status,
            requestedAt: Date(timeIntervalSince1970: requestedAt),
            resolvedAt: (row["resolved_at"] as Double?).map(Date.init(timeIntervalSince1970:))
        )
    }
}

extension AuspexTaskLink {
    init?(row: Row) {
        guard let taskID = row["task_id"] as Int64?,
              let keyString = row["session_key"] as String?,
              let session = SessionKey(string: keyString),
              let kindRaw = row["kind"] as String?,
              let kind = AuspexTaskLinkKind(rawValue: kindRaw),
              let createdAt = row["created_at"] as Double?
        else { return nil }
        self.init(
            taskID: taskID,
            session: session,
            kind: kind,
            createdAt: Date(timeIntervalSince1970: createdAt)
        )
    }
}

extension AuspexTaskLogEntry {
    init?(row: Row) {
        guard let id = row["id"] as Int64?,
              let taskID = row["task_id"] as Int64?,
              let ts = row["ts"] as Double?,
              let kind = row["kind"] as String?
        else { return nil }
        self.init(
            id: id,
            taskID: taskID,
            timestamp: Date(timeIntervalSince1970: ts),
            actor: (row["actor_key"] as String?).flatMap(SessionKey.init(string:)),
            kind: kind,
            message: row["detail_json"],
            ref: row["ref"]
        )
    }
}

extension AgentNotice {
    init?(row: Row) {
        guard let keyString = row["session_key"] as String?,
              let session = SessionKey(string: keyString),
              let kindRaw = row["kind"] as String?,
              let kind = AgentNoticeKind(rawValue: kindRaw),
              let message = row["message"] as String?,
              let createdAt = row["created_at"] as Double?
        else { return nil }
        self.init(
            session: session,
            kind: kind,
            message: message,
            urgency: (row["urgency"] as String?).flatMap(AgentNoticeUrgency.init(rawValue:)) ?? .normal,
            createdAt: Date(timeIntervalSince1970: createdAt),
            clearedAt: (row["cleared_at"] as Double?).map(Date.init(timeIntervalSince1970:))
        )
    }
}

extension AgentReport {
    init?(row: Row) {
        guard let keyString = row["session_key"] as String?,
              let session = SessionKey(string: keyString),
              let focus = row["focus"] as String?,
              let createdAt = row["created_at"] as Double?
        else { return nil }
        self.init(
            session: session,
            focus: focus,
            progress: row["progress"],
            createdAt: Date(timeIntervalSince1970: createdAt)
        )
    }
}
