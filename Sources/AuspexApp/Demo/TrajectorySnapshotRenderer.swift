import AgentSessionLive
import AppKit
import AuspexCore
import SwiftUI

/// Renders the Trajectory mode to a PNG, offscreen, from the demo board.
///
/// The same bargain ``WindowSnapshotRenderer`` makes, and for the same two
/// reasons. A screenshot taken off a screen carries whatever else was on that
/// screen — a real repository path, a real prompt, a real account name in a
/// `~` — and this one draws fabricated sessions under `/Users/example` and
/// nothing else. And a `Canvas` has no view hierarchy to assert against, so
/// drawing the waterfall and looking at it is the only honest check that the
/// layout maths reaches the pixels.
///
/// It picks the session with the most to show rather than whichever one the
/// board sorted first: a trajectory screenshot that happens to land on a
/// two-step session demonstrates nothing.
@MainActor
enum TrajectorySnapshotRenderer {
    /// Wider than the board's artboard on purpose. The trajectory is the only
    /// mode with four columns — sidebar, rows, inspector, trace — and 1440
    /// points leaves the rows too narrow to say anything true about how they
    /// read at a working width.
    static let defaultSize = CGSize(width: 1_600, height: 980)

    static func render(
        to url: URL,
        warmup: TimeInterval = 20,
        size: CGSize = defaultSize,
        scale: CGFloat = 2
    ) throws -> String {
        NSApplication.shared.setActivationPolicy(.prohibited)

        let environment = AppEnvironment(mode: .demo)
        environment.board.autoSelectsFirstSession = true
        environment.start()
        defer { Task { await environment.shutdown() } }

        pump(for: warmup)

        let board = environment.board
        guard let chosen = pickSession(in: board) else { throw RenderError.emptyBoard }
        board.selectedKey = chosen
        board.openTrajectory()
        pumpUntilLoaded(board.trajectory)

        // Open the inspector on the step with the most to say: a model answer
        // the harness billed for, which is the only kind of step that fills in
        // every row of the Summary tab.
        let trajectory = board.trajectory
        trajectory.showsInspector = true
        trajectory.tab = .summary
        trajectory.selectedID = interestingStep(in: trajectory)?.id
        pump(for: 0.4)

        let renderer = ImageRenderer(
            content: TrajectorySnapshot(environment: environment, size: size)
        )
        renderer.scale = scale
        let image = renderer.nsImage
        guard let image,
              let tiff = image.tiffRepresentation,
              let representation = NSBitmapImageRep(data: tiff),
              let png = representation.representation(using: .png, properties: [:])
        else { throw RenderError.renderFailed }
        try png.write(to: url)
        return summary(of: trajectory, key: chosen)
    }

    /// The session whose trajectory shows the most.
    ///
    /// Two passes, because folding a trajectory per session is not free and
    /// the board already knows most of the answer. The board's own counters
    /// pick a shortlist; the fold decides between them on the two things a
    /// counter cannot see — whether a *tool* failed, and whether the harness
    /// billed anything.
    ///
    /// A session that was killed is not a session with something to show: its
    /// closing banner is an error, and scoring on "has an error" alone would
    /// hand the screenshot to the shortest trajectory on the board.
    private static func pickSession(in board: LiveBoardModel) -> SessionKey? {
        let shortlist = board.board.sessions
            .sorted { promise(of: $0) > promise(of: $1) }
            .prefix(4)
            .map(\.key)
        guard !shortlist.isEmpty else { return nil }

        var best: (key: SessionKey, score: Int)?
        for key in shortlist {
            board.selectedKey = key
            board.openTrajectory()
            pumpUntilLoaded(board.trajectory)
            let trajectory = board.trajectory
            guard !trajectory.steps.isEmpty else { continue }
            var score = trajectory.steps.count * 10
            if trajectory.steps.contains(where: { $0.role == .tool && $0.isError }) { score += 3_000 }
            if trajectory.tokens != nil { score += 3_000 }
            if trajectory.turns.count > 2 { score += 500 }
            if best == nil || score > best!.score { best = (key, score) }
        }
        return best?.key ?? shortlist.first
    }

    /// How much a session looks like it has to show, from the board's own
    /// counters — no fold required.
    private static func promise(of session: SessionSnapshot) -> Int {
        session.turnCount * 200 + session.toolCallCount * 60 + (session.tokensOut > 0 ? 2_000 : 0)
    }

    private static func interestingStep(in model: TrajectoryModel) -> TrajectoryStep? {
        model.steps.last { $0.role == .assistant && $0.tokens != nil }
            ?? model.steps.first { $0.isError }
            ?? model.steps.last
    }

    /// The pipeline runs on detached tasks; spinning the main run loop is what
    /// lets them make progress while this call is on the main actor.
    private static func pump(for seconds: TimeInterval) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
    }

    private static func pumpUntilLoaded(_ model: TrajectoryModel, timeout: TimeInterval = 2) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline, model.steps.isEmpty || model.isLoading {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.03))
        }
        // The fold lands one debounce after the read; give the layout a beat.
        pump(for: 0.15)
    }

    /// What the picture holds, for the caller to print — the tally that makes
    /// choosing a good moment in the demo loop a decision rather than a guess.
    private static func summary(of model: TrajectoryModel, key: SessionKey) -> String {
        var parts = [
            "\(key.harness.displayName) \(key.sessionID.prefix(8))",
            "\(model.steps.count) steps",
            "\(model.turns.count) turns",
            "\(model.requests.count) requests"
        ]
        parts.append("\(model.errorCount) failed")
        if let tokens = model.tokens {
            parts.append("\(TokenFormat.compact(tokens.input))/\(TokenFormat.compact(tokens.output)) tokens")
        } else {
            parts.append("no usage reported")
        }
        return parts.joined(separator: " · ")
    }

    enum RenderError: Error {
        case emptyBoard
        case renderFailed
    }
}

/// The window as it looks in Trajectory mode: the sidebar, the board column
/// showing one session's history, and the live trace beside it.
///
/// An `HStack` and not the real `NavigationSplitView` for the reason
/// ``WindowSnapshotRenderer`` gives: a split view needs a window to lay itself
/// out in and `ImageRenderer` has none. The columns are the views the window
/// builds, at the widths the window gives them.
private struct TrajectorySnapshot: View {
    let environment: AppEnvironment
    let size: CGSize

    @State private var clock = BoardClock()

    var body: some View {
        HStack(spacing: 0) {
            SidebarView(
                section: .constant(.live),
                model: environment.board,
                projects: environment.projects,
                mode: environment.mode
            )
            .frame(width: 232)
            divider
            VStack(spacing: 0) {
                BoardHeader(model: environment.board, section: .live)
                TrajectoryView(model: environment.board)
            }
            .frame(maxWidth: .infinity)
            divider
            SessionTraceView(model: environment.board)
                .frame(width: 380)
        }
        .frame(width: size.width, height: size.height)
        .background(AuspexPalette.canvas)
        .environment(clock)
        .environment(environment)
        .environment(\.isSnapshotRender, true)
        .preferredColorScheme(.dark)
    }

    private var divider: some View {
        Rectangle().fill(AuspexPalette.line).frame(width: 1)
    }
}
