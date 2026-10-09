import AgentSessionKit
import AgentSessionLive
import AuspexCore
import Foundation

// The words the app shows for values Core defines.
//
// Core keeps its own English `title` / `label` properties, because Core is
// also what the MCP surface and the tests read, and both of those parse what
// they are given. The app never shows those: it shows these, which come from
// the catalogue and follow the Language setting. One extension per Core type,
// each a switch with no `default`, so a case added in Core is a compile error
// here rather than an English word on a Chinese screen.

extension BoardViewMode {
    /// The view's name in the header's menu and the window title.
    var localizedTitle: String {
        switch self {
        case .now: L10n.ViewMode.now
        case .board: L10n.ViewMode.board
        case .scene: L10n.ViewMode.scene
        case .crew: L10n.ViewMode.crew
        case .perch: L10n.ViewMode.perch
        case .trajectory: L10n.ViewMode.trajectory
        }
    }
}

extension BoardGroupBy {
    /// The grouping menu's label.
    var localizedTitle: String {
        switch self {
        case .none: L10n.Board.Group.none
        case .harness: L10n.Common.harness
        case .project: L10n.Common.project
        case .tree: L10n.Board.Group.tree
        }
    }
}

extension SessionWindow {
    /// The window menu's row.
    var localizedTitle: String {
        switch self {
        case .hour: L10n.Board.Window.hours(count: 1)
        case .sixHours: L10n.Board.Window.hours(count: 6)
        case .twelveHours: L10n.Board.Window.hours(count: 12)
        case .day: L10n.Board.Window.hours(count: 24)
        case .week: L10n.Board.Window.days(count: 7)
        case .all: L10n.Common.all
        }
    }

    /// The window menu's label, where the room is a few characters.
    var localizedShortTitle: String {
        switch self {
        case .hour: L10n.Board.Window.hoursShort(count: 1)
        case .sixHours: L10n.Board.Window.hoursShort(count: 6)
        case .twelveHours: L10n.Board.Window.hoursShort(count: 12)
        case .day: L10n.Board.Window.hoursShort(count: 24)
        case .week: L10n.Board.Window.daysShort(count: 7)
        case .all: L10n.Common.all
        }
    }

    /// "3 older than 12 h, hidden", or `nil` when nothing is hidden.
    static func localizedHint(hidden: Int, window: SessionWindow) -> String? {
        guard hidden > 0, window != .all else { return nil }
        return L10n.Board.Window.olderHidden(count: hidden, window: window.localizedShortTitle)
    }
}

extension TaskLedger.Bucket {
    /// The word after the number on a summary chip.
    var localizedLabel: String {
        switch self {
        case .needsYou: L10n.Board.Bucket.needsYou
        case .doneReported: L10n.Board.Bucket.inReview
        case .working: L10n.Board.Bucket.working
        case .idle: L10n.Board.Bucket.idle
        case .ended: L10n.Board.Bucket.ended
        }
    }
}

extension ContextGauge {
    /// `898.8k / 1M · 90 %`, or `850.1k · window ?` when the denominator was
    /// not believable. Numbers are Core's; only the word is the catalogue's.
    var localizedLabel: String {
        overflowedWindow ? L10n.Context.unknownWindow(used: ContextFormat.tokens(used)) : label
    }

    /// Why the denominator was refused, in one sentence.
    var localizedUnknownWindowReason: String {
        isDerived ? L10n.Context.Help.notOnRecord : L10n.Context.Help.overflow
    }

    /// The gauge's tooltip: the reading, then how much of it was measured.
    var localizedHelpText: String {
        var lines = [localizedLabel]
        if let cached, cached > 0 {
            lines.append(L10n.Context.Help.cached(tokens: ContextFormat.tokens(cached)))
        }
        if overflowedWindow {
            lines.append(localizedUnknownWindowReason)
        } else {
            lines.append(isDerived ? L10n.Context.Help.derived : L10n.Context.Help.recorded)
        }
        if compactions > 0 {
            lines.append(L10n.Context.Help.compacted(count: compactions))
        }
        return lines.joined(separator: "\n")
    }
}

extension AuspexTaskStatus {
    /// A task's column and status word.
    var localizedLabel: String {
        switch self {
        case .todo: L10n.Task.Status.todo
        case .doing: L10n.Task.Status.doing
        case .blocked: L10n.Task.Status.blocked
        case .review: L10n.Task.Status.review
        case .done: L10n.Task.Status.done
        }
    }
}

extension TaskImportance {
    var localizedLabel: String {
        switch self {
        case .low: L10n.Task.Importance.low
        case .normal: L10n.Task.Importance.normal
        case .important: L10n.Task.Importance.important
        case .urgent: L10n.Task.Importance.urgent
        }
    }
}

extension TaskKind {
    var localizedLabel: String {
        switch self {
        case .feature: L10n.Task.Kind.feature
        case .fix: L10n.Task.Kind.fix
        case .chore: L10n.Task.Kind.chore
        case .research: L10n.Task.Kind.research
        }
    }
}

extension TaskNoteKind {
    var localizedLabel: String {
        switch self {
        case .decision: L10n.Task.Note.decision
        case .evidence: L10n.Task.Note.evidence
        case .risk: L10n.Task.Note.risk
        case .note: L10n.Task.Note.note
        }
    }
}

extension AuspexTaskLinkKind {
    var localizedLabel: String {
        switch self {
        case .claim: L10n.Task.Link.claimed
        case .manual: L10n.Task.Link.linked
        case .inherited: L10n.Task.Link.inherited
        }
    }
}

extension AgentNoticeKind {
    /// What an agent said it needs, as a pill.
    var localizedLabel: String {
        switch self {
        case .needsInput: L10n.Notice.needsInput
        case .needsReview: L10n.Notice.needsReview
        case .blocked: L10n.Notice.blocked
        case .done: L10n.Notice.done
        }
    }
}

extension SessionControl.Signal {
    /// The session menu's item for this signal.
    var localizedMenuTitle: String {
        switch self {
        case .interrupt: L10n.Session.Signal.interrupt
        case .terminate: L10n.Session.Signal.kill
        case .forceKill: L10n.Session.Signal.forceKill
        }
    }
}

extension SessionControl {
    /// The kill dialog's title, with the session's title cut to one line —
    /// the same cut ``SessionControl/killPrompt(title:target:)`` makes.
    static func localizedKillPrompt(title: String) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let shown = trimmed.isEmpty
            ? L10n.Session.Kill.thisSession
            : (trimmed.count > 60 ? String(trimmed.prefix(59)) + "…" : trimmed)
        return L10n.Session.Kill.prompt(title: shown)
    }

    /// The kill dialog's body: which process, and what it costs.
    static func localizedKillMessage(target: Target, isResumable: Bool) -> String {
        isResumable
            ? L10n.Session.Kill.messageResumable(process: target.processName, pid: Int(target.pid))
            : L10n.Session.Kill.message(process: target.processName, pid: Int(target.pid))
    }

    /// The Interrupt item's tooltip, per harness. See
    /// ``SessionControl/interruptHelp(for:pid:)`` for why Claude Code differs.
    static func localizedInterruptHelp(for harness: Harness, pid: pid_t) -> String {
        switch harness {
        case .claudeCode: L10n.Session.InterruptHelp.claude(pid: Int(pid))
        default: L10n.Session.InterruptHelp.other(pid: Int(pid))
        }
    }
}

extension TaskFilters.Claim {
    /// A filter chip, lower-case — "claimed", "unclaimed".
    var localizedLabel: String {
        switch self {
        case .claimed: L10n.Task.Filter.claimed
        case .unclaimed: L10n.Task.Filter.unclaimed
        }
    }
}

extension SessionState {
    /// The state as a phrase — VoiceOver, tooltips, a palette subtitle. The
    /// kit's own `label` stays English for the identities built from it.
    var localizedLabel: String {
        switch self {
        case .idle: L10n.Now.idle
        case .thinking: L10n.State.thinking
        case .toolCalling(let name): L10n.State.toolNamed(name: name)
        case .writingFile: L10n.State.writingFile
        case .delegating(let children): L10n.State.delegatingCount(count: children)
        case .waitingPermission: L10n.Now.waitingPermission
        case .ended: L10n.Board.Ended.title
        }
    }
}

extension AttentionState {
    /// The sentence a banner draws, in the app's language where Auspex wrote
    /// it. An agent's own words are shown as written; the harness's account
    /// of a permission prompt is Core's fixed English sentence, recognised
    /// here and said again in the catalogue's words.
    var localizedMessage: String? {
        guard let message else { return nil }
        guard case .needsYou(_, .harness) = self else { return message }
        if message == "Waiting for an answer" { return L10n.Now.waitingAnswer }
        let permission = "Waiting for permission: "
        if message.hasPrefix(permission) {
            return L10n.Attention.waitingPermission(tool: String(message.dropFirst(permission.count)))
        }
        return message
    }
}

extension IgnoreRule.Kind.Tag {
    /// What a rule matches on.
    var localizedLabel: String {
        switch self {
        case .pathPrefix: L10n.Ignore.Tag.folder
        case .project: L10n.Common.project
        case .promptPrefix: L10n.Ignore.Tag.promptPrefix
        case .harness: L10n.Common.harness
        case .titleContains: L10n.Ignore.Tag.titleContains
        case .scratchPrefix: L10n.Ignore.Tag.scratchFolder
        }
    }

    /// The field's placeholder. The two examples that are a path or a word
    /// somebody would type stay as typed.
    var localizedPlaceholder: String {
        switch self {
        case .project: L10n.Ignore.Placeholder.project
        case .harness: L10n.Ignore.Placeholder.harness
        case .pathPrefix, .promptPrefix, .titleContains, .scratchPrefix: placeholder
        }
    }

    /// One line saying what the rule does.
    var localizedExplanation: String {
        switch self {
        case .pathPrefix: L10n.Ignore.Explain.folder
        case .project: L10n.Ignore.Explain.project
        case .promptPrefix: L10n.Ignore.Explain.promptPrefix
        case .harness: L10n.Ignore.Explain.harness
        case .titleContains: L10n.Ignore.Explain.titleContains
        case .scratchPrefix: L10n.Ignore.Explain.scratchFolder
        }
    }
}

extension IgnoreRule.Kind {
    /// What a rule matches on, for a rule that exists.
    var localizedLabel: String { tag.localizedLabel }
}

extension TaskProjectCounts {
    /// "3 tasks open", or `nil` when none is — the same rule as
    /// ``TaskProjectCounts/openDescription``.
    var localizedOpenDescription: String? {
        guard open > 0 else { return nil }
        return L10n.Projects.tasksOpen(count: open)
    }
}

extension ContextComposition.Slice {
    /// A band of the context window, in the composition breakdown.
    var localizedTitle: String {
        switch kind {
        case .messages: L10n.Context.Slice.messages
        case .toolResults: L10n.Context.Slice.toolResults
        case .everythingElse: L10n.Context.Slice.everythingElse
        case .free: L10n.Context.Slice.free
        }
    }
}

extension TraceEntry {
    /// The row's title in the app's language.
    ///
    /// Core names each event kind with a fixed English word when it builds
    /// the row — the trace is stored and read back in that form — so the
    /// words are recognised here and said again from the catalogue. A tool
    /// row's title is the tool's own name and passes through unchanged, as
    /// does any word this table does not know.
    var localizedTitle: String {
        if title.hasPrefix(Self.subagentPrefix) {
            return L10n.Trace.Event.subagentType(type: String(title.dropFirst(Self.subagentPrefix.count)))
        }
        if title.hasPrefix(Self.toolResultPrefix) {
            return L10n.Trace.Event.toolResultFor(id: String(title.dropFirst(Self.toolResultPrefix.count)))
        }
        return Self.localizedFixedTitle(title) ?? title
    }

    private static let subagentPrefix = "Subagent · "
    private static let toolResultPrefix = "Tool result · "

    private static func localizedFixedTitle(_ title: String) -> String? {
        switch title {
        case "Session started": L10n.Trace.Event.sessionStarted
        case "Identity updated": L10n.Trace.Event.identityUpdated
        case "Prompt": L10n.Trace.Event.prompt
        case "Turn started": L10n.Trace.Event.turnStarted
        case "Thinking": L10n.State.thinking
        case "Assistant": L10n.Trace.Event.assistant
        case "Tool failed": L10n.Trace.Event.toolFailed
        case "Tool finished": L10n.Trace.Event.toolFinished
        case "Permission requested": L10n.Trace.Event.permissionRequested
        case "Permission allowed": L10n.Trace.Event.permissionAllowed
        case "Permission denied": L10n.Trace.Event.permissionDenied
        case "Subagent started": L10n.Trace.Event.subagentStarted
        case "Subagent finished": L10n.Trace.Event.subagentFinished
        case "Turn ended": L10n.Trace.Event.turnEnded
        case "Usage": L10n.Trace.Tab.usage
        case "Context": L10n.Common.context
        case "Context compacted": L10n.Trace.Event.contextCompacted
        case "Plan limit": L10n.Trace.Event.planLimit
        case "Session ended": L10n.Trace.Event.sessionEnded
        case "Note": L10n.Trace.Event.note
        case "Process alive": L10n.Trace.Event.processAlive
        case "Process gone": L10n.Crew.End.processGone
        case "Tool result": L10n.Trace.Event.toolResult
        default: nil
        }
    }
}

extension TrajectoryRole {
    /// Who a step belongs to, on its chip.
    var localizedLabel: String {
        switch self {
        case .system: L10n.Flight.Role.system
        case .user: L10n.Flight.Role.user
        case .assistant: L10n.Trace.Event.assistant
        case .tool: L10n.State.tool
        }
    }
}

extension TrajectoryScale {
    /// The timeline's scale picker.
    var localizedTitle: String {
        switch self {
        case .events: L10n.Flight.Scale.events
        case .duration: L10n.Flight.Scale.duration
        case .turns: L10n.Flight.Scale.turns
        case .calls: L10n.Flight.Scale.calls
        }
    }
}

extension TrajectoryLane {
    /// A lane's label down the timeline's left edge.
    var localizedTitle: String {
        switch self {
        case .input: L10n.Flight.Lane.input
        case .model: L10n.Flight.Lane.model
        case .tools: L10n.Trace.Tab.tools
        }
    }
}

extension SettingsPane {
    /// The pane's name, in the pane strip and its title row.
    var localizedTitle: String {
        switch self {
        case .agents: L10n.Settings.Pane.agents
        case .general: L10n.Settings.Pane.general
        case .appearance: L10n.Settings.Pane.appearance
        case .characters: L10n.Settings.Pane.characters
        case .scene: L10n.Settings.Pane.scene
        case .crew: L10n.Settings.Pane.crew
        case .ignore: L10n.Ignore.eyebrow
        case .updates: L10n.Settings.Pane.updates
        }
    }

    /// The pane's one line under its title.
    var localizedSubtitle: String {
        switch self {
        case .agents: L10n.Settings.Pane.agentsSubtitle
        case .general: L10n.Settings.Pane.generalSubtitle
        case .appearance: L10n.Settings.Pane.appearanceSubtitle
        case .characters: L10n.Settings.Pane.charactersSubtitle
        case .scene: L10n.Settings.Pane.sceneSubtitle
        case .crew: L10n.Settings.Pane.crewSubtitle
        case .ignore: L10n.Settings.Pane.ignoreSubtitle
        case .updates: L10n.Settings.Pane.updatesSubtitle
        }
    }
}

extension UpdateChannel {
    var localizedTitle: String {
        switch self {
        case .main: L10n.Settings.Updates.Channel.stable
        case .dev: L10n.Settings.Updates.Channel.dev
        }
    }

    var localizedDetail: String {
        switch self {
        case .main: L10n.Settings.Updates.Channel.stableDetail
        case .dev: L10n.Settings.Updates.Channel.devDetail
        }
    }
}

extension AppearanceMode {
    var localizedTitle: String {
        switch self {
        case .system: L10n.Settings.Language.system
        case .light: L10n.Settings.Appearance.light
        case .dark: L10n.Settings.Appearance.dark
        }
    }

    var localizedDetail: String {
        switch self {
        case .system: L10n.Settings.Appearance.systemDetail
        case .light: L10n.Settings.Appearance.lightDetail
        case .dark: L10n.Settings.Appearance.darkDetail
        }
    }
}

extension CharacterChoice {
    /// "Auspex built-in": the procedural figures, as a choice in a picker.
    static var localizedBuiltInDisplayName: String { L10n.Characters.builtIn }
}

extension CharacterPackage.Source {
    var localizedDisplayName: String {
        switch self {
        case .builtIn: L10n.Characters.Source.builtIn
        case .user: L10n.Characters.Source.user
        }
    }
}

extension CharacterKind {
    var localizedDisplayName: String {
        switch self {
        case .person: L10n.Characters.Kind.person
        case .pet: L10n.Characters.Kind.pet
        }
    }
}

extension HarnessInstaller.Piece {
    /// What a setup row installs.
    var localizedTitle: String {
        switch self {
        case .mcpServer: L10n.Setup.Piece.mcpServer
        case .coordinationSkill: L10n.Setup.Piece.coordinationSkill
        case .protocolNote: L10n.Setup.Piece.protocolNote
        case .hooks: L10n.Setup.Piece.hooks
        }
    }

    /// What installing it does, in one sentence.
    var localizedExplanation: String {
        switch self {
        case .mcpServer: L10n.Setup.Piece.mcpServerDetail
        case .coordinationSkill: L10n.Setup.Piece.coordinationSkillDetail
        case .protocolNote: L10n.Setup.Piece.protocolNoteDetail
        case .hooks: L10n.Setup.Piece.hooksDetail
        }
    }
}

/// Core's fixed words for things it names while building a frame.
///
/// Core's layouts and groupings name what they build with fixed English words
/// — "Meeting room", "No project", "All sessions" — beside names that are data
/// (a project's, a branch's). Core keeps them in English because the MCP
/// surface and the tests read the same values. The words are recognised here
/// and said again from the catalogue; anything else is drawn as given.
enum CoreVocabulary {
    static func localized(_ title: String) -> String {
        if let match = title.firstMatch(of: /^(\d+) below$/), let count = Int(match.1) {
            // `BoardGrouping`'s tree subtitle: "3 below".
            return L10n.Board.Group.below(count: count)
        }
        if title.hasSuffix(PseudoProject.scratchSuffix) {
            // A harness's throwaway directories: "Codex · scratch".
            return L10n.Projects.harnessScratch(
                harness: String(title.dropLast(PseudoProject.scratchSuffix.count))
            )
        }
        // A switch rather than a table: several Core constants spell the same
        // word ("No project" names a floor, a ledger section and a task
        // section), and a dictionary literal would trap on the repeat.
        switch title {
        case "Meeting room": return L10n.Aviary.Room.meetingRoom
        case "Meeting rooms": return L10n.Settings.Scene.meetingRooms
        case "Garden": return L10n.Settings.Scene.garden
        case "Tea room": return L10n.Settings.Scene.teaRoom
        case "Lounge": return L10n.Settings.Scene.lounge
        case SceneLayout.unplacedFloorTitle, BoardGrouping.noProjectTitle,
             TaskUnitGrouping.noProjectTitle:
            return L10n.Aviary.noProject
        case BoardGrouping.allSessionsTitle: return L10n.Board.Group.allSessions
        case BoardGrouping.standaloneTitle: return L10n.Board.Group.standalone
        case TaskUnitGrouping.allTasksTitle: return L10n.Board.Group.allTasks
        case ProjectTree.unknownCheckoutTitle: return L10n.Board.Group.unknownCheckout
        case SessionVariantLabel.autoReview: return L10n.Session.autoReview
        case TaskProject.scratchName: return L10n.Common.scratch
        default: return title
        }
    }
}
