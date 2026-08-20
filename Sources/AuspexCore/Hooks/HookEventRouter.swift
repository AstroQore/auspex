import AgentSessionKit
import AgentSessionLive
import Foundation

/// Turns a harness's hook payload into the events the board already speaks.
///
/// ## What hooks are for, and what they are not for
///
/// The passive layer reads what harnesses write down, and it is better at that
/// than a hook could be: a transcript records every tool call, every token
/// count, every word. So a hook that reported tool calls would only duplicate
/// what the tailer already has — and would *double* the counters, because the
/// reducer counts `toolCallStarted` and has no way to know two of them are one
/// call seen twice.
///
/// Hooks earn their place on exactly the facts that are never written down:
///
/// - **A permission prompt.** Claude Code and Codex both ask for approval in
///   their own UI and put nothing in the transcript until the answer arrives.
///   From the outside, an agent waiting for a person and an agent thinking hard
///   are the same silence. `PermissionRequest` is the only thing that tells them
///   apart.
/// - **When a session started and stopped**, immediately, rather than when a
///   file's modification time settles or a process disappears from a sweep.
/// - **A subagent's boundaries**, for the harnesses whose subagent transcripts
///   appear only after the child has written its first line.
///
/// Everything else is passed through as a heartbeat: the reducer treats
/// ``AgentEventKind/note(_:)`` as evidence the session is alive at that instant
/// and changes nothing else, which is precisely the value of a hook that fires
/// for an activity the tailer will describe better in a moment.
///
/// ## Why it is stateful
///
/// A permission has to be *closed* by id, and the harness never repeats the id
/// it opened one with — Claude's `PermissionRequest` payload carries no
/// `tool_use_id` at all. So the router remembers the id it minted for each
/// session and hands the same one back when the resolving event arrives. The
/// map is bounded and holds one small string per session that is currently
/// blocked, which on any real machine is a handful.
public struct HookEventRouter: Sendable {
    /// The permission each session is currently blocked on, by the id this
    /// router minted for it.
    private var openPermissions: [SessionKey: String] = [:]
    /// Insertion order, so the bound evicts the oldest rather than an arbitrary
    /// one.
    private var permissionOrder: [SessionKey] = []

    /// How many blocked sessions are tracked at once.
    ///
    /// A permission that falls off the end stops being closable by hook, and is
    /// cleared by the turn ending instead — the reducer drops the open
    /// permission on `turnEnded` for exactly this reason. Sixty-four is far
    /// past any real machine's simultaneously-blocked agents.
    public static let trackedPermissionLimit = 64

    public init() {}

    // MARK: - Mapping

    /// The events one hook invocation implies.
    ///
    /// - Parameters:
    ///   - hook: what the harness sent.
    ///   - known: the sessions already on the board. Used to decide whether a
    ///     session id from a payload names a row that exists — for the harnesses
    ///     whose key format Auspex infers rather than knows, a key that matches
    ///     nothing is a worse answer than the process-tree one.
    ///   - fallback: the session the hook's pid resolved to, when it did.
    public mutating func events(
        for hook: HookEvent,
        known: Set<SessionKey>,
        fallback: SessionKey?
    ) -> [AgentEvent] {
        guard let session = session(for: hook, known: known, fallback: fallback) else { return [] }
        let kinds: [AgentEventKind]
        switch hook.target {
        case .claude, .grok:
            kinds = claudeShaped(hook, session: session, known: known)
        case .cursor:
            kinds = cursorShaped(hook, session: session)
        case .codex:
            kinds = codexHookShaped(hook, session: session)
        case .codexNotify:
            kinds = codexShaped(hook)
        }
        return kinds.map { kind in
            AgentEvent(
                session: session,
                timestamp: hook.receivedAt,
                observedAt: hook.receivedAt,
                kind: kind
            )
        }
    }

    /// The event name, whatever the harness calls the field.
    static func name(in payload: MCPJSON) -> String? {
        payload["hook_event_name"]?.stringValue
            ?? payload["hookEventName"]?.stringValue
            ?? payload["type"]?.stringValue
    }

    // MARK: - Claude Code, and Grok which copied its schema

    private mutating func claudeShaped(
        _ hook: HookEvent,
        session: SessionKey,
        known: Set<SessionKey>
    ) -> [AgentEventKind] {
        let payload = hook.payload
        guard let name = Self.name(in: payload) else { return [] }

        switch name {
        case "SessionStart":
            // A session the board has never heard of is one whose transcript
            // has not been written to yet — the hook beats the tailer to it by
            // however long the first turn takes. Seeding it here is what makes
            // a new agent appear the instant it starts rather than the instant
            // it says something.
            if known.contains(session) {
                return [.liveness(alive: true), .identityUpdated(patch(payload))]
            }
            guard let path = payload["transcript_path"]?.stringValue, !path.isEmpty else {
                return [.liveness(alive: true)]
            }
            var identity = SessionIdentity(key: session, sourcePath: path)
            identity.cwd = payload["cwd"]?.stringValue
            identity.entrypoint = payload["entrypoint"]?.stringValue
            return [.sessionStarted(identity: identity)]

        case "SessionEnd":
            return [.sessionEnded(reason: .exited)]

        case "PermissionRequest":
            let tool = payload["tool_name"]?.stringValue
            let id = permissionID(payload: payload, tool: tool)
            remember(permission: id, for: session)
            return [.permissionRequested(id: id, tool: tool)]

        case "PostToolUse", "PostToolUseFailure", "UserPromptSubmit":
            // A tool that ran is a permission that was answered. The tailer
            // will describe the call itself; all that is taken from here is the
            // fact that the person is no longer being waited on.
            guard let id = release(session) else { return [] }
            return [.permissionResolved(id: id, allowed: true)]

        case "Stop", "StopFailure", "TeammateIdle":
            _ = release(session)
            return [.turnEnded(reason: name == "StopFailure" ? .error : .complete)]

        case "SubagentStart":
            guard let child = subagentKey(payload, parent: session) else { return [] }
            return [.subagentStarted(
                child: child,
                agentType: payload["agent_type"]?.stringValue,
                toolUseID: payload["tool_use_id"]?.stringValue
            )]

        case "SubagentStop":
            guard let child = subagentKey(payload, parent: session) else { return [] }
            return [.subagentFinished(child: child)]

        case "Notification":
            // Claude fires this both for "needs your permission to use Bash"
            // and for "waiting for your input". The first is already covered
            // precisely by `PermissionRequest`, and the second is idleness
            // rather than blockage — so this is a heartbeat with the harness's
            // own sentence attached, and not a state change.
            guard let message = MCPTextSanitizer.clean(
                payload["message"]?.stringValue, limit: MCPTextSanitizer.labelLimit
            ) else { return [] }
            return [.note(message)]

        default:
            return []
        }
    }

    // MARK: - Cursor

    /// Cursor's hooks are lifecycle and activity only.
    ///
    /// It has no permission event: its `beforeShellExecution` fires for *every*
    /// shell command, approved or not, so reading it as "waiting for a person"
    /// would paint every command red. What Cursor gains from hooks instead is
    /// speed — its store is a content-addressed SQLite DAG that has to be
    /// polled, so a session start, a stop and a subagent boundary arriving as
    /// events is the difference between a second and a poll interval.
    private mutating func cursorShaped(_ hook: HookEvent, session: SessionKey) -> [AgentEventKind] {
        guard let name = Self.name(in: hook.payload) else { return [] }
        switch name {
        case "sessionStart":
            return [.liveness(alive: true)]
        case "sessionEnd":
            return [.sessionEnded(reason: .exited)]
        case "stop":
            return [.turnEnded(reason: .complete)]
        case "beforeSubmitPrompt":
            // Not `userPrompt`: that opens a turn and increments the count, and
            // the transcript will do both when it is read. A heartbeat is the
            // honest amount of information a hook adds here.
            return [.note("prompt submitted")]
        case "afterFileEdit", "afterShellExecution":
            return [.note(name)]
        case "subagentStart":
            guard let child = cursorSubagentKey(hook.payload) else { return [] }
            return [.subagentStarted(child: child, agentType: nil, toolUseID: nil)]
        case "subagentStop":
            guard let child = cursorSubagentKey(hook.payload) else { return [] }
            return [.subagentFinished(child: child)]
        default:
            return []
        }
    }

    private func cursorSubagentKey(_ payload: MCPJSON) -> SessionKey? {
        guard let id = payload["subagent_id"]?.stringValue
            ?? payload["agent_id"]?.stringValue
            ?? payload["subagent_conversation_id"]?.stringValue,
            !id.isEmpty
        else { return nil }
        return SessionKey(harness: .cursor, sessionID: id)
    }

    // MARK: - Codex

    /// Codex's hook table speaks Claude Code's schema, and is read with Claude's
    /// vocabulary: `hook_event_name`, `session_id`, `tool_name`, `tool_use_id`.
    ///
    /// Two deliberate differences from ``claudeShaped(_:session:known:)``:
    ///
    /// - **`SessionStart` seeds nothing.** Claude's session id *is* its
    ///   transcript's file name, so a key built from the payload is provably the
    ///   key the tailer will build. A Codex row is keyed by its rollout thread
    ///   id, which `CodexLiveAdapter` reads out of a file name Auspex has not
    ///   seen yet — so a seeded identity here would risk a second row for a
    ///   session that is about to appear on its own. Liveness is the honest
    ///   amount of information: the session is alive, now.
    /// - **No subagent events.** They are not registered, because a Codex
    ///   sub-agent is a rollout thread of its own and the payload's `agent_id`
    ///   is not that thread's id.
    private mutating func codexHookShaped(
        _ hook: HookEvent,
        session: SessionKey
    ) -> [AgentEventKind] {
        let payload = hook.payload
        guard let name = Self.name(in: payload) else { return [] }
        switch name {
        case "SessionStart":
            return [.liveness(alive: true)]

        case "SessionEnd":
            return [.sessionEnded(reason: .exited)]

        case "PermissionRequest":
            // The whole reason to install a hook table on a harness Auspex can
            // already tail: Codex asks in its own UI and writes nothing to the
            // rollout until the answer arrives.
            let tool = payload["tool_name"]?.stringValue
            let id = permissionID(payload: payload, tool: tool)
            remember(permission: id, for: session)
            return [.permissionRequested(id: id, tool: tool)]

        case "PostToolUse":
            // A tool that ran is a permission that was answered. The count of
            // the call itself comes from the rollout, which describes it better.
            guard let id = release(session) else { return [] }
            return [.permissionResolved(id: id, allowed: true)]

        case "Stop":
            _ = release(session)
            return [.turnEnded(reason: .complete)]

        default:
            return []
        }
    }

    /// Codex's other mechanism — one `notify` program, and one event worth
    /// having in it.
    private func codexShaped(_ hook: HookEvent) -> [AgentEventKind] {
        switch Self.name(in: hook.payload) {
        case "agent-turn-complete":
            return [.turnEnded(reason: .complete)]
        case let other?:
            return [.note(MCPTextSanitizer.clean(other, limit: 40) ?? "notify")]
        case nil:
            return []
        }
    }

    // MARK: - Identity

    /// Which session a hook is about.
    ///
    /// Claude Code's key is derived rather than looked up: its session id *is*
    /// the transcript's file name, so a key built from the payload names the
    /// same row the tailer will build, whether or not the board has got there
    /// yet. Every other harness's key format is inferred from its store layout,
    /// so a derived key is only trusted when it matches a row that exists; the
    /// process the hook ran in answers otherwise.
    private func session(
        for hook: HookEvent,
        known: Set<SessionKey>,
        fallback: SessionKey?
    ) -> SessionKey? {
        let payload = hook.payload
        let raw = [payload["session_id"], payload["conversation_id"], payload["thread_id"]]
            .compactMap { $0?.stringValue }
            .first { !$0.isEmpty }
        guard let raw else { return fallback }
        let key = SessionKey(harness: hook.target.harness, sessionID: raw)

        // Everything a subagent does carries the parent's session id and its
        // own agent id. The row it belongs to is the child's, when the board has
        // one — and the parent's when it does not, because a fabricated child
        // row would be worse than an event attributed one level up.
        //
        // Claude's spelling of a child key, and only for the harnesses that use
        // it: Codex names a sub-agent by its own thread id, so `agent-<id>`
        // would be a key nothing on its board could ever match.
        if hook.target == .claude || hook.target == .grok,
           let agent = payload["agent_id"]?.stringValue, !agent.isEmpty,
           Self.name(in: payload) != "SubagentStart", Self.name(in: payload) != "SubagentStop",
           let child = subagentKey(payload, parent: key), known.contains(child) {
            return child
        }
        if known.contains(key) { return key }
        if hook.target == .claude { return key }
        // Codex and ChatGPT Work read the same `~/.codex`, so one hooks file
        // serves both and a payload cannot say which of the two a thread
        // belongs to. The board can: `CodexOriginator` decided that when it
        // read the rollout's header.
        if hook.target == .codex {
            let sibling = SessionKey(harness: .chatgptWork, sessionID: raw)
            if known.contains(sibling) { return sibling }
        }
        return fallback ?? key
    }

    /// A Claude subagent's key: the parent's id, then the transcript file the
    /// child writes. The same string ``ClaudeLiveAdapter`` builds from the
    /// directory listing, so a hook and a tailer name one child once.
    private func subagentKey(_ payload: MCPJSON, parent: SessionKey) -> SessionKey? {
        guard let agent = payload["agent_id"]?.stringValue, !agent.isEmpty else { return nil }
        return SessionKey(
            harness: parent.harness,
            sessionID: "\(parent.sessionID)/agent-\(agent)"
        )
    }

    private func patch(_ payload: MCPJSON) -> SessionIdentityPatch {
        var patch = SessionIdentityPatch()
        patch.cwd = payload["cwd"]?.stringValue
        patch.entrypoint = payload["entrypoint"]?.stringValue
        return patch
    }

    // MARK: - Permissions

    /// The id a permission is opened and closed under.
    ///
    /// The harness's own id when it sends one, and a per-session synthetic
    /// otherwise. It is prefixed, because the id space is shared with the ones
    /// a transcript carries and a collision would let a tailer's
    /// `permissionResolved` close a hook's permission for a different thing.
    private func permissionID(payload: MCPJSON, tool: String?) -> String {
        if let id = payload["tool_use_id"]?.stringValue, !id.isEmpty { return "hook:\(id)" }
        return "hook:permission:\(tool ?? "tool")"
    }

    private mutating func remember(permission id: String, for session: SessionKey) {
        if openPermissions[session] == nil { permissionOrder.append(session) }
        openPermissions[session] = id
        while permissionOrder.count > Self.trackedPermissionLimit {
            let oldest = permissionOrder.removeFirst()
            openPermissions.removeValue(forKey: oldest)
        }
    }

    private mutating func release(_ session: SessionKey) -> String? {
        guard let id = openPermissions.removeValue(forKey: session) else { return nil }
        permissionOrder.removeAll { $0 == session }
        return id
    }

    /// Whether this session is currently blocked according to a hook. For the
    /// suite, and for anything that wants to know without waiting for a frame.
    public func isWaitingForPermission(_ session: SessionKey) -> Bool {
        openPermissions[session] != nil
    }
}
