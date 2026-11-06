import CoreGraphics
import Foundation

/// Where Now's balloons hang so that no two cover each other, and none is
/// under the strip's own chrome.
///
/// ## The rule
///
/// A balloon hangs over its person's head. Two people a desk apart with a
/// sentence each are two balloons on one line, and the second drawn covers the
/// first — which is how a stage of six balloons came to show three, two of
/// them half a sentence. So balloons are placed in order of what they say,
/// most urgent first — *needs you*, then *may need you*, then *working* — and
/// each one takes the first of these that is free:
///
/// 1. where it hangs;
/// 2. one line up;
/// 3. one line down.
///
/// A balloon hangs to the right of its person, so one near the right-hand
/// edge of the picture would run off it; there, each of those three is tried
/// *flipped* first — the balloon hung to the left of its person instead —
/// and only if neither way fits is a balloon left to be clipped.
///
/// Free means: inside the picture, clear of every balloon already placed, and
/// clear of the safe areas — the view's tag and hint, its fold chevron, its
/// legend. A balloon with nowhere free to go is folded into a dot over its
/// person's head, which says *there is something here* and opens under the
/// pointer.
///
/// Pure and total: the same balloons in the same picture always land in the
/// same places, so a board frame that changes nothing moves nothing.
public enum CaptionLayout {
    /// How much a balloon matters. Higher is placed first.
    public enum Priority: Int, Sendable, Comparable {
        case working = 0
        case mayNeedYou = 1
        case needsYou = 2

        public static func < (lhs: Priority, rhs: Priority) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    /// One balloon, where it would hang.
    public struct Item: Sendable, Equatable {
        public let id: String
        /// Where it hangs before anything moves it, in the picture's own
        /// coordinates.
        public let rect: CGRect
        public let priority: Priority

        public init(id: String, rect: CGRect, priority: Priority) {
            self.id = id
            self.rect = rect
            self.priority = priority
        }
    }

    /// Where one balloon went.
    public enum Placement: Sendable, Hashable {
        /// Moved by this many lines — `0` is where it hangs, positive is up.
        case lines(Int)
        /// Hung to the left of its person rather than the right, and moved by
        /// this many lines.
        case flipped(Int)
        /// Folded into a dot over its person.
        case dot

        /// How many lines it was moved, when it is drawn as a balloon.
        public var lines: Int? {
            switch self {
            case .lines(let lines), .flipped(let lines): lines
            case .dot: nil
            }
        }
    }

    /// The rectangle a balloon at `rect` occupies once placed, or `nil` for a
    /// dot.
    ///
    /// - Parameter flipOffset: how far right of the balloon's left edge its
    ///   tail is when it hangs to the left instead — the flipped balloon's
    ///   right edge.
    public static func frame(
        of rect: CGRect, at placement: Placement, line: CGFloat, flipOffset: CGFloat
    ) -> CGRect? {
        switch placement {
        case .lines(let lines):
            return rect.offsetBy(dx: 0, dy: CGFloat(lines) * line)
        case .flipped(let lines):
            return rect.offsetBy(dx: flipOffset - rect.width, dy: CGFloat(lines) * line)
        case .dot:
            return nil
        }
    }

    /// The lines a balloon tries, in order: in place, up one, down one.
    public static let candidates = [0, 1, -1]

    /// The air kept between two balloons, so two that merely touch are not
    /// read as one.
    public static let spacing: CGFloat = 2

    /// Places every balloon.
    ///
    /// - Parameters:
    ///   - items: the balloons, in any order.
    ///   - bounds: the picture. A balloon moved off its line must stay inside
    ///     it vertically; one that hangs where it always does may run off an
    ///     edge, which is clipping rather than covering.
    ///   - safeAreas: what no balloon may be under.
    ///   - line: how far one line is, signed in the direction "up" runs —
    ///     positive in SpriteKit's y-up world.
    ///   - flipOffset: see ``frame(of:at:line:flipOffset:)``. `0` never
    ///     flips a balloon.
    /// - Returns: a placement for every item, by id.
    public static func resolve(
        _ items: [Item],
        bounds: CGRect,
        safeAreas: [CGRect] = [],
        line: CGFloat,
        flipOffset: CGFloat = 0
    ) -> [String: Placement] {
        let ordered = items.sorted { lhs, rhs in
            if lhs.priority != rhs.priority { return lhs.priority > rhs.priority }
            if lhs.rect.minX != rhs.rect.minX { return lhs.rect.minX < rhs.rect.minX }
            return lhs.id < rhs.id
        }
        let hasBounds = !bounds.isNull && !bounds.isEmpty
        var placed: [CGRect] = []
        var result: [String: Placement] = [:]

        func fits(_ candidate: CGRect, shifted: Bool, wholeWidth: Bool) -> Bool {
            if hasBounds, shifted, candidate.minY < bounds.minY || candidate.maxY > bounds.maxY {
                return false
            }
            if hasBounds, wholeWidth,
               candidate.minX < bounds.minX - 0.5 || candidate.maxX > bounds.maxX + 0.5 {
                return false
            }
            if safeAreas.contains(where: { $0.intersects(candidate) }) { return false }
            let padded = candidate.insetBy(dx: -spacing, dy: -spacing)
            return !placed.contains(where: { $0.intersects(padded) })
        }

        for item in ordered {
            // A balloon that runs off the right-hand edge where it hangs tries
            // each line flipped first; one that fits as drawn never flips.
            let overflows = hasBounds && flipOffset > 0 && item.rect.maxX > bounds.maxX + 0.5
            var options: [Placement] = []
            for shift in candidates {
                if overflows { options.append(.flipped(shift)) }
                options.append(.lines(shift))
            }
            var landed: Placement = .dot
            // First with the whole balloon inside the picture; failing that,
            // as before, letting the edge clip it rather than folding it.
            search: for wholeWidth in overflows ? [true, false] : [false] {
                for option in options {
                    guard let candidate = frame(
                        of: item.rect, at: option, line: line, flipOffset: flipOffset
                    ) else { continue }
                    let shifted = option.lines != 0
                    guard fits(candidate, shifted: shifted, wholeWidth: wholeWidth) else { continue }
                    placed.append(candidate)
                    landed = option
                    break search
                }
            }
            result[item.id] = landed
        }
        return result
    }
}
