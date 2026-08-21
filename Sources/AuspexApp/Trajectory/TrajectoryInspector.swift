import AgentSessionLive
import AppKit
import AuspexCore
import SwiftUI

/// The panel on the right of the trajectory: everything about one step.
///
/// Three tabs, because there are three different questions a person opens a
/// step with. *Summary* is the numbers — where it came from, what it cost, how
/// long the model took to answer. *Preview* is the text, in full, selectable.
/// *Raw* is the original record, read back off the harness's own transcript.
///
/// Every unknown is an em dash. A harness that does not report token counts
/// gets "—" and not a zero, because a zero is a claim and this pane is not
/// allowed to make one — see `docs/ARCHITECTURE.md`, "No inference of missing
/// data".
struct TrajectoryInspector: View {
    @Bindable var model: TrajectoryModel
    /// The session's brief, for the one piece of context a step does not carry
    /// on its own: what the whole session was asked to do.
    var brief: SessionBrief?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if model.selectedStep != nil {
                tabs
                BoardScroll {
                    body(for: model.tab)
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                empty
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(AuspexPalette.bg0)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 8) {
            if let step = model.selectedStep {
                TrajectoryRoleChip(role: step.role, isError: step.isError)
                Text("Turn \(step.turn)")
                    .font(AuspexType.labelSmall)
                    .foregroundStyle(AuspexPalette.text3)
                Text("Step \(step.index + 1)")
                    .font(AuspexType.labelSmall)
                    .foregroundStyle(AuspexPalette.text3)
            } else {
                Text("Inspector")
                    .auspexLabel(AuspexType.labelLarge)
                    .foregroundStyle(AuspexPalette.text3)
            }
            Spacer(minLength: 4)
            Button { model.showsInspector = false } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(AuspexPalette.text3)
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.auspex)
            .help("Close the inspector (Esc)")
        }
        .padding(.horizontal, 14)
        .frame(height: 40)
        .overlay(alignment: .bottom) {
            Rectangle().fill(AuspexPalette.line).frame(height: 1)
        }
    }

    private var tabs: some View {
        HStack(spacing: 4) {
            ForEach(TrajectoryTab.allCases) { tab in
                Button { model.tab = tab } label: {
                    Text(tab.title)
                        .font(AuspexType.pill)
                        .foregroundStyle(
                            model.tab == tab ? AuspexPalette.text : AuspexPalette.text3
                        )
                        .padding(.horizontal, 9)
                        .frame(height: 22)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(model.tab == tab ? AuspexPalette.selection : .clear)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.auspex)
                .accessibilityAddTraits(model.tab == tab ? [.isButton, .isSelected] : .isButton)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .overlay(alignment: .bottom) {
            Rectangle().fill(AuspexPalette.line).frame(height: 1)
        }
    }

    @ViewBuilder
    private func body(for tab: TrajectoryTab) -> some View {
        switch tab {
        case .summary: summary
        case .preview: preview
        case .raw: raw
        }
    }

    // MARK: Summary

    @ViewBuilder
    private var summary: some View {
        if let step = model.selectedStep {
            VStack(alignment: .leading, spacing: 16) {
                block("Source") {
                    fact("Request", step.request > 0 ? "#\(step.request)" : "—")
                    fact("Turn", step.turn == 0 ? "before turn 1" : "\(step.turn)")
                    fact("Started", Self.clock.string(from: step.start))
                    fact("Record", step.raw.map { ($0.path as NSString).lastPathComponent } ?? "—")
                }
                block("Status") {
                    fact(
                        "Outcome",
                        step.isError ? "failed" : (step.end == nil ? "no end recorded" : "ok"),
                        tint: step.isError ? AuspexPalette.statePermission : nil
                    )
                    fact("Duration", step.duration.map(DurationFormat.short) ?? "—")
                    if let id = step.toolCallID { fact("Call id", id) }
                }
                block("Tokens") {
                    fact("In", step.tokens.map { TokenFormat.compact($0.input) } ?? "—")
                    fact("Out", step.tokens.map { TokenFormat.compact($0.output) } ?? "—")
                    fact("Cached", step.tokens.map { TokenFormat.compact($0.cached) } ?? "—")
                }
                requestTiming
                previewBlock(for: step)
                if let asked = brief?.firstPrompt {
                    block("Asked") {
                        Text(asked)
                            .font(AuspexType.body)
                            .foregroundStyle(AuspexPalette.text2)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                }
            }
        }
    }

    /// The five numbers a DevTools request row carries, for the model call
    /// this step belongs to.
    @ViewBuilder
    private var requestTiming: some View {
        block("Request timing") {
            if let request = model.selectedRequest {
                fact("Started", Self.clock.string(from: request.started))
                fact("Total duration", request.duration.map(DurationFormat.short) ?? "—")
                fact("TTFT", request.timeToFirstToken.map(DurationFormat.short) ?? "—")
                fact("Generation", request.generation.map(DurationFormat.short) ?? "—")
                fact(
                    "Throughput",
                    request.throughput.map { String(format: "%.1f tok/s", $0) } ?? "—"
                )
            } else {
                Text("This step happened outside a model request.")
                    .font(AuspexType.caption)
                    .foregroundStyle(AuspexPalette.text3)
            }
        }
    }

    @ViewBuilder
    private func previewBlock(for step: TrajectoryStep) -> some View {
        block("Preview") {
            Text(step.title)
                .font(AuspexType.body)
                .foregroundStyle(AuspexPalette.text)
                .lineLimit(4)
                .fixedSize(horizontal: false, vertical: true)
            if let args = step.argsPreview {
                Text(args)
                    .font(AuspexType.monoSmall)
                    .foregroundStyle(AuspexPalette.text3)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let result = step.resultPreview {
                Text("→ \(result)")
                    .font(AuspexType.monoSmall)
                    .foregroundStyle(
                        step.isError ? AuspexPalette.statePermission : AuspexPalette.text2
                    )
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: Preview

    @ViewBuilder
    private var preview: some View {
        if let step = model.selectedStep {
            VStack(alignment: .leading, spacing: 12) {
                if let body = step.body {
                    well(body, font: step.role == .tool ? AuspexType.monoBlock : AuspexType.body)
                } else {
                    well(step.title, font: AuspexType.body)
                    Text(
                        "This harness recorded only a preview of this step; there is no full text "
                            + "in the log to show."
                    )
                    .font(AuspexType.caption)
                    .foregroundStyle(AuspexPalette.text3)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // MARK: Raw

    @ViewBuilder
    private var raw: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                if let path = model.selectedStep?.raw?.path {
                    Text(PathDisplay.abbreviate(path))
                        .font(AuspexType.monoSmall)
                        .foregroundStyle(AuspexPalette.text3)
                        .lineLimit(1)
                        .truncationMode(.head)
                        .textSelection(.enabled)
                }
                Spacer(minLength: 4)
                if let text = model.raw?.text {
                    Button("Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(text, forType: .string)
                    }
                    .buttonStyle(.link)
                    .font(AuspexType.caption)
                }
            }
            if model.isLoadingRaw {
                Text("Reading the record…")
                    .font(AuspexType.caption)
                    .foregroundStyle(AuspexPalette.text3)
            } else if let text = model.raw?.text {
                well(text, font: AuspexType.monoBlock)
            } else if let message = model.raw?.message {
                Text(message)
                    .font(AuspexType.caption)
                    .foregroundStyle(AuspexPalette.text3)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Nothing has been read yet.")
                    .font(AuspexType.caption)
                    .foregroundStyle(AuspexPalette.text3)
            }
        }
        .task(id: model.selectedID) { model.loadRaw() }
    }

    // MARK: Pieces

    private func block(
        _ title: String,
        @ViewBuilder content: () -> some View
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .auspexLabel(AuspexType.labelSmall)
                .foregroundStyle(AuspexPalette.text3)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func fact(_ key: String, _ value: String, tint: Color? = nil) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(key)
                .font(AuspexType.caption)
                .foregroundStyle(AuspexPalette.text3)
                .frame(width: 100, alignment: .leading)
            Text(value)
                .font(AuspexType.monoSmall)
                .auspexTabularDigits()
                .foregroundStyle(tint ?? AuspexPalette.text)
                .lineLimit(2)
                .truncationMode(.middle)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    private func well(_ text: String, font: Font) -> some View {
        Text(text)
            .font(font)
            .foregroundStyle(AuspexPalette.text2)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous).fill(AuspexPalette.bg2)
            )
    }

    private var empty: some View {
        EmptyStateView(
            title: "Nothing selected",
            detail: "Click a row, or a bar on the timeline, to take a step apart."
        )
        .centredInPane()
    }

    private static let clock: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()
}
