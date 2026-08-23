import Foundation
import Testing

@testable import AuspexCore

@Suite("Delivery snapshot")
struct DeliverySnapshotTests {
    private final class FakeRunner: GitCommandRunning, @unchecked Sendable {
        typealias Answer = @Sendable ([String]) -> GitCommandResult

        private let lock = NSLock()
        private let answer: Answer
        private(set) var calls: [[String]] = []

        init(answer: @escaping Answer) { self.answer = answer }

        func run(
            in directory: URL,
            arguments: [String],
            timeout: TimeInterval,
            maxOutputBytes: Int
        ) -> GitCommandResult {
            lock.lock()
            calls.append(arguments)
            lock.unlock()
            return answer(arguments)
        }
    }

    @Test("unsafe and missing paths are refused before Git starts")
    func unsafePaths() {
        let runner = FakeRunner { _ in .init(stdout: "should not run") }
        let reader = GitDeliveryReader(runner: runner)

        let relative = reader.snapshot(atPath: "../checkout")
        let pseudo = reader.snapshot(atPath: "auspex:pseudo:codex")
        let missing = reader.snapshot(atPath: "/tmp/auspex-path-that-does-not-exist")

        #expect(relative.workingTree == .unknown)
        #expect(pseudo.workingTree == .unknown)
        #expect(missing.workingTree == .unknown)
        #expect(runner.calls.isEmpty)
    }

    @Test("a timed out repository probe stays unknown")
    func timeout() throws {
        let directory = try GitFixtures.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let runner = FakeRunner { _ in
            .init(stdout: "", exitCode: -1, timedOut: true)
        }

        let snapshot = GitDeliveryReader(runner: runner).snapshot(atPath: directory.path)

        #expect(snapshot.workingTree == .unknown)
        #expect(snapshot.diagnostic?.contains("timed out") == true)
        #expect(runner.calls.count == 1)
    }

    @Test("changed files are counted while the displayed list stays capped")
    func changedFilesCap() throws {
        let directory = try GitFixtures.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let status = (0..<12).map { "?? file-\($0).txt\0" }.joined()
        let runner = FakeRunner { arguments in
            switch arguments.first {
            case "rev-parse":
                if arguments.contains("--show-toplevel") {
                    return .init(stdout: directory.path + "\n")
                }
                return .init(stdout: "abc123\n")
            case "status": return .init(stdout: status)
            case "symbolic-ref": return .init(stdout: "feat/delivery\n")
            case "diff": return .init(stdout: "12 files changed, 12 insertions(+)\n")
            case "log": return .init(stdout: "abc123\tAdd delivery\t1700000000\n")
            case "rev-list": return .init(stdout: "2\t3\n")
            default: return .init(stdout: "", exitCode: 1)
            }
        }
        let limits = GitDeliveryReader.Limits(changedFiles: 3)

        let snapshot = GitDeliveryReader(runner: runner, limits: limits)
            .snapshot(atPath: directory.path)

        #expect(snapshot.workingTree == .dirty)
        #expect(snapshot.changedFileCount == 12)
        #expect(snapshot.changedFiles.count == 3)
        #expect(snapshot.changedFilesTruncated)
        #expect(snapshot.branch == "feat/delivery")
        #expect(snapshot.ahead == 3)
        #expect(snapshot.behind == 2)
        #expect(snapshot.lastCommit?.shortHash == "abc123")
        #expect(runner.calls.allSatisfy { !$0.contains("fetch") && !$0.contains("pull") })
    }

    @Test("the process runner retains no more than its byte ceiling")
    func processOutputCap() throws {
        let directory = try GitFixtures.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let runner = ProcessGitCommandRunner()
        #expect(runner.run(
            in: directory, arguments: ["init", "--quiet"], timeout: 2, maxOutputBytes: 1_024
        ).exitCode == 0)
        for index in 0..<100 {
            try Data("x".utf8).write(to: directory.appendingPathComponent("file-\(index).txt"))
        }

        let result = runner.run(
            in: directory,
            arguments: ["status", "--porcelain=v1", "--untracked-files=normal"],
            timeout: 2,
            maxOutputBytes: 64
        )

        #expect(result.exitCode == 0)
        #expect(result.outputTruncated)
        #expect(result.stdout.utf8.count + result.stderr.utf8.count <= 64)
    }

    @Test("a real checkout moves from clean to dirty without fetching")
    func cleanAndDirty() throws {
        let directory = try GitFixtures.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try git(["init", "--quiet"], in: directory)
        try git(["config", "user.name", "Example"], in: directory)
        try git(["config", "user.email", "example@example.invalid"], in: directory)
        try Data("one\n".utf8).write(to: directory.appendingPathComponent("tracked.txt"))
        try git(["add", "tracked.txt"], in: directory)
        try git(["commit", "--quiet", "-m", "Initial"], in: directory)

        let reader = GitDeliveryReader()
        let clean = reader.snapshot(atPath: directory.path)
        #expect(clean.workingTree == .clean)
        #expect(clean.changedFileCount == 0)
        #expect(clean.lastCommit?.subject == "Initial")

        try Data("two\n".utf8).write(to: directory.appendingPathComponent("tracked.txt"))
        try Data("new\n".utf8).write(to: directory.appendingPathComponent("new.txt"))
        let dirty = reader.snapshot(atPath: directory.path)
        #expect(dirty.workingTree == .dirty)
        #expect(dirty.changedFileCount == 2)
        #expect(Set(dirty.changedFiles.map(\.path)) == ["tracked.txt", "new.txt"])
    }

    private func git(_ arguments: [String], in directory: URL) throws {
        let result = ProcessGitCommandRunner().run(
            in: directory, arguments: arguments, timeout: 3, maxOutputBytes: 16 * 1_024
        )
        guard result.exitCode == 0 else {
            throw GitTestError.failed(result.stderr)
        }
    }
}

private enum GitTestError: Error { case failed(String) }
