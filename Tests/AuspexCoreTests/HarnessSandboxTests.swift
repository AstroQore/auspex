import Foundation
import Testing

@testable import AuspexCore

/// The directories a harness makes per conversation, which look like projects
/// and are not.
@Suite("HarnessSandbox")
struct HarnessSandboxTests {
    private let home = "/Users/example"

    // MARK: - Matching

    @Test("a dated thread directory is a thread, named after its folder")
    func datedThread() {
        let thread = HarnessSandbox.thread(
            forPath: "/Users/example/Documents/Codex/2026-08-21/zhe", home: home
        )
        #expect(thread?.directory == "/Users/example/Documents/Codex/2026-08-21/zhe")
        #expect(thread?.name == "zhe")
        #expect(thread?.note == HarnessSandbox.sandboxNote)
    }

    @Test("the older flat shape is the same thread, minus the date")
    func flatThread() {
        // Builds before the date bucket put the day and the slug in one
        // component. The day is not what a card should show.
        let thread = HarnessSandbox.thread(
            forPath: "/Users/example/Documents/Codex/2026-04-21-new-chat-2", home: home
        )
        #expect(thread?.directory == "/Users/example/Documents/Codex/2026-04-21-new-chat-2")
        #expect(thread?.name == "new-chat-2")
    }

    @Test("a session that moved deeper still belongs to its own thread")
    func deeperInsideAThread() {
        let thread = HarnessSandbox.thread(
            forPath: "/Users/example/Documents/Codex/2026-08-21/zhe/src/app", home: home
        )
        // The thread is the conversation's folder, not wherever it cd-ed to.
        #expect(thread?.directory == "/Users/example/Documents/Codex/2026-08-21/zhe")
        #expect(thread?.name == "zhe")
    }

    @Test("the day's bucket itself is scratch, and says so with the only name it has")
    func bucketItself() {
        let thread = HarnessSandbox.thread(
            forPath: "/Users/example/Documents/Codex/2026-08-21", home: home
        )
        #expect(thread?.directory == "/Users/example/Documents/Codex/2026-08-21")
        #expect(thread?.name == "2026-08-21")
    }

    @Test("the same tree under another name is matched too")
    func siblingRoot() {
        #expect(
            HarnessSandbox.thread(
                forPath: "/Users/example/Documents/ChatGPT/2026-08-21/rota", home: home
            )?.name == "rota")
    }

    // MARK: - What it must not swallow

    @Test("a real repository kept inside the root is still a project")
    func undatedChildIsNotAThread() {
        // The date bucket is the whole safety margin: someone who keeps their
        // notes repository at ~/Documents/Codex/notes gets a project.
        for path in [
            "/Users/example/Documents/Codex/notes",
            "/Users/example/Documents/Codex/notes/src",
            "/Users/example/Documents/Codex",
            "/Users/example/Documents",
        ] {
            #expect(HarnessSandbox.thread(forPath: path, home: home) == nil, "\(path)")
        }
    }

    @Test("an ordinary working directory is untouched")
    func ordinaryDirectories() {
        for path in [
            "/Users/example/Code/auspex",
            "/Users/example/Documents/ops-runbook",
            "/Users/example/Documents/Claude/Artifacts",
            "/tmp/Documents/Codex/2026-08-21/zhe",
        ] {
            #expect(HarnessSandbox.thread(forPath: path, home: home) == nil, "\(path)")
        }
    }

    @Test("another account's identical tree is not this one's scratch")
    func anotherHome() {
        // The rule is positional. A path under somebody else's home says
        // nothing about where *this* harness put its threads.
        #expect(
            HarnessSandbox.thread(
                forPath: "/Users/someone-else/Documents/Codex/2026-08-21/zhe", home: home
            ) == nil)
        #expect(!HarnessSandbox.isThread(path: "/Users/example", home: home))
        #expect(!HarnessSandbox.isThread(path: "", home: home))
    }

    // MARK: - The date prefix

    @Test("a bucket name is recognised by its shape, not by whether the day exists")
    func datePrefixes() {
        #expect(HarnessSandbox.datePrefix(of: "2026-08-21") == "2026-08-21")
        #expect(HarnessSandbox.datePrefix(of: "2026-08-21-new-chat") == "2026-08-21")
        // Not a calendar lookup on purpose: the question is whether the app
        // named this directory, and the app names them from a clock that has
        // been wrong before.
        #expect(HarnessSandbox.datePrefix(of: "2026-13-45") == "2026-13-45")
        for name in ["2026-08", "20260821", "notes", "2026/08/21", "v2026-08-21"] {
            #expect(HarnessSandbox.datePrefix(of: name) == nil, "\(name)")
        }
    }
}
