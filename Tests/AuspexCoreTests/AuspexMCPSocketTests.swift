import AgentSessionKit
import AgentSessionLive
import Darwin
import Foundation
import Testing

@testable import AuspexCore

/// The task tools over the real transport: a Unix socket, the kit's framing,
/// and a client that is nothing but a file descriptor.
///
/// The in-process tests next door call `server.answer(line:)` directly, which
/// proves the dispatch and none of the plumbing. This one binds a socket in a
/// temporary directory, connects to it the way `auspex --mcp-stdio` does, and
/// reads the answer back off the wire — so a change that broke the framing,
/// the JSON, or the actor hop would fail here rather than in somebody's
/// harness. Everything on the board is fabricated under `/Users/example`.
@Suite("The task board over the socket")
struct AuspexMCPSocketTests {
    private static let sessionKey = Fixtures.key(.codex, "0198f4c2-77bd-7a10-b3e9-5c2d84f10ab6")
    private static let harnessPID: pid_t = 900
    private static let clientPID: pid_t = 901
    private static let project = "/Users/example/Code/auspex"

    @Test("a task filed down the socket comes back filed in the caller's project")
    func filesATaskInTheCallersProject() async throws {
        var snapshot = SessionStateReducer.initialSnapshot(
            identity: Fixtures.identity(
                key: Self.sessionKey, cwd: Self.project, gitRoot: Self.project,
                pid: Self.harnessPID
            )
        )
        snapshot.state = .thinking
        let store = try AuspexStore(inMemory: true)
        let host = TestMCPHost(
            board: BoardSnapshot(generatedAt: Fixtures.date(60), sessions: [snapshot]),
            store: store,
            table: FakeProcessTable(records: [
                .fake(pid: Self.clientPID, ppid: Self.harnessPID, name: "Auspex"),
                .fake(pid: Self.harnessPID, ppid: 1, name: "codex")
            ]),
            clientPIDs: [Self.clientPID]
        )
        let server = AuspexMCPServer(host: host, now: { Fixtures.date(100) })

        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ax-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let listener = MCPSocketServer(
            handler: server, socketPath: directory.appendingPathComponent("s.sock").path
        )
        try listener.start()
        defer { listener.stop() }

        let client = try SocketClient(path: listener.socketPath)
        defer { client.close() }

        // The handshake a real client makes before it calls anything.
        let initialize = try client.call(RPC.line("initialize", id: 1))
        #expect(initialize["result"]?["serverInfo"]?["name"]?.stringValue == "auspex")
        let instructions = try #require(initialize["result"]?["instructions"]?.stringValue)
        #expect(instructions.contains("projects"))

        // No project named, and nothing unfiled at the other end.
        let created = try structured(try client.call(RPC.call("tasks.create", id: 2, [
            "title": "Tail the Codex rollout format"
        ])))
        #expect(created["project"]?.stringValue == Self.project)
        #expect(created["projectName"]?.stringValue == "auspex")
        let taskID = try #require(created["id"]?.intValue)

        // And the claim that follows agrees about where the work is.
        let claimed = try structured(try client.call(RPC.call("tasks.claim", id: 3, [
            "task_id": .int(Int64(taskID)), "role": "implementer", "scope": "the rollout tailer"
        ])))
        #expect(claimed["project"]?.stringValue == Self.project)
        #expect(claimed["claimedBy"]?.stringValue == Self.sessionKey.description)

        let listed = try structured(try client.call(RPC.call("tasks.list", id: 4, [
            "project": .string(Self.project)
        ])))
        #expect(listed["tasks"]?.arrayValue?.count == 1)

        let stored = try #require(try TaskRepository(store: store).tasks().first)
        #expect(stored.projectKey == Self.project)
        #expect(try TaskRepository(store: store).taskCounts()[Self.project]?.open == 1)
    }

    private func structured(_ response: MCPJSON) throws -> MCPJSON {
        let result = try #require(response["result"])
        #expect(result["isError"]?.boolValue == false, "expected a success, got: \(result)")
        return try #require(result["structuredContent"])
    }
}

/// A newline-framed JSON-RPC client over a Unix socket, in the twenty lines a
/// test needs. Not a general one: it writes a line, reads a line, and has no
/// opinion about anything else.
private struct SocketClient {
    let descriptor: Int32

    init(path: String) throws {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        try #require(bytes.count <= MemoryLayout.size(ofValue: address.sun_path) - 1)
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            guard let base = raw.baseAddress else { return }
            base.initializeMemory(as: UInt8.self, repeating: 0, count: raw.count)
            base.copyMemory(from: bytes, byteCount: bytes.count)
        }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)

        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        try #require(descriptor >= 0)
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else {
            Darwin.close(descriptor)
            throw SocketClientError.couldNotConnect(errno)
        }
        // A test that hangs is a test that has to be killed by hand.
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(
            descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size)
        )
        self.descriptor = descriptor
    }

    func close() { Darwin.close(descriptor) }

    /// Writes one framed line and reads the one that comes back.
    func call(_ line: Data) throws -> MCPJSON {
        var payload = line
        payload.append(0x0A)
        try payload.withUnsafeBytes { raw in
            var sent = 0
            while sent < raw.count {
                let count = Darwin.write(descriptor, raw.baseAddress! + sent, raw.count - sent)
                guard count > 0 else { throw SocketClientError.writeFailed(errno) }
                sent += count
            }
        }
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 4_096)
        while !buffer.contains(0x0A) {
            let count = chunk.withUnsafeMutableBytes { read(descriptor, $0.baseAddress, $0.count) }
            guard count > 0 else { throw SocketClientError.noAnswer }
            buffer.append(contentsOf: chunk[0..<count])
        }
        let line = buffer.prefix { $0 != 0x0A }
        return try JSONDecoder().decode(MCPJSON.self, from: Data(line))
    }
}

private enum SocketClientError: Error {
    case couldNotConnect(Int32)
    case writeFailed(Int32)
    case noAnswer
}
