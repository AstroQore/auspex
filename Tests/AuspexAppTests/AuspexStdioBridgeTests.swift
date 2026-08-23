import AgentSessionKit
import AuspexCore
import Darwin
import Foundation
import Testing

@testable import AuspexApp

@Suite("Auspex stdio bridge")
struct AuspexStdioBridgeTests {
    private actor AttributionHandler: MCPLineHandler {
        private(set) var attribution: MCPTransportAttribution = .absent

        func handle(line: Data) async -> Data? {
            attribution = MCPTransportEnvelope.attribution(in: line)
            let request = try? MCPRequest.decode(line: line)
            return MCPResponse(id: request?.id ?? .null, result: .object([:])).framed()
        }
    }

    @Test("the real stdio path stamps each forwarded request with its bridge pid")
    func forwardedRequestIsAttributed() async throws {
        let suffix = UUID().uuidString.prefix(8)
        let directory = URL(
            fileURLWithPath: "/tmp/auspex-bridge-\(getpid())-\(suffix)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let socketPath = directory.appendingPathComponent("mcp.sock").path
        let handler = AttributionHandler()
        let server = MCPSocketServer(handler: handler, socketPath: socketPath)
        try server.start()
        defer { server.stop() }

        var input: [Int32] = [-1, -1]
        var output: [Int32] = [-1, -1]
        try #require(pipe(&input) == 0)
        try #require(pipe(&output) == 0)
        defer {
            if input[0] >= 0 { close(input[0]) }
            if input[1] >= 0 { close(input[1]) }
            if output[0] >= 0 { close(output[0]) }
            if output[1] >= 0 { close(output[1]) }
        }

        var request = try MCPJSON.object([
            "jsonrpc": "2.0", "id": 1, "method": "ping",
            MCPTransportEnvelope.field: .object(["peerPID": 99_999])
        ]).serialized()
        request.append(0x0A)
        _ = request.withUnsafeBytes { raw in
            Darwin.write(input[1], raw.baseAddress, raw.count)
        }
        close(input[1])
        input[1] = -1

        let code = AuspexStdioBridge.run(
            socketPath: socketPath,
            input: input[0],
            output: output[1],
            standardError: .nullDevice
        )
        close(input[0])
        input[0] = -1
        close(output[1])
        output[1] = -1

        #expect(code == MCPStdioBridge.ExitCode.ok)
        #expect(await handler.attribution == .peer(getpid()))
        let response = FileHandle(fileDescriptor: output[0], closeOnDealloc: false)
            .readDataToEndOfFile()
        #expect(try MCPResponseLine(response).id == 1)
    }
}

private struct MCPResponseLine {
    let id: Int?

    init(_ framed: Data) throws {
        let line = framed.firstIndex(of: 0x0A).map { Data(framed[..<$0]) } ?? framed
        let json = try JSONDecoder().decode(MCPJSON.self, from: line)
        id = json["id"]?.intValue
    }
}
