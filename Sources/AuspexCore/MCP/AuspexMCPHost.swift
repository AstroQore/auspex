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

    /// The pids of the processes attached to the MCP socket, **most recently
    /// active first**.
    ///
    /// The kit's transport hands one line handler every connection's traffic,
    /// so a request does not arrive labelled with its connection. The order
    /// here is what stands in for that label: the transport records activity
    /// on the connection immediately before dispatching its line, so the
    /// caller is the head of this list — exactly, unless two clients are
    /// answered in the same instant. `sessions.self` says which pid it used,
    /// and every tool that acts as a session takes an explicit `session_id`
    /// override, so a wrong guess is visible and correctable rather than
    /// silent.
    func clientPIDs() async -> [pid_t]

    /// An agent called for the person. The app posts the notification and
    /// refreshes the board.
    func didRecordNotice(_ notice: AgentNotice) async

    /// An agent said what it is doing.
    func didRecordReport(_ report: AgentReport) async

    /// A plan or task changed, so the Tasks board should re-read.
    func didChangeLedger() async
}

/// A host with no app behind it: an empty board, no store, nothing attached.
///
/// What `--mcp-stdio` would fall back to if it ever served in-process, and
/// what the suite uses as a base to override one method at a time.
public struct EmptyMCPHost: AuspexMCPHost {
    public init() {}
    public var isReadOnly: Bool { get async { true } }
    public func boardSnapshot() async -> BoardSnapshot { .empty }
    public func ledger() async -> TaskRepository? { nil }
    public func processTable() async -> any ProcessTableReading { ProcessTable() }
    public func clientPIDs() async -> [pid_t] { [] }
    public func didRecordNotice(_ notice: AgentNotice) async {}
    public func didRecordReport(_ report: AgentReport) async {}
    public func didChangeLedger() async {}
}
