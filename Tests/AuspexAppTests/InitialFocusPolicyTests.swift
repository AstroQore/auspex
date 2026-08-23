import Foundation
import Testing

@testable import AuspexApp

@Suite("Presentation focus policy")
@MainActor
struct InitialFocusPolicyTests {
    @Test("the presentation clears one responder and never steals later keyboard focus")
    func oneShotClear() {
        let presentation = NSObject()
        var policy = InitialFocusState()
        var clearCount = 0
        policy.attach(to: presentation)

        #expect(policy.consumeClear(for: presentation) {
            clearCount += 1
            return true
        })

        // This stands in for Tab entering the key-view loop. The policy has
        // consumed its one shot, so a later SwiftUI update cannot erase real
        // keyboard navigation or its normal focus feedback.
        #expect(!policy.consumeClear(for: presentation) {
            clearCount += 1
            return true
        })
        #expect(clearCount == 1)

        // Re-presenting the same reusable Settings or popover window is a new
        // cycle and gets exactly one new clear.
        policy.attach(to: presentation)
        #expect(policy.consumeClear(for: presentation) {
            clearCount += 1
            return true
        })
        #expect(clearCount == 2)
    }

    @Test("every window, sheet, and popover opts into the one-shot policy")
    func allPresentationBoundariesAreCovered() throws {
        let sources = try appSources()
        let presentationCount = sources.values.reduce(into: 0) { count, source in
            count += source.numberOfOccurrences(of: ".sheet(")
            count += source.numberOfOccurrences(of: ".popover(")
        }
        let app = try #require(sources["AuspexApp.swift"])
        let sceneCount = app.numberOfOccurrences(of: "WindowGroup(")
            + app.numberOfOccurrences(of: "Settings {")
            + app.numberOfOccurrences(of: "MenuBarExtra {")
        let policyCount = sources.values.reduce(0) {
            $0 + $1.numberOfOccurrences(of: ".auspexNoInitialFocus()")
        }

        let expectedByFile = [
            "AuspexApp.swift": 3,
            "RootView.swift": 3,
            "ProjectsPageView.swift": 2,
            "SessionControlModel.swift": 1,
            "ContextUsagePopover.swift": 1,
            "SessionTraceView.swift": 1,
        ]
        for (file, expected) in expectedByFile {
            #expect(
                try #require(sources[file]).numberOfOccurrences(
                    of: ".auspexNoInitialFocus()"
                ) == expected,
                "\(file) presentation coverage changed"
            )
        }

        #expect(presentationCount == 8)
        #expect(sceneCount == 3)
        #expect(policyCount == presentationCount + sceneCount)
    }

    @Test("no presentation can create an implicit default action")
    func noImplicitDefaultAction() throws {
        let sources = try appSources()
        let combined = sources.values.joined(separator: "\n")

        #expect(!combined.contains(".keyboardShortcut(.defaultAction)"))
        #expect(!combined.contains(".alert("))
        #expect(!combined.contains(".confirmationDialog("))
    }

    @Test("forms presented from hand-drawn columns restore native Tab feedback")
    func inheritedFocusEffectsAreRestored() throws {
        let sources = try appSources()
        let expectedByFile = [
            "RootView.swift": 1, // in-board Settings
            "BoardHeader.swift": 2,
            "CommandPalette.swift": 1,
            "SessionWindowMenu.swift": 1,
            "ProjectsPageView.swift": 4, // two sheets, rename, folder picker
            "TaskDetailView.swift": 2,
            "TasksPageView.swift": 2,
            "ContextUsagePopover.swift": 2, // opener and presented content
            "SessionTraceView.swift": 4, // three links and Family popover
            "TrajectoryInspector.swift": 1,
            "TrajectoryView.swift": 3,
        ]
        for (file, expected) in expectedByFile {
            #expect(
                try #require(sources[file]).numberOfOccurrences(
                    of: ".auspexSystemControlFocus()"
                ) == expected,
                "\(file) native focus restoration changed"
            )
        }
    }

    @Test("the policy clears only the responder and leaves the key-view loop intact")
    func implementationLeavesTraversalIntact() throws {
        let sources = try appSources()
        let source = try #require(sources["InitialFocusPolicy.swift"])
        #expect(source.contains("makeFirstResponder(nil)"))
        #expect(!source.contains("initialFirstResponder"))
        #expect(!source.contains("nextKeyView"))
        #expect(!source.contains("didBecomeKeyNotification"))
    }

    @Test("kill confirmation keeps explicit cancel and destructive semantics")
    func killConfirmationSemantics() throws {
        let sources = try appSources()
        let source = try #require(sources["SessionControlModel.swift"])

        #expect(source.contains("Button(\"Cancel\", role: .cancel"))
        #expect(source.contains(".keyboardShortcut(.cancelAction)"))
        #expect(source.contains("Button(prompt.confirmTitle, role: .destructive"))
        #expect(source.contains("control.confirm(prompt)"))
        #expect(source.contains("control.dismiss()"))
    }

    private func appSources() throws -> [String: String] {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let root = repository.appendingPathComponent("Sources/AuspexApp", isDirectory: true)
        let files = try FileManager.default.subpathsOfDirectory(atPath: root.path)
            .filter { $0.hasSuffix(".swift") }

        return try Dictionary(uniqueKeysWithValues: files.map { relative in
            let url = root.appendingPathComponent(relative)
            return (url.lastPathComponent, try String(contentsOf: url, encoding: .utf8))
        })
    }
}

private extension String {
    func numberOfOccurrences(of needle: String) -> Int {
        components(separatedBy: needle).count - 1
    }
}
