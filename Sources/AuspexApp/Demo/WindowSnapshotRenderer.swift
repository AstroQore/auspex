import AppKit
import AuspexCore
import SwiftUI

/// Renders the main window to a PNG, offscreen, from the demo board.
///
/// ## Why the app draws its own screenshot
///
/// The same reason `SceneSnapshotRenderer` exists. A screenshot taken off a
/// screen is whatever happened to be on that screen: a real session's title, a
/// real repository path, a real account name in a `~`. This one draws
/// fabricated sessions under `/Users/example` and nothing else, so the image
/// is safe to publish and reproducible by anybody with the repository.
///
/// It is also the only way to *look at* the board on a machine with no
/// attached display, which is where this is usually run.
///
/// ## Why it is an `HStack` and not the real `NavigationSplitView`
///
/// A split view needs a window to lay itself out in, and `ImageRenderer` has
/// none. The three columns are the same views the window builds, at the
/// widths the window gives them, which is what the design's artboard is too —
/// so what this renders is the window's content, not a mock-up of it.
@MainActor
enum WindowSnapshotRenderer {
    /// The artboard's size, so a render can be compared with the design
    /// directly rather than after a resize.
    static let defaultSize = CGSize(width: 1_440, height: 900)

    /// Brings the demo pipeline up, lets it run for `warmup` seconds, and
    /// writes the window to `url`.
    ///
    /// The warm-up is a real wait on the real pipeline rather than a
    /// fabricated snapshot: the demo replays against the wall clock, so the
    /// board at *t* is the board a person would see at *t*, stopwatches and
    /// all.
    /// - Parameters:
    ///   - focus: a project key to bind the window to, as the sidebar would —
    ///     so the picture can show what the board looks like *inside* a
    ///     project rather than only across all of them.
    ///   - ignore: rules to apply first. Both exist so the user layer can be
    ///     photographed without writing anything into somebody's `~/.auspex/`:
    ///     the demo's catalog has no stores behind it, so these live and die
    ///     with the process.
    static func render(
        to url: URL,
        warmup: TimeInterval = 20,
        size: CGSize = defaultSize,
        section: BoardSection = .live,
        scale: CGFloat = 2,
        focus: String? = nil,
        ignore: [IgnoreRule.Kind] = [],
        groupBy: BoardGroupBy? = nil,
        pane: SettingsPane? = nil,
        appearance: AppearanceMode = .dark
    ) throws {
        // Touching AppKit at all requires the shared application to exist; the
        // policy keeps it out of the Dock and off the menu bar while it does.
        NSApplication.shared.setActivationPolicy(.prohibited)

        let environment = AppEnvironment(mode: .demo, offersSignalTarget: false)
        environment.board.autoSelectsFirstSession = true
        environment.start()
        for kind in ignore { environment.catalog.add(rule: IgnoreRule(kind: kind)) }
        environment.board.focusedProjectKey = focus
        if let groupBy { environment.board.groupBy = groupBy }
        defer { Task { await environment.shutdown() } }

        // The pipeline runs on detached tasks; spinning the main run loop is
        // what lets them make progress while this call is on the main actor.
        let deadline = Date().addingTimeInterval(warmup)
        while Date() < deadline {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        // The trace is loaded off a debounce, so give the selected session's
        // rows a moment to arrive after the board has settled.
        let traceDeadline = Date().addingTimeInterval(1.5)
        while Date() < traceDeadline, environment.board.traceItems.isEmpty {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }

        let renderer = ImageRenderer(
            content: WindowSnapshot(
                environment: environment,
                size: size,
                section: section,
                pane: pane,
                appearance: appearance
            )
        )
        renderer.scale = scale
        // A window has no transparency, and saying so is what keeps the PNG at
        // three channels instead of four — a third of the bytes, in a
        // repository that carries a dozen of these.
        renderer.isOpaque = true
        guard let image = renderer.nsImage,
              let tiff = image.tiffRepresentation,
              let representation = NSBitmapImageRep(data: tiff),
              let png = representation.representation(using: .png, properties: [:])
        else { throw RenderError.renderFailed }
        try png.write(to: url)
    }

    /// What the board held when the image was taken, for the caller to print.
    static func summary(of environment: AppEnvironment) -> String {
        let summary = environment.board.summary
        return "\(environment.board.board.sessions.count) sessions — "
            + "\(summary.needsYou) needs you, \(summary.doneReported) done, "
            + "\(summary.working) working, \(summary.idle) idle, "
            + "\(summary.ended) ended"
    }

    enum RenderError: Error {
        case renderFailed
    }
}

/// The window's three columns, laid out the way the split view lays them out.
private struct WindowSnapshot: View {
    let environment: AppEnvironment
    let size: CGSize
    var section: BoardSection = .live
    /// Which pane of Settings to open on, when the section is Settings.
    ///
    /// Settings is six pages behind one segmented control, and the two that
    /// have to be looked at at three window widths — Agents and Characters —
    /// are the two whose contents are a *grid*. A renderer that could only
    /// reach the first pane could not photograph either.
    var pane: SettingsPane?
    /// Which column of the palette to draw with.
    ///
    /// `system` is deliberately not offered by the command line — a screenshot
    /// whose colours depend on what the machine's appearance happened to be
    /// when the build ran is not a reproducible artefact — but the type is the
    /// app's own so the two cannot drift.
    var appearance: AppearanceMode = .dark

    @State private var clock = BoardClock()

    var body: some View {
        HStack(spacing: 0) {
            SidebarView(
                section: .constant(section),
                model: environment.board,
                projects: environment.projects,
                tasks: environment.tasks,
                mode: environment.mode
            )
            .frame(width: 232)
            divider
            VStack(spacing: 0) {
                BoardHeader(model: environment.board, section: section)
                switch section {
                case .harnesses:
                    HarnessesView(
                        model: environment.harnesses,
                        board: environment.board.board,
                        mcp: environment.mcp
                    )
                case .projects:
                    ProjectsPageView(
                        catalog: environment.catalog,
                        tree: environment.projects.tree
                    )
                case .tasks:
                    TasksPageView(model: environment.tasks, board: environment.board)
                case .settings:
                    SettingsSectionView(
                        catalog: environment.catalog,
                        setup: environment.setup,
                        detected: environment.harnesses.detected,
                        socketPath: environment.mcp?.socketPath,
                        initialPane: pane
                    )
                default:
                    BoardView(model: environment.board)
                }
            }
            .frame(maxWidth: .infinity)
            if section != .harnesses, section != .projects, section != .tasks,
               section != .settings {
                divider
                SessionTraceView(model: environment.board)
                    .frame(width: 420)
            }
        }
        .frame(width: size.width, height: size.height)
        .environment(clock)
        .environment(environment)
        .environment(\.isSnapshotRender, true)
        // The scheme is set on the *environment* rather than preferred: there
        // is no window here for a preference to reach, and `ImageRenderer`
        // resolves a dynamic colour against the environment it is handed.
        // The background comes after it, so the ground is the token this
        // scheme resolves to rather than the one the process launched in.
        .environment(\.colorScheme, appearance == .light ? .light : .dark)
        .background(AuspexPalette.canvas)
        .tint(AuspexPalette.accent)
    }

    private var divider: some View {
        Rectangle().fill(AuspexPalette.line).frame(width: 1)
    }
}
