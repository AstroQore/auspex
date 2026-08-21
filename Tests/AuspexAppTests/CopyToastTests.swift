import Foundation
import Testing

@testable import AuspexApp

/// The one-line receipt a copy leaves behind.
///
/// It exists because copying is the only action in the window with no visible
/// result, so the two things worth asserting are that it says something and
/// that it stops saying it — a toast that stayed up would be a permanent line
/// of chrome, which is worse than no toast at all.
@Suite("Copy toast")
@MainActor
struct CopyToastTests {
    @Test("a message goes up, and takes itself down")
    func aMessageExpires() async throws {
        let toast = CopyToast.shared
        toast.clear()
        toast.show("Copied the session ID")
        #expect(toast.message == "Copied the session ID")

        // Its own duration plus a margin: the dismissal is a real sleep on the
        // main actor's clock, which is what it is in the window too.
        try await Task.sleep(for: CopyToast.duration + .milliseconds(400))
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
