import AgentSessionKit
import AgentSessionLive
import Foundation

/// The fabricated task board a demo replay shows.
///
/// The Tasks page is the one surface with nothing to draw until somebody has
/// used it, and "nothing to draw" is a poor answer to *what does this look
/// like* — which is the only question a demo exists to answer. So the demo
/// seeds one plan, six tasks across the four columns, and claims by the same
/// synthetic sessions the wall is already showing, with a role and a scope on
/// each so the shape of a real decomposition is visible.
///
/// Everything here is written for the demo. The plan, the tasks, the roles and
/// the scopes describe work on Auspex itself; the session keys come from
/// ``DemoScript``, which fabricates its sessions under `/Users/example`. It
/// writes only into the in-memory store a demo launch creates for itself —
/// ``AuspexStore/init(inMemory:)`` — and never into `~/.auspex/`.
public enum DemoTaskLedger {
    /// Fills `ledger` with the demo board. Idempotent by the plan's slug, so a
    /// second call is a no-op rather than a second lane.
    public static func seed(into ledger: TaskRepository, now: Date = Date()) throws {
        let keys = DemoScript.sessionKeys
        func key(_ index: Int) -> SessionKey? {
            index < keys.count ? keys[index] : nil
        }

        let plan = try ledger.createPlan(
            title: "Ship the live board",
            slug: "live-board",
            summary: "One board for every agent on this Mac: adapters, grouping, and the wall.",
            now: now.addingTimeInterval(-3_600)
        )
        // Already there — a demo relaunching into the same in-memory store, or
        // a second call from a renderer.
        guard try ledger.tasks(planID: plan.id).isEmpty else { return }

        // One session calling for a person, because that is the thing the
        // board exists to surface and a demo that never shows it is a demo of
        // the easy half.
        //
        // `blocked` rather than `needs_input`, and that is the rule working
        // rather than a preference: a demo replays a scripted conversation on
        // a loop, so every session is about to receive another prompt — and a
        // `needs_input` notice is *answered* by the next prompt. It would clear
        // itself within seconds of the demo starting, which is correct and
        // would make for a demo of nothing. A blocker is about the world, not
        // about the conversation, and stays until somebody dismisses it.
        if let stuck = key(4) {
            try ledger.recordNotice(
                session: stuck,
                kind: .blocked,
                message: "Two step enums disagree about status 9. Ship the partial decode, or keep digging?",
                now: now.addingTimeInterval(-540)
            )
        }

        let claimed = try ledger.createTask(
            title: "Tail the Codex rollout format",
            body: "Function calls, sub-agent activity, and the guardian approval event.",
            planID: plan.id, priority: 3, source: "demo", now: now.addingTimeInterval(-3_000)
        )
        if let worker = key(1) {
            try ledger.claimTask(
                id: claimed.id, role: "implementer", scope: "the rollout tailer",
                by: worker, now: now.addingTimeInterval(-2_400)
            )
        }

        let blocked = try ledger.createTask(
            title: "Decode the AntiGravity step enum",
            body: "Only the SQL columns are on the hot path; the tool name is best effort.",
            planID: plan.id, status: .blocked, priority: 2, source: "demo",
            now: now.addingTimeInterval(-2_800)
        )
        if let worker = key(4) {
            try ledger.claimTask(
                id: blocked.id, role: "researcher", scope: "protobuf wire reader",
                by: worker, now: now.addingTimeInterval(-2_000)
            )
            try ledger.appendLog(
                taskID: blocked.id, actor: worker, kind: "note",
                message: "Waiting on a decision: ship the partial enum or keep digging?",
                now: now.addingTimeInterval(-600)
            )
        }

        let review = try ledger.createTask(
            title: "Group sessions by worktree",
            planID: plan.id, priority: 1, source: "demo", now: now.addingTimeInterval(-2_600)
        )
        if let worker = key(2) {
            try ledger.claimTask(
                id: review.id, role: "implementer", scope: "the placement service",
                by: worker, now: now.addingTimeInterval(-1_800)
            )
        }

        _ = try ledger.createTask(
            title: "Cursor's blob DAG, incrementally",
            body: "Walk only the unseen references under each new root blob.",
            planID: plan.id, source: "demo", now: now.addingTimeInterval(-2_500)
        )
        _ = try ledger.createTask(
            title: "Retention: 2000 events or 14 days per session",
            planID: plan.id, source: "demo", now: now.addingTimeInterval(-2_400)
        )

        let done = try ledger.createTask(
            title: "Claude Code adapter",
            planID: plan.id, source: "demo", now: now.addingTimeInterval(-3_400)
        )
        if let worker = key(0) {
            try ledger.claimTask(
                id: done.id, role: "implementer", scope: "transcript + subagents",
                by: worker, now: now.addingTimeInterval(-3_300)
            )
            try ledger.completeTask(
                id: done.id,
                result: "Tool calls, sub-agents and the pid registry, with fixtures.",
                by: worker, now: now.addingTimeInterval(-1_200)
            )
        }
    }
}
