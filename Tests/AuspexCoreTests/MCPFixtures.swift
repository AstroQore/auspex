import AgentSessionKit
import AgentSessionLive
import Foundation
import Testing

@testable import AuspexCore

/// A host with a board and a store the test controls.
///
/// Everything here is fabricated: `/Users/example` paths, hand-written prompts,
/// and pids that belong to no real process. The process table is a fixed array,
/// so a resolution test asserts on the rule rather than on whatever happened to
/// be running.
actor TestMCPHost: AuspexMCPHost {
    private var board: BoardSnapshot
    private let store: AuspexStore?
    private let table: any ProcessTableReading
    private var pids: [pid_t]
    private var readOnly: Bool

    private(set) var notices: [AgentNotice] = []
    private(set) var reports: [AgentReport] = []
    private(set) var ledgerChanges = 0

    init(
        board: BoardSnapshot = .empty,
        store: AuspexStore? = nil,
        table: any ProcessTableReading = FakeProcessTable(),
        clientPIDs: [pid_t] = [],
        isReadOnly: Bool = false
    ) {
        self.board = board
        self.store = store
        self.table = table
        self.pids = clientPIDs
        self.readOnly = isReadOnly
    }

    var isReadOnly: Bool { readOnly }
    func boardSnapshot() -> BoardSnapshot { board }
    func ledger() -> TaskRepository? { store.map(TaskRepository.init(store:)) }
    func processTable() -> any ProcessTableReading { table }
    func clientPIDs() -> [pid_t] { pids }
    func didRecordNotice(_ notice: AgentNotice) { notices.append(notice) }
    func didRecordReport(_ report: AgentReport) { reports.append(report) }
    func didChangeLedger() { ledgerChanges += 1 }

    func setBoard(_ board: BoardSnapshot) { self.board = board }
    func setClientPIDs(_ pids: [pid_t]) { self.pids = pids }
}

/// A fixed process tree, with environments the test wrote.
struct FakeProcessTable: ProcessTableReading {
    var records: [ProcessRecord] = []
    var environments: [pid_t: [String: String]] = [:]

    func processes() -> [ProcessRecord] { records }
    func environment(pid: pid_t) -> [String: String]? { environments[pid] }
}

extension ProcessRecord {
    /// A synthetic process. No command line: the tests here never need one, and
    /// argv is where credentials live.
    static func fake(pid: pid_t, ppid: pid_t, name: String = "agent") -> ProcessRecord {
        ProcessRecord(
            pid: pid,
            ppid: ppid,
            startTime: Fixtures.date(-30),
            executablePath: "/usr/local/bin/\(name)",
            argv: []
        )
    }
}

/// The JSON-RPC lines a test sends, and the answers it reads back.
enum RPC {
    static func line(_ method: String, id: Int? = nil, params: [String: MCPJSON]? = nil) -> Data {
        var fields: [String: MCPJSON] = ["jsonrpc": "2.0", "method": .string(method)]
        if let id { fields["id"] = .int(Int64(id)) }
        if let params { fields["params"] = .object(params) }
        return (try? MCPJSON.object(fields).serialized()) ?? Data()
    }

    static func call(
        _ tool: String,
        id: Int = 1,
        _ arguments: [String: MCPJSON] = [:]
    ) -> Data {
        line("tools/call", id: id, params: [
            "name": .string(tool),
            "arguments": .object(arguments)
        ])
    }

    static func decode(_ data: Data?) throws -> MCPJSON {
        let data = try #require(data)
        return try JSONDecoder().decode(MCPJSON.self, from: data)
    }

    /// The `structuredContent` of a successful tool call.
    static func structured(_ data: Data?) throws -> MCPJSON {
        let response = try decode(data)
        let result = try #require(response["result"])
        #expect(result["isError"]?.boolValue == false, "expected a success, got: \(result)")
        return try #require(result["structuredContent"])
    }

    /// The message of a tool call that ran and failed.
    static func failureText(_ data: Data?) throws -> String {
        let response = try decode(data)
        let result = try #require(response["result"])
        #expect(result["isError"]?.boolValue == true, "expected a tool failure, got: \(result)")
        return try #require(result["content"]?.arrayValue?.first?["text"]?.stringValue)
    }

    /// The JSON-RPC error of a request that never reached a tool.
    static func rpcError(_ data: Data?) throws -> String {
        let response = try decode(data)
        return try #require(response["error"]?["message"]?.stringValue)
    }
}
