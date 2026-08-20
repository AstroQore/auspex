import AgentSessionKit
import AgentSessionLive
import AuspexCore
import Foundation
import Observation

/// Owns the MCP listener and says, on screen, what it is doing.
///
/// One of these per process. It binds `~/.auspex/mcp.sock` through the kit's
/// `MCPSocketServer`, hands every line to ``AuspexMCPServer``, and keeps the
/// two numbers the Harnesses page shows: whether the socket is being served,
/// and how many agents are attached to it.
///
/// ## Demo mode does not bind
///
/// A demo replay reads nothing and writes nothing — that is the promise on the
/// sidebar — and binding a socket would create `~/.auspex/`, or worse, take
/// the path away from a live instance that agents are attached to. So the demo
/// serves only when a socket is named explicitly through `AUSPEX_MCP_SOCKET`,
/// which is how a test points one at a temporary directory. Either way the
/// board it serves is read-only: the nine writing tools are refused by name.
@MainActor
@Observable
final class MCPController {
    /// What the listener is doing.
    private(set) var status: MCPSocketServerStatus = .stopped

    /// How many bridges are attached right now.
    private(set) var clientCount = 0

    /// Where it is listening, once it is.
    private(set) var socketPath: String?

    /// Why it is not, when it is not. Shown on the Harnesses page rather than
    /// logged: a socket that failed to bind is the difference between "my
    /// agents cannot see the board" and "my agents are ignoring the board",
    /// and only one of those is worth debugging.
    private(set) var errorDescription: String?

    /// Whether this process is serving a demo board.
    let isReadOnly: Bool

    private let host: AppMCPHost
    private let server: AuspexMCPServer
    private var listener: MCPSocketServer?
    private let paths: AuspexPaths

    /// The command an MCP client is configured with, as it goes into every
    /// harness config Auspex writes.
    ///
    /// The running binary's own path, so a source build registers itself and
    /// an installed `Auspex.app` registers itself — rather than a hard-coded
    /// `/Applications` path that would silently point somebody's agents at a
    /// copy they are not running.
    static var bridgeCommand: String {
        Bundle.main.executableURL?.resolvingSymlinksInPath().path
            ?? CommandLine.arguments.first
            ?? "Auspex"
    }

    init(
        paths: AuspexPaths,
        store: AuspexStore?,
        table: any ProcessTableReading,
        isReadOnly: Bool,
        board: LiveBoardModel,
        onNotice: @escaping @Sendable (AgentNotice) async -> Void,
        onReport: @escaping @Sendable (AgentReport) async -> Void,
        onLedgerChange: @escaping @Sendable () async -> Void,
        onEvents: @escaping @Sendable ([AgentEvent]) async -> Void
    ) {
        self.paths = paths
        self.isReadOnly = isReadOnly
        self.host = AppMCPHost(
            store: store,
            table: table,
            isReadOnly: isReadOnly,
            // Weak: the server outlives nothing, but a strong reference from an
            // actor to the main-actor model would be a cycle through the
            // environment that owns both.
            readBoard: { [weak board] in await MainActor.run { board?.board ?? .empty } },
            onNotice: onNotice,
            onReport: onReport,
            onLedgerChange: onLedgerChange,
            onEvents: onEvents
        )
        self.server = AuspexMCPServer(host: host)
    }

    // MARK: - Lifecycle

    /// Binds the socket, unless this is a demo that was not pointed at one.
    func start(environment: [String: String] = ProcessInfo.processInfo.environment) {
        guard listener == nil else { return }
        let override = environment[AuspexStdioBridge.config.envKey]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let explicit = (override?.isEmpty == false) ? override : nil

        guard let path = explicit ?? (isReadOnly ? nil : paths.socketPath) else {
            errorDescription = "This is a demo replay, so no MCP socket was bound."
            return
        }

        let paths = self.paths
        let listener = MCPSocketServer(
            handler: server,
            socketPath: path,
            // The kit's default. A machine running a dozen agents, each with
            // one bridge, is nowhere near it.
            maximumConnections: MCPSocketServer.maximumConnections,
            ensureDirectory: {
                // The one filesystem touch the transport makes, and it goes
                // through `AuspexPaths` so the containment check applies: a
                // socket outside `~/.auspex/` can only come from an explicit
                // override, whose parent directory the caller already owns.
                _ = try? paths.ensureBaseDirectory()
            }
        )
        // Only the count, and only for the page that draws it. Who is attached
        // is read straight off the listener by `AppMCPHost`, because a snapshot
        // that had to arrive here first would be a frame behind the request it
        // is meant to identify.
        listener.onConnectionsChange = { [weak self] connections in
            Task { @MainActor [weak self] in self?.clientCount = connections.count }
        }
        self.listener = listener

        do {
            try listener.start()
            Task { [host] in await host.setListener(listener) }
            status = listener.status
            socketPath = path
            errorDescription = nil
        } catch let error as MCPSocketError {
            status = listener.status
            errorDescription = error.message
            self.listener = nil
        } catch {
            status = .stopped
            errorDescription = String(describing: error)
            self.listener = nil
        }
    }

    /// Stops serving and removes the socket file this instance created.
    func stop() {
        listener?.stop()
        Task { [host] in await host.setListener(nil) }
        listener = nil
        status = .stopped
        clientCount = 0
        socketPath = nil
    }

    /// Disconnects one client. The process is not signalled: its bridge sees
    /// EOF and exits, which is the same path as Auspex quitting.
    func disconnect(_ id: UUID) {
        _ = listener?.disconnectClient(id: id)
    }

    /// The live clients, for the Harnesses page.
    var connections: [MCPClientConnectionInfo] {
        listener?.clientConnections ?? []
    }

    /// One sentence for the Harnesses page.
    var summary: String {
        switch status {
        case .listening:
            let clients = clientCount == 1 ? "1 agent attached" : "\(clientCount) agents attached"
            return "Serving \(socketPath ?? "the MCP socket") · \(clients)"
        case .conflict:
            return errorDescription ?? "Another copy of Auspex is serving the MCP socket."
        case .stopped:
            return errorDescription ?? "Not serving."
        }
    }
}
