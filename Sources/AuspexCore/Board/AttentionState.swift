import AgentSessionKit
import AgentSessionLive
import Foundation

/// Who said this session wants a person, or has finished.
///
/// Two answers, and the difference is worth a field because a reader acts on
/// them differently. An agent's call is a *sentence somebody wrote*; a
/// harness's permission wait is a *fact Auspex observed*. The card marks the
/// difference, and so does the clearing rule below.
public enum AttentionSource: String, Sendable, Hashable, Codable, CaseIterable {
    /// The agent said so itself: `auspex.notify`, or `tasks.complete`.
    case agent
    /// The harness said so: a `PermissionRequest` hook, or a native permission
    /// wait its own store records — Codex's guardian, Grok's
    /// `permission_requested`, Antigravity's status 9, Grok Bot's
    /// `awaitingUserResponse`. All of them arrive as
    /// ``SessionState/waitingPermission(tool:)``, which is why one code path
    /// serves the three of them.
    case harness
}

/// Whether this session wants a person, and why.
///
/// ## The axis this is, and the axis it is not
///
/// A session has two independent facts about it. **Activity** is what it is
/// doing — thinking, calling a tool, writing, idle, ended — and Auspex infers
/// it from the transcript, always, for every session on the machine. This is
/// the other one: **attention**, which is whether the *person* has something to
/// do about it. Attention is never inferred. It exists only where something
/// explicit said so.
///
/// The two are orthogonal, and deliberately. An agent that calls
/// `notify(done)` while a `swift build` is still running is `working` and
/// `doneReported` at once, and both are true: it finished the task it was
/// given, and its process is alive. A model that folded them into one enum
/// would have to pick one of those to throw away.
///
/// ## Why a plain turn ending is not in here
///
/// It used to be. "Done and unseen" was inferred — a turn closed, nobody had
/// opened the card since — and on a machine that has been running agents all
/// week that inference labels four hundred sessions as things the person owes
/// attention to. A count nobody can act on is a count nobody reads, which
/// takes the two counts *beside* it down with it.
///
/// So a plain `turnEnded` now goes in no bucket at all. What survives of the
/// inference is ``TaskLedger/isQuietReply(state:lastTurnEndedAt:lastSeenAt:isChild:hasAssignment:)``,
/// which puts a faint dot on the card and is counted nowhere and notified
/// never.
public enum AttentionState: Sendable, Hashable {
    /// Nothing explicit has been said. Almost every session, almost always.
    case none
    /// Blocked on a person, and going nowhere without one.
    case needsYou(reason: String, source: AttentionSource)
    /// Finished something and said so. Waiting to be read, not to be answered.
    case doneReported(summary: String, source: AttentionSource)

    /// Whether a person has to act before this session moves.
    public var wantsPerson: Bool {
        if case .needsYou = self { return true }
        return false
    }

    /// Whether an agent has reported finishing something.
    public var isDoneReported: Bool {
        if case .doneReported = self { return true }
        return false
    }

    /// Whether anything explicit is being said at all.
    public var isSignalling: Bool { self != .none }

    /// The sentence a banner draws — the agent's own words, or the harness's
    /// account of what it is waiting for. `nil` when nothing is being said.
    public var message: String? {
        switch self {
        case .none: nil
        case .needsYou(let reason, _): reason
        case .doneReported(let summary, _): summary
        }
    }

    /// Who said it.
    public var source: AttentionSource? {
        switch self {
        case .none: nil
        case .needsYou(_, let source), .doneReported(_, let source): source
        }
    }

    // MARK: - Derivation

    /// How long an unanswered signal stays on the board.
    ///
    /// A day. Long enough that something asked for overnight is still asking
    /// in the morning; short enough that a machine left running over a weekend
    /// does not come back with a wall of red about a question whose terminal
    /// has since been closed. It is the one clearing rule nobody has to
    /// perform.
    public static let ageOut: TimeInterval = 24 * 60 * 60

    /// How long after a call an event still counts as *the call being
    /// recorded* rather than as the agent going back to work.
    ///
    /// An agent that calls `auspex.notify` is usually mid-turn: the harness
    /// writes the tool call, the notice arrives, and the tool's result is
    /// written a moment later. All three are one gesture, and a rule that read
    /// the third as "it carried on without you" would clear every call the
    /// instant it was made.
    ///
    /// Three quarters of a minute, which is comfortably longer than a tool
    /// round trip and far shorter than a session that has genuinely resumed.
    public static let workingGrace: TimeInterval = 45

    /// What one session's attention is, from every explicit source at once.
    ///
    /// Pure and total: the same arguments always give the same answer, and
    /// there is no clock in it — `now` is passed, because the frame it is
    /// derived for carries its own `generatedAt` and a derivation that read
    /// the wall clock could not be tested or replayed.
    ///
    /// ## The clearing rules, and why the two sources do not share them
    ///
    /// An **agent's** call is a claim about a moment. It is cleared by the
    /// person opening the card, by them typing into that session's terminal,
    /// by the agent going back to work (a `needs_input` that started running
    /// tools again has been answered somewhere Auspex cannot see), by a
    /// dismissal, and by age.
    ///
    /// A **harness's** permission wait is a claim about *now*, and clicking a
    /// card does not un-block it. So an acknowledgement does not clear one: it
    /// stops when the state stops, when the person answers in the terminal, or
    /// when it is a day old and whatever was asked is no longer being waited
    /// for. A board that let you dismiss a genuinely blocked session would be
    /// a board that hides the one thing it exists to show.
    ///
    /// - Parameters:
    ///   - state: what the session is doing.
    ///   - notice: the agent's live call, when it made one.
    ///   - acknowledgedAt: when the person last cleared this session's signal —
    ///     opened its card, dismissed it, or marked everything seen.
    ///   - lastPromptAt: when the person last said something *to this session*,
    ///     which answers a question wherever it was asked.
    ///   - lastEventAt: the session's most recent event, which is how "it went
    ///     back to work" is told from "it stopped where it was".
    ///   - now: the frame's own instant, for the age-out.
    public static func derive(
        state: SessionState,
        notice: AgentNotice?,
        acknowledgedAt: Date? = nil,
        lastPromptAt: Date? = nil,
        lastEventAt: Date? = nil,
        now: Date
    ) -> AttentionState {
        if let notice, notice.isLive,
           let attention = fromAgent(
               notice,
               state: state,
               acknowledgedAt: acknowledgedAt,
               lastPromptAt: lastPromptAt,
               lastEventAt: lastEventAt,
               now: now
           ) {
            return attention
        }
        // The harness's own wait, and it is checked *after* the agent's call so
        // that a session which said something more specific keeps its own
        // words. Both land in the same bucket either way.
        if case .waitingPermission(let tool) = state {
            let since = lastEventAt ?? now
            guard now.timeIntervalSince(since) < ageOut else { return .none }
            if let lastPromptAt, lastPromptAt > since { return .none }
            return .needsYou(reason: harnessReason(tool: tool), source: .harness)
        }
        return .none
    }

    /// The agent's own call, if it is still standing.
    private static func fromAgent(
        _ notice: AgentNotice,
        state: SessionState,
        acknowledgedAt: Date?,
        lastPromptAt: Date?,
        lastEventAt: Date?,
        now: Date
    ) -> AttentionState? {
        let at = notice.createdAt
        if now.timeIntervalSince(at) >= ageOut { return nil }
        if let acknowledgedAt, acknowledgedAt > at { return nil }
        if let lastPromptAt, lastPromptAt > at { return nil }

        if notice.kind.wantsPerson {
            // Back at work, after having said it was stuck. Whatever it was
            // waiting for arrived somewhere Auspex cannot see — a terminal, a
            // file, a colleague — and a card still shouting about it is a card
            // teaching its reader that red means nothing.
            //
            // `waitingPermission` is deliberately not "back at work": a
            // session that asked for input and then hit a permission prompt is
            // stuck twice over.
            if isWorking(state), let lastEventAt,
               lastEventAt.timeIntervalSince(at) > workingGrace {
                return nil
            }
            return .needsYou(reason: notice.message, source: .agent)
        }
        // A receipt, not a request. It survives the agent carrying on — see
        // the note on the two axes above.
        return .doneReported(summary: notice.message, source: .agent)
    }

    /// Whether the harness is expected to produce more events on its own
    /// *without* anybody doing anything first.
    ///
    /// ``SessionState/isActive`` is one case wider than this: it counts
    /// `waitingPermission`, which is exactly the state this has to exclude.
    static func isWorking(_ state: SessionState) -> Bool {
        switch state {
        case .thinking, .toolCalling, .writingFile, .delegating: true
        case .idle, .ended, .waitingPermission: false
        }
    }

    /// What a harness's permission wait is about, in a sentence.
    ///
    /// The tool when the harness named one — a wait is about *that* call, and
    /// a person deciding whether to get up wants to know which. Grok Bot's
    /// roster carries a flag and no name, and "a tool" would be inventing one:
    /// its bot is waiting on an answer, not on an approval.
    static func harnessReason(tool: String?) -> String {
        guard let tool, !tool.isEmpty else { return "Waiting for an answer" }
        return "Waiting for permission: \(tool)"
    }
}
