import AgentSessionKit
import AgentSessionLive
import Foundation

/// What the wall is narrowed to, beyond the project it is bound to.
///
/// ## Why these five and not a query language
///
/// Each one is a question somebody asks out loud while looking at a board of
/// thirty tasks — *what is urgent*, *what is tagged `adapter`*, *what is Codex
/// doing*, *what could I start right now*, *what has nobody taken* — and each
/// answers in one click. A filter that needed a sentence typed into it would
/// be a filter nobody used twice.
///
/// They compose by conjunction and nothing else. Two values of the same facet
/// are not offered: a wall showing "urgent or important" is a wall showing
/// most of itself, and the chip that produced it teaches nothing.
///
/// Applied to units rather than to sessions, and in the assembler rather than
/// in a view body — the same rule everything else on this path follows.
public struct TaskFilters: Sendable, Equatable, Hashable {
    /// Only tasks at this importance.
    public var importance: TaskImportance?
    /// Only tasks carrying this label.
    public var label: String?
    /// Only tasks whose *lead* runs on this harness. The lead and not any
    /// member, for the reason the harness sections use: one piece of work
    /// belongs in one place.
    public var harness: Harness?
    /// Only tasks whose dependencies are all closed.
    public var readyOnly: Bool
    /// Whether somebody is holding it.
    public var claim: Claim?
    /// Only the claims whose session ended without finishing.
    public var orphanedOnly: Bool

    /// Whether anybody has taken the task.
    ///
    /// "Claimed" rather than "mine", which is what a board with one human and
    /// a dozen agents actually means by it: every task here is the person's,
    /// and the useful cut is between work an agent has picked up and work
    /// waiting for one.
    public enum Claim: String, Sendable, Hashable, CaseIterable {
        case claimed
        case unclaimed

        public var label: String {
            switch self {
            case .claimed: "claimed"
            case .unclaimed: "unclaimed"
            }
        }
    }

    public static let none = TaskFilters()

    public init(
        importance: TaskImportance? = nil,
        label: String? = nil,
        harness: Harness? = nil,
        readyOnly: Bool = false,
        claim: Claim? = nil,
        orphanedOnly: Bool = false
    ) {
        self.importance = importance
        self.label = label
        self.harness = harness
        self.readyOnly = readyOnly
        self.claim = claim
        self.orphanedOnly = orphanedOnly
    }

    /// Whether anything is narrowed at all.
    public var isEmpty: Bool {
        importance == nil && label == nil && harness == nil && !readyOnly && claim == nil
            && !orphanedOnly
    }

    /// How many facets are on — the number on the "clear" button.
    public var count: Int {
        [importance != nil, label != nil, harness != nil, readyOnly, claim != nil, orphanedOnly]
            .count { $0 }
    }

    /// Whether one unit survives.
    public func keeps(_ unit: TaskUnit) -> Bool {
        if let importance, unit.importance != importance { return false }
        if let label, !unit.labels.contains(label) { return false }
        if let harness, unit.lead.harness != harness { return false }
        if readyOnly, !unit.isReady { return false }
        if orphanedOnly, !unit.isClaimOrphaned { return false }
        switch claim {
        case .claimed where unit.claim == nil: return false
        case .unclaimed where unit.claim != nil: return false
        default: break
        }
        return true
    }

    /// The units that survive, in the order given.
    public func apply(to units: [TaskUnit]) -> [TaskUnit] {
        isEmpty ? units : units.filter(keeps)
    }

    // MARK: - What the bar offers

    /// The facets worth showing a control for, derived from what is actually
    /// on the wall.
    ///
    /// A menu of every label the ledger has ever held would be a menu of
    /// labels that match nothing. This offers only what the frame in hand can
    /// answer, which also means the menu shrinks as the board does — and a
    /// filter that is on but no longer offered stays on and stays visible, so
    /// nobody is left with an empty wall and no explanation.
    public struct Options: Sendable, Equatable {
        public var importances: [TaskImportance]
        public var labels: [String]
        public var harnesses: [Harness]
        public var hasOrphans: Bool
        public var hasDependencies: Bool

        public init(
            importances: [TaskImportance] = [],
            labels: [String] = [],
            harnesses: [Harness] = [],
            hasOrphans: Bool = false,
            hasDependencies: Bool = false
        ) {
            self.importances = importances
            self.labels = labels
            self.harnesses = harnesses
            self.hasOrphans = hasOrphans
            self.hasDependencies = hasDependencies
        }

        public static let none = Options()

        /// Whether the bar has anything to offer at all.
        public var isEmpty: Bool {
            importances.isEmpty && labels.isEmpty && harnesses.count < 2 && !hasOrphans
                && !hasDependencies
        }
    }

    /// What a frame's units offer to filter by.
    ///
    /// One pass, and it runs on the assembler's executor with everything else.
    public static func options(for units: [TaskUnit]) -> Options {
        var importances: Set<TaskImportance> = []
        var labels: Set<String> = []
        var harnesses: Set<Harness> = []
        var hasOrphans = false
        var hasDependencies = false
        for unit in units {
            if unit.importance.isMarked { importances.insert(unit.importance) }
            for label in unit.labels { labels.insert(label) }
            harnesses.insert(unit.lead.harness)
            if unit.isClaimOrphaned { hasOrphans = true }
            if !unit.dependsOn.isEmpty { hasDependencies = true }
        }
        return Options(
            importances: TaskImportance.allCases.filter(importances.contains),
            labels: labels.sorted(),
            harnesses: Harness.allCases.filter(harnesses.contains),
            hasOrphans: hasOrphans,
            hasDependencies: hasDependencies
        )
    }
}
