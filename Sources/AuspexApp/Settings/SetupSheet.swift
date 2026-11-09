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
    let catalog: ProjectCatalogModel
    let loginItem: LoginItemController
    let detected: Set<Harness>
    let socketPath: String?
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().overlay(AuspexPalette.line)
            BoardScroll {
                LazyVStack(alignment: .leading, spacing: 10) {
                    StartupSetupRow(catalog: catalog, loginItem: loginItem)
                    ForEach(model.groups) { group in
                        SetupGroupView(group: group, model: model, detected: detected)
                    }
                }
                .padding(16)
            }
            Divider().overlay(AuspexPalette.line)
            footer
        }
        // A range rather than a number. The board's window may be as short as
        // 560 points, and a sheet with a hard 560 pt height on a 560 pt window
        // covers the thing it is a sheet *over* — including the title bar it
        // is supposed to hang from. The middle of the sheet is a scroll view,
        // so it has somewhere to give.
        .frame(width: 640)
        .frame(minHeight: 340, idealHeight: 540, maxHeight: 620)
        .background(AuspexPalette.bg0)
        .onAppear { loginItem.refresh() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 9) {
                AuspexMark(size: 24)
                Text(L10n.Setup.title)
                    .font(AuspexType.paneTitle)
                    .foregroundStyle(AuspexPalette.text)
            }
            Text(L10n.Setup.intro)
            .font(AuspexType.body)
            .foregroundStyle(AuspexPalette.text2)
            .fixedSize(horizontal: false, vertical: true)
            Text(L10n.Setup.safety)
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
                Text(L10n.Setup.serving(path: socketPath))
                    .font(AuspexType.monoSmall)
                    .foregroundStyle(AuspexPalette.text3)
                    .lineLimit(1)
                    .truncationMode(.middle)
            } else {
                Text(L10n.Setup.notServing)
                    .font(AuspexType.caption)
                    .foregroundStyle(AuspexPalette.stateStale)
            }
            HStack(spacing: 10) {
                Button(L10n.Setup.selectAll) { model.selectEverythingActionable() }
                    .buttonStyle(.auspex)
                    .font(AuspexType.pill)
                    .foregroundStyle(AuspexPalette.text3)
                    .disabled(model.actionableCount == 0)
                Spacer(minLength: 8)
                Button(L10n.Setup.skip) {
                    model.skip()
                    onClose()
                }
                .keyboardShortcut(.cancelAction)
                Button(model.selected.isEmpty ? L10n.Common.done : L10n.Setup.install(count: model.selected.count)) {
                    guard !model.selected.isEmpty else {
                        onClose()
                        return
                    }
                    Task {
                        await model.install(detected: detected)
                        onClose()
                    }
                }
                .disabled(model.isWorking)
            }
        }
        .padding(16)
    }
}

/// Login launch sits beside the harness integrations because a monitoring
/// board is only useful after restart if it is already there. Unlike the
/// batched config installs below, this Toggle is itself the person's explicit
/// ServiceManagement gesture and takes effect immediately.
private struct StartupSetupRow: View {
    let catalog: ProjectCatalogModel
    let loginItem: LoginItemController

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Toggle(
                isOn: Binding(
                    get: { loginItem.isOn(desired: catalog.launchAtLogin) },
                    set: { enabled in
                        guard loginItem.setEnabled(enabled) else { return }
                        catalog.setLaunchAtLogin(
                            enabled,
                            registration: loginItem.registrationForPersistence
                        )
                    }
                )
            ) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(L10n.Setup.keepWatching)
                        .font(AuspexType.body)
                        .foregroundStyle(AuspexPalette.text)
                    Text(loginItem.statusDescription)
                        .font(AuspexType.caption)
                        .foregroundStyle(AuspexPalette.text3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .toggleStyle(.checkbox)

            Text(L10n.Setup.loginNote)
            .font(AuspexType.caption)
            .foregroundStyle(AuspexPalette.text3)
            .fixedSize(horizontal: false, vertical: true)

            if loginItem.status == .requiresApproval {
                Button(L10n.Settings.General.openLoginItems, systemImage: "gear") {
                    loginItem.openSystemSettings()
                }
                .buttonStyle(.auspex)
                .controlSize(.small)
            }

            if let error = loginItem.errorDescription {
                Text(L10n.Settings.General.loginError(error: error))
                    .font(AuspexType.caption)
                    .foregroundStyle(AuspexPalette.statePermission)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let reconciliation = loginItem.reconciliationDescription {
                Text(reconciliation)
                    .font(AuspexType.caption)
                    .foregroundStyle(AuspexPalette.text3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .panelChrome()
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
                    Text(L10n.Setup.notDetected)
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
                Text(row.piece.localizedTitle)
                    .font(AuspexType.body)
                    .foregroundStyle(isEnabled ? AuspexPalette.text : AuspexPalette.text3)
                Text(row.piece.localizedExplanation)
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
                if let note = row.note {
                    Text(note)
                        .font(AuspexType.caption)
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
                Button(L10n.Common.remove) {
                    Task { await model.uninstall(row, detected: detected) }
                }
                .buttonStyle(.auspex)
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
        case .installed: L10n.Setup.State.installed
        case let .installedElsewhere(what):
            row.piece == .coordinationSkill
                ? L10n.Setup.State.ownedInstalled(what: what)
                : L10n.Setup.State.elsewhere(what: what)
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
