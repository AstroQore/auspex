import AgentSessionKit
import Foundation

/// The four conditions of `AGENTS.md` § 6 that are about *writing*, in one
/// place: back up first, write atomically, re-read and re-parse, restore from
/// the backup when the result is not what it should be.
///
/// Registering an MCP server and registering a hook are different edits to
/// different files, but they make the same promise about how the edit is done —
/// and a promise implemented twice is a promise kept once. Whether the edit
/// itself is allowed (a person clicked; it goes inside a fence Auspex owns) is
/// the caller's half, because only the caller knows what its fence is.
struct ConfigFileWriter: Sendable {
    /// Where backups go. Always under `~/.auspex/`: a `.bak` beside the
    /// original would itself be a write into a harness's directory.
    let paths: AuspexPaths
    /// Whose file this is, for the backup's name.
    let harness: Harness

    /// What one edit did.
    struct Outcome: Sendable {
        var didChange: Bool
        var backupPath: String?
        var failure: String?
    }

    /// Reads the file, applies `transform`, and writes the result — unless the
    /// transform changed nothing, in which case the file is not opened for
    /// writing at all.
    ///
    /// - Parameter verify: what the file has to still be afterwards, given its
    ///   bytes. Return a sentence to reject and restore; `nil` to accept.
    func edit(
        path: String,
        verify: (Data) -> String? = { _ in nil },
        transform: (String) throws -> String
    ) -> Outcome {
        let url = URL(fileURLWithPath: path)
        let existing = try? String(contentsOf: url, encoding: .utf8)

        do {
            let updated = try transform(existing ?? "")
            guard updated != (existing ?? "") else { return Outcome(didChange: false) }
            let backup = existing.flatMap { try? writeBackup($0, for: url) }

            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try Data(updated.utf8).write(to: url, options: .atomic)

            // Verified by reading it back, not by trusting the string we wrote:
            // a file another process rewrote underneath us is the case this
            // catches, and it is the case that would otherwise corrupt one.
            if let problem = check(url: url, verify: verify) {
                restore(backup, to: url)
                return Outcome(
                    didChange: false,
                    backupPath: backup,
                    failure: "\(problem) The file was restored from the backup."
                )
            }
            return Outcome(didChange: true, backupPath: backup)
        } catch {
            return Outcome(didChange: false, failure: "\(error)")
        }
    }

    /// Deletes a file Auspex created, after backing it up.
    ///
    /// Only for a file that is entirely Auspex's — Grok reads a directory of
    /// hook files, one per tool, so Auspex's is `auspex.json` and removing it is
    /// exact by construction. Nothing here would be safe on a file with
    /// somebody else's bytes in it.
    func remove(path: String) -> Outcome {
        let url = URL(fileURLWithPath: path)
        guard let existing = try? String(contentsOf: url, encoding: .utf8) else {
            return Outcome(didChange: false)
        }
        let backup = try? writeBackup(existing, for: url)
        do {
            try FileManager.default.removeItem(at: url)
            return Outcome(didChange: true, backupPath: backup)
        } catch {
            return Outcome(didChange: false, backupPath: backup, failure: "\(error)")
        }
    }

    private func check(url: URL, verify: (Data) -> String?) -> String? {
        guard let data = FileManager.default.contents(atPath: url.path) else {
            return "The file could not be read back after writing."
        }
        return verify(data)
    }

    private func restore(_ backup: String?, to url: URL) {
        guard let backup,
              let restored = try? String(contentsOf: URL(fileURLWithPath: backup), encoding: .utf8)
        else { return }
        try? Data(restored.utf8).write(to: url, options: .atomic)
    }

    private func writeBackup(_ contents: String, for url: URL) throws -> String {
        let directory = try paths.ensureDirectory(
            paths.baseDirectory.appendingPathComponent("backups", isDirectory: true)
        )
        let stamp = Self.stampFormatter.string(from: Date())
        let name = "\(harness.rawValue)-\(url.lastPathComponent)-\(stamp).bak"
        let destination = directory.appendingPathComponent(name)
        try Data(contents.utf8).write(to: destination, options: .atomic)
        return destination.path
    }

    private static let stampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter
    }()

    /// The check every JSON config has to pass after an edit.
    static func isStillJSON(_ data: Data) -> String? {
        (try? JSONSerialization.jsonObject(with: data)) == nil
            ? "The file is no longer valid JSON after the edit."
            : nil
    }
}
