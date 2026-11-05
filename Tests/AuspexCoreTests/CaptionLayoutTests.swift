import AuspexCore
import CoreGraphics
import Foundation
import Testing

/// Where Now's balloons hang: never over each other, never under the strip's
/// chrome, the urgent ones first.
@Suite("Caption layout")
struct CaptionLayoutTests {
    private static let bounds = CGRect(x: 0, y: 0, width: 1_000, height: 400)
    /// One line of balloons, in a y-up picture.
    private static let line: CGFloat = 24

    private static func item(
        _ id: String, x: CGFloat, y: CGFloat = 200, width: CGFloat = 200,
        _ priority: CaptionLayout.Priority = .working
    ) -> CaptionLayout.Item {
        CaptionLayout.Item(id: id, rect: CGRect(x: x, y: y, width: width, height: 20), priority: priority)
    }

    /// The rectangles the placements describe, for checking that nothing
    /// drawn as a balloon overlaps anything else drawn as one.
    private static func drawn(
        _ items: [CaptionLayout.Item], _ placements: [String: CaptionLayout.Placement]
    ) -> [String: CGRect] {
        var result: [String: CGRect] = [:]
        for item in items {
            guard let placement = placements[item.id],
                  let frame = CaptionLayout.frame(of: item.rect, at: placement, line: line, flipOffset: 12)
            else { continue }
            result[item.id] = frame
        }
        return result
    }

    @Test("Balloons that do not touch stay where they hang")
    func separateBalloonsStay() {
        let items = [Self.item("a", x: 0), Self.item("b", x: 400), Self.item("c", x: 800, width: 150)]
        let placements = CaptionLayout.resolve(items, bounds: Self.bounds, line: Self.line)
        #expect(placements == ["a": .lines(0), "b": .lines(0), "c": .lines(0)])
    }

    @Test("Of two overlapping balloons the less urgent one moves a line, up first")
    func lowerPriorityMoves() {
        let items = [
            Self.item("working", x: 100, .working),
            Self.item("needs", x: 150, .needsYou),
        ]
        let placements = CaptionLayout.resolve(items, bounds: Self.bounds, line: Self.line)
        #expect(placements["needs"] == .lines(0))
        #expect(placements["working"] == .lines(1))
    }

    @Test("Needs you outranks may need you, which outranks working")
    func priorityOrder() {
        let items = [
            Self.item("working", x: 100, .working),
            Self.item("maybe", x: 120, .mayNeedYou),
            Self.item("needs", x: 140, .needsYou),
        ]
        let placements = CaptionLayout.resolve(items, bounds: Self.bounds, line: Self.line)
        #expect(placements["needs"] == .lines(0))
        #expect(placements["maybe"] == .lines(1))
        #expect(placements["working"] == .lines(-1))
    }

    @Test("A balloon with nowhere free to go folds into a dot")
    func crowdedBalloonFolds() {
        let items = (0..<4).map { Self.item("b\($0)", x: CGFloat($0) * 10, .working) }
        let placements = CaptionLayout.resolve(items, bounds: Self.bounds, line: Self.line)
        #expect(placements.values.filter { $0 == .dot }.count == 1)
        #expect(Set(placements.values.filter { $0 != .dot }) == [.lines(0), .lines(1), .lines(-1)])
    }

    @Test("No two balloons drawn overlap, whatever the crowd")
    func nothingDrawnOverlaps() {
        // A deterministic scatter of balloons of every priority.
        var generator = SeededRandom(seed: 7)
        for _ in 0..<50 {
            let items: [CaptionLayout.Item] = (0..<6).map { index in
                let x = CGFloat(generator.next() % 800)
                let y = CGFloat(40 + generator.next() % 320)
                let width = CGFloat(80 + generator.next() % 220)
                let priority = CaptionLayout.Priority(rawValue: Int(generator.next() % 3)) ?? .working
                return Self.item("b\(index)", x: x, y: y, width: width, priority)
            }
            let placements = CaptionLayout.resolve(items, bounds: Self.bounds, line: Self.line)
            #expect(placements.count == items.count)
            let rects = Array(Self.drawn(items, placements).values)
            for (index, rect) in rects.enumerated() {
                for other in rects[(index + 1)...] { #expect(!rect.intersects(other)) }
            }
        }
    }

    @Test("Nothing is placed under the strip's chrome")
    func safeAreasAreKeptClear() {
        // The tag row along the top of a y-up picture, and the legend in the
        // bottom right.
        let tagRow = CGRect(x: 0, y: 360, width: 1_000, height: 40)
        let legend = CGRect(x: 660, y: 0, width: 340, height: 40)
        let items = [
            Self.item("under-tag", x: 20, y: 362),
            Self.item("near-legend", x: 700, y: 30),
            Self.item("free", x: 300, y: 200),
        ]
        let placements = CaptionLayout.resolve(
            items, bounds: Self.bounds, safeAreas: [tagRow, legend], line: Self.line
        )
        for (id, rect) in Self.drawn(items, placements) {
            #expect(!rect.intersects(tagRow), "\(id)")
            #expect(!rect.intersects(legend), "\(id)")
        }
        #expect(placements["free"] == .lines(0))
        // Down a line clears the tag row; up a line clears the legend.
        #expect(placements["under-tag"] == .lines(-1))
        #expect(placements["near-legend"] == .lines(1))
    }

    @Test("A moved balloon stays inside the picture; one that cannot folds")
    func shiftsStayInBounds() {
        // Two at the very top of the picture: the second cannot go up.
        let items = [
            Self.item("first", x: 0, y: 380, .needsYou),
            Self.item("second", x: 50, y: 380, .working),
        ]
        let placements = CaptionLayout.resolve(items, bounds: Self.bounds, line: Self.line)
        #expect(placements["second"] == .lines(-1))
    }

    @Test("A balloon that would run off the right-hand edge hangs to the left of its person")
    func balloonsFlipAtTheRightEdge() {
        let items = [
            Self.item("edge", x: 900, width: 220),
            Self.item("middle", x: 300, width: 220),
        ]
        let placements = CaptionLayout.resolve(items, bounds: Self.bounds, line: Self.line, flipOffset: 12)
        #expect(placements["edge"] == .flipped(0))
        #expect(placements["middle"] == .lines(0))
        let frame = CaptionLayout.frame(of: items[0].rect, at: .flipped(0), line: Self.line, flipOffset: 12)
        #expect(frame.map { Self.bounds.contains($0) } == true)
        // Its tail stays over its person: the flipped balloon ends where the
        // balloon as drawn began, give or take the tail.
        #expect(frame?.maxX == 912)

        // Without a flip offset nothing flips, and the balloon is clipped.
        let unflipped = CaptionLayout.resolve(items, bounds: Self.bounds, line: Self.line)
        #expect(unflipped["edge"] == .lines(0))
    }

    @Test("The same balloons always land in the same places")
    func deterministic() {
        let items = [
            Self.item("a", x: 100), Self.item("b", x: 110), Self.item("c", x: 120),
            Self.item("d", x: 130, .mayNeedYou),
        ]
        let first = CaptionLayout.resolve(items, bounds: Self.bounds, line: Self.line)
        let second = CaptionLayout.resolve(items.reversed(), bounds: Self.bounds, line: Self.line)
        #expect(first == second)
    }
}
