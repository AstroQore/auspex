import AgentSessionKit
import AgentSessionLive
import AuspexCore
import Foundation

/// Every word the Now screen prints, in one place.
///
/// The words come from the `auspex-i18n` catalogue through `L10n`; this type
/// forwards to it and keeps the few rules about how a line is put together —
/// a tool and its target, a balloon's lead, where a line is clipped. Every
/// member is computed rather than stored, so a change of language reaches the
/// next frame without a relaunch.
enum NowCopy {
    // MARK: Header

    static var title: String { L10n.ViewMode.now }
    static var needsYou: String { L10n.Now.needsYou }
    static var mayNeedYou: String { L10n.Now.mayNeedYou }
    static var doneUnseen: String { L10n.Now.doneUnseen }
    static var stageAndLists: String { L10n.Now.Stage.officeAndLists }
    static var listsOnly: String { L10n.Now.Stage.listsOnly }
    static var search: String { L10n.Now.search }
    static var viewMode: String { L10n.Now.ViewMenu.title }

    static func status(time: String, live: Int, working: Int) -> String {
        L10n.Now.status(time: time, live: live, working: working)
    }

    // MARK: Stage

    /// The view's own name, set as a tag. Upper-cased here rather than in the
    /// catalogue so the tag and the menu can never name the view differently.
    static var stageTag: String { L10n.ViewMode.scene.uppercased() }
    static var stageHint: String { L10n.Now.Stage.hint }
    static var collapseStage: String { L10n.Now.Stage.collapse }
    static var expandStage: String { L10n.Now.Stage.expand }

    /// The folded stage's line. The Needs you half is a second key rather
    /// than a fragment, because it is left out entirely at zero and Chinese
    /// does not put the two halves together the way English does.
    static func collapsedSummary(working: Int, needsYou: Int) -> String {
        needsYou > 0
            ? L10n.Now.Stage.collapsedSummaryNeedsYou(working: working, needsYou: needsYou)
            : L10n.Now.Stage.collapsedSummary(working: working)
    }

    /// The folded stage, read aloud: both counts, zero included, and no ▸.
    static func collapsedA11y(working: Int, needsYou: Int) -> String {
        L10n.Now.Stage.collapsedA11y(working: working, needsYou: needsYou)
    }
    static var legendWorking: String { L10n.Now.working }
    static var legendNeedsYou: String { L10n.Now.needsYou }
    static var legendMayNeedYou: String { L10n.Now.mayNeedYou }
    static var legendIdle: String { L10n.Now.idle }

    // MARK: Sections

    static var needsYouHeading: String { needsYou.uppercased() }
    static var mayNeedYouHeading: String { mayNeedYou.uppercased() }
    static var workingHeading: String { legendWorking.uppercased() }
    static var doneHeading: String { doneUnseen.uppercased() }
    static var idleHeading: String { legendIdle.uppercased() }

    static var needsYouNote: String { L10n.Now.Note.needsYou }
    static var mayNeedYouNote: String { L10n.Now.Note.mayNeedYou }
    static var workingNote: String { L10n.Now.Note.working }
    /// The two MCP calls that put a row here, by their protocol names. Not
    /// copy: an agent's author greps for exactly these.
    static let doneNote = "notify(done) / tasks.complete"

    static var columnProject: String { L10n.Common.project.uppercased() }
    static var columnHarness: String { L10n.Common.harness.uppercased() }
    static var columnDoing: String { L10n.Now.Column.doing.uppercased() }
    static var columnTurn: String { L10n.Now.Column.turn.uppercased() }
    static var columnContext: String { L10n.Common.context.uppercased() }

    static var open: String { L10n.Now.openArrow }
    static var openQuiet: String { L10n.Common.open }
    static var markSeen: String { L10n.Now.markSeen }
    static var openTask: String { L10n.Now.taskArrow }

    static func more(_ count: Int) -> String { L10n.Now.more(count: count) }
    static var fewer: String { L10n.Now.fewer }
    static func idle(_ count: Int, isOpen: Bool) -> String {
        isOpen ? L10n.Now.IdleFold.hide(count: count) : L10n.Now.IdleFold.show(count: count)
    }

    static var allClear: String { L10n.Now.allClear }

    // MARK: Lines

    static var waitingPermission: String { L10n.Now.waitingPermission }
    static var waitingAnswer: String { L10n.Now.waitingAnswer }
    static var blockedTask: String { L10n.Now.blockedTask }

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
        case .staleSession: L10n.Now.Watch.staleSession
        case .longTool:
            L10n.Now.Watch.longTool(
                tool: tool ?? L10n.Now.Watch.aTool,
                minutes: Int(CollaborationSignals.longToolAfter / 60)
            )
        case .contextPressure: L10n.Now.Watch.contextPressure(percent: 90)
        case .sharedDirectory: L10n.Now.Watch.sharedDirectory
        case .sharedBranch: L10n.Now.Watch.sharedBranch
        case .orphanedClaim: L10n.Now.Watch.orphanedClaim
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
