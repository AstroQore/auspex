import AgentSessionKit
import Foundation

/// Request attribution added by Auspex's own stdio bridge.
///
/// `MCPLineHandler` in agent-session-kit 0.6.1 receives only bytes, not the
/// accepted socket that supplied them. The official bridge therefore stamps
/// each JSON-RPC object with its own process id. The app accepts that id only
/// while the kernel also reports it in the live socket roster. This removes
/// accidental cross-connection attribution; the socket remains a local-user
/// trust boundary, not authentication against another process of that user.
public enum MCPTransportAttribution: Sendable, Equatable {
    case absent
    case peer(Int32)
    case invalid
}

public enum MCPTransportEnvelope {
    public static let field = "_auspexTransport"
    private static let peerPIDField = "peerPID"

    /// Overwrites the reserved field, so bytes supplied by the harness cannot
    /// choose the identity stamped by the trusted bridge process.
    public static func attributing(_ line: Data, to peerPID: Int32) -> Data {
        guard peerPID > 0,
              let decoded = try? JSONDecoder().decode(MCPJSON.self, from: line),
              case var .object(fields) = decoded
        else { return line }
        fields[field] = .object([peerPIDField: .int(Int64(peerPID))])
        return (try? MCPJSON.object(fields).serialized()) ?? line
    }

    public static func attribution(in line: Data) -> MCPTransportAttribution {
        guard let decoded = try? JSONDecoder().decode(MCPJSON.self, from: line),
              let fields = decoded.objectValue,
              let metadata = fields[field]
        else { return .absent }
        guard let rawPID = metadata[peerPIDField]?.intValue,
              rawPID > 0,
              let pid = Int32(exactly: rawPID)
        else { return .invalid }
        return .peer(pid)
    }
}
