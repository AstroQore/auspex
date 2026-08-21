import Foundation
import Testing

@testable import AuspexApp

/// What the Harnesses rack draws in its MCP column.
///
/// The column is the one part of the rack whose width is decided by somebody
/// else's configuration file, and a machine with two dozen MCP servers on it
/// turned an eight-row page into eight paragraphs that ran out over the hook
/// state beside them. The cap and the shortening are what bound it, so they
/// are asserted here rather than left to whatever width the column was handed.
@Suite("Rack chips")
struct RackChipsTests {
    @Test("a short list is drawn whole, globals before scoped ones")
    func shortListIsWhole() {
        let chips = RackChips(names: ["auspex", "github"], scoped: ["local-notes"])
        #expect(chips.shown.map(\.name) == ["auspex", "github", "local-notes"])
        #expect(chips.shown.map(\.isScoped) == [false, false, true])
        #expect(chips.hidden == 0)
    }

    @Test("the cap counts both lists together")
    func theCapIsShared() {
        // Five and five: neither list reaches the limit on its own, and a cap
        // applied per list would draw ten chips.
        let chips = RackChips(
            names: (0..<5).map { "global-\($0)" },
            scoped: (0..<5).map { "scoped-\($0)" }
        )
        #expect(chips.shown.count == RackChips.limit)
        #expect(chips.hidden == 10 - RackChips.limit)
        // The stronger fact survives the cap: every server available
        // everywhere is drawn before the first one that is available in a
        // single directory.
        #expect(chips.shown.map(\.isScoped) == [false, false, false, false, false, true])
        #expect(chips.hiddenHelp.contains("scoped-4"))
    }

    @Test("a long name keeps both ends")
    func longNamesKeepBothEnds() {
        let shortened = RackChips.shorten("cloudflare-observability")
        #expect(shortened.count == RackChips.nameLimit)
        #expect(shortened.hasPrefix("cloud"))
        #expect(shortened.hasSuffix("lity"))
        #expect(shortened.contains("…"))
        // Two servers that differ only at the end stay distinguishable, which
        // is the entire reason the middle is what goes.
        #expect(RackChips.shorten("cloudflare-docs") != shortened)
    }

    @Test("a name that fits is left alone")
    func shortNamesAreUntouched() {
        #expect(RackChips.shorten("auspex") == "auspex")
        #expect(RackChips.shorten("xiaodianpin-0856").count <= RackChips.nameLimit)
    }
}
