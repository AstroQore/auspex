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

if arguments.contains("--help") || arguments.contains("-h") {
    FileHandle.standardOutput.write(Data("""
        auspex — one live board for every AI coding agent on this Mac.

        Usage: Auspex [--demo]

          --demo        Replay a fabricated board instead of tailing the real
                        harness stores. Runs entirely in memory: no harness
                        store is read and nothing is written to ~/.auspex/.
                        `AUSPEX_DEMO=1` does the same, for launchers such as
                        `open -a` that cannot pass arguments through.
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
