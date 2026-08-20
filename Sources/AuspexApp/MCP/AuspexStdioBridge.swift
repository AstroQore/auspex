import AgentSessionKit
import AuspexCore
import Darwin
import Foundation

/// `Auspex --mcp-stdio`: the process an MCP client actually spawns.
///
/// MCP clients talk to a server by launching a command and speaking
/// newline-delimited JSON-RPC over its stdin and stdout. The running Auspex
/// listens on a Unix socket instead, because a menu-bar app cannot be
/// respawned once per client — so this mode is a byte pump between the two.
/// `MCPStdioBridge` in the kit is the pump; everything here is the vocabulary
/// around it: the flag that appears in every user's config, the environment
/// key a test points at a temporary socket with, and the sentence a person
/// sees when the app is not running.
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

    /// Connects, announces which process spawned us, and pumps until either
    /// side closes.
    ///
    /// ## Why the announcement
    ///
    /// The socket's peer pid — which the kit reports from `LOCAL_PEERPID` — is
    /// *this* process, and walking up from it reaches the harness. That is the
    /// primary way `sessions.self` works and it needs nothing from here. The
    /// hello covers the case where the kernel will not attribute a peer pid at
    /// all: `getppid()` is the harness directly, known for free, and one line
    /// costs nothing to send.
    ///
    /// It is a JSON-RPC *notification*, so the server answers with silence and
    /// the MCP client never sees a message it did not ask for.
    ///
    /// The line is injected by making the bridge read from a pipe this process
    /// fills — the hello first, then everything stdin says — rather than by
    /// reaching into the kit's transport. The pump stays the kit's, and this
    /// file stays the vocabulary.
    static func run() -> Int32 {
        let path = MCPStdioBridge.socketPath(config)

        var descriptors: [Int32] = [-1, -1]
        guard pipe(&descriptors) == 0 else {
            // No pipe, no hello — and no reason to fail: the peer pid answers
            // the same question in the ordinary case.
            return MCPStdioBridge.run(config, socketPath: path)
        }
        let readEnd = descriptors[0]
        let writeEnd = descriptors[1]

        let hello = helloLine(parent: getppid())
        let thread = Thread {
            _ = writeAll(hello, to: writeEnd)
            pump(from: STDIN_FILENO, to: writeEnd)
            close(writeEnd)
        }
        thread.name = "com.astroqore.auspex.mcp.hello"
        thread.start()

        let code = MCPStdioBridge.run(config, socketPath: path, input: readEnd)
        close(readEnd)
        return code
    }

    /// The announcement, as one framed line.
    static func helloLine(parent: pid_t) -> Data {
        let json = MCPJSON.object([
            "jsonrpc": "2.0",
            "method": "auspex/hello",
            "params": .object(["pid": .int(Int64(parent))])
        ])
        var data = (try? json.serialized()) ?? Data()
        data.append(0x0A)
        return data
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

    /// Copies bytes until the source ends. Byte-for-byte: the newline framing
    /// travels inside the stream, so nothing here needs to know where a
    /// message starts or ends.
    private static func pump(from source: Int32, to destination: Int32) {
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = chunk.withUnsafeMutableBytes { read(source, $0.baseAddress, $0.count) }
            if count > 0 {
                var offset = 0
                while offset < count {
                    let written = chunk.withUnsafeBytes { raw -> Int in
                        guard let base = raw.baseAddress else { return -1 }
                        return Darwin.write(destination, base + offset, count - offset)
                    }
                    if written > 0 { offset += written; continue }
                    if errno == EINTR { continue }
                    return
                }
                continue
            }
            if count == 0 { return }
            if errno == EINTR { continue }
            return
        }
    }
}
