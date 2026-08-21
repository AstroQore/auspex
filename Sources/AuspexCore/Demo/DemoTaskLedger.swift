import AgentSessionKit
import AgentSessionLive
import Foundation

/// The fabricated task board a demo replay shows.
///
/// The Tasks page is the one surface with nothing to draw until somebody has
/// used it, and "nothing to draw" is a poor answer to *what does this look
/// like* — which is the only question a demo exists to answer. So the demo
/// seeds two projects' worth of work: one with a milestone over most of it and
/// a task an agent filed beside the milestone, one with no milestone at all.
/// The claims come from the same synthetic sessions the wall is already
/// showing, with a role and a scope on each, so the shape of a real
/// decomposition is visible — including the fact that a project is the
/// container and a milestone is only a heading.
///
/// Every task is filed under the project of the session that claims it, which
/// is exactly what `tasks.create` does for a real agent. Nothing is unfiled,
/// because nothing can be.
///
/// Everything here is written for the demo. The projects, the tasks, the roles
/// and the scopes describe work on Auspex and on a fictional storefront; the
/// session keys come from ``DemoScript``, which fabricates its sessions under
/// `/Users/example`. It writes only into the in-memory store a demo launch
/// creates for itself — ``AuspexStore/init(inMemory:)`` — and never into
/// `~/.auspex/`.
public enum DemoTaskLedger {
    /// The two projects the demo files work in. Both are keys the demo board
    /// itself produces, so a lane on the Tasks page is the same project as a
    /// section on the wall.
    static let auspex = "/Users/example/Code/auspex"
    static let storefront = "/Users/example/Code/storefront-web"

    /// Fills `ledger` with the demo board. Idempotent by the milestone's slug,
    /// so a second call is a no-op rather than a second heading.
    public static func seed(into ledger: TaskRepository, now: Date = Date()) throws {
        let keys = DemoScript.sessionKeys
        func key(_ index: Int) -> SessionKey? {
            index < keys.count ? keys[index] : nil
        }

        let plan = try ledger.createPlan(
            title: "Ship the live board",
            slug: "live-board",
            summary: "One board for every agent on this Mac: adapters, grouping, and the wall.",
            projectKey: auspex,
            now: now.addingTimeInterval(-3_600)
        )
        // Already there — a demo relaunching into the same in-memory store, or
        // a second call from a renderer.
        guard try ledger.tasks(planID: plan.id).isEmpty else { return }

        // What the agents on this board have said out loud, from the one
        // list the headless renderers read too — so a screenshot of the demo
        // and a demo launch cannot disagree about which cards are shouting.
        for notice in DemoScript.notices(now: now).values.sorted(by: {
            $0.session.description < $1.session.description
        }) {
            try ledger.recordNotice(
                session: notice.session,
                kind: notice.kind,
                message: notice.message,
                urgency: notice.urgency,
                now: notice.createdAt
            )
        }

        // MARK: auspex — a milestone, and one task filed beside it

        let claimed = try ledger.createTask(
            title: "Tail the Codex rollout format",
            body: "Function calls, sub-agent activity, and the guardian approval event.",
            planID: plan.id, priority: 3, projectKey: auspex, source: "demo",
            now: now.addingTimeInterval(-3_000)
        )
        if let worker = key(1) {
            try ledger.claimTask(
                id: claimed.id, role: "implementer", scope: "the rollout tailer",
                by: worker, projectKey: auspex, now: now.addingTimeInterval(-2_400)
            )
        }

        let blocked = try ledger.createTask(
            title: "Decode the AntiGravity step enum",
            body: "Only the SQL columns are on the hot path; the tool name is best effort.",
            planID: plan.id, status: .blocked, priority: 2, projectKey: auspex, source: "demo",
            now: now.addingTimeInterval(-2_800)
        )
        if let worker = key(4) {
            try ledger.claimTask(
                id: blocked.id, role: "researcher", scope: "protobuf wire reader",
                by: worker, projectKey: auspex, now: now.addingTimeInterval(-2_000)
            )
            try ledger.appendLog(
                taskID: blocked.id, actor: worker, kind: "note",
                message: "Waiting on a decision: ship the partial enum or keep digging?",
                now: now.addingTimeInterval(-600)
            )
        }

        _ = try ledger.createTask(
            title: "Cursor's blob DAG, incrementally",
            body: "Walk only the unseen references under each new root blob.",
            planID: plan.id, projectKey: auspex, source: "demo",
            now: now.addingTimeInterval(-2_500)
        )
        _ = try ledger.createTask(
            title: "Retention: 2000 events or 14 days per session",
            planID: plan.id, projectKey: auspex, source: "demo",
            now: now.addingTimeInterval(-2_400)
        )

        let done = try ledger.createTask(
            title: "Claude Code adapter",
            planID: plan.id, projectKey: auspex, source: "demo",
            now: now.addingTimeInterval(-3_400)
        )
        if let worker = key(0) {
            try ledger.claimTask(
                id: done.id, role: "implementer", scope: "transcript + subagents",
                by: worker, projectKey: auspex, now: now.addingTimeInterval(-3_300)
            )
            try ledger.completeTask(
                id: done.id,
                result: "Tool calls, sub-agents and the pid registry, with fixtures.",
                by: worker, now: now.addingTimeInterval(-1_200)
            )
        }

        // An agent filed this one itself, under no milestone. It is in the
        // project because that is where the session was working — which is the
        // whole of what used to land in "Unfiled".
        _ = try ledger.createTask(
            title: "Sanitize argv before it reaches a log line",
            body: "A harness that takes a credential flag in argv; strip it at the boundary.",
            projectKey: auspex, createdBy: key(11), source: "mcp",
            now: now.addingTimeInterval(-900)
        )

        // MARK: storefront-web — a project with no milestone at all

        let cart = try ledger.createTask(
            title: "Port the cart to the new checkout API",
            body: "Keep the old totals endpoint answering until the mobile client moves.",
            priority: 1, projectKey: storefront, source: "demo",
            now: now.addingTimeInterval(-2_700)
        )
        if let worker = key(2) {
            try ledger.claimTask(
                id: cart.id, role: "implementer", scope: "the cart",
                by: worker, projectKey: storefront, now: now.addingTimeInterval(-2_100)
            )
        }

        let totals = try ledger.createTask(
            title: "Three-way split on the totals",
            projectKey: storefront, source: "demo", now: now.addingTimeInterval(-2_600)
        )
        if let worker = key(5) {
            try ledger.claimTask(
                id: totals.id, role: "implementer", scope: "rounding",
                by: worker, projectKey: storefront, now: now.addingTimeInterval(-2_200)
            )
            try ledger.completeTask(
                id: totals.id,
                result: "Fixed the three-way split: the remainder is distributed, not truncated.",
                by: worker, now: now.addingTimeInterval(-300)
            )
        }

        _ = try ledger.createTask(
            title: "A smoke test for the discount rule",
            projectKey: storefront, createdBy: key(9), source: "mcp",
            now: now.addingTimeInterval(-600)
        )
    }
}
