import AgentSessionKit
import AgentSessionLive
import Foundation

/// A ledger the size a busy machine reaches, for measuring the Tasks page.
///
/// ``DemoTaskLedger`` is a good board and a small one: eleven tasks in two
/// projects. The Tasks page's pathology only shows at the size a real ledger
/// grows to — a few hundred explicit tasks across forty-odd projects, most of
/// them unclaimed or waiting in Review for weeks — and the one place that size
/// can be reached without opening somebody's store is here.
///
/// `AUSPEX_DEMO_TASKS=400` asks for it, and only a demo launch reads that
/// variable. Everything is fabricated: the projects are folders under
/// `/Users/example/Code`, the claimers are the demo's own sessions or keys no
/// board has ever seen, and every timestamp is spread over the six weeks before
/// `now` by a seeded generator, so two launches seed the same ledger.
public enum DemoBulkLedger {
    /// The ceiling on what a launch may ask for. Writing a few thousand rows
    /// into the in-memory store is quick; a typo with three more zeroes in it
    /// would spend the first minute of the launch doing nothing else.
    public static let limit = 2_000

    /// The variable a demo launch reads.
    public static let environmentKey = "AUSPEX_DEMO_TASKS"

    /// How many tasks a launch asked for, clamped. `0` when it asked for none.
    public static func requestedCount(in environment: [String: String]) -> Int {
        guard let raw = environment[environmentKey], let count = Int(raw) else { return 0 }
        return min(max(count, 0), limit)
    }

    /// The folders the bulk work is filed in, besides the demo's own projects.
    static let projectNames = [
        "atlas-api", "billing-service", "checkout-mobile", "design-tokens", "docs-site",
        "edge-proxy", "feature-flags", "fleet-agent", "geo-search", "growth-dashboards",
        "identity", "infra-terraform", "ingest-pipeline", "inventory", "firmware-updater",
        "lab-notebooks", "ledger-exporter", "mail-relay", "maps-tiles", "metrics-gateway",
        "notifications", "onboarding-flow", "orders-ui", "payments-sdk", "photo-pipeline",
        "pricing-engine", "queue-workers", "recommendations", "release-tools", "search-ranking",
        "settings-web", "support-console", "sync-engine", "telemetry", "web-shell"
    ]

    static let verbs = [
        "Add", "Fix", "Port", "Document", "Measure", "Retire", "Split", "Cache",
        "Validate", "Migrate", "Trim", "Rename"
    ]

    static let objects = [
        "the retry policy", "the settings schema", "the login redirect", "the export job",
        "the rate limiter", "the cold-start path", "the audit log", "the webhook signer",
        "the onboarding copy", "the pagination cursor", "the health probe", "the CSV import",
        "the feature flag cleanup", "the error banner", "the nightly backup", "the price rounding"
    ]

    /// Fills `ledger` with `count` tasks under `count / 10` milestones.
    ///
    /// Idempotent by the first milestone's slug, like ``DemoTaskLedger``.
    public static func seed(into ledger: TaskRepository, count: Int, now: Date = Date()) throws {
        guard count > 0 else { return }
        let count = min(count, limit)
        guard try ledger.plan(slug: "demo-bulk-0") == nil else { return }

        var rng = SeededRandom(seed: 0xB0_1C_7A_5C)
        let day: TimeInterval = 86_400
        let demoKeys = DemoScript.sessionKeys
        let demoProjects = Array(Set(DemoScript.Blueprint.all.compactMap { $0.gitRoot ?? $0.cwd }))
            .sorted()
        let projects = demoProjects + projectNames.map { "\(DemoScript.homeDirectory)/Code/\($0)" }

        func pick<T>(_ values: [T]) -> T { values[Int(rng.next() % UInt64(values.count))] }
        func ago(_ maximumDays: Double) -> TimeInterval {
            Double(rng.next() % 10_000) / 10_000 * maximumDays * day
        }

        let planCount = max(1, count / 10)
        var plans: [AuspexPlan] = []
        for index in 0..<planCount {
            let project = projects[index % projects.count]
            plans.append(try ledger.createPlan(
                title: "\(pick(verbs)) \(pick(objects)) — milestone \(index + 1)",
                slug: "demo-bulk-\(index)",
                projectKey: project,
                now: now.addingTimeInterval(-42 * day + Double(index) * 0.4 * day)
            ))
        }

        for index in 0..<count {
            let plan: AuspexPlan? = rng.next() % 10 < 7 ? plans[index % plans.count] : nil
            let project = plan?.projectKey ?? pick(projects)
            let created = now.addingTimeInterval(-ago(42) - 600)
            let task = try ledger.createTask(
                title: "\(pick(verbs)) \(pick(objects)) (\(index + 1))",
                body: "Fabricated for the demo ledger.",
                planID: plan?.id,
                priority: rng.next() % 9 == 0 ? 2 : 0,
                projectKey: project,
                source: "demo",
                now: created
            )
            let age = now.timeIntervalSince(created)
            func at(_ fraction: Double) -> Date { created.addingTimeInterval(age * fraction) }
            // A claimer the board is showing, or one that has long since gone.
            let claimer: SessionKey = rng.next() % 3 == 0
                ? pick(demoKeys)
                : SessionKey(harness: pick([.claudeCode, .codex, .cursor]), sessionID: "gone-\(index)")
            switch rng.next() % 100 {
            case 0..<45:
                // Unclaimed. Most of a real backlog is exactly this.
                continue
            case 45..<55:
                try ledger.claimTask(
                    id: task.id, role: "implementer", scope: pick(objects),
                    by: pick(demoKeys), projectKey: project, now: at(0.5)
                )
            case 55..<58:
                try ledger.claimTask(
                    id: task.id, role: "implementer", scope: nil,
                    by: claimer, projectKey: project, now: at(0.3)
                )
                try ledger.updateTask(id: task.id, status: .blocked, actor: claimer, now: at(0.6))
            case 58..<88:
                try ledger.claimTask(
                    id: task.id, role: "implementer", scope: nil,
                    by: claimer, projectKey: project, now: at(0.2)
                )
                try ledger.completeTask(
                    id: task.id, result: "Did the work; the tests for it pass.",
                    by: claimer, now: at(0.4)
                )
            default:
                try ledger.claimTask(
                    id: task.id, role: "implementer", scope: nil,
                    by: claimer, projectKey: project, now: at(0.2)
                )
                try ledger.completeTask(
                    id: task.id, result: "Shipped behind the flag.", by: claimer, now: at(0.4)
                )
                try ledger.closeTask(id: task.id, now: at(0.6))
            }
        }
    }
}
