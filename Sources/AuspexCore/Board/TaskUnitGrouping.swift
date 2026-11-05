import AgentSessionKit
import AgentSessionLive
import Foundation

/// How the task wall divides its cards into sections.
///
/// The same four axes the session wall had — see ``BoardGroupBy`` — asked of
/// units instead of sessions, with one change of meaning that falls out of the
/// wall being a task wall:
///
/// **``BoardGroupBy/tree`` no longer makes sections.** A delegation family is
/// what a card now *is*, so a section per tree would be a section per card.
/// What the axis is worth on this wall is the other half of what it always
/// meant — *show me the shape inside* — so choosing it opens every card's
/// member list, and sections stay divided by project. That is why this
/// function answers a `Bool` alongside the sections.
public enum TaskUnitGrouping {
    /// The single section's title when nothing is grouped.
    public static let allTasksTitle = "All tasks"
    /// The section for units whose work is in no resolvable project.
    public static let noProjectTitle = "No project"

    /// Divides `units` into the sections the wall draws.
    ///
    /// - Parameters:
    ///   - units: the frame's units, already in board order. That order is
    ///     preserved inside every section and decides section order, so the
    ///     project holding the blocked task is at the top of the wall.
    ///   - board: the frame, for project display names.
    ///   - groupBy: which axis to divide along.
    /// - Returns: the sections, in display order. Empty sections are dropped
    ///   rather than drawn with a zero in them.
    public static func groups(
        for units: [TaskUnit],
        board: BoardSnapshot,
        groupBy: BoardGroupBy
    ) -> [TaskUnitGroup] {
        guard !units.isEmpty else { return [] }
        switch groupBy {
        case .none:
            return [group(id: "all", title: allTasksTitle, units: units)]
        case .harness:
            return harnessGroups(units)
        // The tree axis divides by project too — what it changes is what the
        // cards show, not how they are filed. See the type's note.
        case .project, .tree:
            return projectGroups(units, board: board)
        }
    }

    /// Whether this axis asks for every card's members to be listed.
    public static func expandsMembers(_ groupBy: BoardGroupBy) -> Bool { groupBy == .tree }

    /// The units that have left the wall: no session still running, and
    /// nothing anybody has to do about them.
    ///
    /// The same bargain the session wall made — see ``EndedSessions`` — and it
    /// is worth more here, because a unit folds a whole family into one row.
    /// A unit in review or blocked stays on the wall however dead its
    /// processes are: work waiting to be read is not history.
    public static func split(_ units: [TaskUnit]) -> (live: [TaskUnit], ended: [TaskUnit]) {
        var live: [TaskUnit] = []
        var ended: [TaskUnit] = []
        for unit in units {
            if unit.bucket == .ended {
                ended.append(unit)
            } else {
                live.append(unit)
            }
        }
        return (live, ended)
    }

    /// Harness sections in catalog order, by the *lead's* harness.
    ///
    /// The lead and not "every harness in the family": a Claude Code session
    /// that delegated to a Codex `exec` is one piece of work, and putting its
    /// card in two sections would be counting it twice on a wall whose whole
    /// job is to count each piece of work once.
    private static func harnessGroups(_ units: [TaskUnit]) -> [TaskUnitGroup] {
        let byHarness = Dictionary(grouping: units) { $0.lead.harness }
        return Harness.allCases.compactMap { harness in
            guard let group = byHarness[harness], !group.isEmpty else { return nil }
            return self.group(
                id: "harness:\(harness.rawValue)",
                title: harness.displayName,
                harness: harness,
                units: group
            )
        }
    }

    /// Project sections, ordered by the rank of their first unit — so the
    /// repository holding the blocked task is at the top — with Projectless
    /// after all of them.
    ///
    /// Projectless is one section whatever filed a unit there: a scratch
    /// thread, a session with no directory, a task a ledger entry from an
    /// earlier build put under a harness's own key. Its detached helper runs
    /// are counted on the section rather than drawn — see
    /// ``TaskUnit/isDetachedHelper``.
    private static func projectGroups(
        _ units: [TaskUnit],
        board: BoardSnapshot
    ) -> [TaskUnitGroup] {
        var order: [String] = []
        var byProject: [String: [TaskUnit]] = [:]
        var ungrouped: [TaskUnit] = []
        var helpers = 0

        for unit in units {
            guard let raw = unit.projectKey else {
                ungrouped.append(unit)
                continue
            }
            let key = TaskProject.canonicalKey(raw)
            if PseudoProject.isProjectless(key), unit.isDetachedHelper, unit.bucket != .ended {
                helpers += 1
                continue
            }
            if byProject[key] == nil {
                byProject[key] = []
                order.append(key)
            }
            byProject[key]?.append(unit)
        }
        if helpers > 0, byProject[PseudoProject.projectlessKey] == nil {
            byProject[PseudoProject.projectlessKey] = []
            order.append(PseudoProject.projectlessKey)
        }

        let ordered = PseudoProject.projectlessLast(board.claims.pinnedFirst(order) { $0 })
        var groups = ordered.map { key -> TaskUnitGroup in
            let isProjectless = PseudoProject.isProjectless(key)
            return group(
                id: "project:\(key)",
                title: TaskProject.displayName(forKey: key, in: board),
                subtitle: isProjectless ? nil : TaskProject.subtitle(forKey: key),
                units: byProject[key] ?? [],
                helperCount: isProjectless ? helpers : 0
            )
        }
        if !ungrouped.isEmpty {
            groups.append(group(id: "project:none", title: noProjectTitle, units: ungrouped))
        }
        return groups
    }

    /// One section, with its units filed under their milestones.
    ///
    /// Milestone runs in the order their first unit appears, which is urgency
    /// order — so the heading over the blocked work is the first heading in
    /// the section, and the units under no milestone (the ordinary case) sit
    /// wherever their urgency puts them rather than being exiled to the end.
    static func group(
        id: String,
        title: String,
        subtitle: String? = nil,
        harness: Harness? = nil,
        units: [TaskUnit],
        helperCount: Int = 0
    ) -> TaskUnitGroup {
        var order: [Int64?] = []
        var byPlan: [Int64?: [TaskUnit]] = [:]
        for unit in units {
            let plan = unit.planID
            if byPlan[plan] == nil {
                byPlan[plan] = []
                order.append(plan)
            }
            byPlan[plan]?.append(unit)
        }
        let milestones = order.map { plan in
            let members = byPlan[plan] ?? []
            return TaskUnitGroup.Milestone(
                id: plan.map { "\(id)#plan:\($0)" } ?? "\(id)#loose",
                title: plan == nil ? nil : members.first?.planTitle,
                units: members
            )
        }
        return TaskUnitGroup(
            id: id,
            title: title,
            subtitle: subtitle,
            harness: harness,
            liveCount: units.count { $0.counts.live > 0 },
            milestones: milestones,
            helperCount: helperCount
        )
    }
}

/// The numbers across the top, asked of units.
///
/// A separate initialiser rather than a separate type, because the header, the
/// menu bar and the sidebar have always quoted ``BoardSummary`` and the whole
/// change here is *what is being counted*: a delegation of four used to be
/// four working sessions and is now one working task. Everything downstream —
/// the chips, the colours, the filter a click applies — is unchanged.
extension BoardSummary {
    /// A summary of a frame's units. Each unit is in exactly one bucket, so
    /// the five numbers add up to the number of cards on the wall.
    public init(units: [TaskUnit]) {
        var tally: [TaskLedger.Bucket: Int] = [:]
        for unit in units { tally[unit.bucket, default: 0] += 1 }
        self.init(
            needsYou: tally[.needsYou] ?? 0,
            doneReported: tally[.doneReported] ?? 0,
            working: tally[.working] ?? 0,
            idle: tally[.idle] ?? 0,
            ended: tally[.ended] ?? 0
        )
    }
}
