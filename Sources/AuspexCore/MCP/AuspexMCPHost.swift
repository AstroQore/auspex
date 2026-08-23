import AgentSessionKit
import AgentSessionLive
import Foundation

/// What ``AuspexMCPServer`` needs from the running app.
///
/// A seam rather than a direct reference, for three reasons and each is a
/// thing that would otherwise be untestable:
///
/// - The board lives on an actor the server must not import, and the store may
///   not exist at all (a launch that could not open it still shows a window).
/// - The socket transport reports which processes are attached, and only the
///   app owns the listener.
/// - Demo mode has to answer reads and refuse writes, which is one flag here
///   rather than a second server implementation.
public protocol AuspexMCPHost: Sendable {
    /// Whether this Auspex is replaying a fabricated board. Writes are refused
    /// and no notification is ever posted.
    var isReadOnly: Bool { get async }

    /// The frame the board is currently showing.
    func boardSnapshot() async -> BoardSnapshot

    /// The ledger, or `nil` when the store could not be opened.
    func ledger() async -> TaskRepository?

    /// The process table, for working out who is calling. Shared with the
    /// liveness loop so an ancestor walk costs no extra sweep.
    func processTable() async -> any ProcessTableReading

    /// The exact live socket roster. `connectionCount` includes peers whose
    /// pid the kernel could not expose; that distinction is what makes the
    /// one-connection compatibility fallback fail closed with two unknown
    /// peers instead of mistaking them for no connection at all.
    func clientRoster() async -> MCPClientRoster

    /// An agent called for the person. The app posts the notification and
    /// refreshes the board.
    func didRecordNotice(_ notice: AgentNotice) async

    /// An agent said what it is doing.
    func didRecordReport(_ report: AgentReport) async

    /// A plan or task changed, so the Tasks board should re-read.
    func didChangeLedger() async

    /// A harness's hook reported something the transcript will not. The app
    /// puts these into the same stream the tailers feed, so the reducer folds a
    /// permission prompt and a tool call the same way.
    func didObserve(_ events: [AgentEvent]) async
}

public struct MCPClientRoster: Sendable, Equatable {
    public let connectionCount: Int
    public let processIDs: [pid_t]

    public init(connectionCount: Int, processIDs: [pid_t]) {
        self.connectionCount = connectionCount
        self.processIDs = processIDs
    }
}

public extension AuspexMCPHost {
    /// Hosts that only answer questions ignore them.
    func didObserve(_ events: [AgentEvent]) async {}
}
