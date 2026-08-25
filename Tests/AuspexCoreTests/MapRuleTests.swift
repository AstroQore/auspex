import AgentSessionKit
import Foundation
import Testing

@testable import AuspexCore

@Suite("Map rules")
struct MapRuleTests {
    private let candidate = MapRuleCandidate(
        nodeID: "node",
        projectKey: "/Users/example/Code/auspex",
        harness: .codex,
        labels: ["swift", "ui"],
        status: .doing,
        attention: .working
    )

    @Test("nested boolean rules evaluate without flattening their meaning")
    func nestedRules() throws {
        let rule = MapRule.all([
            .predicate(.harness(.codex)),
            .any([
                .predicate(.label("swift")),
                .predicate(.attention(.needsYou)),
            ]),
            .not(.predicate(.status(.done))),
        ])
        try rule.validate()
        #expect(rule.matches(candidate))
        #expect(!MapRule.not(rule).matches(candidate))
    }

    @Test("rule depth and predicate count are bounded")
    func validationBounds() {
        let tooDeep = MapRule.not(.not(.not(.not(.predicate(.label("x"))))))
        #expect(throws: MapRuleError.tooDeep(maximum: 4)) { try tooDeep.validate() }

        let tooMany = MapRule.all(
            (0...MapRule.maximumPredicates).map { .predicate(.label("l\($0)")) }
        )
        #expect(throws: MapRuleError.tooManyPredicates(maximum: 50)) {
            try tooMany.validate()
        }
    }

    @Test("membership overrides win over automatic matching")
    func overrides() {
        let now = Date(timeIntervalSince1970: 1)
        #expect(MapMembership(
            boardID: "b", nodeID: "n", ruleMatches: false,
            override: .include, updatedAt: now
        ).isVisible)
        #expect(!MapMembership(
            boardID: "b", nodeID: "n", ruleMatches: true,
            override: .exclude, updatedAt: now
        ).isVisible)
    }

    @Test("a new project starts beyond a full four-card row")
    func projectPlacementGutter() {
        let existing = (0..<6).map { index in
            MapPlacementPlanner.Existing(
                point: CGPoint(x: (index % 4) * 320, y: (index / 4) * 148),
                projectKey: "first"
            )
        }
        let next = MapPlacementPlanner.next(projectKey: "second", existing: existing)
        let firstProjectRightEdge = CGFloat(3 * 320) + MapPlacement.cardSize.width
        #expect(next.x > firstProjectRightEdge)
    }
}
