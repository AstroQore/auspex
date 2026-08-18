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

AuspexApp.main()
