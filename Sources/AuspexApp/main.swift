import AuspexCore
import Darwin
import Foundation

// Subcommand dispatch happens before SwiftUI's `App.main()`, so a headless
// invocation never brings up NSApplication, the Dock, or a window. MCP
// clients and harness hooks spawn this binary as a plain child process —
// sometimes inside a sandbox — and touching AppKit there is fatal.
//
// Both modes are placeholders; they land in M3.
let arguments = CommandLine.arguments.dropFirst()

if arguments.contains("--mcp-stdio") {
    FileHandle.standardError.write(
        Data("auspex: --mcp-stdio is not implemented yet (planned for M3).\n".utf8)
    )
    exit(2)
}

if arguments.contains("--hook") {
    FileHandle.standardError.write(
        Data("auspex: --hook is not implemented yet (planned for M3).\n".utf8)
    )
    exit(2)
}

// Renders `docs/screenshots/scene.png` from the demo board, offscreen. Keeping
// it in the binary rather than in a capture script is what makes the screenshot
// in the README reproducible and safe to publish: it draws fabricated sessions
// under `/Users/example`, never a real one, and never whatever else happened to
// be on the screen of the machine that took it.
if let flag = arguments.firstIndex(of: "--render-scene") {
    let rest = arguments[arguments.index(after: flag)...]
    guard let path = rest.first, !path.hasPrefix("-") else {
        FileHandle.standardError.write(
            Data("auspex: --render-scene needs a destination path.\n".utf8)
        )
        exit(2)
    }
    let elapsed = rest.dropFirst().first.flatMap(TimeInterval.init) ?? 16
    let focus = rest.dropFirst(2).first
    do {
        let board = SceneSnapshotRenderer.demoBoard(elapsed: elapsed)
        let project = focus.flatMap { SceneSnapshotRenderer.projectKey(named: $0, in: board) }
        if let focus, project == nil {
            FileHandle.standardError.write(
                Data("auspex: no project on the demo board is called \(focus).\n".utf8)
            )
            exit(2)
        }
        try SceneSnapshotRenderer.render(
            board: board, to: URL(fileURLWithPath: path), focusing: project
        )
        // Report what was drawn. Choosing *when* in the demo loop to render is
        // the whole job of picking a good screenshot, and this tally is how it
        // is chosen.
        let counts = board.counts
        let framing = project.map { " framed on \(($0 as NSString).lastPathComponent)" } ?? ""
        let summary = "auspex: \(board.sessions.count) sessions at t+\(Int(elapsed))s\(framing) — "
            + "\(counts.thinking) thinking, \(counts.tooling) tooling, "
            + "\(counts.delegating) delegating, \(counts.waitingPermission) blocked, "
            + "\(counts.idle) idle, \(counts.ended) ended\n"
        FileHandle.standardOutput.write(Data(summary.utf8))
        exit(0)
    } catch {
        FileHandle.standardError.write(Data("auspex: \(error)\n".utf8))
        exit(1)
    }
}

// Renders the crew wall from the demo board, offscreen, for the same reasons
// `--render-scene` does: a picture of a running window is a picture of whatever
// else was on that screen, and a `Canvas` has no view hierarchy to assert
// against, so drawing one and looking at it is the honest check.
if let flag = arguments.firstIndex(of: "--render-crew") {
    let rest = arguments[arguments.index(after: flag)...]
    guard let path = rest.first, !path.hasPrefix("-") else {
        FileHandle.standardError.write(
            Data("auspex: --render-crew needs a destination path.\n".utf8)
        )
        exit(2)
    }
    let elapsed = rest.dropFirst().first.flatMap(TimeInterval.init) ?? 16
    let avatarTime = rest.dropFirst(2).first.flatMap(TimeInterval.init) ?? 1.4
    do {
        let board = SceneSnapshotRenderer.demoBoard(elapsed: elapsed)
        try CrewSnapshotRenderer.render(
            board: board,
            to: URL(fileURLWithPath: path),
            avatarTime: avatarTime
        )
        let counts = board.counts
        let summary = "auspex: \(board.sessions.count) avatars at t+\(Int(elapsed))s, "
            + "animation t=\(avatarTime)s — "
            + "\(counts.thinking) thinking, \(counts.tooling) tooling, "
            + "\(counts.delegating) delegating, \(counts.waitingPermission) blocked, "
            + "\(counts.idle) idle, \(counts.ended) ended\n"
        FileHandle.standardOutput.write(Data(summary.utf8))
        exit(0)
    } catch {
        FileHandle.standardError.write(Data("auspex: \(error)\n".utf8))
        exit(1)
    }
}

// Renders the main window from the demo board, offscreen. The same bargain
// `--render-scene` makes: a screenshot taken off a screen carries whatever was
// on that screen, and this one carries fabricated sessions under
// `/Users/example` instead. It is also the only way to look at the board on a
// machine with no attached display.
if let flag = arguments.firstIndex(of: "--render-board") {
    let rest = arguments[arguments.index(after: flag)...]
    guard let path = rest.first, !path.hasPrefix("-") else {
        FileHandle.standardError.write(
            Data("auspex: --render-board needs a destination path.\n".utf8)
        )
        exit(2)
    }
    let warmup = rest.dropFirst().first.flatMap(TimeInterval.init) ?? 20
    // A taller frame is how the parts of the board below the artboard's fold —
    // the collapsed `Ended` section, most of all — get looked at.
    let height = rest.dropFirst(2).first.flatMap(Double.init)
        ?? WindowSnapshotRenderer.defaultSize.height
    let section = rest.dropFirst(3).first
        .flatMap { BoardSection(rawValue: String($0)) } ?? .live
    // The user layer, as `focus=<project key>` and `ignore=<kind>:<value>`
    // among the trailing arguments. Keyword rather than positional because
    // they are the two knobs that are usually absent, and because a picture of
    // the board bound to a project — or with a rule hiding something — is
    // otherwise impossible to take without writing into somebody's ~/.auspex/.
    let focus = rest.first { $0.hasPrefix("focus=") }.map { String($0.dropFirst(6)) }
    let ignore = rest.filter { $0.hasPrefix("ignore=") }.compactMap { argument -> IgnoreRule.Kind? in
        let body = argument.dropFirst(7)
        guard let separator = body.firstIndex(of: ":") else { return nil }
        guard let tag = IgnoreRule.Kind.Tag(rawValue: String(body[..<separator])) else { return nil }
        return IgnoreRule.Kind.make(tag: tag, value: String(body[body.index(after: separator)...]))
    }
    do {
        try WindowSnapshotRenderer.render(
            to: URL(fileURLWithPath: path),
            warmup: warmup,
            size: CGSize(width: WindowSnapshotRenderer.defaultSize.width, height: height),
            section: section,
            focus: focus,
            ignore: ignore
        )
        FileHandle.standardOutput.write(Data("auspex: wrote \(path)\n".utf8))
        exit(0)
    } catch {
        FileHandle.standardError.write(Data("auspex: \(error)\n".utf8))
        exit(1)
    }
}

// Renders the Trajectory mode from the demo board, offscreen. The waterfall
// is a `Canvas`, which has no view hierarchy to assert against, so drawing one
// and looking at it is the only honest check that the layout maths reaches the
// pixels — and it is the only way to look at the mode at all on a machine with
// no attached display.
if let flag = arguments.firstIndex(of: "--render-trajectory") {
    let rest = arguments[arguments.index(after: flag)...]
    guard let path = rest.first, !path.hasPrefix("-") else {
        FileHandle.standardError.write(
            Data("auspex: --render-trajectory needs a destination path.\n".utf8)
        )
        exit(2)
    }
    let warmup = rest.dropFirst().first.flatMap(TimeInterval.init) ?? 20
    let height = rest.dropFirst(2).first.flatMap(Double.init)
        ?? TrajectorySnapshotRenderer.defaultSize.height
    let width = rest.dropFirst(3).first.flatMap(Double.init)
        ?? TrajectorySnapshotRenderer.defaultSize.width
    do {
        let summary = try TrajectorySnapshotRenderer.render(
            to: URL(fileURLWithPath: path),
            warmup: warmup,
            size: CGSize(width: width, height: height)
        )
        FileHandle.standardOutput.write(Data("auspex: wrote \(path) — \(summary)\n".utf8))
        exit(0)
    } catch {
        FileHandle.standardError.write(Data("auspex: \(error)\n".utf8))
        exit(1)
    }
}

if arguments.contains("--help") || arguments.contains("-h") {
    FileHandle.standardOutput.write(Data("""
        auspex — one live board for every AI coding agent on this Mac.

        Usage: Auspex [--demo]

          --demo        Replay a fabricated board instead of tailing the real
                        harness stores. Runs entirely in memory: no harness
                        store is read and nothing is written to ~/.auspex/.
                        `AUSPEX_DEMO=1` does the same, for launchers such as
                        `open -a` that cannot pass arguments through.
          --view <board|scene|crew>
                        Open the live section in this view instead of the
                        board. `AUSPEX_VIEW` does the same. What the
                        performance budget for the scene and the crew is
                        measured with.
          --render-scene <path> [seconds] [project]
                        Render the scene view's office to a PNG, offscreen,
                        from the demo board at `seconds` into its loop
                        (default 16). Used to build the README screenshot.
                        With `project` — a project's short name — the camera
                        is bound to that room instead of framing the whole
                        map, which is what the scene does when a project is
                        picked in the sidebar.
          --render-crew <path> [seconds] [animation seconds]
                        Render the crew view's avatars to a PNG, offscreen,
                        from the demo board at `seconds` into its loop
                        (default 16), with every avatar frozen `animation
                        seconds` into its own animation (default 1.4).
          --render-board <path> [seconds] [height] [section]
                        [focus=<project>] [ignore=<kind>:<value>]
                        Render the whole window — sidebar, board, trace — to a
                        PNG, offscreen, after letting the demo run for
                        `seconds` (default 20), at `height` points (default
                        900), showing `section` (default `live`; `harnesses`
                        draws the rack, `projects` the projects page).
                        `focus=` binds the window to one project the way
                        clicking it in the sidebar does; `ignore=` applies an
                        ignore rule (`pathPrefix`, `project`, `promptPrefix`,
                        `harness`, `titleContains`) for this render only.
                        Reads no harness store and writes nothing.
          --render-trajectory <path> [seconds] [height] [width]
                        Render one session's Trajectory — the waterfall, the
                        step list, and the inspector — to a PNG, offscreen,
                        after letting the demo run for `seconds` (default 20),
                        at `height` x `width` points (default 980 x 1600). The
                        session shown is whichever demo session has the most to
                        show. Reads no harness store.
          --mcp-stdio   Serve the task board over MCP on stdio. (M3)
          --hook        Handle a harness hook invocation. (M3)
          --help        Show this.

        """.utf8))
    exit(0)
}

// `--demo` is not handled here: it does not change what the process *is*, only
// which event producer `AppEnvironment` starts, so it is read by
// `AppLaunchOptions` inside the app rather than dispatched around it.
AuspexApp.main()
