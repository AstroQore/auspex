import Testing

@testable import AuspexCore

/// The window's column rule: what a launch opens with, and what is never
/// allowed to stay on screen.
@Suite("Sidebar visibility")
struct SidebarVisibilityTests {
    @Test("a launch opens with all three columns, whatever the last one left")
    func launchAlwaysRestoresTheSidebar() {
        // The bug: the split view persisted a collapsed sidebar and the window
        // removed the toggle, so one stray ⌘⌥S was permanent. Every stored
        // state has to open the same window.
        for stored in SidebarColumns.allCases {
            #expect(SidebarVisibility.restored(from: stored) == .all)
        }
        #expect(SidebarVisibility.restored(from: nil) == .all)
    }

    @Test("a state that hides the board is corrected; one that only hides the sidebar is not")
    func onlyTheBoardIsNonNegotiable() {
        // Collapsing the sidebar is a gesture a person can mean, and the
        // toolbar's toggle is the way back from it — so it stands.
        #expect(SidebarVisibility.correction(for: .all) == nil)
        #expect(SidebarVisibility.correction(for: .boardAndTrace) == nil)
        // Losing the board as well is not something anybody asks for: it is
        // what a drag past the minimum width leaves behind.
        #expect(SidebarVisibility.correction(for: .traceOnly) == .all)
    }

    @Test("correcting is idempotent — the corrected state needs no correction")
    func correctionSettles() {
        for columns in SidebarColumns.allCases {
            let settled = SidebarVisibility.correction(for: columns) ?? columns
            #expect(SidebarVisibility.correction(for: settled) == nil)
        }
    }

    @Test("the sidebar is drawn in exactly one state, and the board in two")
    func whatEachStateShows() {
        #expect(SidebarColumns.allCases.filter(\.showsSidebar) == [.all])
        #expect(SidebarColumns.allCases.filter(\.showsBoard) == [.all, .boardAndTrace])
    }

    @Test("a state round-trips through its raw value")
    func rawValueRoundTrips() {
        // Persisted by name if it is ever persisted at all, so a renamed case
        // must be a deliberate migration rather than a silent reset.
        for columns in SidebarColumns.allCases {
            #expect(SidebarColumns(rawValue: columns.rawValue) == columns)
        }
    }
}
