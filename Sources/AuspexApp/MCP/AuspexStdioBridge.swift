import AgentSessionKit
import AuspexCore
import Darwin
import Foundation

/// `Auspex --mcp-stdio`: the process an MCP client actually spawns.
///
/// MCP clients talk to a server by launching a command and speaking
/// newline-delimited JSON-RPC over its stdin and stdout. The running Auspex
/// listens on a Unix socket instead, because a menu-bar app cannot be
/// respawned once per client. This mode attributes each framed request to its
/// bridge process, then uses the kit's stdio/socket pump for the transport.
/// The rest is the vocabulary around it: the flag that appears in every
/// user's config, the environment key a test points at a temporary socket
/// with, and the sentence a person sees when the app is not running.
///
/// The process installs no status item, opens no window, and touches nothing
/// on disk except the socket it connects to. That is why it is dispatched from
/// `main.swift` before `App.main()`: touching AppKit in a spawned child — which
/// may be inside somebody else's sandbox — is fatal.
enum AuspexStdioBridge {
    /// The flag, the environment override, and the default socket.
    ///
    /// `AuspexPaths.default` rather than a captured value: the closure is
    /// evaluated when the socket is needed, and the home directory is resolved
    /// through `getpwuid` so a stray `HOME` in the harness's environment cannot
    /// redirect a bridge to a socket in a temporary directory.
    static let config = MCPStdioBridgeConfig(
        flag: "--mcp-stdio",
        envKey: "AUSPEX_MCP_SOCKET",
        defaultSocketPath: { AuspexPaths.default.socketPath },
        notRunningMessage: { path in
            "Auspex is not running, so there is no task board to serve (\(path)). "
                + "Launch Auspex and this MCP server answers on the next call."
        },
        connectionLimitMessage: {
            "Auspex has no free MCP client slots. Quit some idle agents, or "
                + "disconnect a stale client from Auspex's Harnesses page."
        }
    )

    /// Whether this launch is a bridge rather than the app.
    static func isRequested(arguments: [String] = CommandLine.arguments) -> Bool {
        MCPStdioBridge.isRequested(config, arguments: arguments)
    }

    /// Connects and pumps until either side closes. Every JSON-RPC request is
    /// re-encoded with this bridge process's pid in a reserved top-level field.
    /// The running app corroborates that value against `LOCAL_PEERPID` in its
    /// live roster, so two simultaneous bridges cannot be confused by a
    /// last-activity timestamp race.
    static func run() -> Int32 {
        let path = MCPStdioBridge.socketPath(config)

        var descriptors: [Int32] = [-1, -1]
        guard pipe(&descriptors) == 0 else {
            // One direct connection remains safely attributable from the
            // kernel roster. With multiple clients the server fails closed.
            return MCPStdioBridge.run(config, socketPath: path)
        }
        let readEnd = descriptors[0]
        let writeEnd = descriptors[1]

        let peerPID = getpid()
        let thread = Thread {
            pumpAttributed(from: STDIN_FILENO, to: writeEnd, peerPID: peerPID)
            close(writeEnd)
        }
        thread.name = "com.astroqore.auspex.mcp.hello"
        thread.start()

        let code = MCPStdioBridge.run(config, socketPath: path, input: readEnd)
        close(readEnd)
        return code
    }

    // MARK: - Plumbing

    private static func writeAll(_ data: Data, to descriptor: Int32) -> Bool {
        var remaining = data
        while !remaining.isEmpty {
            let written = remaining.withUnsafeBytes { raw -> Int in
                guard let base = raw.baseAddress else { return -1 }
                return Darwin.write(descriptor, base, raw.count)
            }
            if written > 0 {
                remaining = remaining.dropFirst(written)
                continue
            }
            if errno == EINTR { continue }
            return false
        }
        return true
    }

    /// Attributes complete newline-framed objects with a moving scan cursor.
    /// The buffer is compacted once per read, never once per line, so a burst
    /// of small MCP messages remains O(n).
    private static func pumpAttributed(
        from source: Int32,
        to destination: Int32,
        peerPID: pid_t
    ) {
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        var buffer = Data()
        while true {
            let count = chunk.withUnsafeMutableBytes { read(source, $0.baseAddress, $0.count) }
            if count > 0 {
                buffer.append(contentsOf: chunk[0..<count])
                var start = buffer.startIndex
                while let newline = buffer[start...].firstIndex(of: 0x0A) {
                    let raw = Data(buffer[start..<newline])
                    if !raw.isEmpty {
                        var attributed = MCPTransportEnvelope.attributing(
                            raw, to: Int32(peerPID)
                        )
                        // The transport's cap applies after attribution too.
                        guard attributed.count <= MCPSocketServer.maximumLineBytes else { return }
                        attributed.append(0x0A)
                        guard writeAll(attributed, to: destination) else { return }
                    }
                    start = buffer.index(after: newline)
                }
                if start != buffer.startIndex { buffer = Data(buffer[start...]) }
                guard buffer.count <= MCPSocketServer.maximumLineBytes else { return }
                continue
            }
            if count == 0 { return }
            if errno == EINTR { continue }
            return
        }
    }
}
