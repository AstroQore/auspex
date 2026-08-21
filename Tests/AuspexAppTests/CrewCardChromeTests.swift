import AgentSessionKit
import AgentSessionLive
import AuspexCore
import Foundation
import Testing

@testable import AuspexApp

/// What a crew card says over and above the avatar.
///
/// The crew's state language is the face, and a face is a mood rather than a
/// demand. Two things on a board are demands — a session waiting on a person,
/// and a turn that finished while nobody was looking — and both have to be
/// findable from across a room without decoding an expression. So they are card
/// chrome, and this is the table that decides which card gets one.
///
/// Derived from the snapshot rather than read out of the avatar's driver, so a
/// renderer with no roster gets the same answer as the live wall — which is why
/// it can be tested at all without a window.
@Suite("Crew card chrome")
@MainActor
struct CrewCardChromeTests {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func session(
        _ state: SessionState,
        turns: Int = 3,
        lastEventAgo: TimeInterval = 2,
        endedAgo: TimeInterval? = nil
    ) -> SessionSnapshot {
        let key = SessionKey(harness: .claudeCode, sessionID: "s-1")
        var snapshot = SessionSnapshot(
            identity: SessionIdentity(
                key: key,
                sourcePath: "/Users/example/.claude/projects/demo/s-1.jsonl",
                parent: nil,
                cwd: "/Users/example/repo",
                gitRoot: "/Users/example/repo"
            ),
            state: state,
            isAlive: !state.isEnded
        )
        snapshot.turnCount = turns
        snapshot.lastEventAt = now.addingTimeInterval(-lastEventAgo)
        snapshot.endedAt = endedAgo.map { now.addingTimeInterval(-$0) }
        return snapshot
    }

    @Test("a session waiting on you gets the ring and the mark")
    func blocked() {
        let chrome = CrewCardChrome.of(
            session(.waitingPermission(tool: "bash")),
            isUnseenDone: false
        )
        #expect(chrome == .blocked)
        #expect(chrome.ringColour != nil)
        #expect(chrome.badge?.symbol == "exclamationmark")
    }

    @Test("a finished turn nobody has read gets a tick")
    func done() {
        let chrome = CrewCardChrome.of(session(.idle), isUnseenDone: true)
        #expect(chrome == .done)
        #expect(chrome.badge?.symbol == "checkmark")
        // The tick is the board's judgement, not the avatar's clock. The
        // celebration lasts twenty seconds because a wall of permanent confetti
        // is not good news; the tick stays until somebody has looked.
        #expect(CrewCardChrome.of(session(.idle), isUnseenDone: false) == CrewCardChrome.none)
    }

    @Test("a working session is never chrome, however recently it spoke")
    func workingIsQuiet() {
        for state: SessionState in [
            .thinking,
            .toolCalling(name: "shell"),
            .writingFile(path: "/Users/example/a.swift"),
            .delegating(children: 2)
        ] {
            #expect(CrewCardChrome.of(session(state, lastEventAgo: 0.5), isUnseenDone: false)
                == CrewCardChrome.none, "\(state)")
        }
    }

    /// Waiting on you outranks a finished turn: the one that will not resolve
    /// itself must not be masked by the one that already has.
    @Test("needs-you outranks a tick")
    func blockedOutranksDone() {
        #expect(
            CrewCardChrome.of(session(.waitingPermission(tool: nil)), isUnseenDone: true)
                == .blocked
        )
    }

    @Test("ended outranks everything and wears no ring")
    func endedIsQuiet() {
        let chrome = CrewCardChrome.of(
            session(.ended(reason: .exited), lastEventAgo: 1, endedAgo: 5),
            isUnseenDone: true
        )
        #expect(chrome == .over)
        #expect(chrome.ringColour == nil)
        #expect(chrome.badge == nil)
    }

    // MARK: The fold

    @Test("a session folds off the wall a minute after it ends")
    func foldWindow() {
        #expect(!CrewView.hasFolded(session(.ended(reason: .exited), endedAgo: 10), at: now))
        #expect(!CrewView.hasFolded(session(.ended(reason: .exited), endedAgo: 59), at: now))
        #expect(CrewView.hasFolded(session(.ended(reason: .exited), endedAgo: 61), at: now))
        // A session that is still running never folds, whatever its dates say.
        #expect(!CrewView.hasFolded(session(.thinking, endedAgo: 900), at: now))
        // And one that ended before Auspex ever saw it has no date to wait on.
        #expect(CrewView.hasFolded(session(.ended(reason: .unknown), endedAgo: nil), at: now))
    }
}
