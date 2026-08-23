import AgentSessionKit
import AgentSessionLive
import AuspexCore
import Foundation

/// The running app, as ``AuspexMCPServer`` sees it.
///
/// An actor rather than a reference to ``AppEnvironment``: the server answers
/// on the socket's own queues, and every question it asks — what is on the
/// board, which pids are attached, is this a demo — must be answerable without
/// hopping to the main actor and without blocking it. The board is pushed in
/// once per applied frame instead of pulled per call, which is also what makes
/// a tool answer in microseconds rather than at the mercy of a layout pass.
actor AppMCPHost: AuspexMCPHost {
    /// Reads the frame the window is drawing, on the main actor.
    ///
    /// Pulled rather than pushed, and that is a memory decision. A frame holds
    /// every session on the board — on a machine with a thousand of them that
    /// is tens of megabytes — so a copy kept here would keep one whole extra
    /// frame alive for as long as the app runs, to serve a handful of tool
    /// calls a minute. Hopping to the main actor when an agent actually asks
    /// costs a value read at a rate nobody can measure, and retains nothing.
    private let readBoard: @Sendable () async -> BoardSnapshot
    /// The transport, for the one question only it can answer: who is attached
    /// right now.
    ///
    /// Read straight through rather than pushed in from `onConnectionsChange`,
    /// and that is a correctness fix rather than a shortcut. A bridge connects
    /// and writes `initialize` and its first `tools/call` in the same
    /// millisecond; a connection snapshot that had to hop to the main actor and
    /// back would lose that race, and `sessions.self` would answer "nothing is
    /// attached" to the client that was, at that moment, attached. The kit's
    /// `clientConnections` is lock-protected and safe to call from here.
    private var listener: MCPSocketServer?
    private let store: AuspexStore?
    private let table: any ProcessTableReading
    private let readOnly: Bool

    /// Called when an agent asks for a person. Hops to the main actor itself.
    private let onNotice: @Sendable (AgentNotice) async -> Void
    /// Called when an agent says what it is doing.
    private let onReport: @Sendable (AgentReport) async -> Void
    /// Called when a plan or a task moved.
    private let onLedgerChange: @Sendable () async -> Void
    /// Called with the events a harness's hook implied.
    private let onEvents: @Sendable ([AgentEvent]) async -> Void

    init(
        store: AuspexStore?,
        table: any ProcessTableReading,
        isReadOnly: Bool,
        readBoard: @escaping @Sendable () async -> BoardSnapshot,
        onNotice: @escaping @Sendable (AgentNotice) async -> Void,
        onReport: @escaping @Sendable (AgentReport) async -> Void,
        onLedgerChange: @escaping @Sendable () async -> Void,
        onEvents: @escaping @Sendable ([AgentEvent]) async -> Void
    ) {
        self.readBoard = readBoard
        self.store = store
        self.table = table
        self.readOnly = isReadOnly
        self.onNotice = onNotice
        self.onReport = onReport
        self.onLedgerChange = onLedgerChange
        self.onEvents = onEvents
    }

    // MARK: - AuspexMCPHost

    var isReadOnly: Bool { readOnly }
    func boardSnapshot() async -> BoardSnapshot { await readBoard() }
    func ledger() -> TaskRepository? { store.map(TaskRepository.init(store:)) }
    func processTable() -> any ProcessTableReading { table }
    func clientRoster() -> MCPClientRoster {
        let connections = listener?.clientConnections ?? []
        return MCPClientRoster(
            connectionCount: connections.count,
            processIDs: connections.compactMap(\.processID)
        )
    }
    func didRecordNotice(_ notice: AgentNotice) async { await onNotice(notice) }
    func didRecordReport(_ report: AgentReport) async { await onReport(report) }
    func didChangeLedger() async { await onLedgerChange() }
    func didObserve(_ events: [AgentEvent]) async { await onEvents(events) }

    // MARK: - Fed from outside

    /// Hands over the listener once it has bound.
    func setListener(_ listener: MCPSocketServer?) { self.listener = listener }
}
