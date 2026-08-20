import AuspexCore
import Darwin
import Foundation

// Subcommand dispatch happens before SwiftUI's `App.main()`, so a headless
// invocation never brings up NSApplication, the Dock, or a window. MCP
// clients and harness hooks spawn this binary as a plain child process —
// sometimes inside a sandbox — and touching AppKit there is fatal.
let arguments = CommandLine.arguments.dropFirst()

// The MCP server, as an MCP client expects to spawn it: a byte pump between
// this process's stdio and the socket the running app listens on. It reads no
// harness store, opens no window, and writes nothing to disk.
if AuspexStdioBridge.isRequested() {
    exit(AuspexStdioBridge.run())
}

// A harness hook: read the payload, write one line to the socket, exit 0.
// Second only to the bridge, and for the same reason — this process is a
// synchronous child of a harness that is waiting on it, so it must not touch
// AppKit, must not read a store, and must not take longer than
// `HookIngress.deadline` no matter what is on the other end.
if HookIngress.isRequested(arguments: CommandLine.arguments) {
    exit(HookIngress.run())
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
    // `--office-only` renders the map with both annexes switched off, which is
    // the office exactly as it was before they existed. Having it here rather
    // than only in Settings is what makes "the annexes changed nothing about
    // the office" a picture two commands apart rather than a claim.
    let officeOnly = rest.contains("--office-only")
    let positional = rest.dropFirst().filter { !$0.hasPrefix("-") }
    let elapsed = positional.first.flatMap(TimeInterval.init) ?? 16
    let focus = positional.dropFirst().first
    do {
        let board = SceneSnapshotRenderer.demoBoard(elapsed: elapsed)
        let project = focus.flatMap { SceneSnapshotRenderer.projectKey(named: $0, in: board) }
        if let focus, project == nil {
            FileHandle.standardError.write(
                Data("auspex: no project on the demo board is called \(focus).\n".utf8)
            )
            exit(2)
        }
        let zones: SceneZoneOptions = officeOnly ? .officeOnly : .all
        let unseenDone = SceneSnapshotRenderer.demoUnseenDone(board)
        try SceneSnapshotRenderer.render(
            board: board,
            to: URL(fileURLWithPath: path),
            focusing: project,
            zones: zones,
            unseenDone: unseenDone
        )
        // Report what was drawn. Choosing *when* in the demo loop to render is
        // the whole job of picking a good screenshot, and this tally is how it
        // is chosen — which now includes the two states only the annexes draw.
        let counts = board.counts
        let stale = board.sessions.filter { $0.isStale && $0.state.isActive }.count
        let framing = project.map { " framed on \(($0 as NSString).lastPathComponent)" } ?? ""
        let map = officeOnly ? " office only" : ""
        let summary = "auspex: \(board.sessions.count) sessions at t+\(Int(elapsed))s"
            + "\(framing)\(map) — "
            + "\(counts.thinking) thinking, \(counts.tooling) tooling, "
            + "\(counts.delegating) delegating, \(counts.waitingPermission) blocked, "
            + "\(counts.idle) idle, \(stale) stale, \(unseenDone.count) done unseen, "
            + "\(counts.ended) ended\n"
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

// Renders one avatar's transition as a filmstrip. A still of the crew wall
// cannot show whether a morph is eased or linear — every individual frame looks
// the same either way — so this lays sixteen of them out in reading order with
// the per-frame travel drawn under each. An eased morph is a row of bars that
// rises and falls; a linear one is a row of equal bars.
if let flag = arguments.firstIndex(of: "--render-crew-strip") {
    let rest = arguments[arguments.index(after: flag)...]
    let names = Array(rest.prefix(3))
    guard names.count == 3, !names[0].hasPrefix("-"),
          let from = BloubStateID(rawValue: names[1]),
          let to = BloubStateID(rawValue: names[2])
    else {
        let known = BloubStateID.allCases.map(\.rawValue).joined(separator: ", ")
        let usage = "auspex: --render-crew-strip needs <path> <from-state> <to-state> "
            + "[fps].\n        states: \(known)\n"
        FileHandle.standardError.write(Data(usage.utf8))
        exit(2)
    }
    // A frame rate turns the strip into a steady-state sample at that rate,
    // which is the only way to judge whether a cadence steps.
    let fps = rest.dropFirst(3).first.flatMap(Double.init)
    do {
        try CrewMotionRenderer.renderStrip(
            from: from,
            to: to,
            to: URL(fileURLWithPath: names[0]),
            cadence: fps.map { 1 / $0 }
        )
        let frames = CrewMotionRenderer.stripFrames
        let summary: String
        if let fps {
            summary = "auspex: \(frames) settled frames of \(from.rawValue) "
                + "at \(Int(fps.rounded())) fps\n"
        } else {
            let morph = Int(
                (BloubTransition.duration(BloubStates.state(to).morph) * 1000).rounded()
            )
            let lag = Int((BloubTransition.eyeLag * 1000).rounded())
            summary = "auspex: \(frames) frames of \(from.rawValue) → \(to.rawValue), "
                + "morph \(morph) ms, eyes \(lag) ms behind\n"
        }
        FileHandle.standardOutput.write(Data(summary.utf8))
        exit(0)
    } catch {
        FileHandle.standardError.write(Data("auspex: \(error)\n".utf8))
        exit(1)
    }
}

// The whole demo wall over a couple of seconds — as an animated GIF when the
// destination ends in `.gif`, otherwise as a 4 × 4 contact sheet. The GIF is
// assembled with ImageIO, so no ffmpeg has to exist for the evidence to be
// reproducible.
if let flag = arguments.firstIndex(of: "--render-crew-motion") {
    let rest = arguments[arguments.index(after: flag)...]
    guard let path = rest.first, !path.hasPrefix("-") else {
        FileHandle.standardError.write(
            Data("auspex: --render-crew-motion needs a destination path.\n".utf8)
        )
        exit(2)
    }
    let seconds = rest.dropFirst().first.flatMap(TimeInterval.init) ?? 2
    let elapsed = rest.dropFirst(2).first.flatMap(TimeInterval.init) ?? 16
    do {
        let board = SceneSnapshotRenderer.demoBoard(elapsed: elapsed)
        let url = URL(fileURLWithPath: path)
        let avatars = board.sessions.count
        let summary: String
        if url.pathExtension.lowercased() == "gif" {
            try CrewMotionRenderer.renderGIF(board: board, to: url, seconds: seconds)
            let frames = Int((seconds * 20).rounded())
            summary = "auspex: \(frames) frames of \(avatars) avatars over "
                + "\(seconds)s at 20 fps\n"
        } else {
            try CrewMotionRenderer.renderContactSheet(board: board, to: url, seconds: seconds)
            summary = "auspex: 16 frames of \(avatars) avatars over \(seconds)s, "
                + "as a 4x4 contact sheet\n"
        }
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
    // `group=` picks the axis the wall is divided along, for the screenshots
    // that are *about* the grouping — a tree render cannot be reached any other
    // way from a headless process.
    let groupBy = rest.first { $0.hasPrefix("group=") }
        .flatMap { BoardGroupBy(rawValue: String($0.dropFirst(6))) }
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
            ignore: ignore,
            groupBy: groupBy
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
          --render-crew-strip <path> <from-state> <to-state> [fps]
                        Render one avatar's state → state transition as a
                        16-frame filmstrip, with the distance the silhouette
                        travelled between frames drawn as a bar under each.
                        That row of bars is what tells an eased morph from a
                        linear one; a single frame cannot. Given `fps` (and the
                        same state twice) it instead samples that state once
                        settled, at exactly that rate — which is how a frame
                        rate is judged before it is chosen.
          --render-crew-motion <path> [seconds] [board seconds]
                        Render the whole demo wall in motion over `seconds`
                        (default 2). A `.gif` destination writes an animated
                        GIF at 20 fps; anything else writes a 4×4 contact
                        sheet of 16 frames.
          --render-board <path> [seconds] [height] [section]
                        [focus=<project>] [ignore=<kind>:<value>]
                        [group=<none|harness|project|tree>]
                        Render the whole window — sidebar, board, trace — to a
                        PNG, offscreen, after letting the demo run for
                        `seconds` (default 20), at `height` points (default
                        900), showing `section` (default `live`; `harnesses`
                        draws the rack, `projects` the projects page).
                        `focus=` binds the window to one project the way
                        clicking it in the sidebar does; `ignore=` applies an
                        ignore rule (`pathPrefix`, `project`, `promptPrefix`,
                        `harness`, `titleContains`) for this render only;
                        `group=` divides the wall along that axis, which is the
                        only way to reach the tree grouping headlessly.
                        Reads no harness store and writes nothing.
          --render-trajectory <path> [seconds] [height] [width]
                        Render one session's Trajectory — the waterfall, the
                        step list, and the inspector — to a PNG, offscreen,
                        after letting the demo run for `seconds` (default 20),
                        at `height` x `width` points (default 980 x 1600). The
                        session shown is whichever demo session has the most to
                        show. Reads no harness store.
          --mcp-stdio   Serve the running Auspex's task board over MCP on
                        stdio. This is the command an MCP client is
                        configured with; it connects to ~/.auspex/mcp.sock
                        (override with AUSPEX_MCP_SOCKET) and pumps bytes.
                        Exits 1 when Auspex is not running.
          --hook <harness> [--then <command>…]
                        Handle a harness hook invocation: read the
                        harness's JSON from stdin (or, for Codex's notify,
                        from the last argument), send it to the running
                        Auspex on ~/.auspex/mcp.sock, and exit 0 within
                        200 ms whatever happens. This is the command the
                        installer writes into a harness's hook table; it is
                        not meant to be run by hand. `--then` runs the
                        program Auspex was put in front of, which is how
                        Codex's single `notify` slot is shared.
          --help        Show this.

        """.utf8))
    exit(0)
}

// `--demo` is not handled here: it does not change what the process *is*, only
// which event producer `AppEnvironment` starts, so it is read by
// `AppLaunchOptions` inside the app rather than dispatched around it.
AuspexApp.main()
