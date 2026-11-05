import AgentSessionKit
import AgentSessionLive
import Foundation
import Testing

@testable import AuspexCore

/// A row's headline, and the one thing it is never allowed to be: a bare id.
@Suite("BoardRow title")
struct BoardRowTitleTests {
    private let threadID = "01a18c9c-92c4-4d1e-8a77-3b6f0c2d9e51"
    private let utc = TimeZone(identifier: "UTC")!

    private func session(
        _ harness: Harness = .codex,
        id: String? = nil,
        title: String? = nil,
        prompt: String? = nil,
        cwd: String? = nil,
        startedAt: Date? = Fixtures.date(3_600 * 14 + 60 * 32)
    ) -> SessionSnapshot {
        let key = SessionKey(harness: harness, sessionID: id ?? threadID)
        let identity = SessionIdentity(
            key: key, sourcePath: "/Users/example/store/\(key.sessionID)", cwd: cwd, title: title
        )
        var snapshot = SessionStateReducer.initialSnapshot(identity: identity)
        snapshot.startedAt = startedAt
        snapshot.lastEventAt = startedAt
        snapshot.brief.firstPrompt = prompt
        return snapshot
    }

    @Test("a title that is the thread's own id is no title")
    func idTitlesAreSkipped() {
        for title in [threadID, String(threadID.prefix(12)), threadID.uppercased(),
                      "0198f7b4-2ce9-7f31-84ad-6b0c7e2915df", "e07c4a91b2d8635fa1"] {
            let item = session(title: title, prompt: "Plan the release notes\nwith care")
            #expect(BoardRowBuilder.title(for: item, project: "widget") == "Plan the release notes",
                    "\(title)")
        }
        // Words, dates and short hex-ish names are names.
        for title in ["Fix the resizer", "2026-11-06", "deadbeef", "cafe-menu"] {
            #expect(BoardRowBuilder.title(for: session(title: title), project: nil) == title)
        }
    }

    @Test("the prompt's first line is the headline, cut at sixty characters")
    func promptHeadline() {
        let long = String(repeating: "word ", count: 30)
        let headline = BoardRowBuilder.title(for: session(prompt: "\n\n  " + long + "\nsecond"), project: nil)
        #expect(headline.count == BoardRowBuilder.headlineLimit)
        #expect(headline.hasSuffix("…"))
        #expect(!headline.contains("\n"))
        #expect(BoardRowBuilder.headline(of: "   \n \t") == nil)
        #expect(BoardRowBuilder.headline(of: nil) == nil)
        #expect(BoardRowBuilder.headline(of: "  short one  ") == "short one")
    }

    @Test("with nothing to go on, a row is its harness and when it started")
    func harnessAndTime() {
        let item = session(.cursor)
        let start = item.startedAt
        // The same day as the frame: the time is enough.
        #expect(BoardRowBuilder.fallbackTitle(
            harness: .cursor, at: start, now: Fixtures.date(3_600 * 20), timeZone: utc
        ) == "Cursor · 14:32")
        // Another day: the date too.
        #expect(BoardRowBuilder.fallbackTitle(
            harness: .cursor, at: start, now: Fixtures.date(86_400 * 3), timeZone: utc
        ) == "Cursor · 01-01 14:32")
        // No frame: always the date, so the title never depends on a clock.
        #expect(BoardRowBuilder.fallbackTitle(harness: .cursor, at: start, now: nil, timeZone: utc)
            == "Cursor · 01-01 14:32")
        #expect(BoardRowBuilder.fallbackTitle(harness: .cursor, at: nil, now: nil) == "Cursor")
    }

    @Test("no rung of the ladder shows the id, on a row, a parent chip or a tree heading")
    func neverTheID() {
        let parent = session(.codex, id: threadID, title: threadID)
        var child = session(.claudeCode, id: "aaaaaaaa-1111-4222-8333-444444444444")
        child.identity.parent = parent.key
        child.identity.parentLink = .subagent(toolUseID: nil)
        let frame = BoardSnapshot(generatedAt: Fixtures.date(3_600 * 15), sessions: [parent, child])

        let rows = BoardRowBuilder(board: frame)
        let parentRow = rows.row(for: parent)
        let childRow = rows.row(for: child)
        // Projectless: neither the section's name nor the id is a headline.
        #expect(parentRow.project == "Projectless")
        #expect(parentRow.title.hasPrefix("Codex · "))
        #expect(!parentRow.title.contains("01a18c9c"))
        #expect(childRow.parent?.title == parentRow.title)
        // The id is still on the row, where it is a fact rather than a name.
        #expect(parentRow.shortID == String(threadID.prefix(8)))

        let tree = BoardGrouping.groups(for: frame, groupBy: .tree)
        #expect(tree.first?.title.contains("01a18c9c") == false)
    }

    @Test("a session in a real project still falls back to the project's name")
    func projectRungStays() {
        let item = session(.claudeCode, cwd: "/Users/example/Code/widget")
        let frame = BoardSnapshot(generatedAt: Fixtures.date(0), sessions: [item])
        #expect(BoardRowBuilder(board: frame).row(for: item).title == "widget")
    }
}
