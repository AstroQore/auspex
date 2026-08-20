import AgentSessionKit
import Darwin
import Foundation

/// `Auspex --hook <target>`: the process a harness runs when something happens.
///
/// ## The one rule
///
/// **It exits 0, within its deadline, no matter what.** A hook is a synchronous
/// child of the harness: every millisecond it spends is a millisecond the
/// agent is not working, and a non-zero exit is, in most harnesses, a *veto* —
/// Claude Code reads a failing `PermissionRequest` hook as a decision, and
/// Cursor's `failClosed` hooks block the tool call. An observer that can block
/// the thing it observes is not an observer.
///
/// So the shape here is deliberately paranoid:
///
/// - Every blocking call has a deadline of its own: the stdin read polls, the
///   connect polls, the write has `SO_SNDTIMEO`.
/// - A watchdog thread ends the process at the deadline regardless of what the
///   main path is doing. Belt, braces, and a second pair of braces — because
///   the failure this guards against is a socket that accepts a connection and
///   then never reads, and no amount of care in the happy path covers it.
/// - `SO_NOSIGPIPE`, because a `SIGPIPE` on a socket the app closed mid-write
///   would kill the process with a signal, and a signalled hook is a failed
///   hook.
/// - Auspex not running is not an error. There is nothing to tell, so it says
///   nothing and exits 0.
///
/// ## What it does not do
///
/// It does not parse the payload, does not read any harness store, does not
/// touch `~/.auspex/`, and writes nothing to a log. Hook payloads carry prompt
/// text and file contents; the only place they go is the socket, and the app
/// on the other end keeps them in memory.
public enum HookIngress {
    /// How long the whole thing may take.
    ///
    /// 200 ms is well past what it costs — a connect and a write on a local
    /// socket is under a millisecond — and short enough that a hung Auspex
    /// costs a harness less than one frame of its own spinner.
    public static let deadline: TimeInterval = 0.2

    /// The flag that selects this mode.
    public static let flag = "--hook"

    /// The flag that wraps a program Auspex was asked to run in front of.
    public static let chainFlag = "--then"

    // MARK: - Argv

    /// What a command line asked for.
    public struct Invocation: Sendable, Equatable {
        /// Which harness's hook this is.
        public let target: HookTarget
        /// The program Auspex is standing in front of, and its arguments, when
        /// `--then` named one. Empty when it did not.
        ///
        /// Only Codex needs this. Its `notify` is a single slot rather than a
        /// list, so registering Auspex there means displacing whatever was
        /// already in it — and the honest way to displace a program is to run
        /// it. Every other harness has a hook *table*, where Auspex adds an
        /// entry beside the ones already there and nothing has to be wrapped.
        public let chain: [String]
        /// The payload, when the harness passed it as an argument rather than
        /// on stdin. Codex's `notify` is the only one that does.
        public let payloadArgument: String?

        public init(target: HookTarget, chain: [String] = [], payloadArgument: String? = nil) {
            self.target = target
            self.chain = chain
            self.payloadArgument = payloadArgument
        }

        /// The chained program's own argv — its arguments, with the harness's
        /// payload put back on the end exactly where the harness appended it.
        ///
        /// A wrapped `notify` has to be indistinguishable from an unwrapped
        /// one, and the payload is the only argument Codex actually passes.
        public var chainCommand: [String] {
            guard !chain.isEmpty else { return [] }
            guard let payloadArgument else { return chain }
            return chain + [payloadArgument]
        }
    }

    /// Whether this launch is a hook.
    public static func isRequested(arguments: [String] = CommandLine.arguments) -> Bool {
        arguments.dropFirst().contains(flag)
    }

    /// Reads the invocation out of argv.
    ///
    /// The shape it has to cope with is Codex's: the harness appends its JSON
    /// as the *last* argument of whatever command it was told to run, so a
    /// chained invocation arrives as
    ///
    /// ```text
    /// Auspex --hook codex-notify --then /old/notify --flag <json>
    /// ```
    ///
    /// and the last argument belongs to the payload rather than to the chained
    /// program. Everything between `--then` and it is the program.
    public static func parse(arguments: [String]) -> Invocation? {
        let rest = Array(arguments.dropFirst())
        guard let flagIndex = rest.firstIndex(of: flag), flagIndex + 1 < rest.count,
              let target = HookTarget(rawValue: rest[flagIndex + 1])
        else { return nil }

        var trailing = Array(rest[(flagIndex + 2)...])
        var chain: [String] = []
        if let chainIndex = trailing.firstIndex(of: chainFlag) {
            let after = Array(trailing[(chainIndex + 1)...])
            trailing = Array(trailing[..<chainIndex])
            if target.readsStandardInput {
                chain = after
            } else {
                // The harness's own argument is the last one, and it is ours,
                // not the chained program's — until we hand it back.
                chain = Array(after.dropLast())
                if let payload = after.last { trailing.append(payload) }
            }
        }
        return Invocation(
            target: target,
            chain: chain,
            payloadArgument: target.readsStandardInput ? nil : trailing.last
        )
    }

    // MARK: - Running

    /// Ships one hook invocation and returns the process's exit code, which is
    /// always `0`.
    ///
    /// - Parameters:
    ///   - installsWatchdog: the thread that ends the process at the deadline.
    ///     `false` in tests, which must not have the suite killed under them;
    ///     every individual step has its own deadline, so the bound holds
    ///     either way and the watchdog only covers what nothing else can.
    @discardableResult
    public static func run(
        arguments: [String] = CommandLine.arguments,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        input: Int32 = STDIN_FILENO,
        now: Date = Date(),
        limit: TimeInterval = deadline,
        installsWatchdog: Bool = true
    ) -> Int32 {
        let expiry = Date().addingTimeInterval(limit)
        guard let invocation = parse(arguments: arguments) else {
            // An unknown target is somebody's config from a newer Auspex, or a
            // typo. Neither is worth failing a harness's tool call over.
            return 0
        }

        if installsWatchdog { startWatchdog(after: limit, chain: invocation.chainCommand) }

        let payload = read(invocation, input: input, until: expiry)
        let event = HookEvent(
            target: invocation.target,
            pid: getppid(),
            receivedAt: now,
            payload: payload
        )
        send(event.line(), to: socketPath(environment: environment), until: expiry)

        // Whatever Codex was told to run before Auspex was put in front of it
        // still has to run, and has to look to Codex exactly as it did before:
        // same argv, same stdio, same exit code. `execv` replaces this process,
        // so it is the same pid too.
        exec(invocation.chainCommand)
        return 0
    }

    /// Where the running app is listening.
    public static func socketPath(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String {
        let override = environment[socketEnvironmentKey]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let override, !override.isEmpty { return override }
        return AuspexPaths.default.socketPath
    }

    /// The same override `--mcp-stdio` honours, so a test — or a second
    /// Auspex — moves both halves of the protocol together.
    public static let socketEnvironmentKey = "AUSPEX_MCP_SOCKET"

    // MARK: - The payload

    /// The harness's JSON, from stdin or from argv.
    ///
    /// Anything that is not a JSON object becomes an empty one rather than
    /// stopping the run: the event still carries the target and the pid, which
    /// is enough for the app to know the harness is alive.
    static func read(_ invocation: Invocation, input: Int32, until expiry: Date) -> MCPJSON {
        let data: Data
        if let argument = invocation.payloadArgument {
            data = Data(argument.utf8)
        } else if invocation.target.readsStandardInput {
            data = readAll(input, limit: HookEvent.payloadLimit, until: expiry)
        } else {
            data = Data()
        }
        guard !data.isEmpty, data.count <= HookEvent.payloadLimit else { return .object([:]) }
        guard let json = try? JSONDecoder().decode(MCPJSON.self, from: data),
              json.objectValue != nil
        else { return .object([:]) }
        return json
    }

    /// Reads a descriptor to EOF, the cap, or the deadline — whichever comes
    /// first.
    ///
    /// Polls rather than blocks. A harness that opens the pipe and then hangs
    /// is not a hypothetical: it is what happens when the harness itself is
    /// stopped in a debugger, and a blocking read would park this process for
    /// as long as that lasted.
    static func readAll(_ descriptor: Int32, limit: Int, until expiry: Date) -> Data {
        var out = Data()
        var buffer = [UInt8](repeating: 0, count: 32 * 1024)
        while out.count <= limit {
            let remaining = expiry.timeIntervalSinceNow
            guard remaining > 0 else { return out }
            var fd = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
            let ready = poll(&fd, 1, Int32(remaining * 1000))
            if ready < 0 {
                if errno == EINTR { continue }
                return out
            }
            if ready == 0 { return out }
            let count = buffer.withUnsafeMutableBytes {
                Darwin.read(descriptor, $0.baseAddress, $0.count)
            }
            if count > 0 {
                out.append(contentsOf: buffer[0..<count])
                continue
            }
            if count == 0 { return out }
            if errno == EINTR { continue }
            return out
        }
        return out
    }

    // MARK: - The socket

    /// Connects, writes one line, closes. Silent about every failure.
    ///
    /// `@discardableResult` and a `Bool` rather than a throw: there is nothing
    /// a caller could do differently, and the return exists so a test can say
    /// "this one did get through".
    @discardableResult
    static func send(_ line: Data, to path: String, until expiry: Date) -> Bool {
        guard let descriptor = connect(to: path, until: expiry) else { return false }
        defer { close(descriptor) }

        var remaining = line
        while !remaining.isEmpty {
            let timeout = expiry.timeIntervalSinceNow
            guard timeout > 0 else { return false }
            var send = timeval(
                tv_sec: Int(timeout),
                tv_usec: Int32((timeout - Double(Int(timeout))) * 1_000_000)
            )
            setsockopt(
                descriptor, SOL_SOCKET, SO_SNDTIMEO, &send, socklen_t(MemoryLayout<timeval>.size)
            )
            let written = remaining.withUnsafeBytes { raw -> Int in
                guard let base = raw.baseAddress else { return -1 }
                return Darwin.write(descriptor, base, raw.count)
            }
            if written > 0 {
                remaining = remaining.dropFirst(written)
                continue
            }
            if written < 0, errno == EINTR { continue }
            return false
        }
        // A half-close rather than a bare `close`: the app's transport sees a
        // clean EOF and drops the connection, instead of finding out when it
        // next tries to read.
        shutdown(descriptor, SHUT_WR)
        return true
    }

    /// A non-blocking connect with a deadline.
    private static func connect(to path: String, until expiry: Date) -> Int32? {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) - 1 else { return nil }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            guard let base = raw.baseAddress else { return }
            base.initializeMemory(as: UInt8.self, repeating: 0, count: raw.count)
            base.copyMemory(from: bytes, byteCount: bytes.count)
        }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)

        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return nil }
        // A SIGPIPE would kill this process with a signal, and a harness reads
        // a signalled hook as a failed one.
        var on: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        let flags = fcntl(descriptor, F_GETFL, 0)
        _ = fcntl(descriptor, F_SETFL, flags | O_NONBLOCK)

        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if result == 0 { return descriptor }
        guard errno == EINPROGRESS else {
            close(descriptor)
            return nil
        }

        let remaining = expiry.timeIntervalSinceNow
        guard remaining > 0 else {
            close(descriptor)
            return nil
        }
        var fd = pollfd(fd: descriptor, events: Int16(POLLOUT), revents: 0)
        guard poll(&fd, 1, Int32(remaining * 1000)) > 0 else {
            close(descriptor)
            return nil
        }
        var error: Int32 = 0
        var size = socklen_t(MemoryLayout<Int32>.size)
        guard getsockopt(descriptor, SOL_SOCKET, SO_ERROR, &error, &size) == 0, error == 0 else {
            close(descriptor)
            return nil
        }
        return descriptor
    }

    // MARK: - The deadline

    /// Ends the process at the deadline, whatever the main path is doing.
    ///
    /// `_exit` rather than `exit`: at this point the main thread may be inside
    /// a `read` on a descriptor the harness owns, and running `atexit` handlers
    /// on top of that is how a "safety net" becomes a crash report.
    private static func startWatchdog(after seconds: TimeInterval, chain: [String]) {
        let thread = Thread {
            Thread.sleep(forTimeInterval: seconds)
            exec(chain)
            _exit(0)
        }
        thread.name = "com.astroqore.auspex.hook.deadline"
        thread.stackSize = 64 * 1024
        thread.start()
    }

    /// Replaces this process with the program `--then` named. Returns only if
    /// there was none, or if it could not be run.
    private static func exec(_ chain: [String]) {
        guard let program = chain.first else { return }
        var pointers: [UnsafeMutablePointer<CChar>?] = chain.map { strdup($0) }
        pointers.append(nil)
        execv(program, &pointers)
        // `execv` returning is a failure — the program moved, or is not
        // executable. The chained command is lost either way; exiting 0 keeps
        // that from also being the harness's problem.
        for pointer in pointers { free(pointer) }
    }
}
