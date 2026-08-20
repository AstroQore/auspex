import AgentSessionKit
import AgentSessionLive
import Darwin
import Foundation
import Testing

@testable import AuspexCore

/// `Auspex --hook`, against a socket the test owns.
///
/// The property under test is the one the harness cares about: **it comes back,
/// with a zero, inside its deadline, whatever is on the other end** — nothing
/// listening, something listening that never answers, a stdin that never closes,
/// a megabyte of nonsense. A hook that can hang is a harness that can hang.
///
/// The watchdog is off in every test here. It ends the *process*, which in a
/// test is the suite; leaving it off also means these tests prove the bound
/// holds without it, which is what makes it a backstop rather than the
/// mechanism.
@Suite("Hook ingress")
struct HookIngressTests {
    /// A socket in a temporary directory that records the lines written to it.
    private final class Listener {
        let path: String
        private let descriptor: Int32
        private let queue = DispatchQueue(label: "auspex.test.hook.listener")
        private let lock = NSLock()
        private var received: [Data] = []

        init() throws {
            // A short name on purpose. `sun_path` is 104 bytes, and this
            // machine's `NSTemporaryDirectory()` is 48 of them before anything
            // is added — a socket called `auspex-hook-<uuid>/mcp.sock` under it
            // does not fit, and the failure is a connect that quietly never
            // happens.
            let directory = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("ax-\(UUID().uuidString.prefix(8))", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            path = directory.appendingPathComponent("s.sock").path
            try #require(path.utf8.count < 104)

            descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
            var address = sockaddr_un()
            address.sun_family = sa_family_t(AF_UNIX)
            let bytes = Array(path.utf8)
            withUnsafeMutableBytes(of: &address.sun_path) { raw in
                guard let base = raw.baseAddress else { return }
                base.initializeMemory(as: UInt8.self, repeating: 0, count: raw.count)
                base.copyMemory(from: bytes, byteCount: bytes.count)
            }
            address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
            let bound = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            try #require(bound == 0)
            try #require(listen(descriptor, 4) == 0)
            accept()
        }

        deinit {
            close(descriptor)
            try? FileManager.default.removeItem(
                at: URL(fileURLWithPath: path).deletingLastPathComponent()
            )
        }

        private func accept() {
            queue.async { [descriptor] in
                while true {
                    let client = Darwin.accept(descriptor, nil, nil)
                    guard client >= 0 else { return }
                    var out = Data()
                    var buffer = [UInt8](repeating: 0, count: 4096)
                    while true {
                        let count = buffer.withUnsafeMutableBytes {
                            read(client, $0.baseAddress, $0.count)
                        }
                        guard count > 0 else { break }
                        out.append(contentsOf: buffer[0..<count])
                    }
                    close(client)
                    self.append(out)
                }
            }
        }

        private func append(_ data: Data) {
            lock.lock()
            received.append(data)
            lock.unlock()
        }

        /// Waits briefly for a line, because the accept loop is on its own
        /// queue and the writer has already gone home.
        func line(within seconds: TimeInterval = 2) -> MCPJSON? {
            let deadline = Date().addingTimeInterval(seconds)
            while Date() < deadline {
                lock.lock()
                let first = received.first
                lock.unlock()
                if let first, let end = first.firstIndex(of: 0x0A) {
                    return try? JSONDecoder().decode(MCPJSON.self, from: first[..<end])
                }
                usleep(20_000)
            }
            return nil
        }
    }

    /// A descriptor holding the payload, already at EOF.
    ///
    /// A file rather than a pipe: a pipe's buffer is 64 KB, and the test that
    /// checks the megabyte cap would deadlock writing into one nobody is
    /// reading. A file is the same `read`-to-EOF from the ingress's side.
    private func stdin(_ text: String) throws -> Int32 {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("auspex-hook-stdin-\(UUID().uuidString)")
        try Data(text.utf8).write(to: url)
        let descriptor = open(url.path, O_RDONLY)
        try? FileManager.default.removeItem(at: url)
        return descriptor
    }

    /// A pipe the harness opened and has not closed. Small payloads only, for
    /// the same reason.
    private func openPipe(_ text: String) -> Int32 {
        var descriptors: [Int32] = [-1, -1]
        _ = pipe(&descriptors)
        let data = Array(text.utf8)
        if !data.isEmpty {
            _ = data.withUnsafeBytes { write(descriptors[1], $0.baseAddress, $0.count) }
        }
        return descriptors[0]
    }

    // MARK: - Argv

    @Test("the command line says which harness, and what to run afterwards")
    func parsing() {
        let plain = HookIngress.parse(arguments: ["Auspex", "--hook", "claude"])
        #expect(plain?.target == .claude)
        #expect(plain?.chain.isEmpty == true)
        #expect(plain?.payloadArgument == nil)

        // Codex appends its JSON to whatever command it was told to run, so the
        // last argument is the payload and everything before it is the program.
        let chained = HookIngress.parse(arguments: [
            "Auspex", "--hook", "codex-notify", "--then",
            "/Users/example/bin/notify", "turn-ended", "{\"type\":\"agent-turn-complete\"}"
        ])
        #expect(chained?.target == .codexNotify)
        #expect(chained?.chain == ["/Users/example/bin/notify", "turn-ended"])
        #expect(chained?.payloadArgument == "{\"type\":\"agent-turn-complete\"}")
        #expect(chained?.chainCommand == [
            "/Users/example/bin/notify", "turn-ended", "{\"type\":\"agent-turn-complete\"}"
        ])

        #expect(HookIngress.parse(arguments: ["Auspex", "--hook"]) == nil)
        #expect(HookIngress.parse(arguments: ["Auspex", "--hook", "nonesuch"]) == nil)
        #expect(HookIngress.isRequested(arguments: ["Auspex", "--hook", "claude"]))
        #expect(!HookIngress.isRequested(arguments: ["Auspex", "--demo"]))
    }

    // MARK: - The happy path

    @Test("a payload on stdin reaches the socket as one notification")
    func shipsThePayload() throws {
        let listener = try Listener()
        let code = HookIngress.run(
            arguments: ["Auspex", "--hook", "claude"],
            environment: [HookIngress.socketEnvironmentKey: listener.path],
            input: try stdin(#"{"hook_event_name":"PermissionRequest","session_id":"abc","tool_name":"Bash"}"#),
            installsWatchdog: false
        )
        #expect(code == 0)

        let line = try #require(listener.line())
        #expect(line["method"]?.stringValue == "auspex/hookEvent")
        #expect(line["id"] == nil, "a notification, so the app answers with silence")
        let params = try #require(line["params"])
        #expect(params["target"]?.stringValue == "claude")
        #expect(params["harness"]?.stringValue == Harness.claudeCode.rawValue)
        #expect(params["pid"]?.intValue == Int(getppid()))
        #expect(params["payload"]?["tool_name"]?.stringValue == "Bash")
        #expect(params["payload"]?["session_id"]?.stringValue == "abc")
    }

    @Test("Codex's argv payload travels the same way stdin's does")
    func shipsAnArgumentPayload() throws {
        let listener = try Listener()
        let code = HookIngress.run(
            arguments: [
                "Auspex", "--hook", "codex-notify",
                #"{"type":"agent-turn-complete","turn-id":"t1"}"#
            ],
            environment: [HookIngress.socketEnvironmentKey: listener.path],
            input: try stdin(""),
            installsWatchdog: false
        )
        #expect(code == 0)
        let params = try #require(listener.line()?["params"])
        #expect(params["target"]?.stringValue == "codex-notify")
        #expect(params["payload"]?["type"]?.stringValue == "agent-turn-complete")
    }

    // MARK: - Everything that could go wrong

    @Test("nothing listening is not an error")
    func noSocket() throws {
        let started = Date()
        let code = HookIngress.run(
            arguments: ["Auspex", "--hook", "claude"],
            environment: [HookIngress.socketEnvironmentKey:
                NSTemporaryDirectory() + "auspex-does-not-exist-\(UUID().uuidString).sock"],
            input: try stdin("{}"),
            installsWatchdog: false
        )
        #expect(code == 0)
        #expect(Date().timeIntervalSince(started) < HookIngress.deadline)
    }

    @Test("a socket path that is an ordinary file is not an error either")
    func socketPathIsAFile() throws {
        let file = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("auspex-not-a-socket-\(UUID().uuidString)")
        try Data("x".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        #expect(HookIngress.run(
            arguments: ["Auspex", "--hook", "grok"],
            environment: [HookIngress.socketEnvironmentKey: file.path],
            input: try stdin("{}"),
            installsWatchdog: false
        ) == 0)
    }

    @Test("a stdin that never closes ends at the deadline, with a zero")
    func stdinNeverCloses() throws {
        let listener = try Listener()
        let held = openPipe("{\"hook_event_name\":\"Stop\"}")
        let started = Date()
        let code = HookIngress.run(
            arguments: ["Auspex", "--hook", "claude"],
            environment: [HookIngress.socketEnvironmentKey: listener.path],
            input: held,
            limit: 0.2,
            installsWatchdog: false
        )
        let elapsed = Date().timeIntervalSince(started)
        #expect(code == 0)
        // Not exactly 0.2: `poll` takes whole milliseconds and the clock is
        // read twice, so the wait lands a hair either side of the deadline.
        #expect(elapsed >= 0.15, "it waited for the payload it was promised")
        // Generous, because a loaded machine running the whole suite is not a
        // real-time system. The point is that it is bounded at all.
        #expect(elapsed < 1.0, "and gave up rather than waiting for the harness")
    }

    @Test("a payload past the cap is dropped rather than pumped through")
    func oversizePayload() throws {
        let listener = try Listener()
        let huge = "{\"junk\":\"" + String(repeating: "x", count: HookEvent.payloadLimit) + "\"}"
        #expect(HookIngress.run(
            arguments: ["Auspex", "--hook", "claude"],
            environment: [HookIngress.socketEnvironmentKey: listener.path],
            input: try stdin(huge),
            limit: 1,
            installsWatchdog: false
        ) == 0)
        let params = try #require(listener.line()?["params"])
        #expect(params["payload"]?.objectValue?.isEmpty == true)
    }

    @Test("a payload that is not JSON is dropped, and the event still goes")
    func garbagePayload() throws {
        let listener = try Listener()
        #expect(HookIngress.run(
            arguments: ["Auspex", "--hook", "cursor"],
            environment: [HookIngress.socketEnvironmentKey: listener.path],
            input: try stdin("not json at all"),
            installsWatchdog: false
        ) == 0)
        let params = try #require(listener.line()?["params"])
        #expect(params["target"]?.stringValue == "cursor")
        #expect(params["payload"]?.objectValue?.isEmpty == true)
    }

    // MARK: - The whole path

    @Test("argv to board event: the real socket, the real server, one card moved")
    func endToEnd() async throws {
        let session = Fixtures.key(.claudeCode, "aaaa1111-2222-3333-4444-555555555555")
        var snapshot = SessionStateReducer.initialSnapshot(
            identity: Fixtures.identity(key: session, pid: 900)
        )
        snapshot.state = .thinking
        let host = TestMCPHost(
            board: BoardSnapshot(generatedAt: Fixtures.date(60), sessions: [snapshot]),
            table: FakeProcessTable(records: [.fake(pid: 900, ppid: 1, name: "claude")])
        )
        let server = AuspexMCPServer(host: host)

        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ax-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let socketPath = directory.appendingPathComponent("s.sock").path

        let listener = MCPSocketServer(handler: server, socketPath: socketPath)
        try listener.start()
        defer { listener.stop() }

        #expect(HookIngress.run(
            arguments: ["Auspex", "--hook", "claude"],
            environment: [HookIngress.socketEnvironmentKey: socketPath],
            input: try stdin("""
                {"hook_event_name":"PermissionRequest",\
                "session_id":"\(session.sessionID)","tool_name":"Bash",\
                "tool_input":{"command":"rm -rf build"}}
                """),
            installsWatchdog: false
        ) == 0)

        // The socket is read on the transport's own queue, so the event arrives
        // a moment after the hook process has already gone home — which is the
        // whole point of the arrangement.
        var observed: [AgentEvent] = []
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline, observed.isEmpty {
            observed = await host.observed
            if observed.isEmpty { try? await Task.sleep(for: .milliseconds(20)) }
        }
        #expect(observed.count == 1)
        let moved = SessionStateReducer().reduce(snapshot, event: try #require(observed.first))
        #expect(moved.state == .waitingPermission(tool: "Bash"))
    }

    @Test("an unknown target is somebody's newer config, not a failure")
    func unknownTarget() throws {
        #expect(HookIngress.run(
            arguments: ["Auspex", "--hook", "something-new"],
            environment: [:],
            input: try stdin("{}"),
            installsWatchdog: false
        ) == 0)
    }
}
