import AgentSessionLive
import AuspexCore
import SwiftUI

/// The 30-second answer to "what changed while I was elsewhere?"
///
/// The panel draws only flat values assembled off the main actor. It never
/// reads a transcript, runs a summarizer, or derives a task inside a view body.
struct CatchUpPanel: View {
    @Bindable var model: LiveBoardModel
    let onOpen: (String, SessionKey) -> Void
    let onMarkCaughtUp: () -> Void

    private var queueIDs: Set<String> { Set(model.humanWorkQueue.items.map(\.id)) }
    private var otherChanges: [CatchUpSnapshot.Item] {
        model.catchUp.items.filter { !queueIDs.contains($0.id) }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(AuspexPalette.line)
            BoardScroll {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if !model.humanWorkQueue.items.isEmpty {
                        sectionTitle("Your queue", count: model.humanWorkQueue.items.count)
                        ForEach(model.humanWorkQueue.items) { item in
                            CapsuleRow(
                                capsule: item.capsule,
                                eyebrow: queueLabel(item),
                                explanation: item.orderingReason,
                                tone: item.reason == .needsYou
                                    ? AuspexPalette.statePermission
                                    : AuspexPalette.stateWriting,
                                onOpen: { onOpen(item.capsule.id, item.capsule.leadSession) }
                            )
                        }
                    }

                    if !otherChanges.isEmpty {
                        sectionTitle("Other changes", count: otherChanges.count)
                        ForEach(otherChanges) { item in
                            CapsuleRow(
                                capsule: item.capsule,
                                eyebrow: changeLabel(item.kind),
                                explanation: nil,
                                tone: AuspexPalette.stateThinking,
                                onOpen: { onOpen(item.capsule.id, item.capsule.leadSession) }
                            )
                        }
                    }

                    if !model.watchSignals.isEmpty {
                        sectionTitle("Watch signals", count: model.watchSignals.count)
                        Text(
                            "Observed or inferred risks worth a glance. They are not requests "
                                + "from an agent and never raise a notification by themselves."
                        )
                        .font(AuspexType.caption)
                        .foregroundStyle(AuspexPalette.text3)
                        .fixedSize(horizontal: false, vertical: true)
                        ForEach(model.watchSignals) { signal in
                            WatchSignalRow(signal: signal) {
                                guard let id = signal.unitIDs.first,
                                      let unit = model.unit(withID: id) else { return }
                                onOpen(unit.id, unit.lead.key)
                            }
                        }
                    }

                    if model.humanWorkQueue.items.isEmpty,
                       otherChanges.isEmpty,
                       model.watchSignals.isEmpty {
                        EmptyStateView(
                            title: "Caught up",
                            detail: "No material changes or watch signals are waiting."
                        )
                        .padding(.vertical, 48)
                    }
                }
                .padding(18)
            }
        }
        .frame(width: 720)
        .frame(minHeight: 420, idealHeight: 620, maxHeight: 720)
        .background(AuspexPalette.bg0)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Catch up")
                    .font(AuspexType.paneTitle)
                    .foregroundStyle(AuspexPalette.text)
                Text("Changes since \(model.catchUp.since, style: .relative)")
                    .font(AuspexType.caption)
                    .foregroundStyle(AuspexPalette.text3)
            }
            Spacer(minLength: 8)
            Button("Mark caught up") {
                onMarkCaughtUp()
            }
            .buttonStyle(.auspex)
            Button("Done") { model.isCatchUpOpen = false }
                .buttonStyle(.auspex)
                .keyboardShortcut(.cancelAction)
        }
        .padding(16)
    }

    private func sectionTitle(_ title: String, count: Int) -> some View {
        HStack(spacing: 7) {
            Text(title).font(AuspexType.rowStrong)
            Text("\(count)")
                .font(AuspexType.monoCount)
                .foregroundStyle(AuspexPalette.text3)
        }
        .foregroundStyle(AuspexPalette.text)
    }

    private func queueLabel(_ item: HumanWorkQueue.Item) -> String {
        switch item.reason {
        case .needsYou: "Needs you"
        case .review: "Review"
        case .orphanedClaim: "Orphaned claim"
        }
    }

    private func changeLabel(_ kind: CatchUpSnapshot.Item.Kind) -> String {
        switch kind {
        case .needsYou: "Needs you"
        case .review: "Review"
        case .orphanedClaim: "Orphaned claim"
        case .completed: "Completed"
        case .started: "Started"
        case .changed: "Changed"
        }
    }
}

private struct CapsuleRow: View {
    let capsule: TaskCapsule
    let eyebrow: String
    let explanation: String?
    let tone: Color
    let onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Text(eyebrow.uppercased())
                        .font(AuspexType.labelSmall)
                        .foregroundStyle(tone)
                    Text(capsule.shortID)
                        .font(AuspexType.monoSmall)
                        .foregroundStyle(AuspexPalette.text3)
                    Text(phaseLabel)
                        .auspexLabel(AuspexType.labelSmall)
                        .foregroundStyle(AuspexPalette.text3)
                    Spacer(minLength: 0)
                    if capsule.memberCount > 1 {
                        Text("\(capsule.memberCount) sessions")
                            .font(AuspexType.caption)
                            .foregroundStyle(AuspexPalette.text3)
                    }
                }
                Text(capsule.title)
                    .font(AuspexType.rowStrong)
                    .foregroundStyle(AuspexPalette.text)
                    .lineLimit(2)
                capsuleLine("goal", capsule.goal)
                if let current = capsule.current { capsuleLine("now", current) }
                if let recent = capsule.recentOutcome { capsuleLine("latest", recent) }
                if let next = capsule.nextAction { capsuleLine("next", next) }
                if let risk = capsule.risk { capsuleLine("risk", risk, tint: AuspexPalette.stateStale) }
                if let explanation {
                    Text(explanation)
                        .font(AuspexType.caption)
                        .foregroundStyle(AuspexPalette.text3)
                        .lineLimit(2)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(AuspexPalette.bg1)
                    .overlay(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .strokeBorder(tone.opacity(0.32), lineWidth: 1)
                    )
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var phaseLabel: String {
        switch capsule.phase {
        case .notStarted: "not started"
        case .working: "working"
        case .idle: "idle"
        case .blocked: "blocked"
        case .review: "review"
        case .done: "done"
        case .ended: "ended"
        }
    }

    private func capsuleLine(_ key: String, _ line: TaskCapsule.Line, tint: Color? = nil) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Text(key)
                .font(AuspexType.monoSmall)
                .foregroundStyle(tint ?? AuspexPalette.text3)
                .frame(width: 42, alignment: .leading)
            Text(line.text)
                .font(AuspexType.caption)
                .foregroundStyle(AuspexPalette.text2)
                .lineLimit(2)
            Spacer(minLength: 4)
            Text(sourceLabel(line.source))
                .font(AuspexType.labelSmall)
                .foregroundStyle(AuspexPalette.text3)
        }
    }

    private func sourceLabel(_ source: TaskCapsule.Source) -> String {
        switch source {
        case .observed: "observed"
        case .selfReported: "reported"
        case .derived: "derived"
        case .recorded: "task"
        }
    }
}

private struct WatchSignalRow: View {
    let signal: WatchSignal
    let onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            HStack(alignment: .top, spacing: 9) {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(AuspexPalette.stateStale)
                VStack(alignment: .leading, spacing: 3) {
                    Text(label)
                        .font(AuspexType.rowStrong)
                        .foregroundStyle(AuspexPalette.text)
                    Text(signal.message)
                        .font(AuspexType.caption)
                        .foregroundStyle(AuspexPalette.text2)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("\(signal.confidence.rawValue) confidence · not an attention request")
                        .font(AuspexType.labelSmall)
                        .foregroundStyle(AuspexPalette.text3)
                }
                Spacer(minLength: 0)
            }
            .padding(11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(AuspexPalette.stateStale.opacity(0.06))
            )
        }
        .buttonStyle(.plain)
    }

    private var label: String {
        switch signal.kind {
        case .orphanedClaim: "Orphaned claim"
        case .staleSession: "Stale session"
        case .longTool: "Long-running tool"
        case .contextPressure: "Context pressure"
        case .sharedDirectory: "Shared working directory"
        case .sharedBranch: "Shared branch"
        }
    }
}
