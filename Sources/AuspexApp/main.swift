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

/// `appearance=light|dark` among a subcommand's trailing arguments.
///
/// Keyword rather than positional because it is absent from almost every
/// invocation, and it has to be reachable on four different renderers whose
/// positional arguments are all different. Absent means dark, which is what
/// every screenshot in the repository was before there was a light column and
/// is what `docs/screenshots/*.png` still are; `*-light.png` is the same
/// command with this on the end.
///
/// `system` is deliberately not accepted: a picture whose colours depend on
/// what the machine's appearance happened to be when the build ran is not a
/// reproducible artefact, and the whole reason these renderers exist rather
/// than a capture script is reproducibility.
func renderAppearance<S: Sequence<String>>(in arguments: S) -> AppearanceMode? {
    guard let argument = arguments.first(where: { $0.hasPrefix("appearance=") })
    else { return .dark }
    return AppearanceMode.rendered(from: String(argument.dropFirst(11)))
}

/// Complains about a bad `appearance=` and exits, so the four call sites do
/// not each invent their own wording.
func exitOnBadAppearance() -> Never {
    FileHandle.standardError.write(
        Data("auspex: appearance= takes `light` or `dark`.\n".utf8)
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
    // `--office-only` renders the map with both annexes switched off, which is
    // the office exactly as it was before they existed. Having it here rather
    // than only in Settings is what makes "the annexes changed nothing about
    // the office" a picture two commands apart rather than a claim.
    let officeOnly = rest.contains("--office-only")
    guard let appearance = renderAppearance(in: rest) else { exitOnBadAppearance() }
    let positional = rest.dropFirst().filter {
        !$0.hasPrefix("-") && !$0.contains("=")
    }
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
        let attention = SceneSnapshotRenderer.demoAttention(board)
        try SceneSnapshotRenderer.render(
            board: board,
            to: URL(fileURLWithPath: path),
            focusing: project,
            zones: zones,
            attention: attention,
            appearance: appearance
        )
        // Report what was drawn. Choosing *when* in the demo loop to render is
        // the whole job of picking a good screenshot, and this tally is how it
        // is chosen — which now includes the two states only the annexes draw.
        let counts = board.counts
        let stale = board.sessions.filter { $0.isStale && $0.state.isActive }.count
        let needsYou = attention.values.count { $0.wantsPerson }
        let reported = attention.values.count { $0.isDoneReported }
        let framing = project.map { " framed on \(($0 as NSString).lastPathComponent)" } ?? ""
        let map = officeOnly ? " office only" : ""
        let activity = "\(counts.thinking) thinking, \(counts.tooling) tooling, "
            + "\(counts.delegating) delegating, \(counts.idle) idle, "
            + "\(stale) stale, \(counts.ended) ended"
        let waiting = "\(needsYou) needs you, \(reported) done"
        let summary = "auspex: \(board.sessions.count) sessions at t+\(Int(elapsed))s"
            + "\(framing)\(map) — \(activity) — \(waiting)\n"
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
    guard let appearance = renderAppearance(in: rest) else { exitOnBadAppearance() }
    let numbers = rest.dropFirst().filter { !$0.contains("=") }
    let elapsed = numbers.first.flatMap(TimeInterval.init) ?? 16
    let avatarTime = numbers.dropFirst().first.flatMap(TimeInterval.init) ?? 1.4
    do {
        let board = SceneSnapshotRenderer.demoBoard(elapsed: elapsed)
        let cards = try CrewSnapshotRenderer.render(
            board: board,
            to: URL(fileURLWithPath: path),
            avatarTime: avatarTime,
            appearance: appearance
        )
        let counts = board.counts
        let summary = "auspex: \(cards) tasks (\(board.sessions.count) sessions) "
            + "at t+\(Int(elapsed))s, "
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

// Renders one reaction as a filmstrip. A still of the crew wall cannot show
// whether a morph is eased or cut — every individual frame looks the same
// either way — so this lays sixteen of them out in reading order with the
// per-frame face travel drawn under each. An eased hand-over is a row of bars
// that rises and falls; a cut is one tall bar with nothing either side.
if let flag = arguments.firstIndex(of: "--render-crew-strip") {
    let rest = arguments[arguments.index(after: flag)...]
    let names = Array(rest.prefix(3))
    guard names.count == 3, !names[0].hasPrefix("-"),
          let stance = CrewStance(rawValue: names[1]),
          let reaction = AvatarSequenceID(rawValue: names[2])
    else {
        let stances = CrewStance.allCases.map(\.rawValue).joined(separator: ", ")
        let reactions = AvatarSequenceID.allCases.map(\.rawValue).joined(separator: ", ")
        let usage = "auspex: --render-crew-strip needs <path> <stance> <reaction> [fps].\n"
            + "        stances: \(stances)\n"
            + "        reactions: \(reactions)\n"
        FileHandle.standardError.write(Data(usage.utf8))
        exit(2)
    }
    // A frame rate turns the strip into a steady-state sample of the base loop
    // at that rate, which is the only way to judge whether a cadence steps.
    let fps = rest.dropFirst(3).first.flatMap(Double.init)
    do {
        try CrewMotionRenderer.renderStrip(
            stance: stance,
            reaction: reaction,
            to: URL(fileURLWithPath: names[0]),
            cadence: fps.map { 1 / $0 }
        )
        let frames = CrewMotionRenderer.stripFrames
        let summary: String
        if let fps {
            summary = "auspex: \(frames) settled frames of \(stance.rawValue) "
                + "at \(Int(fps.rounded())) fps\n"
        } else {
            let length = Int((CrewChoreography.accentCap * 1000).rounded())
            let handover = Int(
                (CrewChoreography.handover(for: CrewChoreography.accentCap) * 1000).rounded()
            )
            summary = "auspex: \(frames) frames of \(stance.rawValue) → "
                + "\(reaction.rawValue), \(length) ms, \(handover) ms hand-over\n"
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
    // Twenty seconds by default. Two was enough when the question was "does a
    // morph ease"; the question now is "do twelve avatars do twelve different
    // things", and the reaction schedule runs on gaps of eight to thirty
    // seconds, so a two-second clip could show none of it.
    let seconds = rest.dropFirst().first.flatMap(TimeInterval.init) ?? 20
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
    guard let appearance = renderAppearance(in: rest) else { exitOnBadAppearance() }
    let positional = rest.dropFirst().filter { !$0.contains("=") }
    let warmup = positional.first.flatMap(TimeInterval.init) ?? 20
    // A taller frame is how the parts of the board below the artboard's fold —
    // the collapsed `Ended` section, most of all — get looked at.
    let height = positional.dropFirst().first.flatMap(Double.init)
        ?? WindowSnapshotRenderer.defaultSize.height
    let section = positional.dropFirst(2).first
        .flatMap { BoardSection(rawValue: String($0)) } ?? .live
    // The width, as a keyword, because it is absent from every screenshot in
    // the repository and present in every check of how a page behaves when it
    // is squeezed — which is a different job from taking a picture, and the
    // only way to do it without dragging a real window about.
    let width = rest.first { $0.hasPrefix("width=") }
        .flatMap { Double($0.dropFirst(6)) } ?? WindowSnapshotRenderer.defaultSize.width
    // Which pane of Settings, for the same reason: the two that are grids are
    // not the first one, and a renderer that could only reach the first could
    // not photograph either of them.
    let pane = rest.first { $0.hasPrefix("pane=") }
        .flatMap { SettingsPane(rawValue: String($0.dropFirst(5))) }
    // Which way of looking at the board. The window has four and the renderer
    // had one, so three of them could only ever be checked by opening the app.
    let viewMode = rest.first { $0.hasPrefix("view=") }
        .flatMap { BoardViewMode(rawValue: String($0.dropFirst(5))) }
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
            size: CGSize(width: width, height: height),
            section: section,
            focus: focus,
            ignore: ignore,
            groupBy: groupBy,
            pane: pane,
            viewMode: viewMode,
            appearance: appearance
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
    guard let appearance = renderAppearance(in: rest) else { exitOnBadAppearance() }
    let positional = rest.dropFirst().filter { !$0.contains("=") }
    let warmup = positional.first.flatMap(TimeInterval.init) ?? 20
    let height = positional.dropFirst().first.flatMap(Double.init)
        ?? TrajectorySnapshotRenderer.defaultSize.height
    let width = positional.dropFirst(2).first.flatMap(Double.init)
        ?? TrajectorySnapshotRenderer.defaultSize.width
    do {
        let summary = try TrajectorySnapshotRenderer.render(
            to: URL(fileURLWithPath: path),
            warmup: warmup,
            size: CGSize(width: width, height: height),
            appearance: appearance
        )
        FileHandle.standardOutput.write(Data("auspex: wrote \(path) — \(summary)\n".utf8))
        exit(0)
    } catch {
        FileHandle.standardError.write(Data("auspex: \(error)\n".utf8))
        exit(1)
    }
}

// Renders the context popover on its own. `ImageRenderer` has no window and
// therefore no popover, so `--render-board` can draw the header control that
// opens this and never what is behind it — and what is behind it is the one
// panel in the app whose entire job is to be read carefully.
if let flag = arguments.firstIndex(of: "--render-context") {
    let rest = arguments[arguments.index(after: flag)...]
    guard let path = rest.first, !path.hasPrefix("-") else {
        FileHandle.standardError.write(
            Data("auspex: --render-context needs a destination path.\n".utf8)
        )
        exit(2)
    }
    guard let appearance = renderAppearance(in: rest) else { exitOnBadAppearance() }
    let positional = rest.dropFirst().filter { !$0.contains("=") }
    let warmup = positional.first.flatMap(TimeInterval.init) ?? 20
    let height = positional.dropFirst().first.flatMap(Double.init)
        ?? ContextPopoverRenderer.defaultSize.height
    let width = positional.dropFirst(2).first.flatMap(Double.init)
        ?? ContextPopoverRenderer.defaultSize.width
    do {
        let summary = try ContextPopoverRenderer.render(
            to: URL(fileURLWithPath: path),
            warmup: warmup,
            size: CGSize(width: width, height: height),
            appearance: appearance
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
          --demo-scale <N>
                        Run the demo's cast N times over, each copy with its
                        own session ids, directories and pids: 12 is about 170
                        sessions across 60 projects, which is the size a busy
                        machine reaches. Implies --demo, and is how the
                        performance budget is measured without opening
                        anybody's real store. `AUSPEX_DEMO_SCALE` does the
                        same. Capped at 64.
          --view <ledger|aviary|flock|flight>
                        Open the live section in this view instead of the
                        ledger. `AUSPEX_VIEW` does the same. The old spellings
                        — `board`, `scene`, `crew`, `trajectory` — still work,
                        because they are in people's shell histories. What the
                        performance budget for the aviary and the flock is
                        measured with.
          --appearance <system|light|dark>
                        Draw this launch in that appearance, without changing
                        the saved setting or the appearance of the Mac.
                        `AUSPEX_APPEARANCE` does the same. Auspex follows the
                        system by default; the persistent choice lives in
                        Settings → Appearance.
          --render-scene <path> [seconds] [project] [appearance=…]
                        Render the scene view's office to a PNG, offscreen,
                        from the demo board at `seconds` into its loop
                        (default 16). Used to build the README screenshot.
                        With `project` — a project's short name — the camera
                        is bound to that room instead of framing the whole
                        map, which is what the scene does when a project is
                        picked in the sidebar.
          --render-crew <path> [seconds] [animation seconds] [appearance=…]
                        Render the crew view's avatars to a PNG, offscreen,
                        from the demo board at `seconds` into its loop
                        (default 16), with every avatar frozen `animation
                        seconds` into its own animation (default 1.4).
          --render-crew-strip <path> <stance> <reaction> [fps]
                        Render one reaction as a 16-frame filmstrip: the
                        avatar living in `stance`'s loop, the reaction arriving
                        and handing back, with the distance the face travelled
                        between frames drawn as a bar under each. That row of
                        bars is what tells an eased hand-over from a cut; a
                        single frame cannot. Given `fps` it instead samples the
                        settled base loop at exactly that rate — which is how a
                        frame rate is judged before it is chosen.
          --render-crew-motion <path> [seconds] [board seconds]
                        Render the whole demo wall in motion over `seconds`
                        (default 20 — long enough for the reaction schedule,
                        whose gaps are eight to thirty seconds, to show). A
                        `.gif` destination writes an animated GIF at 20 fps;
                        anything else writes a 4×4 contact sheet of 16 frames.
          --render-board <path> [seconds] [height] [section]
                        [width=<points>] [pane=<settings pane>]
                        [focus=<project>] [ignore=<kind>:<value>]
                        [group=<none|harness|project|tree>]
                        [appearance=<light|dark>]
                        Render the whole window — sidebar, board, trace — to a
                        PNG, offscreen, after letting the demo run for
                        `seconds` (default 20), at `height` points (default
                        900), showing `section` (default `live`; `harnesses`
                        draws the rack, `projects` the projects page,
                        `settings` the settings pane).
                        `width=` draws the window at that width instead of
                        1440, which is how a page is checked at the sizes a
                        person actually has one open at; `pane=` picks which
                        of Settings' seven pages is shown (`agents`,
                        `characters`, …); `view=` picks the way of looking at
                        the board (`board`, `scene`, `crew`, `trajectory`).
                        `focus=` binds the window to one project the way
                        clicking it in the sidebar does; `ignore=` applies an
                        ignore rule (`pathPrefix`, `project`, `promptPrefix`,
                        `harness`, `titleContains`) for this render only;
                        `group=` divides the wall along that axis, which is the
                        only way to reach the tree grouping headlessly.
                        Reads no harness store and writes nothing.
          --render-trajectory <path> [seconds] [height] [width]
                        [appearance=<light|dark>]
                        Render one session's Trajectory — the waterfall, the
                        step list, and the inspector — to a PNG, offscreen,
                        after letting the demo run for `seconds` (default 20),
                        at `height` x `width` points (default 980 x 1600). The
                        session shown is whichever demo session has the most to
                        show. Reads no harness store.
          --render-context <path> [seconds] [height] [width]
                        [appearance=<light|dark>]
                        Render the context popover on its own — the fill, the
                        estimated composition, and the exact counts — to a PNG,
                        offscreen (default 560 x 360 points). `ImageRenderer`
                        has no window and therefore no popover, so this is the
                        only way to look at the panel at all. It runs the real
                        demo pipeline and the real estimate query behind it;
                        the session shown is whichever one has a reading with
                        something to hedge. Reads no harness store.
                        `appearance=` on any of the five renderers picks which
                        column of the palette to draw with — `dark` (the
                        default) or `light`. Not `system`: a picture whose
                        colours depend on what the machine was set to when the
                        build ran is not a reproducible artefact.
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
