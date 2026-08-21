import AgentSessionKit
import AuspexCore
import SwiftUI

/// Settings → Agents: what Auspex has written into each harness, and the way
/// to change it.
///
/// The same rows the setup sheet offers, in the place a person goes when they
/// want to *change their mind* rather than to get started. Removing is a button
/// on every installed row, because an install a person cannot see how to undo
/// is an install they should not have been offered.
struct AgentsSettingsView: View {
    @Bindable var model: SetupModel
    /// The user layer, for the one preference on this pane that is about what
    /// agents *say* rather than about what is installed.
    @Bindable var catalog: ProjectCatalogModel
    let detected: Set<Harness>
    let socketPath: String?
    let onOpenSetup: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                notifications
                ForEach(model.groups) { group in
                    AgentsSettingsGroup(group: group, model: model, detected: detected)
                }
                note
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(AuspexPalette.canvas)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("Agents")
                    .font(AuspexType.paneTitle)
                    .foregroundStyle(AuspexPalette.text)
                Spacer(minLength: 8)
                Button("Open setup…", action: onOpenSetup)
                    .buttonStyle(.auspex)
                    .font(AuspexType.pill)
                    .foregroundStyle(AuspexPalette.stateThinking)
            }
            Text(
                socketPath.map { "Auspex is serving its MCP server on \($0)." }
                    ?? "Auspex is not serving its MCP server in this process."
            )
            .font(AuspexType.body)
            .foregroundStyle(AuspexPalette.text2)
            if let summary = model.summary {
                Text(summary)
                    .font(AuspexType.caption)
                    .foregroundStyle(AuspexPalette.text3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// The one switch, and the one that is deliberately not there.
    ///
    /// A person running a dozen agents gets two kinds of interruption from
    /// this app, and they are worth very different amounts. *Somebody is stuck
    /// on you* is worth a banner every time — it will not resolve itself, and
    /// closing the gap between an agent stopping to ask and a person finding
    /// out is why the MCP surface exists at all. *Somebody finished* is good
    /// news that keeps, and twelve of those in an afternoon is twelve banners
    /// for things that could all have been read at once on the board.
    ///
    /// So the receipts get a switch and the calls do not. A settings pane with
    /// a switch for everything is a settings pane that has declined to have an
    /// opinion.
    private var notifications: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(isOn: Binding(
                get: { catalog.notifiesOnDone },
                set: { catalog.setNotifiesOnDone($0) }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Notify when an agent reports finishing")
                        .font(AuspexType.body)
                        .foregroundStyle(AuspexPalette.text)
                    Text(
                        "A session that is blocked on you always raises one. "
                            + "It will not get unstuck on its own."
                    )
                    .font(AuspexType.caption)
                    .foregroundStyle(AuspexPalette.text3)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
            .toggleStyle(.switch)
            .tint(AuspexPalette.stateWriting)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(AuspexPalette.panel)
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(AuspexPalette.line, lineWidth: 1)
                )
        )
    }

    private var note: some View {
        Text(
            "Auspex writes into a harness's own files only from here, only in a region "
                + "it owns — a block marked `>>> auspex >>>`, one `auspex` entry in a "
                + "JSON config, or the hook entries that run the Auspex binary — and "
                + "only after backing the file up to ~/.auspex/backups/. Removing takes "
                + "back exactly those and leaves everything else as it was."
        )
        .font(AuspexType.caption)
        .foregroundStyle(AuspexPalette.text3)
        .fixedSize(horizontal: false, vertical: true)
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(
                AuspexPalette.line,
                style: StrokeStyle(lineWidth: 1, dash: [4, 4])
            )
        )
    }
}

private struct AgentsSettingsGroup: View {
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
                HStack(alignment: .top, spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(row.piece.title)
                            .font(AuspexType.body)
                            .foregroundStyle(AuspexPalette.text)
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
                        if let note = row.note {
                            Text(note)
                                .font(AuspexType.caption)
                                .foregroundStyle(AuspexPalette.text3)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Spacer(minLength: 8)
                    action(for: row)
                }
                .padding(.vertical, 2)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .panelChrome()
        .opacity(group.isDetected ? 1 : 0.72)
    }

    @ViewBuilder
    private func action(for row: SetupModel.Row) -> some View {
        switch row.state {
        case .installed:
            HStack(spacing: 8) {
                Text("installed")
                    .font(AuspexType.pill)
                    .foregroundStyle(AuspexPalette.stateWriting)
                Button("Remove") {
                    Task { await model.uninstall(row, detected: detected) }
                }
                .buttonStyle(.auspex)
                .font(AuspexType.pill)
                .foregroundStyle(AuspexPalette.text3)
                .disabled(model.isWorking)
            }
        case .installedElsewhere:
            Button("Replace") {
                Task { await model.install(row, detected: detected) }
            }
            .buttonStyle(.auspex)
            .font(AuspexType.pill)
            .foregroundStyle(AuspexPalette.stateStale)
            .disabled(model.isWorking)
        case .absent:
            Button("Install") {
                Task { await model.install(row, detected: detected) }
            }
            .buttonStyle(.auspex)
            .font(AuspexType.pill)
            .foregroundStyle(AuspexPalette.stateThinking)
            .disabled(model.isWorking)
        case let .unavailable(reason), let .unreadable(reason):
            Text(reason)
                .font(AuspexType.caption)
                .foregroundStyle(AuspexPalette.text3)
                .frame(maxWidth: 240, alignment: .trailing)
                .multilineTextAlignment(.trailing)
        }
    }
}
