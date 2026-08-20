import AgentSessionKit
import Foundation

/// Registers Auspex's MCP server with a harness, and writes the short protocol
/// note that tells an agent to use it.
///
/// ## The one place Auspex writes outside `~/.auspex/`
///
/// The house rule (`AGENTS.md` § 6) is that other tools' directories are
/// read-only to Auspex, and it exists because the observation layer must never
/// have a reason to write. This is the deliberate exception, and it is
/// hedged accordingly:
///
/// - **Only when a person clicks.** Nothing here runs on launch, on a timer,
///   or while a status page is being looked at.
/// - **Only inside a fence.** Every write is a `>>> auspex >>>` block or one
///   named JSON member. Bytes somebody else authored are never rewritten —
///   see ``ConfigTextEditors``.
/// - **Backed up first**, into `~/.auspex/backups/`, not next to the original:
///   a stray `.bak` in `~/.codex/` would itself be a write into a harness's
///   directory.
/// - **Verified after.** The file is re-read and re-parsed; a file that no
///   longer parses is restored from the backup and the install reported as
///   failed.
/// - **Exactly reversible.** Uninstall removes the fence or the member and
///   nothing else.
public struct HarnessInstaller: Sendable {
    /// Where the harness configs are looked for.
    public let homeDirectory: URL
    /// Where backups go. Always under `~/.auspex/`.
    public let paths: AuspexPaths
    /// The Auspex binary an MCP client should spawn.
    public let command: String
    /// The flag that puts it into bridge mode.
    public let arguments: [String]

    public init(
        homeDirectory: URL = AuspexPaths.realHomeDirectory(),
        paths: AuspexPaths = .default,
        command: String,
        arguments: [String] = ["--mcp-stdio"]
    ) {
        self.homeDirectory = homeDirectory
        self.paths = paths
        self.command = command
        self.arguments = arguments
    }

    /// What can be installed for one harness.
    public enum Piece: String, Sendable, CaseIterable, Hashable {
        /// The `auspex` entry in the harness's MCP config.
        case mcpServer
        /// The paragraph in the harness's always-loaded instructions telling an
        /// agent when to call `auspex.notify` and how to claim a task.
        case protocolNote

        public var title: String {
            switch self {
            case .mcpServer: "Register the Auspex MCP server"
            case .protocolNote: "Install the task-protocol note"
            }
        }

        public var explanation: String {
            switch self {
            case .mcpServer:
                "Adds one `auspex` server entry, so this harness's agents can "
                    + "call notify, plans and tasks."
            case .protocolNote:
                "Appends a fenced paragraph telling agents to call auspex.notify "
                    + "when they need you, and to claim the task id in their brief."
            }
        }
    }

    /// Whether a piece is in place for a harness.
    public enum State: Sendable, Equatable {
        /// There is nothing to write for this harness — see
        /// ``HarnessInstaller/reasonUnavailable(_:_:)``.
        case unavailable(String)
        /// The file can be written and nothing of ours is in it.
        case absent
        /// Ours is there, and points at this build.
        case installed
        /// Ours is there and names a different Auspex binary — the usual cause
        /// is a source build registering itself and then an installed
        /// `Auspex.app` being run, or the other way round.
        case installedElsewhere(String)
        /// The file exists and could not be read or parsed. Refused rather than
        /// overwritten.
        case unreadable(String)

        public var isInstalled: Bool {
            switch self {
            case .installed, .installedElsewhere: true
            case .unavailable, .absent, .unreadable: false
            }
        }

        public var canInstall: Bool {
            switch self {
            case .absent, .installedElsewhere: true
            case .installed, .unavailable, .unreadable: false
            }
        }
    }

    /// What one row of the installer offers, and where it would write.
    public struct Offer: Sendable, Equatable, Identifiable {
        public let harness: Harness
        public let piece: Piece
        /// The exact file. Shown to the person before they agree to anything:
        /// "adds one entry" means nothing without "to this file".
        public let path: String?
        public let state: State

        public var id: String { "\(harness.rawValue).\(piece.rawValue)" }

        public init(harness: Harness, piece: Piece, path: String?, state: State) {
            self.harness = harness
            self.piece = piece
            self.path = path
            self.state = state
        }

        /// The path with the home directory abbreviated, for a label.
        public var displayPath: String? {
            guard let path else { return nil }
            let home = AuspexPaths.realHomeDirectory().path
            return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
        }
    }

    /// What happened.
    public struct Report: Sendable, Equatable {
        public let harness: Harness
        public let piece: Piece
        public let didChange: Bool
        public let path: String?
        /// Where the previous contents went, when there were any.
        public let backupPath: String?
        /// `nil` on success.
        public let failure: String?

        public var succeeded: Bool { failure == nil }
    }

    // MARK: - What can be offered

    /// Every row the install surface shows, in board order.
    public func offers(for harnesses: [Harness]) -> [Offer] {
        harnesses.flatMap { harness in
            Piece.allCases.map { offer(harness, $0) }
        }
    }

    /// One row.
    public func offer(_ harness: Harness, _ piece: Piece) -> Offer {
        switch piece {
        case .mcpServer:
            guard let location = HarnessMCPConfigStore.location(for: harness, home: homeDirectory)
            else {
                return Offer(
                    harness: harness, piece: piece, path: nil,
                    state: .unavailable(Self.reasonUnavailable(harness, piece))
                )
            }
            return Offer(
                harness: harness, piece: piece, path: location.path,
                state: mcpState(location)
            )
        case .protocolNote:
            guard let path = Self.protocolNotePath(for: harness, home: homeDirectory) else {
                return Offer(
                    harness: harness, piece: piece, path: nil,
                    state: .unavailable(Self.reasonUnavailable(harness, piece))
                )
            }
            return Offer(
                harness: harness, piece: piece, path: path,
                state: noteState(path, harness: harness)
            )
        }
    }

    /// Why a harness has no row of this kind.
    public static func reasonUnavailable(_ harness: Harness, _ piece: Piece) -> String {
        if let note = HarnessMCPConfigStore.externallyManagedNote(for: harness) {
            return "MCP is \(note)."
        }
        switch piece {
        case .mcpServer:
            return "No local MCP config file to write."
        case .protocolNote:
            return "This harness has no always-loaded instruction file Auspex knows about."
        }
    }

    /// Where a harness keeps the instructions it loads into every session.
    ///
    /// Only the two Auspex can name with confidence. Cursor's rules live in
    /// per-project `.cursor/rules`, Grok's in a directory whose format has
    /// moved twice, and writing into a project's own tree would be a different
    /// and much larger promise than this makes.
    public static func protocolNotePath(for harness: Harness, home: URL) -> String? {
        switch harness {
        case .claudeCode:
            return home.appendingPathComponent(".claude/CLAUDE.md").path
        case .codex, .chatgptWork:
            return home.appendingPathComponent(".codex/AGENTS.md").path
        default:
            return nil
        }
    }

    // MARK: - Install

    /// Writes one piece. Idempotent: installing what is already installed
    /// reports `didChange == false` and touches nothing.
    public func install(_ harness: Harness, _ piece: Piece) -> Report {
        let offer = offer(harness, piece)
        switch offer.state {
        case let .unavailable(reason), let .unreadable(reason):
            // A file Auspex cannot read is a file Auspex must not write: the
            // only safe edit is one that starts from what is already there.
            return Report(
                harness: harness, piece: piece, didChange: false,
                path: offer.path, backupPath: nil, failure: reason
            )
        case .absent, .installed, .installedElsewhere:
            return edit(offer) { text, location in
                try self.installed(into: text, at: location, harness: harness, piece: piece)
            }
        }
    }

    /// Removes one piece, restoring the file to what it was without it.
    public func uninstall(_ harness: Harness, _ piece: Piece) -> Report {
        let offer = offer(harness, piece)
        guard offer.path != nil else {
            return Report(
                harness: harness, piece: piece, didChange: false,
                path: nil, backupPath: nil,
                failure: Self.reasonUnavailable(harness, piece)
            )
        }
        return edit(offer) { text, location in
            try self.removed(from: text, at: location, harness: harness, piece: piece)
        }
    }

    // MARK: - The edit itself

    private func edit(
        _ offer: Offer,
        _ transform: (String, MCPConfigLocation?) throws -> String
    ) -> Report {
        guard let path = offer.path else {
            return Report(
                harness: offer.harness, piece: offer.piece, didChange: false,
                path: nil, backupPath: nil, failure: "Nowhere to write."
            )
        }
        let location = offer.piece == .mcpServer
            ? HarnessMCPConfigStore.location(for: offer.harness, home: homeDirectory)
            : nil
        let url = URL(fileURLWithPath: path)
        let existing = (try? String(contentsOf: url, encoding: .utf8))

        do {
            let updated = try transform(existing ?? "", location)
            guard updated != (existing ?? "") else {
                return Report(
                    harness: offer.harness, piece: offer.piece, didChange: false,
                    path: path, backupPath: nil, failure: nil
                )
            }
            // The backup comes before the write and goes under `~/.auspex/`, not
            // beside the original: a stray `.bak` in `~/.codex/` would itself be
            // a write into a harness's directory.
            let backup = existing.flatMap { try? writeBackup($0, for: url, harness: offer.harness) }

            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data(updated.utf8).write(to: url, options: .atomic)

            // Verified by reading it back, not by trusting the string we wrote:
            // a file another process rewrote underneath us is the case this
            // catches, and it is the case that would otherwise corrupt one.
            if let problem = verify(url: url, location: location) {
                if let backup, let restored = try? String(contentsOf: URL(fileURLWithPath: backup), encoding: .utf8) {
                    try? Data(restored.utf8).write(to: url, options: .atomic)
                }
                return Report(
                    harness: offer.harness, piece: offer.piece, didChange: false,
                    path: path, backupPath: backup,
                    failure: "\(problem) The file was restored from the backup."
                )
            }
            return Report(
                harness: offer.harness, piece: offer.piece, didChange: true,
                path: path, backupPath: backup, failure: nil
            )
        } catch {
            return Report(
                harness: offer.harness, piece: offer.piece, didChange: false,
                path: path, backupPath: nil, failure: "\(error)"
            )
        }
    }

    /// The file still has to be what it claims to be after the edit.
    private func verify(url: URL, location: MCPConfigLocation?) -> String? {
        guard let data = FileManager.default.contents(atPath: url.path) else {
            return "The file could not be read back after writing."
        }
        switch location?.format {
        case .json:
            guard (try? JSONSerialization.jsonObject(with: data)) != nil else {
                return "The file is no longer valid JSON after the edit."
            }
            guard let names = HarnessMCPConfigStore.jsonServerNames(
                in: data, includesScopes: location?.isScoped ?? false
            ) else {
                return "The MCP servers could not be read back after the edit."
            }
            _ = names
            return nil
        case .toml, .none:
            // Nothing to parse: the TOML scanner is a scanner, and a Markdown
            // file has no grammar to break. The fence's own integrity is the
            // check, and `ConfigFence` writes both markers or neither.
            return nil
        }
    }

    private func writeBackup(_ contents: String, for url: URL, harness: Harness) throws -> String {
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

    // MARK: - The four transforms

    private func installed(
        into text: String,
        at location: MCPConfigLocation?,
        harness: Harness,
        piece: Piece
    ) throws -> String {
        switch piece {
        case .protocolNote:
            return Self.noteFence.applying(Self.protocolNote(for: harness), to: text)
        case .mcpServer:
            guard let location else { throw InstallError.noLocation }
            switch location.format {
            case .toml:
                return Self.tomlFence.applying(tomlBody, to: text)
            case .json:
                return try installedJSON(into: text)
            }
        }
    }

    private func removed(
        from text: String,
        at location: MCPConfigLocation?,
        harness: Harness,
        piece: Piece
    ) throws -> String {
        switch piece {
        case .protocolNote:
            return Self.noteFence.removing(from: text)
        case .mcpServer:
            guard let location else { throw InstallError.noLocation }
            switch location.format {
            case .toml:
                return Self.tomlFence.removing(from: text)
            case .json:
                return try removedJSON(from: text)
            }
        }
    }

    /// JSON has no comments, so the fence cannot be a marker in the text — the
    /// *member name* is the fence. `mcpServers.auspex` is what Auspex owns;
    /// everything else in the file is somebody else's.
    private func installedJSON(into text: String) throws -> String {
        var document = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "{\n}\n" : text
        guard let root = JSONTextEditor.topLevelObjectStart(in: document) else {
            throw InstallError.notAnObject
        }
        let members = JSONTextEditor.members(in: document, objectAt: root)
        guard let members else { throw InstallError.unparsable }

        if members.contains(where: { $0.name == "mcpServers" }) {
            // Find the servers object and put the entry inside it.
            guard let serversStart = objectStart(ofMemberNamed: "mcpServers", in: document, objectAt: root),
                  let updated = JSONTextEditor.upsert(
                      member: HarnessMCPConfigStore.auspexServerName,
                      value: serverEntryJSON,
                      in: document,
                      objectAt: serversStart
                  )
            else { throw InstallError.unparsable }
            return updated
        }

        let servers = "{\n  \"\(HarnessMCPConfigStore.auspexServerName)\": "
            + serverEntryJSON.replacingOccurrences(of: "\n", with: "\n  ")
            + "\n}"
        guard let updated = JSONTextEditor.upsert(
            member: "mcpServers", value: servers, in: document, objectAt: root
        ) else { throw InstallError.unparsable }
        document = updated
        return document
    }

    private func removedJSON(from text: String) throws -> String {
        guard let root = JSONTextEditor.topLevelObjectStart(in: text) else { return text }
        guard let serversStart = objectStart(ofMemberNamed: "mcpServers", in: text, objectAt: root)
        else { return text }
        guard let updated = JSONTextEditor.remove(
            member: HarnessMCPConfigStore.auspexServerName, in: text, objectAt: serversStart
        ) else { throw InstallError.unparsable }
        return updated
    }

    /// The `{` of a named member's object value.
    private func objectStart(
        ofMemberNamed name: String,
        in text: String,
        objectAt root: String.Index
    ) -> String.Index? {
        guard let members = JSONTextEditor.members(in: text, objectAt: root),
              let member = members.first(where: { $0.name == name })
        else { return nil }
        var cursor = member.range.lowerBound
        var sawColon = false
        while cursor < member.range.upperBound {
            let character = text[cursor]
            if character == ":" , !sawColon {
                sawColon = true
            } else if sawColon, !character.isWhitespace {
                return character == "{" ? cursor : nil
            }
            cursor = text.index(after: cursor)
        }
        return nil
    }

    // MARK: - What gets written

    /// The fence in a TOML config.
    public static let tomlFence = ConfigFence(comment: .hash)
    /// The fence in a Markdown instruction file.
    public static let noteFence = ConfigFence(comment: .html)

    /// The `[mcp_servers.auspex]` table, without its fence.
    var tomlBody: String {
        let args = arguments
            .map { "\"\(JSONTextEditor.escaped($0))\"" }
            .joined(separator: ", ")
        return """
            [mcp_servers.\(HarnessMCPConfigStore.auspexServerName)]
            command = "\(JSONTextEditor.escaped(command))"
            args = [\(args)]
            """
    }

    /// The `auspex` server entry, without its member name.
    var serverEntryJSON: String {
        let args = arguments
            .map { "\"\(JSONTextEditor.escaped($0))\"" }
            .joined(separator: ", ")
        return """
            {
              "command": "\(JSONTextEditor.escaped(command))",
              "args": [\(args)]
            }
            """
    }

    /// Whether the config already names this exact binary.
    private func mcpState(_ location: MCPConfigLocation) -> State {
        guard let text = try? String(contentsOfFile: location.path, encoding: .utf8) else {
            return FileManager.default.fileExists(atPath: location.path)
                ? .unreadable("The file exists but could not be read as UTF-8.")
                : .absent
        }
        switch location.format {
        case .json:
            guard let data = text.data(using: .utf8) else { return .unreadable("Not UTF-8.") }
            if data.isEmpty { return .absent }
            guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return .unreadable("The file is not a JSON object.")
            }
            guard let servers = root["mcpServers"] as? [String: Any],
                  let entry = servers[HarnessMCPConfigStore.auspexServerName] as? [String: Any]
            else { return .absent }
            let registered = entry["command"] as? String
            return registered == command ? .installed : .installedElsewhere(registered ?? "an unnamed command")
        case .toml:
            guard let body = Self.tomlFence.body(in: text) else {
                // Somebody may have written the table by hand, outside the
                // fence. That is theirs; say so rather than adding a second one.
                let names = HarnessMCPConfigStore.tomlTableNames(in: text)
                return names.contains(HarnessMCPConfigStore.auspexServerName)
                    ? .installedElsewhere("an entry Auspex did not write")
                    : .absent
            }
            return body.contains("\"\(JSONTextEditor.escaped(command))\"")
                ? .installed
                : .installedElsewhere("a different Auspex binary")
        }
    }

    /// Whether the fenced note is there, and whether it is this build's
    /// wording.
    ///
    /// A note from an older Auspex reads as `installedElsewhere` rather than as
    /// installed, so re-installing rewrites it. It is our fence: replacing what
    /// is inside it is the whole point of having drawn one.
    private func noteState(_ path: String, harness: Harness) -> State {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
            return FileManager.default.fileExists(atPath: path)
                ? .unreadable("The file exists but could not be read as UTF-8.")
                : .absent
        }
        guard let body = Self.noteFence.body(in: text) else { return .absent }
        let current = Self.protocolNote(for: harness)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return body == current ? .installed : .installedElsewhere("a note from an older Auspex")
    }

    enum InstallError: Error, CustomStringConvertible {
        case noLocation
        case notAnObject
        case unparsable

        var description: String {
            switch self {
            case .noLocation: "This harness has no MCP config file."
            case .notAnObject: "The config file is not a JSON object."
            case .unparsable: "The config file could not be read closely enough to edit safely."
            }
        }
    }
}

// MARK: - The note itself

extension HarnessInstaller {
    /// The paragraph that goes into a harness's always-loaded instructions.
    ///
    /// Short on purpose. It competes for context with everything else in the
    /// file, and a protocol nobody reads is worse than no protocol — so it says
    /// the one thing that matters (call for the person instead of going quiet),
    /// the one habit that makes the board useful (claim the task id you were
    /// given), and stops.
    ///
    /// It never tells an agent to do anything Auspex cannot do: no shell
    /// commands, no paths, no "run this". Everything is a tool call the server
    /// itself advertises.
    public static func protocolNote(for harness: Harness) -> String {
        """
        ## Auspex

        Auspex watches every agent session on this Mac and exposes an MCP server
        called `auspex`. Two habits make it useful:

        1. **Call `auspex.notify` instead of going quiet.** The moment you need
           the person — a question (`needs_input`), something to check
           (`needs_review`), something you cannot get past (`blocked`), or work
           you have finished (`done`) — call it with one sentence saying what you
           need. It posts a macOS notification and moves your session into the
           right bucket on their board. Nothing else can tell "waiting for a
           human" apart from "thinking hard".
        2. **Keep the task board honest.** If your brief names a task id, call
           `tasks.claim(task_id, role, scope)` before you start. If it does not,
           read `plans.list` and `tasks.list` first and claim the task that
           matches; file one with `tasks.create` only if none does. Call
           `tasks.update` when you get blocked and `tasks.complete` with one line
           of what you finished.

        If you are the one handing work out, register the decomposition with
        `plans.create` and a task per worker, and put each task id in the brief
        you send. You never need to know your own session id — Auspex works it
        out from the process on the other end of the connection.
        """
    }
}
