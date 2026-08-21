import AppKit
import AuspexCore
import SwiftUI
import Testing

@testable import AuspexApp

/// The translation between the setting and the two platforms that have to be
/// told about it — SwiftUI, which takes a `ColorScheme?`, and AppKit, which
/// takes an `NSAppearance` and cannot be handed "no preference" at all.
@Suite("Appearance, in the view layer")
@MainActor
struct AppearanceViewTests {
    @Test("Following the system is the absence of a preference")
    func systemIsNoPreference() {
        // `nil`, not "whatever the system currently is". A window given a
        // concrete scheme stops following, so resolving `system` here would
        // pin the window to whichever appearance the Mac was in when the app
        // launched and leave it there through sunset.
        #expect(AppearanceMode.system.colorScheme == nil)
        #expect(AppearanceMode.light.colorScheme == .light)
        #expect(AppearanceMode.dark.colorScheme == .dark)
    }

    @Test("AppKit is given a concrete appearance for each explicit mode")
    func appKitGetsSomethingConcrete() {
        #expect(AuspexPalette.isDark(AppearanceMode.dark.nsAppearance))
        #expect(!AuspexPalette.isDark(AppearanceMode.light.nsAppearance))
    }

    /// A screenshot whose colours depend on what the machine's appearance
    /// happened to be when the build ran is not a reproducible artefact, and
    /// reproducibility is the entire reason Auspex draws its own screenshots
    /// rather than pointing a capture tool at a window.
    @Test("A render can be asked for light or dark, and for nothing else")
    func rendersRefuseToFollowTheMachine() {
        #expect(AppearanceMode.rendered(from: "light") == .light)
        #expect(AppearanceMode.rendered(from: "dark") == .dark)
        #expect(AppearanceMode.rendered(from: "system") == nil)
        #expect(AppearanceMode.rendered(from: "") == nil)
        #expect(AppearanceMode.rendered(from: "Dark") == nil)
    }

    /// The two grounds a sidebar can stand on. The flat one has to be the
    /// board's own canvas: a sidebar a shade off the board is a tray, and the
    /// window is meant to read as one surface divided by hairlines.
    @Test("The flat sidebar is the board's own ground")
    func flatSidebarMatchesTheBoard() {
        for appearance in [NSAppearance(named: .aqua)!, NSAppearance(named: .darkAqua)!] {
            let sidebar = AuspexPalette.resolve(AuspexPalette.canvas, for: appearance)
            let board = AuspexPalette.resolve(AuspexPalette.bg0, for: appearance)
            #expect(sidebar == board)
        }
    }
}
