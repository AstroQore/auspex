import Foundation
import Testing

@testable import AuspexApp

@Suite("Packaged application resources")
struct AppResourceBundleTests {
    @Test("the conventional Contents/Resources child is preferred when present")
    func packagedCandidate() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("auspex-resource-layout-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let expected = root.appendingPathComponent(AppResourceBundle.bundleName, isDirectory: true)
        try FileManager.default.createDirectory(at: expected, withIntermediateDirectories: true)

        #expect(AppResourceBundle.packagedBundleURL(in: root) == expected)
    }

    @Test("a missing packaged child does not masquerade as a bundle")
    func missingCandidate() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("auspex-resource-layout-missing-\(UUID().uuidString)")
        #expect(AppResourceBundle.packagedBundleURL(in: root) == nil)
        #expect(AppResourceBundle.packagedBundleURL(in: nil) == nil)
    }

    @Test("a packaged app never falls through to SwiftPM's fatal accessor")
    func packagedDetection() {
        #expect(AppResourceBundle.isPackagedApplication(URL(fileURLWithPath: "/tmp/Auspex.app")))
        #expect(!AppResourceBundle.isPackagedApplication(URL(fileURLWithPath: "/tmp/Auspex")))
        #expect(!AppResourceBundle.isPackagedApplication(URL(fileURLWithPath: "/tmp/tests.xctest")))
    }

    @Test("the development/test resolver can open every critical asset")
    func criticalResourcesLoad() throws {
        let urls = try AppResourceBundle.verifyCriticalResources()
        #expect(urls.count == 11)
        #expect(urls.allSatisfy { FileManager.default.isReadableFile(atPath: $0.path) })
    }
}
