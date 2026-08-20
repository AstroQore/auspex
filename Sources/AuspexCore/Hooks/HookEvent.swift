import AgentSessionKit
import Foundation

/// Which harness's hook is calling, as it appears on the command line.
///
/// The raw values are what goes into somebody's `settings.json` and stays
/// there across upgrades, so they are frozen for the same reason
/// `Harness.rawValue` is: renaming one orphans every config Auspex has ever
/// written.
///
/// `codexNotify` is a harness *and* a shape. Codex has no hook table; it has a
/// single `notify` program, and Auspex may have to run in front of one that was
/// already there — see ``HookIngress``.
public enum HookTarget: String, Sendable, CaseIterable, Hashable {
    case claude
    case cursor
    case grok
    case codexNotify = "codex-notify"

    /// The harness whose sessions these events belong to.
    public var harness: Harness {
        switch self {
        case .claude: .claudeCode
        case .cursor: .cursor
        case .grok: .grokBuild
        case .codexNotify: .codex
        }
    }

    /// Whether the payload arrives on stdin (every hook table) or as the last
    /// argument (Codex's `notify`).
    public var readsStandardInput: Bool {
        self != .codexNotify
    }
}

/// One hook invocation, as it travels from the short-lived `--hook` process to
/// the running app.
///
/// Deliberately thin. Auspex adds three facts the harness could not know —
/// which target was invoked, which process invoked it, and when Auspex saw it —
/// and otherwise passes the harness's own JSON through untouched. Interpreting
/// it is ``HookEventRouter``'s job, in the app, where the board is; a hook
/// process that understood payloads would be a second place harness vocabulary
/// has to be kept up to date.
public struct HookEvent: Sendable, Equatable {
    /// Which harness's hook ran.
    public let target: HookTarget
    /// The process that ran it — the harness itself, since a hook is a direct
    /// child. The fallback when a payload carries no session id.
    public let pid: pid_t
    /// When the hook process read it, not when the app got it.
    public let receivedAt: Date
    /// The harness's own JSON, verbatim.
    public let payload: MCPJSON

    public init(target: HookTarget, pid: pid_t, receivedAt: Date, payload: MCPJSON) {
        self.target = target
        self.pid = pid
        self.receivedAt = receivedAt
        self.payload = payload
    }

    /// The JSON-RPC method the notification is sent as.
    public static let method = "auspex/hookEvent"

    /// The largest payload that will be forwarded.
    ///
    /// A hook payload is a few hundred bytes of metadata; a megabyte is already
    /// two orders of magnitude past anything a harness sends, and past it the
    /// honest thing is to drop the body rather than to pump an unbounded read
    /// into a socket the app has to parse on its own timeline.
    public static let payloadLimit = 1024 * 1024

    /// The notification line, framed and ready to write.
    public func line() -> Data {
        var data = (try? json().serialized()) ?? Data()
        data.append(0x0A)
        return data
    }

    /// The `params` object, as the server reads it back.
    public func json() -> MCPJSON {
        .object([
            "jsonrpc": "2.0",
            "method": .string(Self.method),
            "params": .object([
                "target": .string(target.rawValue),
                "harness": .string(target.harness.rawValue),
                "pid": .int(Int64(pid)),
                "receivedAt": .double(receivedAt.timeIntervalSince1970),
                "payload": payload
            ])
        ])
    }

    /// Reads one back out of a notification's `params`.
    ///
    /// Every field but `target` tolerates being missing: this is parsing input
    /// from a process Auspex does not control the lifetime of, and half an
    /// event about a session Auspex can still identify is worth more than a
    /// refusal.
    public init?(params: MCPJSON?) {
        guard let params,
              let raw = params["target"]?.stringValue,
              let target = HookTarget(rawValue: raw)
        else { return nil }
        self.target = target
        self.pid = params["pid"]?.intValue.map { pid_t($0) } ?? 0
        self.receivedAt = params["receivedAt"]?.doubleValue
            .map { Date(timeIntervalSince1970: $0) } ?? Date()
        self.payload = params["payload"] ?? .object([:])
    }
}
