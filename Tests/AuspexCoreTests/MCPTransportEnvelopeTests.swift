import AgentSessionKit
import Foundation
import Testing

@testable import AuspexCore

@Suite("MCP request transport attribution")
struct MCPTransportEnvelopeTests {
    @Test("the bridge overwrites a caller supplied reserved field")
    func bridgeOwnsReservedField() throws {
        let raw: MCPJSON = [
            "jsonrpc": "2.0",
            "id": 7,
            "method": "tools/list",
            MCPTransportEnvelope.field: ["peerPID": 999]
        ]
        let line = try raw.serialized()
        let attributed = MCPTransportEnvelope.attributing(line, to: 42)
        #expect(MCPTransportEnvelope.attribution(in: attributed) == .peer(42))
        let decoded = try MCPRequest.decode(line: attributed)
        #expect(decoded.id?.intValue == 7)
        #expect(decoded.method == "tools/list")
    }

    @Test("absent and malformed attribution stay distinguishable")
    func absentAndMalformed() throws {
        let ordinary: MCPJSON = ["jsonrpc": "2.0", "id": 1, "method": "ping"]
        #expect(
            MCPTransportEnvelope.attribution(in: try ordinary.serialized()) == .absent
        )
        let malformed: MCPJSON = [
            "jsonrpc": "2.0", "id": 1, "method": "ping",
            MCPTransportEnvelope.field: ["peerPID": -1]
        ]
        #expect(
            MCPTransportEnvelope.attribution(in: try malformed.serialized()) == .invalid
        )
    }
}
