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
                        sectionTitle(L10n.CatchUp.yourQueue, count: model.humanWorkQueue.items.count)
                        ForEach(model.humanWorkQueue.items) { item in
                            CapsuleRow(
                                capsule: item.capsule,
                                eyebrow: queueLabel(item),
                                explanation: item.orderingReason,
                                tone: queueTone(item.reason),
                                onOpen: { onOpen(item.capsule.id, item.capsule.leadSession) }
                            )
                        }
                    }

                    if !otherChanges.isEmpty {
                        sectionTitle(L10n.CatchUp.otherChanges, count: otherChanges.count)
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
                        sectionTitle(L10n.CatchUp.watchSignals, count: model.watchSignals.count)
                        Text(L10n.CatchUp.watchSignalsNote)
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
                            title: L10n.CatchUp.caughtUp,
                            detail: L10n.CatchUp.caughtUpDetail
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
        // Every interactive control here is drawn by Auspex. Keyboard focus
        // uses the style's thin accent hairline, never AppKit's blue block.
        .auspexControlFocus()
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(L10n.CatchUp.title)
                    .font(AuspexType.paneTitle)
                    .foregroundStyle(AuspexPalette.text)
                Text(L10n.CatchUp.since(
                    time: AppLocale.relativeDateTimeFormatter()
                        .localizedString(for: model.catchUp.since, relativeTo: Date())
                ))
                    .font(AuspexType.caption)
                    .foregroundStyle(AuspexPalette.text3)
            }
            Spacer(minLength: 8)
            Button(L10n.CatchUp.markCaughtUp) {
                onMarkCaughtUp()
            }
            .buttonStyle(.auspex)
            Button(L10n.Common.done) { model.isCatchUpOpen = false }
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
        case .needsYou: L10n.Now.needsYou
        case .takeover: L10n.CatchUp.Reason.takeover
        case .review: L10n.CatchUp.Reason.review
        case .orphanedClaim: L10n.CatchUp.Reason.orphanedClaim
        }
    }

    private func changeLabel(_ kind: CatchUpSnapshot.Item.Kind) -> String {
        switch kind {
        case .needsYou: L10n.Now.needsYou
        case .takeover: L10n.CatchUp.Reason.takeover
        case .review: L10n.CatchUp.Reason.review
        case .orphanedClaim: L10n.CatchUp.Reason.orphanedClaim
        case .completed: L10n.CatchUp.Change.completed
        case .started: L10n.CatchUp.Change.started
        case .changed: L10n.CatchUp.Change.changed
        }
    }

    private func queueTone(_ reason: HumanWorkQueue.Item.Reason) -> Color {
        switch reason {
        case .needsYou, .takeover: AuspexPalette.statePermission
        case .review: AuspexPalette.stateWriting
        case .orphanedClaim: AuspexPalette.stateStale
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
                        Text(L10n.CatchUp.sessions(count: capsule.memberCount))
                            .font(AuspexType.caption)
                            .foregroundStyle(AuspexPalette.text3)
                    }
                }
                Text(capsule.title)
                    .font(AuspexType.rowStrong)
                    .foregroundStyle(AuspexPalette.text)
                    .lineLimit(2)
                capsuleLine(L10n.CatchUp.Line.goal, capsule.goal)
                if let current = capsule.current { capsuleLine(L10n.CatchUp.Line.now, current) }
                if let recent = capsule.recentOutcome { capsuleLine(L10n.CatchUp.Line.latest, recent) }
                if let next = capsule.nextAction { capsuleLine(L10n.CatchUp.Line.next, next) }
                if let risk = capsule.risk {
                    capsuleLine(L10n.CatchUp.Line.risk, risk, tint: AuspexPalette.stateStale)
                }
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
        .buttonStyle(.auspex(cornerRadius: 9))
    }

    private var phaseLabel: String {
        switch capsule.phase {
        case .notStarted: L10n.CatchUp.Phase.notStarted
        case .working: L10n.Board.Bucket.working
        case .idle: L10n.Board.Bucket.idle
        case .blocked: L10n.CatchUp.Phase.blocked
        case .review: L10n.CatchUp.Phase.review
        case .done: L10n.CatchUp.Phase.done
        case .ended: L10n.Board.Bucket.ended
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
        case .observed: L10n.CatchUp.Source.observed
        case .selfReported: L10n.CatchUp.Source.reported
        case .derived: L10n.CatchUp.Source.derived
        case .recorded: L10n.CatchUp.Source.task
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
                    Text(L10n.CatchUp.Signal.confidence(confidence: confidenceLabel))
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
        .buttonStyle(.auspex(cornerRadius: 8))
    }

    private var label: String {
        switch signal.kind {
        case .orphanedClaim: L10n.CatchUp.Reason.orphanedClaim
        case .staleSession: L10n.CatchUp.Signal.staleSession
        case .longTool: L10n.CatchUp.Signal.longTool
        case .contextPressure: L10n.CatchUp.Signal.contextPressure
        case .sharedDirectory: L10n.CatchUp.Signal.sharedDirectory
        case .sharedBranch: L10n.CatchUp.Signal.sharedBranch
        }
    }

    private var confidenceLabel: String {
        switch signal.confidence {
        case .high: L10n.CatchUp.Confidence.high
        case .medium: L10n.CatchUp.Confidence.medium
        }
    }
}
