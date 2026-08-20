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
    private var board: BoardSnapshot = .empty
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

    init(
        store: AuspexStore?,
        table: any ProcessTableReading,
        isReadOnly: Bool,
        onNotice: @escaping @Sendable (AgentNotice) async -> Void,
        onReport: @escaping @Sendable (AgentReport) async -> Void,
        onLedgerChange: @escaping @Sendable () async -> Void
    ) {
        self.store = store
        self.table = table
        self.readOnly = isReadOnly
        self.onNotice = onNotice
        self.onReport = onReport
        self.onLedgerChange = onLedgerChange
    }

    // MARK: - AuspexMCPHost

    var isReadOnly: Bool { readOnly }
    func boardSnapshot() -> BoardSnapshot { board }
    func ledger() -> TaskRepository? { store.map(TaskRepository.init(store:)) }
    func processTable() -> any ProcessTableReading { table }
    func clientPIDs() -> [pid_t] {
        (listener?.clientConnections ?? [])
            .sorted { $0.lastActivityAt > $1.lastActivityAt }
            .compactMap(\.processID)
    }
    func didRecordNotice(_ notice: AgentNotice) async { await onNotice(notice) }
    func didRecordReport(_ report: AgentReport) async { await onReport(report) }
    func didChangeLedger() async { await onLedgerChange() }

    // MARK: - Fed from outside

    /// The frame the board is showing. Pushed once per applied frame.
    func setBoard(_ board: BoardSnapshot) { self.board = board }

    /// Hands over the listener once it has bound.
    func setListener(_ listener: MCPSocketServer?) { self.listener = listener }
}
