import AgentSessionKit
import AgentSessionLive
import Foundation
import Testing

@testable import AuspexCore

@Suite("Session variant chip")
struct SessionVariantLabelTests {
    private static let rootID = "0198f4c2-77bd-7a10-b3e9-5c2d84f10ab6"
    private static let reviewID = "0198f6d0-11ac-7e54-8b26-3ad70f9c1e83"

    private func identity(
        _ harness: Harness,
        _ sessionID: String,
        variant: String? = nil
    ) -> SessionIdentity {
        SessionIdentity(
            key: SessionKey(harness: harness, sessionID: sessionID),
            sourcePath: "/Users/example/store/\(sessionID)",
            variant: variant,
            cwd: "/Users/example/Code/auspex"
        )
    }

    private func review(root: String = SessionVariantLabelTests.rootID) -> SessionIdentity {
        identity(.codex, Self.reviewID, variant: "auto-review:\(root)")
    }

    private func codexRoot() -> SessionIdentity {
        identity(.codex, Self.rootID, variant: "codex_cli_rs")
    }

    @Test("the chip says what the session is, and stays silent about internals")
    func variantLabels() {
        #expect(SessionVariantLabel.label(for: review()) == SessionVariantLabel.autoReview)
        // Even with the root nowhere on the board: it is still a review, and a
        // card that only said so when the link resolved would go quiet exactly
        // when the reader has least context.
        #expect(
            SessionVariantLabel.label(for: review(root: "0198cccc-0000-7000-8000-000000000000"))
                == "auto review"
        )
        #expect(SessionVariantLabel.label(for: identity(.antigravity, "c1", variant: "cli")) == "cli")
        #expect(SessionVariantLabel.label(for: identity(.antigravity, "c2", variant: "ide")) == "ide")
        // Codex's originator, Grok Bot's own name for itself, and no variant
        // at all are all things a card should not repeat back to a person.
        #expect(SessionVariantLabel.label(for: codexRoot()) == nil)
        #expect(SessionVariantLabel.label(for: identity(.grokBot, "b1", variant: "bot")) == nil)
        #expect(SessionVariantLabel.label(for: identity(.cursor, "c3")) == nil)
        // A bare string cannot answer the Codex question — it does not carry
        // the harness that makes the prefix mean anything.
        #expect(SessionVariantLabel.label(forVariant: "auto-review:\(Self.rootID)") == nil)
    }

    @Test("a row carries the chip its identity earns")
    func boardRowCarriesTheLabel() {
        let board = BoardSnapshot(
            generatedAt: Fixtures.epoch,
            sessions: [
                SessionStateReducer.initialSnapshot(identity: codexRoot()),
                SessionStateReducer.initialSnapshot(identity: review()),
            ]
        )
        let rows = BoardRowBuilder(board: board).rows(for: board.sessions)
        let byKey = Dictionary(uniqueKeysWithValues: rows.map { ($0.key, $0) })
        #expect(byKey[review().key]?.variantLabel == "auto review")
        #expect(byKey[codexRoot().key]?.variantLabel == nil)
    }
}
