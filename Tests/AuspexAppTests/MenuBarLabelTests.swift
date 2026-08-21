import AuspexCore
import Foundation
import Testing

@testable import AuspexApp

/// The one part of this app a person sees while they are looking at something
/// else.
///
/// It is worth a suite of its own because it is the surface with the least
/// room and the most exposure: a status item that always shows `0 0 0` teaches
/// its reader to stop looking at it, and once they have stopped, nothing else
/// Auspex does will reach them.
@MainActor
@Suite("Menu bar label")
struct MenuBarLabelTests {
    private func summary(
        needsYou: Int = 0,
        doneReported: Int = 0,
        working: Int = 0,
        idle: Int = 0,
        ended: Int = 0
    ) -> BoardSummary {
        BoardSummary(
            needsYou: needsYou,
            doneReported: doneReported,
            working: working,
            idle: idle,
            ended: ended
        )
    }

    @Test("a quiet board shows the bird and nothing else")
    func quietBoard() {
        #expect(MenuBarLabel.segments(summary()).isEmpty)
        #expect(MenuBarLabel.accessibilityLabel(summary()) == "Auspex, nothing running")
    }

    @Test("history never reaches the menu bar")
    func endedIsNotShown() {
        // The smallest, most permanent piece of chrome on the screen must not
        // be quoting the least urgent number on the board.
        #expect(MenuBarLabel.segments(summary(ended: 400)).isEmpty)
    }

    @Test("the counts read in the board's own order")
    func order() {
        let segments = MenuBarLabel.segments(
            summary(needsYou: 2, doneReported: 1, working: 3, idle: 9, ended: 12)
        )
        #expect(segments.map(\.count) == ["2", "1", "3", "9"])
        #expect(segments.map(\.symbol) == [
            "exclamationmark.triangle.fill", "checkmark.circle", "play.fill", "hourglass",
        ])
    }

    @Test("an empty bucket is dropped rather than shown as a zero")
    func zeroesAreDropped() {
        let segments = MenuBarLabel.segments(summary(needsYou: 1, working: 4))
        #expect(segments.map(\.count) == ["1", "4"])
        #expect(!segments.contains { $0.symbol == "checkmark.circle" })
    }

    @Test("VoiceOver hears the same four numbers, in words")
    func spokenLabel() {
        let spoken = MenuBarLabel.accessibilityLabel(
            summary(needsYou: 2, doneReported: 1, working: 3, idle: 9)
        )
        #expect(spoken == "Auspex, 2 needs you, 1 done, 3 working, 9 idle")
    }

    @Test("the label's numbers are the header's numbers")
    func agreesWithTheHeader() {
        // Two views of one board. A menu bar that counted differently from the
        // window would make one of them wrong, and a person cannot tell which.
        let summary = summary(needsYou: 2, doneReported: 1, working: 3, idle: 9, ended: 12)
        let chips = summary.chips
        #expect(chips.map(\.value) == MenuBarLabel.segments(summary).compactMap { Int($0.count) })
        #expect(chips.map(\.kind) == [.needsYou, .doneReported, .working, .idle])
    }
}
