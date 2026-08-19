import Testing

@testable import AuspexCore

@Suite("BoardViewMode")
struct BoardViewModeTests {
    @Test("the picker offers every mode, in declaration order")
    func pickerOrderIsDeclarationOrder() {
        // The header's segmented control is built from this, so a mode that
        // was added to the enum and not to the picker would be a mode nobody
        // could reach.
        #expect(BoardViewMode.pickerOrder == BoardViewMode.allCases)
        #expect(BoardViewMode.pickerOrder.first == .board)
    }

    @Test("every mode has a label and a symbol, and no two share either")
    func everyModeIsDistinguishable() {
        let titles = BoardViewMode.allCases.map(\.title)
        let symbols = BoardViewMode.allCases.map(\.systemImage)
        #expect(titles.allSatisfy { !$0.isEmpty })
        #expect(symbols.allSatisfy { !$0.isEmpty })
        // Two segments with one word between them is a control that cannot be
        // read, and the same is true of the symbol a narrow window falls back
        // to.
        #expect(Set(titles).count == titles.count)
        #expect(Set(symbols).count == symbols.count)
    }

    @Test("exactly one mode is about a single session")
    func onlyTrajectoryNeedsASelection() {
        // The picker disables what `requiresSelection` marks, and the board
        // model refuses to enter it with nothing selected. A second mode
        // acquiring the flag by accident would silently become unreachable
        // from an empty board.
        #expect(BoardViewMode.allCases.filter(\.requiresSelection) == [.trajectory])
        #expect(BoardViewMode.board.requiresSelection == false)
    }

    @Test("a mode round-trips through its raw value")
    func rawValueRoundTrips() {
        // The window restores its mode across launches by raw value, so a
        // rename would silently drop a person back to the board.
        for mode in BoardViewMode.allCases {
            #expect(BoardViewMode(rawValue: mode.rawValue) == mode)
        }
        #expect(BoardViewMode(rawValue: "office") == nil)
    }
}
