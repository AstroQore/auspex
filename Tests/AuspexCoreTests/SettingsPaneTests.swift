import Testing

@testable import AuspexCore

/// The stale subtitle bug was a copy problem, not a layout problem: one line
/// written beside one pane and then shown over five others. These are the
/// checks that make a seventh pane impossible to add without writing its own.
@Suite("Settings · every pane introduces itself")
struct SettingsPaneTests {
    @Test("every pane has a title and a subtitle of its own")
    func everyPaneSpeaksForItself() {
        for pane in SettingsPane.allCases {
            #expect(!pane.title.isEmpty)
            #expect(!pane.subtitle.isEmpty)
            #expect(!pane.systemImage.isEmpty)
        }
    }

    @Test("no two panes share a subtitle")
    func subtitlesAreDistinct() {
        let subtitles = Set(SettingsPane.allCases.map(\.subtitle))
        #expect(subtitles.count == SettingsPane.allCases.count)
    }

    @Test("no two panes share a title, a symbol, or a place in the strip")
    func titlesAreDistinct() {
        #expect(Set(SettingsPane.allCases.map(\.title)).count == SettingsPane.allCases.count)
        #expect(Set(SettingsPane.allCases.map(\.systemImage)).count == SettingsPane.allCases.count)
        #expect(Set(SettingsPane.allCases.map(\.id)).count == SettingsPane.allCases.count)
    }

    /// A subtitle is a line under a heading, not a paragraph. The chrome gives
    /// it one wrapped line at 660 points and the panes' own prose follows
    /// underneath.
    @Test("a subtitle is one sentence")
    func subtitlesAreShort() {
        for pane in SettingsPane.allCases {
            #expect(pane.subtitle.count <= 90, "\(pane.rawValue) is too long for a title row")
            #expect(pane.subtitle.hasSuffix("."))
        }
    }

    /// Agents is the only pane that needs an app behind it: it lists what
    /// Auspex has written into other tools' files, and a renderer has written
    /// nothing. It drops out rather than drawing an empty pane.
    @Test("a render with no app behind it is offered every pane but Agents")
    func agentsNeedsAnApp() {
        #expect(SettingsPane.available(hasSetup: true) == SettingsPane.allCases)
        #expect(!SettingsPane.available(hasSetup: false).contains(.agents))
        #expect(SettingsPane.available(hasSetup: false).count == SettingsPane.allCases.count - 1)
        // And the order the rest are in does not change when one is dropped.
        #expect(SettingsPane.available(hasSetup: false).first == .general)
    }

    /// The two panes that are a grid of cards are allowed to be wider than the
    /// panes that are prose, and every pane is capped at something: a settings
    /// page that filled a 1,680 pt window would be one line of text per
    /// eyeful.
    @Test("a grid pane may be wider than a paragraph, and both are bounded")
    func measuresAreBounded() {
        #expect(SettingsPane.agents.measure == SettingsPane.gridMeasure)
        #expect(SettingsPane.characters.measure == SettingsPane.gridMeasure)
        for pane in SettingsPane.allCases where pane != .agents && pane != .characters {
            #expect(pane.measure == SettingsPane.proseMeasure)
        }
        #expect(SettingsPane.proseMeasure < SettingsPane.gridMeasure)
        // Wide enough for three 440 pt cards and the gaps between them, which
        // is what "three columns in a big window" means in points.
        #expect(SettingsPane.gridMeasure >= 440 * 3 + 16 * 2)
    }
}
