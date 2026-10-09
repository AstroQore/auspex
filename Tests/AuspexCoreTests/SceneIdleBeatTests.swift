import AuspexCore
import Foundation
import Testing

/// The office's idle motion comes in stirs — see ``SceneIdleBeat``.
@Suite("Scene idle beat")
struct SceneIdleBeatTests {
    @Test("Stirs come every three to eight seconds, and not on a fixed period")
    func gapsAreBoundedAndVaried() {
        let gaps = (0..<200).map { SceneIdleBeat.gap(after: UInt64($0)) }
        #expect(gaps.allSatisfy { $0 >= SceneIdleBeat.shortestGap && $0 < SceneIdleBeat.longestGap })
        #expect(Set(gaps.map { Int($0 * 10) }).count > 20)
        let mean = gaps.reduce(0, +) / Double(gaps.count)
        #expect(mean > 4.5 && mean < 6.5)
    }

    @Test("About three in five idle people join a stir, and not always the same ones")
    func participationIsPartial() {
        let ids = (0..<60).map { "slot.\($0)" }
        for round in UInt64(1)...20 {
            let joined = ids.filter { SceneIdleBeat.joins($0, round: round) }.count
            #expect(joined > 20 && joined < 52)
        }
        // Every place sits some stirs out and joins others.
        for id in ids {
            let rounds = (UInt64(1)...40).filter { SceneIdleBeat.joins(id, round: $0) }.count
            #expect(rounds > 8 && rounds < 40)
        }
    }

    @Test("Joining is staggered inside a stir, so a garden does not move in unison")
    func delaysAreStaggered() {
        let delays = (0..<40).map { SceneIdleBeat.delay("seat.\($0)", round: 7) }
        #expect(delays.allSatisfy { $0 >= 0 && $0 < SceneIdleBeat.longestDelay })
        #expect(Set(delays.map { Int($0 * 100) }).count > 15)
    }

    @Test("The rhythm is a pure function of the id and the stir")
    func rhythmIsDeterministic() {
        #expect(SceneIdleBeat.gap(after: 9) == SceneIdleBeat.gap(after: 9))
        #expect(SceneIdleBeat.joins("desk.3", round: 4) == SceneIdleBeat.joins("desk.3", round: 4))
        #expect(SceneIdleBeat.delay("desk.3", round: 4) == SceneIdleBeat.delay("desk.3", round: 4))
    }
}
