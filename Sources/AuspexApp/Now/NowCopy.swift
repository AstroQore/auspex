import AgentSessionKit
import AgentSessionLive
import AuspexCore
import Foundation

/// Every word the Now screen prints, in one place.
///
/// The rest of the app speaks English and has no strings table yet, so this
/// screen does too. Keeping every line here rather than scattered across the
/// views is what makes it one edit to change — and the obvious seam for a
/// strings table when the app grows one.
enum NowCopy {
    // MARK: Header

    static let title = "Now"
    static let needsYou = "Needs you"
    static let mayNeedYou = "May need you"
    static let doneUnseen = "Done, unseen"
    static let stageAndLists = "Office + lists"
    static let listsOnly = "Lists only"
    static let search = "Search sessions…"
    static let viewMode = "View"

    static func status(time: String, live: Int, working: Int) -> String {
        "\(time) · \(live) live · \(working) working"
    }

    // MARK: Stage

    static let stageTag = "AVIARY"
    static let stageHint = "Click a person to open the session · hover for what they are doing"
    static let collapseStage = "Hide the office"
    static let legendWorking = "Working"
    static let legendNeedsYou = "Needs you"
    static let legendMayNeedYou = "May need you"
    static let legendIdle = "Idle"

    // MARK: Sections

    static let needsYouHeading = "NEEDS YOU"
    static let mayNeedYouHeading = "MAY NEED YOU"
    static let workingHeading = "WORKING"
    static let doneHeading = "DONE, UNSEEN"
    static let idleHeading = "IDLE"

    static let needsYouNote = "explicit signals only"
    static let mayNeedYouNote = "inferred — watch signals"
    static let workingNote = "one row per root session, sub-agents folded"
    static let doneNote = "notify(done) / tasks.complete"

    static let columnProject = "PROJECT"
    static let columnHarness = "HARNESS"
    static let columnDoing = "DOING"
    static let columnTurn = "TURN / SUB-AGENTS"
    static let columnContext = "CONTEXT"

    static let open = "Open →"
    static let openQuiet = "Open"
    static let markSeen = "Mark seen"
    static let openTask = "Task →"

    static func more(_ count: Int) -> String { "\(count) more →" }
    static let fewer = "Fewer"
    static func idle(_ count: Int, isOpen: Bool) -> String {
        "\(idleHeading) \(count) · \(isOpen ? "hide" : "show →")"
    }

    static let allClear = "Nothing is running, and nothing is waiting on you."

    // MARK: Lines

    static let waitingPermission = "Waiting for permission"
    static let waitingAnswer = "Waiting for an answer"
    static let blockedTask = "Task marked blocked"

    /// A tool and what it is aimed at, the way a permission prompt names it:
    /// `Bash(gh pr merge)`.
    static func call(_ tool: String, _ target: String?, limit: Int = 48) -> String {
        guard let target, !target.isEmpty else { return tool }
        return "\(tool)(\(PathDisplay.condense(target, limit: limit)))"
    }

    /// A watch signal, in a few words. The signal's own sentence is English
    /// and written for the Catch-up panel; this is the list's version.
    static func watch(_ kind: WatchSignal.Kind, tool: String?) -> String {
        switch kind {
        case .staleSession: "alive, but nothing new"
        case .longTool: "\(tool ?? "a tool") has run for over \(Int(CollaborationSignals.longToolAfter / 60)) min"
        case .contextPressure: "context over 90% used"
        case .sharedDirectory: "shares a working directory"
        case .sharedBranch: "shares a branch"
        case .orphanedClaim: "the session that claimed it has ended"
        }
    }

    // MARK: Balloons

    /// The balloon a caption prints over its person on the stage.
    static func balloon(for caption: NowFrame.Caption) -> SceneCaption? {
        guard let tone = SceneCaption.Tone(caption.tone) else { return nil }
        switch caption.reason {
        case .permission(let tool, let target):
            let body = tool.map { "! \(waitingPermission) \(call($0, target, limit: 22))" }
                ?? "! \(waitingAnswer)"
            return SceneCaption(tone: tone, lead: nil, body: body, since: caption.since)
        case .notice(let message):
            return SceneCaption(
                tone: tone, lead: nil, body: "! " + clip(message, 34), since: caption.since
            )
        case .blockedTask:
            return SceneCaption(tone: tone, lead: nil, body: "! " + blockedTask, since: caption.since)
        case .watch(let kind, _):
            return SceneCaption(
                tone: tone, lead: nil,
                body: "? " + watch(kind, tool: caption.activity.tool),
                since: caption.since
            )
        case .working, .idle, .done:
            return SceneCaption(
                tone: tone,
                lead: caption.harness.displayName,
                body: activity(caption.activity, limit: 28),
                since: caption.since
            )
        }
    }

    /// What a session is doing, as one short line: `WebSearch “Dots API”`.
    static func activity(_ activity: NowFrame.Activity, limit: Int) -> String {
        switch (activity.tool, activity.detail) {
        case let (tool?, detail?) where !detail.isEmpty:
            "\(tool) “\(PathDisplay.condense(detail, limit: limit))”"
        case let (tool?, _):
            tool
        case let (nil, detail?):
            clip(detail, limit)
        case (nil, nil):
            "…"
        }
    }

    /// At most `limit` characters, with an ellipsis when it was cut.
    static func clip(_ text: String, _ limit: Int) -> String {
        let single = text.replacingOccurrences(of: "\n", with: " ")
        guard single.count > limit else { return single }
        return String(single.prefix(max(1, limit - 1))) + "…"
    }
}
