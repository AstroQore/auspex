import AgentSessionLive
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

/// What a change of appearance has to reach without a relaunch.
///
/// Three surfaces in the app hold *bytes* rather than a dynamic colour, and
/// each of them is invisible in a screenshot when it goes wrong — a strip with
/// last night's blue in it animates exactly like a correct one. So each is
/// driven through an appearance change here and asked what it is holding
/// afterwards.
@Suite("Repainting on an appearance change")
@MainActor
struct AppearanceRepaintTests {
    /// The strip is a `CALayer`, and a layer holds a `CGColor`. Setting a
    /// view's `appearance` is what AppKit does to a window's subtree when the
    /// scheme changes, so this is the real path and not a stand-in for it.
    @Test("An activity strip re-resolves its layer colour")
    func stripFollowsTheAppearance() {
        let state = SessionState.thinking
        let view = ActivityStripView()
        view.appearance = NSAppearance(named: .darkAqua)
        view.apply(StripSpec(rhythm: StripRhythm(state.style.motion), color: state.style.color))

        let dark = view.ground.backgroundColor
        view.appearance = NSAppearance(named: .aqua)
        let light = view.ground.backgroundColor

        #expect(dark != nil)
        #expect(light != nil)
        #expect(dark != light)
        #expect(components(light) == components(
            AuspexPalette.nsColor(.stateThinking, dark: false).cgColor
        ))
    }

    /// The strip must still be *moving* afterwards. Re-applying a spec is what
    /// re-resolves the colour, and re-applying is also the one thing that can
    /// silently drop the animation.
    @Test("A strip that was animating is still animating afterwards")
    func stripKeepsItsRhythm() {
        let state = SessionState.thinking
        let view = ActivityStripView()
        view.appearance = NSAppearance(named: .darkAqua)
        view.apply(StripSpec(rhythm: StripRhythm(state.style.motion), color: state.style.color))
        view.appearance = NSAppearance(named: .aqua)

        let breath = view.ground.animation(forKey: ActivityStripView.animationKey)
        #expect(breath != nil)
        #expect(breath?.repeatCount == .infinity)
    }

    /// The office is textures, and a texture is bytes. The theme's identity is
    /// what the texture cache is keyed by, so two appearances must not share
    /// one.
    @Test("The office resolves a different theme for each appearance")
    func sceneThemeFollowsTheAppearance() {
        let dark = SceneTheme.resolved(for: NSAppearance(named: .darkAqua)!)
        let light = SceneTheme.resolved(for: NSAppearance(named: .aqua)!)

        #expect(dark.isDark)
        #expect(!light.isDark)
        #expect(dark.id != light.id, "the texture cache is keyed by this")
        #expect(dark.canvas != light.canvas)
        #expect(dark.deskTop != light.deskTop)
        // A glow that only got weaker would still be a white haze on a white
        // floor — see `SceneTheme.glowBlend`.
        #expect(dark.glowBlend != light.glowBlend)
        #expect(light.glowScale < dark.glowScale)
    }

    private func components(_ color: CGColor?) -> [CGFloat]? {
        color.flatMap { $0.converted(
            to: CGColorSpace(name: CGColorSpace.sRGB)!, intent: .defaultIntent, options: nil
        ) }?.components
    }
}

/// The command line's appearance flag.
@Suite("Launch options")
struct AppearanceLaunchOptionTests {
    @Test("--appearance sets the launch's appearance and nothing else")
    func flagIsRead() {
        let options = AppLaunchOptions.current(
            arguments: ["Auspex", "--demo", "--appearance", "light"], environment: [:]
        )
        #expect(options.appearance == .light)
        #expect(options.isDemo)
    }

    @Test("The environment variable does the same, for launchers that own argv")
    func environmentIsRead() {
        let options = AppLaunchOptions.current(
            arguments: ["Auspex"], environment: ["AUSPEX_APPEARANCE": "dark"]
        )
        #expect(options.appearance == .dark)
    }

    @Test("Nothing said means nothing overridden, and the setting decides")
    func absentMeansTheSetting() {
        let options = AppLaunchOptions.current(arguments: ["Auspex"], environment: [:])
        #expect(options.appearance == nil)
        // Not `.system`: `nil` is "the person's setting stands", and `.system`
        // would override a saved `dark` with "follow the Mac" on every launch.
        #expect(AppLaunchOptions.current(
            arguments: ["Auspex", "--appearance", "banana"], environment: [:]
        ).appearance == nil)
    }

    @Test("--view still works beside it")
    func flagsCoexist() {
        let options = AppLaunchOptions.current(
            arguments: ["Auspex", "--view", "scene", "--appearance", "dark"], environment: [:]
        )
        #expect(options.viewMode == .scene)
        #expect(options.appearance == .dark)
    }
}

/// The command line's demo scale.
///
/// It exists so the performance budget can be measured at the size a real
/// machine reaches without opening a real machine's store — see
/// ``AppLaunchOptions/demoScale``.
@Suite("Demo scale launch option")
struct DemoScaleLaunchOptionTests {
    @Test("--demo-scale is read, and asks for a demo on its own")
    func flagIsRead() {
        let options = AppLaunchOptions.current(
            arguments: ["Auspex", "--demo-scale", "12"], environment: [:]
        )
        #expect(options.demoScale == 12)
        #expect(options.isDemo)
        #expect(options.mode == .demo)
    }

    @Test("The environment variable does the same, for launchers that own argv")
    func environmentIsRead() {
        let options = AppLaunchOptions.current(
            arguments: ["Auspex"], environment: ["AUSPEX_DEMO_SCALE": "8"]
        )
        #expect(options.demoScale == 8)
        #expect(options.isDemo)
    }

    @Test("Nothing said is the demo as written, and a live run is still live")
    func absentMeansOne() {
        let options = AppLaunchOptions.current(arguments: ["Auspex"], environment: [:])
        #expect(options.demoScale == 1)
        #expect(!options.isDemo)
    }

    @Test("Nonsense and extremes are clamped rather than obeyed")
    func scaleIsClamped() {
        #expect(AppLaunchOptions.current(
            arguments: ["Auspex", "--demo-scale", "0"], environment: [:]
        ).demoScale == 1)
        #expect(AppLaunchOptions.current(
            arguments: ["Auspex", "--demo-scale", "-4"], environment: [:]
        ).demoScale == 1)
        #expect(AppLaunchOptions.current(
            arguments: ["Auspex", "--demo-scale", "banana"], environment: [:]
        ).demoScale == 1)
        #expect(AppLaunchOptions.current(
            arguments: ["Auspex", "--demo-scale", "5000"], environment: [:]
        ).demoScale == 64)
    }

    @Test("A scale of one does not turn a live launch into a demo")
    func oneDoesNotImplyDemo() {
        let options = AppLaunchOptions.current(
            arguments: ["Auspex", "--demo-scale", "1"], environment: [:]
        )
        #expect(!options.isDemo)
    }
}
