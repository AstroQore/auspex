import Foundation
import Testing

@testable import AuspexApp

@MainActor
@Suite("Surface visibility")
struct SurfaceVisibilityTests {
    private final class Probe {}

    @Test("the board is observed while any surface is visible, and says so once per change")
    func observedWhileAnySurfaceIsVisible() async {
        let visibility = SurfaceVisibility()
        let window = Probe()
        let panel = Probe()

        #expect(!visibility.isObserved)
        visibility.report(ObjectIdentifier(window), isVisible: true)
        #expect(visibility.isObserved)
        // A second surface coming and going does not flip it while the first
        // is still up.
        visibility.report(ObjectIdentifier(panel), isVisible: true)
        visibility.report(ObjectIdentifier(panel), isVisible: false)
        #expect(visibility.isObserved)
        visibility.report(ObjectIdentifier(window), isVisible: false)
        #expect(!visibility.isObserved)
        // Repeating what is already known is not a change.
        visibility.report(ObjectIdentifier(window), isVisible: false)

        // The stream keeps only the newest value, which is the one a slow
        // consumer needs.
        var iterator = visibility.changes.makeAsyncIterator()
        #expect(await iterator.next() == false)
        visibility.report(ObjectIdentifier(panel), isVisible: true)
        #expect(await iterator.next() == true)
    }
}
