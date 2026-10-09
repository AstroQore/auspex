import AgentSessionKit
import AgentSessionLive
import AuspexCore
import Foundation

/// Every word the Now screen prints, in one place.
///
/// The screen was designed with its copy, and that copy is the design's: the
/// section headings in English capitals, everything a person reads in a row
/// or a button in Chinese. Keeping it here rather than scattered across the
/// views is what makes it one edit to change — and the obvious seam for a
/// strings table when the app grows one.
enum NowCopy {
    // MARK: Header

    static let title = "Now"
    static let needsYou = "需要你"
    static let mayNeedYou = "可能需要你"
    static let doneUnseen = "完成未看"
    static let stageAndLists = "办公室 + 清单"
    static let listsOnly = "只看清单"
    static let search = "搜索 session…"
    static let viewMode = "展示模式"

    static func status(time: String, live: Int, working: Int) -> String {
        "\(time) · \(live) live · \(working) working"
    }

    // MARK: Stage

    static let stageTag = "AVIARY"
    static let stageHint = "点人物 = 打开会话 · 悬停 = 当前动作"
    static let collapseStage = "收起办公室"
    static let legendWorking = "工作中"
    static let legendNeedsYou = "需要你"
    static let legendMayNeedYou = "可能需要你"
    static let legendIdle = "空闲"

    // MARK: Sections

    static let needsYouHeading = "NEEDS YOU"
    static let mayNeedYouHeading = "MAY NEED YOU"
    static let workingHeading = "WORKING"
    static let doneHeading = "DONE, UNSEEN"
    static let idleHeading = "IDLE"

    static let needsYouNote = "只认显式信号"
    static let mayNeedYouNote = "WatchSignal，独立一桶"
    static let workingNote = "一行一个根 session，子 agent 折叠"
    static let doneNote = "notify(done) / tasks.complete"

    static let columnProject = "项目"
    static let columnHarness = "HARNESS"
    static let columnDoing = "正在"
    static let columnTurn = "本轮 / 子 AGENT"
    static let columnContext = "CONTEXT"

    static let open = "打开 →"
    static let openQuiet = "打开"
    static let markSeen = "标记已看"
    static let openTask = "任务 →"

    static func more(_ count: Int) -> String { "还有 \(count) 个 →" }
    static let fewer = "收起"
    static func idle(_ count: Int, isOpen: Bool) -> String {
        "\(idleHeading) \(count) · \(isOpen ? "收起" : "折叠 →")"
    }

    static let allClear = "没有在跑的，也没有在等你的。"

    // MARK: Lines

    static let waitingPermission = "等待权限"
    static let waitingAnswer = "等待回答"
    static let blockedTask = "任务被标记为阻塞"

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
        case .staleSession: "活着，但没有新动静"
        case .longTool: "\(tool ?? "工具") 已运行超过 \(Int(CollaborationSignals.longToolAfter / 60)) 分钟"
        case .contextPressure: "context 已用掉 90% 以上"
        case .sharedDirectory: "共用工作目录"
        case .sharedBranch: "共用分支"
        case .orphanedClaim: "认领它的会话已结束"
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

    /// What a session is doing, as one short line: `WebSearch「Dots API」`.
    static func activity(_ activity: NowFrame.Activity, limit: Int) -> String {
        switch (activity.tool, activity.detail) {
        case let (tool?, detail?) where !detail.isEmpty:
            "\(tool)「\(PathDisplay.condense(detail, limit: limit))」"
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
