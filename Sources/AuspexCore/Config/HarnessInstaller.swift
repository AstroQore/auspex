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
/// - **Only inside something Auspex can prove it owns.** A `>>> auspex >>>`
///   block, one named JSON member, owned hook entries, or the exclusive
///   `auspex-coordination` directory with its versioned content hash. Bytes
///   somebody else authored are never rewritten — see ``ConfigTextEditors``
///   and ``CoordinationSkillInstaller``.
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
    /// The checked-in coordination playbook this build can install.
    ///
    /// Optional so Core tests and headless callers do not have to know where
    /// the App target's SwiftPM resource bundle lives. A missing package makes
    /// the row unavailable; it never falls back to bytes from a build path.
    public let coordinationSkill: CoordinationSkillPackage?

    public init(
        homeDirectory: URL = AuspexPaths.realHomeDirectory(),
        paths: AuspexPaths = .default,
        command: String,
        arguments: [String] = ["--mcp-stdio"],
        coordinationSkill: CoordinationSkillPackage? = nil
    ) {
        self.homeDirectory = homeDirectory
        self.paths = paths
        self.command = command
        self.arguments = arguments
        self.coordinationSkill = coordinationSkill
    }

    /// What can be installed for one harness.
    public enum Piece: String, Sendable, CaseIterable, Hashable {
        /// The `auspex` entry in the harness's MCP config.
        case mcpServer
        /// The on-demand Supervisor/Worker/Reviewer playbook. This is guidance;
        /// the MCP server remains the source of task truth and enforcement.
        case coordinationSkill
        /// The paragraph in the harness's always-loaded instructions telling an
        /// agent when to call `auspex.notify` and how to claim a task.
        case protocolNote
        /// The entries in the harness's hook table that run
        /// `Auspex --hook <harness>` when something happens.
        case hooks

        public var title: String {
            switch self {
            case .mcpServer: "Register the Auspex MCP server"
            case .coordinationSkill: "Install the Auspex coordination skill"
            case .protocolNote: "Install the task-protocol note"
            case .hooks: "Install harness hooks"
            }
        }

        public var explanation: String {
            switch self {
            case .mcpServer:
                "Adds one `auspex` server entry, so this harness's agents can "
                    + "call notify, plans and tasks."
            case .coordinationSkill:
                "Adds a versioned, on-demand Supervisor/Worker/Reviewer playbook. "
                    + "It guides MCP use; the server remains the source of truth."
            case .protocolNote:
                "Appends the always-loaded invariants and routes coordinated work "
                    + "to the richer auspex-coordination skill."
            case .hooks:
                "Lets the harness tell Auspex the moment it needs permission, "
                    + "starts, delegates or stops — the states no transcript records."
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
        case .coordinationSkill:
            guard let coordinationSkill,
                  let path = Self.coordinationSkillPath(for: harness, home: homeDirectory)
            else {
                return Offer(
                    harness: harness, piece: piece, path: nil,
                    state: .unavailable(Self.reasonUnavailable(harness, piece))
                )
            }
            let destination = URL(fileURLWithPath: path, isDirectory: true)
            let installer = CoordinationSkillInstaller(
                harness: harness,
                destination: destination,
                package: coordinationSkill,
                paths: paths
            )
            return Offer(
                harness: harness,
                piece: piece,
                path: path,
                state: installer.status()
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
        case .hooks:
            guard let hooks = hookInstaller(for: harness) else {
                return Offer(
                    harness: harness, piece: piece, path: nil,
                    state: .unavailable(Self.reasonUnavailable(harness, piece))
                )
            }
            return Offer(
                harness: harness, piece: piece, path: hooks.path, state: hooks.status()
            )
        }
    }

    /// The hook installer for a harness, built with this installer's binary and
    /// home. `nil` for the harnesses with no hook mechanism.
    public func hookInstaller(for harness: Harness) -> (any HookInstaller)? {
        HookInstallers.installer(
            for: harness, home: homeDirectory, paths: paths, command: command
        )
    }

    /// What installing hooks for a harness would register, for a page that
    /// wants to name the events before anything is agreed to.
    public func hookPlan(for harness: Harness) -> HookPlan? {
        hookInstaller(for: harness)?.plan()
    }

    /// Why a harness has no row of this kind.
    public static func reasonUnavailable(_ harness: Harness, _ piece: Piece) -> String {
        if piece == .hooks { return HookInstallers.reasonUnavailable(harness) }
        if piece == .coordinationSkill {
            if coordinationSkillPath(for: harness, home: URL(fileURLWithPath: "/")) == nil {
                return "Auspex only installs this skill for Claude Code and Codex."
            }
            return "This build does not contain a verified auspex-coordination resource."
        }
        if let note = HarnessMCPConfigStore.externallyManagedNote(for: harness) {
            return "MCP is \(note)."
        }
        switch piece {
        case .mcpServer:
            return "No local MCP config file to write."
        case .coordinationSkill:
            return "This harness has no verified global skill directory Auspex can manage."
        case .protocolNote:
            return "This harness has no always-loaded instruction file Auspex knows about."
        case .hooks:
            return HookInstallers.reasonUnavailable(harness)
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

    /// The one exclusive directory Auspex may manage for a harness skill.
    ///
    /// These are the two global roots verified by their harnesses. Project
    /// skill directories and inferred locations are deliberately excluded:
    /// installing into a repository would be a different permission boundary.
    public static func coordinationSkillPath(for harness: Harness, home: URL) -> String? {
        switch harness {
        case .claudeCode:
            return home.appendingPathComponent(
                ".claude/skills/\(CoordinationSkillPackage.name)",
                isDirectory: true
            ).path
        case .codex:
            return home.appendingPathComponent(
                ".codex/skills/\(CoordinationSkillPackage.name)",
                isDirectory: true
            ).path
        default:
            return nil
        }
    }

    // MARK: - Install

    /// Writes one piece. Idempotent: installing what is already installed
    /// reports `didChange == false` and touches nothing.
    public func install(_ harness: Harness, _ piece: Piece) -> Report {
        let offer = offer(harness, piece)
        if piece == .coordinationSkill {
            guard let coordinationSkill,
                  let path = Self.coordinationSkillPath(for: harness, home: homeDirectory)
            else {
                return Report(
                    harness: harness, piece: piece, didChange: false,
                    path: nil, backupPath: nil,
                    failure: Self.reasonUnavailable(harness, piece)
                )
            }
            return CoordinationSkillInstaller(
                harness: harness,
                destination: URL(fileURLWithPath: path, isDirectory: true),
                package: coordinationSkill,
                paths: paths
            ).install()
        }
        if piece == .hooks {
            guard let hooks = hookInstaller(for: harness) else {
                return Report(
                    harness: harness, piece: piece, didChange: false,
                    path: nil, backupPath: nil,
                    failure: Self.reasonUnavailable(harness, piece)
                )
            }
            // A file Auspex cannot read is a file Auspex must not write: the
            // only safe edit is one that starts from what is already there.
            if case let .unreadable(reason) = offer.state {
                return Report(
                    harness: harness, piece: piece, didChange: false,
                    path: hooks.path, backupPath: nil, failure: reason
                )
            }
            return hooks.install()
        }
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
        if piece == .coordinationSkill {
            guard let coordinationSkill,
                  let path = Self.coordinationSkillPath(for: harness, home: homeDirectory)
            else {
                return Report(
                    harness: harness, piece: piece, didChange: false,
                    path: nil, backupPath: nil,
                    failure: Self.reasonUnavailable(harness, piece)
                )
            }
            return CoordinationSkillInstaller(
                harness: harness,
                destination: URL(fileURLWithPath: path, isDirectory: true),
                package: coordinationSkill,
                paths: paths
            ).uninstall()
        }
        if piece == .hooks {
            guard let hooks = hookInstaller(for: harness) else {
                return Report(
                    harness: harness, piece: piece, didChange: false,
                    path: nil, backupPath: nil,
                    failure: Self.reasonUnavailable(harness, piece)
                )
            }
            return hooks.uninstall()
        }
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
        let outcome = ConfigFileWriter(paths: paths, harness: offer.harness).edit(
            path: path,
            verify: { data in Self.verify(data, location: location) },
            transform: { text in try transform(text, location) }
        )
        return Report(
            harness: offer.harness,
            piece: offer.piece,
            didChange: outcome.didChange,
            path: path,
            backupPath: outcome.backupPath,
            failure: outcome.failure
        )
    }

    /// The file still has to be what it claims to be after the edit.
    private static func verify(_ data: Data, location: MCPConfigLocation?) -> String? {
        switch location?.format {
        case .json:
            if let problem = ConfigFileWriter.isStillJSON(data) { return problem }
            guard HarnessMCPConfigStore.jsonServerNames(
                in: data, includesScopes: location?.isScoped ?? false
            ) != nil else {
                return "The MCP servers could not be read back after the edit."
            }
            return nil
        case .toml, .none:
            // Nothing to parse: the TOML scanner is a scanner, and a Markdown
            // file has no grammar to break. The fence's own integrity is the
            // check, and `ConfigFence` writes both markers or neither.
            return nil
        }
    }

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
        case .coordinationSkill:
            // A directory package, handled before this text-edit path.
            throw InstallError.notATextEdit
        case .hooks:
            // Handled by a `HookInstaller` before the edit machinery here is
            // reached: a hook table is a list somebody else also appends to,
            // and neither a fence nor a member name can own an element of one.
            throw InstallError.notATextEdit
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
        case .coordinationSkill, .hooks:
            throw InstallError.notATextEdit
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
        guard let start = JSONTextEditor.valueStart(ofMemberNamed: name, in: text, objectAt: root)
        else { return nil }
        return text[start] == "{" ? start : nil
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
        case notATextEdit

        var description: String {
            switch self {
            case .noLocation: "This harness has no MCP config file."
            case .notAnObject: "The config file is not a JSON object."
            case .unparsable: "The config file could not be read closely enough to edit safely."
            case .notATextEdit: "Hooks are installed by their own installer."
            }
        }
    }
}

// MARK: - The note itself

extension HarnessInstaller {
    /// The paragraph that goes into a harness's always-loaded instructions.
    ///
    /// Short on purpose. It competes for context with everything else in the
    /// file. The installed skill owns the full Supervisor/Worker/Reviewer
    /// workflow; this always-loaded note keeps only the invariants needed to
    /// route an agent there and degrade safely when MCP is absent.
    ///
    /// It never tells an agent to do anything Auspex cannot do: no shell
    /// commands, no paths, no "run this". Everything is a tool call the server
    /// itself advertises.
    public static func protocolNote(for harness: Harness) -> String {
        """
        ## Auspex

        Auspex watches every agent session on this Mac and exposes an MCP server
        called `auspex`. Passive observation works without agent cooperation;
        MCP adds explicit coordination. Keep these invariants:

        1. **Call `auspex.notify` instead of going quiet.** The moment you need
           the person — a question (`needs_input`), something to check
           (`needs_review`), something you cannot get past (`blocked`), or work
           you have finished (`done`) — call it with one sentence saying what you
           need. It posts a macOS notification and moves your session into the
           right bucket on their board. Nothing else can tell "waiting for a
           human" apart from "thinking hard".
        2. **Use the `auspex-coordination` skill for tracked work.** When a brief
           names an Auspex task id, load that skill and follow its
           Supervisor/Worker/Reviewer playbook. Discover the connected server's
           capabilities and treat MCP as the state source; the skill is guidance.
        3. **Do not manufacture coordination.** With no task id, continue the
           user's work under the implicit session task. Do not create or claim an
           explicit task merely to satisfy this note. Agent completion enters
           Review; it does not close the task.
        4. **Degrade honestly.** If MCP is unavailable or `sessions.self` cannot
           resolve this process, continue the user's task and say which board
           updates were not recorded. Never impersonate another session or claim
           a notification, task update, or completion the server rejected.
        """
    }
}
