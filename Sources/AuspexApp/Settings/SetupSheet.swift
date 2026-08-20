import AgentSessionKit
import AuspexCore
import SwiftUI

/// The one-click setup, offered once on first launch and reachable afterwards.
///
/// ## Why a sheet, and why only once
///
/// Everything Auspex does works without this: the passive layer reads the
/// stores it can already see, and a person who never opens this sheet still
/// gets a live board. What the sheet adds is the *enrichment* — agents that can
/// call for you, and a task board they keep honest — and that costs writes into
/// other tools' config files, which is the one thing this app otherwise never
/// does. So it is an offer, made once, with every file named, every box off by
/// default, and "Skip for now" always available.
///
/// A person who skips is not asked again. Re-asking somebody who already said
/// no is what teaches people to dismiss dialogs without reading them.
struct SetupSheet: View {
    @Bindable var model: SetupModel
    let detected: Set<Harness>
    let socketPath: String?
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().overlay(AuspexPalette.line)
            BoardScroll {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(model.groups) { group in
                        SetupGroupView(group: group, model: model, detected: detected)
                    }
                }
                .padding(16)
            }
            Divider().overlay(AuspexPalette.line)
            footer
        }
        .frame(width: 640, height: 560)
        .background(AuspexPalette.bg0)
        .preferredColorScheme(.dark)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 9) {
                AuspexMark(size: 24)
                Text("Let your agents talk back")
                    .font(AuspexType.paneTitle)
                    .foregroundStyle(AuspexPalette.text)
            }
            Text(
                "Auspex already watches every agent session on this Mac by reading "
                    + "the files they write. These add the two parts reading cannot do: "
                    + "an MCP server, so an agent can call you when it needs you and "
                    + "claim the task it was given — and hooks, so a harness can say it "
                    + "is waiting for your permission, which none of them write down."
            )
            .font(AuspexType.body)
            .foregroundStyle(AuspexPalette.text2)
            .fixedSize(horizontal: false, vertical: true)
            Text(
                "Every box is off until you tick it. Each one names the file it "
                    + "writes to, writes only inside a fenced block Auspex owns, backs "
                    + "the file up to ~/.auspex/backups/ first, and can be undone from "
                    + "the Harnesses page."
            )
            .font(AuspexType.caption)
            .foregroundStyle(AuspexPalette.text3)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let summary = model.summary {
                Text(summary)
                    .font(AuspexType.caption)
                    .foregroundStyle(AuspexPalette.text2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let socketPath {
                Text("Serving \(socketPath)")
                    .font(AuspexType.monoSmall)
                    .foregroundStyle(AuspexPalette.text3)
                    .lineLimit(1)
                    .truncationMode(.middle)
            } else {
                Text("The MCP socket is not being served, so nothing will answer yet.")
                    .font(AuspexType.caption)
                    .foregroundStyle(AuspexPalette.stateStale)
            }
            HStack(spacing: 10) {
                Button("Select all") { model.selectEverythingActionable() }
                    .buttonStyle(.plain)
                    .font(AuspexType.pill)
                    .foregroundStyle(AuspexPalette.text3)
                    .disabled(model.actionableCount == 0)
                Spacer(minLength: 8)
                Button("Skip for now") {
                    model.skip()
                    onClose()
                }
                .keyboardShortcut(.cancelAction)
                Button(model.selected.isEmpty ? "Install" : "Install \(model.selected.count)") {
                    Task {
                        await model.install(detected: detected)
                        onClose()
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(model.selected.isEmpty || model.isWorking)
            }
        }
        .padding(16)
    }
}

/// One harness's block of rows.
private struct SetupGroupView: View {
    let group: SetupModel.HarnessGroup
    @Bindable var model: SetupModel
    let detected: Set<Harness>

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                HarnessBadge(harness: group.harness, size: 20)
                Text(group.harness.displayName)
                    .font(AuspexType.rowStrong)
                    .foregroundStyle(AuspexPalette.text)
                if !group.isDetected {
                    Text("not detected")
                        .auspexLabel(AuspexType.labelSmall)
                        .foregroundStyle(AuspexPalette.text3)
                }
                Spacer(minLength: 0)
            }
            ForEach(group.rows) { row in
                SetupRowView(row: row, model: model, detected: detected)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .panelChrome()
        .opacity(group.isDetected ? 1 : 0.72)
    }
}

/// One thing that can be written, and where.
private struct SetupRowView: View {
    let row: SetupModel.Row
    @Bindable var model: SetupModel
    let detected: Set<Harness>

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            checkbox
            VStack(alignment: .leading, spacing: 2) {
                Text(row.piece.title)
                    .font(AuspexType.body)
                    .foregroundStyle(isEnabled ? AuspexPalette.text : AuspexPalette.text3)
                Text(row.piece.explanation)
                    .font(AuspexType.caption)
                    .foregroundStyle(AuspexPalette.text3)
                    .fixedSize(horizontal: false, vertical: true)
                if let path = row.displayPath {
                    Text(path)
                        .font(AuspexType.monoSmall)
                        .foregroundStyle(AuspexPalette.text3)
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                if let detail = row.detail {
                    Text(detail)
                        .font(AuspexType.monoSmall)
                        .foregroundStyle(AuspexPalette.text3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let note = stateNote {
                    Text(note)
                        .font(AuspexType.caption)
                        .foregroundStyle(stateColor)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 4)
            if row.isInstalled {
                Button("Remove") {
                    Task { await model.uninstall(row, detected: detected) }
                }
                .buttonStyle(.plain)
                .font(AuspexType.pill)
                .foregroundStyle(AuspexPalette.text3)
                .disabled(model.isWorking)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { toggle() }
    }

    private var isEnabled: Bool { row.isActionable }

    private var checkbox: some View {
        Image(systemName: checkboxSymbol)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(checkboxColor)
            .frame(width: 16, height: 16)
            .padding(.top, 1)
    }

    private var checkboxSymbol: String {
        if case .installed = row.state { return "checkmark.square.fill" }
        if !isEnabled { return "minus.square" }
        return model.selected.contains(row.id) ? "checkmark.square.fill" : "square"
    }

    private var checkboxColor: Color {
        if case .installed = row.state { return AuspexPalette.stateWriting }
        if !isEnabled { return AuspexPalette.line2 }
        return model.selected.contains(row.id)
            ? AuspexPalette.stateThinking
            : AuspexPalette.text3
    }

    private var stateNote: String? {
        switch row.state {
        case .installed: "Installed."
        case let .installedElsewhere(what): "Already there, pointing at \(what). Ticking this replaces it."
        case let .unavailable(reason): reason
        case let .unreadable(reason): reason
        case .absent: nil
        }
    }

    private var stateColor: Color {
        switch row.state {
        case .installed: AuspexPalette.stateWriting
        case .installedElsewhere: AuspexPalette.stateStale
        case .unreadable: AuspexPalette.statePermission
        case .unavailable, .absent: AuspexPalette.text3
        }
    }

    private func toggle() {
        guard isEnabled, !model.isWorking else { return }
        if model.selected.contains(row.id) {
            model.selected.remove(row.id)
        } else {
            model.selected.insert(row.id)
        }
    }
}
