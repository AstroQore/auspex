import AgentSessionKit
import AgentSessionLive
import Foundation
import Testing

@testable import AuspexCore

/// The wall's bodies: what they may look like, and who gets which.
///
/// Two properties, and both are about a wall of ninety rather than a wall of
/// eight. Every body has to read as **chubby** at 56 points and still at 22,
/// because a shape with a direction in it competes with the one thing the face
/// uses direction for. And the assignment has to be **deterministic and
/// spread**: the avatar a person was watching must be the same avatar after a
/// relaunch, and ten sessions started a second apart must not all be circles.
@Suite("Flock shapes")
struct FlockShapesTests {
    @Test("every body on the wall is plump")
    func familyIsPlump() {
        #expect(FlockShapes.family.count == 10)
        for id in FlockShapes.family {
            let radii = BloubSkins.radii(id)
            let low = radii.min() ?? 0
            let high = radii.max() ?? 1
            #expect(
                FlockShapes.isPlump(radii),
                "\(id.rawValue) is \(low / high) of its widest, under \(FlockShapes.plumpness)"
            )
        }
    }

    @Test("the pointed bodies are out of the family and still in the engine")
    func pointedShapesAreNotOnTheWall() {
        for id in [BloubShapeID.droplet, .triangle, .capsule, .hexagon] {
            #expect(!FlockShapes.family.contains(id))
            // Still in the catalogue: the transition suite morphs between them
            // and the reference renders use them.
            #expect(BloubSkins.byID[id] != nil)
        }
    }

    @Test("a session keeps its body across relaunches, re-sorts and gaps")
    func assignmentIsStable() {
        let key = SessionKey(harness: .codex, sessionID: "0198f6d0-1111-2222-3333-444455556666")
        #expect(FlockShapes.shape(for: key) == FlockShapes.shape(for: key))
        // The harness is not in it: the same id under another harness is the
        // same creature in another colour.
        let other = SessionKey(harness: .cursor, sessionID: key.sessionID)
        #expect(FlockShapes.shape(for: key) != FlockShapes.shape(for: other))
    }

    @Test("ten sessions minted in a row do not march through the family")
    func consecutiveSeedsSpread() {
        let shapes = (0..<10).map {
            FlockShapes.shape(seed: "claudeCode:0198f6d0-aaaa-bbbb-cccc-00000000000\($0)")
        }
        // Not all ten distinct — a hash is not a permutation, and pretending
        // otherwise would mean keeping a table of what has been handed out. But
        // a hash whose low bits leaked would give one or two, and that is the
        // failure this catches.
        #expect(Set(shapes).count >= 6)
        #expect(shapes != FlockShapes.family)
    }

    @Test("over a wall's worth of sessions every body is used, and none twice over")
    func assignmentSpreadsAcrossTheFamily() {
        var tally: [BloubShapeID: Int] = [:]
        let count = 600
        for index in 0..<count {
            let key = SessionKey(harness: .claudeCode, sessionID: "session-\(index)")
            tally[FlockShapes.shape(for: key), default: 0] += 1
        }
        #expect(tally.keys.count == FlockShapes.family.count)
        let fair = Double(count) / Double(FlockShapes.family.count)
        for (id, seen) in tally {
            #expect(
                Double(seen) > fair / 2 && Double(seen) < fair * 2,
                "\(id.rawValue) took \(seen) of \(count), fair share is \(fair)"
            )
        }
    }
}
