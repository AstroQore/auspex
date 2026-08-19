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
    do {
        let board = SceneSnapshotRenderer.demoBoard(elapsed: elapsed)
        try SceneSnapshotRenderer.render(board: board, to: URL(fileURLWithPath: path))
        // Report what was drawn. Choosing *when* in the demo loop to render is
        // the whole job of picking a good screenshot, and this tally is how it
        // is chosen.
        let counts = board.counts
        let summary = "auspex: \(board.sessions.count) sessions at t+\(Int(elapsed))s — "
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

if arguments.contains("--help") || arguments.contains("-h") {
    FileHandle.standardOutput.write(Data("""
        auspex — one live board for every AI coding agent on this Mac.

        Usage: Auspex [--demo]

          --demo        Replay a fabricated board instead of tailing the real
                        harness stores. Runs entirely in memory: no harness
                        store is read and nothing is written to ~/.auspex/.
                        `AUSPEX_DEMO=1` does the same, for launchers such as
                        `open -a` that cannot pass arguments through.
          --render-scene <path> [seconds]
                        Render the scene view's office to a PNG, offscreen,
                        from the demo board at `seconds` into its loop
                        (default 16). Used to build the README screenshot.
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
