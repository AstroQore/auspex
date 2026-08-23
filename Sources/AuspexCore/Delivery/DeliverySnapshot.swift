import Foundation

#if canImport(Darwin)
import Darwin
#endif

/// The state of a checkout at one explicitly requested instant.
///
/// Delivery is deliberately independent from both activity and attention. A
/// session can be thinking while its checkout is clean, or waiting for a person
/// while it has a finished commit; neither fact should overwrite the other.
/// This value is also deliberately *not live*: callers create it only for a
/// task detail or a user action, never from the frame or discovery loops.
public struct DeliverySnapshot: Sendable, Equatable {
    public enum WorkingTreeState: String, Sendable, Equatable, Codable {
        case clean
        case dirty
        case unknown
    }

    public enum Provenance: String, Sendable, Equatable, Codable {
        /// Read from the checkout with the system Git executable. No fetch or
        /// other network operation was performed.
        case observedLocalGit = "observed_local_git"
    }

    public struct ChangedFile: Sendable, Equatable, Codable {
        /// Git's two-column porcelain status, such as `M `, ` M`, or `??`.
        public let status: String
        public let path: String

        public init(status: String, path: String) {
            self.status = status
            self.path = path
        }
    }

    public struct Commit: Sendable, Equatable, Codable {
        public let shortHash: String
        public let subject: String
        public let authoredAt: Date?

        public init(shortHash: String, subject: String, authoredAt: Date?) {
            self.shortHash = shortHash
            self.subject = subject
            self.authoredAt = authoredAt
        }
    }

    public let repositoryPath: String?
    public let branch: String?
    public let workingTree: WorkingTreeState
    /// The files retained for display. See ``changedFileCount`` for the total.
    public let changedFiles: [ChangedFile]
    public let changedFileCount: Int?
    public let changedFilesTruncated: Bool
    public let diffstat: String?
    public let lastCommit: Commit?
    /// Relative to the already-recorded local upstream ref. Reading this never
    /// contacts a remote; `nil` means no upstream was recorded or Git could not
    /// answer cheaply.
    public let ahead: Int?
    public let behind: Int?
    public let checkedAt: Date
    public let provenance: Provenance
    /// Why a field — most importantly the working tree — is unknown.
    public let diagnostic: String?

    public init(
        repositoryPath: String?,
        branch: String?,
        workingTree: WorkingTreeState,
        changedFiles: [ChangedFile] = [],
        changedFileCount: Int? = nil,
        changedFilesTruncated: Bool = false,
        diffstat: String? = nil,
        lastCommit: Commit? = nil,
        ahead: Int? = nil,
        behind: Int? = nil,
        checkedAt: Date = Date(),
        provenance: Provenance = .observedLocalGit,
        diagnostic: String? = nil
    ) {
        self.repositoryPath = repositoryPath
        self.branch = branch
        self.workingTree = workingTree
        self.changedFiles = changedFiles
        self.changedFileCount = changedFileCount
        self.changedFilesTruncated = changedFilesTruncated
        self.diffstat = diffstat
        self.lastCommit = lastCommit
        self.ahead = ahead
        self.behind = behind
        self.checkedAt = checkedAt
        self.provenance = provenance
        self.diagnostic = diagnostic
    }

    public static func unknown(at date: Date = Date(), reason: String) -> Self {
        DeliverySnapshot(
            repositoryPath: nil,
            branch: nil,
            workingTree: .unknown,
            checkedAt: date,
            diagnostic: reason
        )
    }
}

/// The bounded result of one local Git query.
public struct GitCommandResult: Sendable, Equatable {
    public let stdout: String
    public let stderr: String
    public let exitCode: Int32
    public let timedOut: Bool
    public let outputTruncated: Bool

    public init(
        stdout: String,
        stderr: String = "",
        exitCode: Int32 = 0,
        timedOut: Bool = false,
        outputTruncated: Bool = false
    ) {
        self.stdout = stdout
        self.stderr = stderr
        self.exitCode = exitCode
        self.timedOut = timedOut
        self.outputTruncated = outputTruncated
    }
}

/// The seam that lets the reader's policy be tested without spawning a
/// process. Production uses ``ProcessGitCommandRunner`` below.
public protocol GitCommandRunning: Sendable {
    func run(
        in directory: URL,
        arguments: [String],
        timeout: TimeInterval,
        maxOutputBytes: Int
    ) -> GitCommandResult
}

/// Runs `/usr/bin/git` without a shell, drains both pipes concurrently, and
/// caps the bytes retained across stdout and stderr.
///
/// The executable is fixed and the reader supplies every argument. No caller
/// text becomes a command name or shell fragment, no credential-shaped value
/// is put in argv, and `GIT_OPTIONAL_LOCKS=0` keeps these observations from
/// refreshing another process's index.
public struct ProcessGitCommandRunner: GitCommandRunning {
    public init() {}

    public func run(
        in directory: URL,
        arguments: [String],
        timeout: TimeInterval,
        maxOutputBytes: Int
    ) -> GitCommandResult {
        let process = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        let output = LimitedProcessOutput(limit: max(1, maxOutputBytes))
        let finished = DispatchSemaphore(value: 0)

        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = [
            // A checkout may configure a filesystem-monitor hook. Observation
            // must not execute repository-adjacent helpers, so status falls
            // back to Git's own local scan.
            "-c", "core.fsmonitor=false",
            "-c", "core.untrackedCache=false",
            "-C", directory.path
        ] + arguments
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.standardInput = FileHandle.nullDevice
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_OPTIONAL_LOCKS"] = "0"
        environment["GIT_PAGER"] = "cat"
        environment["GIT_TERMINAL_PROMPT"] = "0"
        environment["LC_ALL"] = "C"
        process.environment = environment

        let stdout = stdoutPipe.fileHandleForReading
        let stderr = stderrPipe.fileHandleForReading
        stdout.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty { output.append(data, channel: .stdout) }
        }
        stderr.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty { output.append(data, channel: .stderr) }
        }
        process.terminationHandler = { _ in finished.signal() }

        do {
            try process.run()
        } catch {
            stdout.readabilityHandler = nil
            stderr.readabilityHandler = nil
            return GitCommandResult(
                stdout: "",
                stderr: String(describing: error),
                exitCode: -1
            )
        }

        let deadline = DispatchTime.now() + .milliseconds(Int(max(0.01, timeout) * 1_000))
        var timedOut = finished.wait(timeout: deadline) == .timedOut
        if timedOut, process.isRunning {
            process.terminate()
            if finished.wait(timeout: .now() + 0.2) == .timedOut, process.isRunning {
                #if canImport(Darwin)
                Darwin.kill(process.processIdentifier, SIGKILL)
                #endif
                _ = finished.wait(timeout: .now() + 0.2)
            }
        } else {
            timedOut = false
        }

        // The process has closed its write ends. Disable callbacks before the
        // final drain so no byte can be appended twice.
        stdout.readabilityHandler = nil
        stderr.readabilityHandler = nil
        output.append(stdout.readDataToEndOfFile(), channel: .stdout)
        output.append(stderr.readDataToEndOfFile(), channel: .stderr)
        let captured = output.snapshot()
        return GitCommandResult(
            stdout: captured.stdout,
            stderr: captured.stderr,
            exitCode: timedOut || process.isRunning ? -1 : process.terminationStatus,
            timedOut: timedOut,
            outputTruncated: captured.truncated
        )
    }
}

private final class LimitedProcessOutput: @unchecked Sendable {
    enum Channel { case stdout, stderr }

    private let lock = NSLock()
    private let limit: Int
    private var retained = 0
    private var stdout = Data()
    private var stderr = Data()
    private var truncated = false

    init(limit: Int) { self.limit = limit }

    func append(_ data: Data, channel: Channel) {
        guard !data.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        let remaining = max(0, limit - retained)
        guard remaining > 0 else {
            truncated = true
            return
        }
        let kept = data.prefix(remaining)
        switch channel {
        case .stdout: stdout.append(kept)
        case .stderr: stderr.append(kept)
        }
        retained += kept.count
        if kept.count < data.count { truncated = true }
    }

    func snapshot() -> (stdout: String, stderr: String, truncated: Bool) {
        lock.lock()
        defer { lock.unlock() }
        return (
            String(decoding: stdout, as: UTF8.self),
            String(decoding: stderr, as: UTF8.self),
            truncated
        )
    }
}

/// Reads a small, bounded delivery snapshot from a checkout.
///
/// It performs no fetch, pull, push, checkout, reset, clean, commit, or index
/// refresh. Every query is local and every subprocess has its own deadline and
/// output ceiling. A partial or failed observation stays `unknown`; it never
/// turns an agent's assertion into an observed fact.
public struct GitDeliveryReader: Sendable {
    public struct Limits: Sendable, Equatable {
        public var timeout: TimeInterval
        public var outputBytes: Int
        public var changedFiles: Int
        public var pathBytes: Int

        public init(
            timeout: TimeInterval = 1.5,
            outputBytes: Int = 256 * 1_024,
            changedFiles: Int = 24,
            pathBytes: Int = 4_096
        ) {
            self.timeout = timeout
            self.outputBytes = outputBytes
            self.changedFiles = changedFiles
            self.pathBytes = pathBytes
        }
    }

    public let runner: any GitCommandRunning
    public let limits: Limits

    public init(
        runner: any GitCommandRunning = ProcessGitCommandRunner(),
        limits: Limits = Limits()
    ) {
        self.runner = runner
        self.limits = limits
    }

    public func snapshot(atPath path: String, checkedAt: Date = Date()) -> DeliverySnapshot {
        let directory: URL
        do {
            directory = try validatedDirectory(path)
        } catch {
            return .unknown(at: checkedAt, reason: String(describing: error))
        }

        let rootResult = command(["rev-parse", "--show-toplevel"], in: directory)
        guard !rootResult.timedOut else {
            return .unknown(at: checkedAt, reason: "Local Git inspection timed out.")
        }
        guard rootResult.exitCode == 0, !rootResult.outputTruncated,
              let rootLine = firstLine(rootResult.stdout), !rootLine.isEmpty else {
            return .unknown(at: checkedAt, reason: "The recorded directory is not a readable Git checkout.")
        }

        let root: URL
        do {
            root = try validatedDirectory(rootLine)
        } catch {
            return .unknown(at: checkedAt, reason: "Git returned an unsafe repository path.")
        }

        let statusResult = command(
            ["status", "--porcelain=v1", "-z", "--untracked-files=normal"], in: root
        )
        let statusKnown = statusResult.exitCode == 0 && !statusResult.timedOut
        let parsed = statusKnown
            ? parseStatus(statusResult.stdout, outputWasTruncated: statusResult.outputTruncated)
            : nil

        let branch = readBranch(in: root)
        let diffstat = successfulText(
            command(
                ["diff", "--no-ext-diff", "--no-textconv", "--shortstat", "HEAD", "--", "."],
                in: root
            ),
            maximumCharacters: 1_000
        )
        let commit = readCommit(in: root)
        let upstream = readUpstreamDelta(in: root)

        return DeliverySnapshot(
            repositoryPath: root.path,
            branch: branch,
            workingTree: parsed.map { $0.count == 0 ? .clean : .dirty } ?? .unknown,
            changedFiles: parsed?.files ?? [],
            changedFileCount: parsed?.count,
            changedFilesTruncated: parsed?.truncated ?? statusResult.outputTruncated,
            diffstat: diffstat,
            lastCommit: commit,
            ahead: upstream?.ahead,
            behind: upstream?.behind,
            checkedAt: checkedAt,
            diagnostic: statusKnown ? nil : (statusResult.timedOut
                ? "Local Git status timed out."
                : "Local Git could not read the working tree.")
        )
    }

    private func command(_ arguments: [String], in directory: URL) -> GitCommandResult {
        runner.run(
            in: directory,
            arguments: arguments,
            timeout: limits.timeout,
            maxOutputBytes: limits.outputBytes
        )
    }

    private func validatedDirectory(_ path: String) throws -> URL {
        guard !path.isEmpty,
              !path.contains("\0"),
              path.utf8.count <= limits.pathBytes,
              NSString(string: path).isAbsolutePath else {
            throw DeliveryPathError.unsafe
        }
        let url = URL(fileURLWithPath: path, isDirectory: true)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw DeliveryPathError.missing
        }
        return url
    }

    private func readBranch(in root: URL) -> String? {
        let symbolic = command(["symbolic-ref", "--quiet", "--short", "HEAD"], in: root)
        if let name = successfulText(symbolic, maximumCharacters: 512) { return name }
        let detached = command(["rev-parse", "--short", "HEAD"], in: root)
        return successfulText(detached, maximumCharacters: 128).map { "detached @ \($0)" }
    }

    private func readCommit(in root: URL) -> DeliverySnapshot.Commit? {
        let result = command(["log", "-1", "--format=%h%x09%s%x09%ct"], in: root)
        guard let line = successfulText(result, maximumCharacters: 4_096) else { return nil }
        let parts = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 3, !parts[0].isEmpty else { return nil }
        let timestamp = Double(String(parts[2])).map(Date.init(timeIntervalSince1970:))
        return DeliverySnapshot.Commit(
            shortHash: String(parts[0]), subject: String(parts[1]), authoredAt: timestamp
        )
    }

    private func readUpstreamDelta(in root: URL) -> (ahead: Int, behind: Int)? {
        let result = command(
            ["rev-list", "--left-right", "--count", "@{upstream}...HEAD"], in: root
        )
        guard let line = successfulText(result, maximumCharacters: 128) else { return nil }
        let values = line.split(whereSeparator: \.isWhitespace).compactMap { Int($0) }
        guard values.count == 2 else { return nil }
        // `upstream...HEAD`: left is upstream-only (behind), right is
        // HEAD-only (ahead).
        return (ahead: values[1], behind: values[0])
    }

    private func successfulText(
        _ result: GitCommandResult,
        maximumCharacters: Int
    ) -> String? {
        guard result.exitCode == 0, !result.timedOut, !result.outputTruncated else { return nil }
        let text = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        return String(text.prefix(maximumCharacters))
    }

    private func firstLine(_ text: String) -> String? {
        text.split(whereSeparator: \.isNewline).first.map(String.init)
    }

    private func parseStatus(
        _ text: String,
        outputWasTruncated: Bool
    ) -> (files: [DeliverySnapshot.ChangedFile], count: Int, truncated: Bool) {
        let records = text.split(separator: "\0", omittingEmptySubsequences: true)
        var files: [DeliverySnapshot.ChangedFile] = []
        var count = 0
        for record in records {
            guard record.utf8.count >= 3 else { continue }
            let status = String(record.prefix(2))
            let separator = record[record.index(record.startIndex, offsetBy: 2)]
            // A rename's second NUL field has no status prefix and is skipped.
            guard separator == " " else { continue }
            let path = String(record.dropFirst(3))
            guard !path.isEmpty else { continue }
            count += 1
            if files.count < limits.changedFiles {
                files.append(.init(status: status, path: String(path.prefix(1_024))))
            }
        }
        return (files, count, outputWasTruncated || count > files.count)
    }
}

private enum DeliveryPathError: Error, CustomStringConvertible {
    case unsafe
    case missing

    var description: String {
        switch self {
        case .unsafe: "The recorded checkout path is not a safe absolute directory."
        case .missing: "The recorded checkout directory no longer exists."
        }
    }
}
