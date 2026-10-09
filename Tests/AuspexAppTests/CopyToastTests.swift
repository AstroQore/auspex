import Foundation
import Testing

@testable import AuspexApp

/// The one-line receipt a copy leaves behind.
///
/// It exists because copying is the only action in the window with no visible
/// result, so the two things worth asserting are that it says something and
/// that it stops saying it — a toast that stayed up would be a permanent line
/// of chrome, which is worse than no toast at all.
@Suite("Copy toast", .serialized)
@MainActor
struct CopyToastTests {
    init() { pinEnglishInterface() }

    @Test("a message goes up, and takes itself down")
    func aMessageExpires() async throws {
        let toast = CopyToast.shared
        toast.clear()
        // A short duration: the dismissal is a real sleep on the main actor,
        // and a CI runner has been seen to starve that actor for ten seconds
        // at a time. What is under test is that the toast comes down after
        // its duration, not what the duration is.
        toast.show("Copied the session ID", for: .milliseconds(30))
        #expect(toast.message == "Copied the session ID")

        let deadline = ContinuousClock.now + .seconds(20)
        while toast.message != nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(toast.message == nil)
    }

    @Test("a second copy replaces the first rather than queueing behind it")
    func theLatestWins() async throws {
        let toast = CopyToast.shared
        toast.clear()
        toast.show("Copied the pid")
        toast.show("Copied the working directory")
        #expect(toast.message == "Copied the working directory")
        toast.clear()
        #expect(toast.message == nil)
    }
}
