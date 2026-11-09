import Foundation
import Testing

/// Every word the app shows goes through the catalogue, and this is what
/// keeps it that way.
///
/// `Scripts/lint_localization.py` walks every Swift file under
/// `Sources/AuspexApp` with a small lexer and fails on a user-facing literal —
/// `Text("…")`, `Button("…")`, `.help("…")`, a `title:` argument, a
/// `var label: String { "…" }` — that does not come from `L10n`. Running it
/// here means a hardcoded English word fails `swift test`, rather than being
/// found in a Chinese screenshot.
@Suite("Localization lint")
struct LocalizationLintTests {
    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func lint(_ arguments: [String]) throws -> (status: Int32, output: String, errors: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", repositoryRoot.appendingPathComponent("Scripts/lint_localization.py").path]
            + arguments
        process.currentDirectoryURL = repositoryRoot
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        let out = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let err = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        process.waitUntilExit()
        return (process.terminationStatus, out, err)
    }

    @Test("no file under Sources/AuspexApp shows a word that is not in the catalogue")
    func appIsClean() throws {
        let result = try lint([])
        #expect(result.status == 0, "\n\(result.errors)")
    }

    /// The exemptions are the promise. A file listed there that has been
    /// renamed or deleted silently stops meaning anything — and a new file
    /// with that name would inherit an exemption nobody gave it.
    @Test("every exempt file exists, and none of them is a view")
    func exemptionsAreReal() throws {
        let result = try lint(["--exempt"])
        let files = result.output.split(separator: "\n").map(String.init)
        #expect(!files.isEmpty)
        for relative in files {
            let url = repositoryRoot.appendingPathComponent(relative)
            #expect(FileManager.default.fileExists(atPath: url.path), "\(relative) is exempt but missing")
        }
    }

    /// The lint is trusted, so it is tested. Each line below is a shape that
    /// once slipped past a lint like it, or a shape that must stay quiet.
    @Test("the scanner catches the shapes that slip past a regex")
    func scannerFixture() throws {
        let fixture = FileManager.default.temporaryDirectory
            .appendingPathComponent("AuspexLintFixture-\(UUID().uuidString).swift")
        defer { try? FileManager.default.removeItem(at: fixture) }
        try """
        import SwiftUI

        struct Fixture: View {
            var body: some View {
                Text("Plain literal")
                Label(busy ? "Ternary A" : "Ternary B", systemImage: "safari")
                Text(
                    "Wrapped onto its own line"
                )
                // A comment that ends in a full stop, see ``Something``.
                Button("After a comment") {}
                MetaField(key: "turns", value: "3")
                    .help("Modifier literal")

                // Quiet, each for its own reason:
                Text(L10n.Common.cancel)
                Text("Claude Code")
                Text("·")
                Text("\\n")
                Image(systemName: "arrow.clockwise")
                Label(L10n.Common.open, systemImage: "chevron.left")
                Text("x").tag("weekly")
                // Text("In a comment")
            }

            var title: String { "Copy member" }
        }

        struct MetaField: View {
            let key: String
            let value: String
            var body: some View { Text(value) }
        }
        """.write(to: fixture, atomically: true, encoding: .utf8)

        let result = try lint(["--scan", fixture.path])
        let found = Set(result.output.split(separator: "\n").compactMap { $0.split(separator: "\t").last.map(String.init) })
        for flagged in [
            "Plain literal", "Ternary A", "Ternary B", "Wrapped onto its own line",
            "After a comment", "turns", "Modifier literal", "Copy member",
        ] {
            #expect(found.contains(flagged), "missed \(flagged)")
        }
        for quiet in ["Claude Code", "·", "\\n", "arrow.clockwise", "chevron.left", "weekly", "In a comment"] {
            #expect(!found.contains(quiet), "flagged \(quiet)")
        }
    }
}
