import AgentSessionKit
import AgentSessionLive
import Foundation
import Testing

@testable import AuspexApp

/// The table every surface reads a harness's identity out of.
///
/// These are cheap assertions about a hand-maintained list, which is exactly
/// the kind of thing that rots: a harness lands in the kit, an adapter is
/// written for it, and the row on the Harnesses page is forgotten for a
/// release. The suite exists so that forgetting fails a build instead of
/// shipping a board that quietly cannot see one of the agents on the machine.
@Suite("Harness catalog")
struct HarnessCatalogTests {
    /// Every harness the app claims to watch, in the order it shows them.
    private var featured: [Harness] { AuspexAdapters.featured }

    @Test("eight harnesses are featured, grouped by vendor, Grok Bot after Grok Build")
    func featuredOrder() {
        #expect(featured == [
            .claudeCode, .claudeCowork, .codex, .chatgptWork, .cursor,
            .grokBuild, .grokBot, .antigravity
        ])
        #expect(featured.count == 8)
        #expect(Set(featured).count == 8)
        let build = try? #require(featured.firstIndex(of: .grokBuild))
        let bot = try? #require(featured.firstIndex(of: .grokBot))
        #expect(build.flatMap { b in bot.map { b + 1 == $0 } } == true)
        // Gemini CLI is the deliberate omission: deprecated, and no adapter
        // reads its store.
        #expect(!featured.contains(.geminiCLI))
    }

    @Test("every featured harness has an adapter that actually reads its store")
    func everyFeaturedHarnessIsWatched() {
        for harness in featured {
            #expect(
                AuspexAdapters.installed.contains(harness),
                "\(harness.rawValue) is featured but no adapter handles it"
            )
        }
        // And the reverse: an adapter Auspex runs whose harness nobody lists
        // is a store being read for a row that does not exist.
        for harness in AuspexAdapters.installed where harness != .chatgptWork {
            #expect(
                featured.contains(harness),
                "\(harness.rawValue) is tailed but is not on the Harnesses page"
            )
        }
    }

    @Test("Grok Bot is tailed from the store the page names")
    func grokBotWatchRoot() {
        let roots = AuspexAdapters.watchRoots(home: "/Users/example")[.grokBot] ?? []
        #expect(roots.map(\.path) == [
            "/Users/example/Library/Application Support/Grok Bot/sand-client-persistence"
        ])
        // The page's description and the adapter's real root have to be the
        // same directory, or the row is documentation of a fiction.
        let described = AuspexAdapters.storeDescription(for: .grokBot)
            .replacingOccurrences(of: "~", with: "/Users/example")
        #expect(roots.map(\.path) == [described])
    }

    @Test("names are the vendors' own, in full, never abbreviated")
    func namesAreNotAbbreviated() {
        for harness in Harness.allCases {
            let name = harness.displayName
            #expect(!name.isEmpty)
            #expect(name == name.trimmingCharacters(in: .whitespaces))
            // An abbreviation is what this rules out: no initials, no
            // truncation, no punctuation standing in for the rest of a word.
            #expect(!name.contains("."), "\(name) reads as an abbreviation")
            #expect(!name.contains("…"))
            #expect(name.count >= 5, "\(name) is too short to be a full name")
        }
        // The two xAI harnesses are the pair a reader is most likely to
        // conflate, and the only thing telling them apart in a list is the
        // name being written out.
        #expect(Harness.grokBuild.displayName == "Grok Build")
        #expect(Harness.grokBot.displayName == "Grok Bot")
        #expect(Harness.claudeCode.displayName == "Claude Code")
        #expect(Harness.claudeCowork.displayName == "Claude Cowork")
        #expect(Harness.chatgptWork.displayName == "ChatGPT Work")
    }

    @Test("every featured harness has an accent of its own")
    func accentsAreDistinct() {
        let accents = featured.map(\.style.accent)
        #expect(Set(accents).count == featured.count)
        #expect(Harness.grokBot.style.accent == AuspexPalette.harnessGrokBot)
        // Same vendor, neighbouring hues, and still two colours: the pair has
        // to read as one company and as two harnesses.
        #expect(Harness.grokBot.style.accent != Harness.grokBuild.style.accent)
    }

    @MainActor
    @Test("the two xAI harnesses share xAI's mark")
    func marksAreSharedByVendor() {
        #expect(HarnessLogo.assetName(for: .grokBot) == "ProviderIcon-grok")
        #expect(HarnessLogo.assetName(for: .grokBot) == HarnessLogo.assetName(for: .grokBuild))
        // Which is why the mark alone cannot identify a row, and the accent
        // and the full name have to.
        #expect(Harness.grokBot.style.symbolName != Harness.grokBuild.style.symbolName)
    }
}
