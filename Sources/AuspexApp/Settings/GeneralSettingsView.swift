import AuspexCore
import SwiftUI

/// Settings → General: whether the observer itself is present after login.
///
/// Auspex is useful precisely when nobody remembered to open it before
/// starting six agents, so login launch is a reliability setting rather than
/// a convenience. It remains opt-in and uses macOS's own Login Items service;
/// no LaunchAgent plist is written and no permission is inferred from merely
/// visiting this pane.
struct GeneralSettingsView: View {
    let catalog: ProjectCatalogModel
    let loginItem: LoginItemController

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            loginCard
            note
            languageCard
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear { loginItem.refresh() }
    }

    private var header: some View {
        Text(L10n.Settings.General.intro)
        .font(AuspexType.body)
        .foregroundStyle(AuspexPalette.textSecondary)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var loginCard: some View {
        VStack(alignment: .leading, spacing: 10) {
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
                    Text(L10n.Settings.General.launchAtLogin)
                        .font(AuspexType.body)
                        .foregroundStyle(AuspexPalette.textPrimary)
                    Text(loginItem.statusDescription)
                        .font(AuspexType.caption)
                        .foregroundStyle(AuspexPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .toggleStyle(.checkbox)

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
                    .foregroundStyle(AuspexPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(SettingsCard())
    }

    /// The interface language. Each language is labelled in itself — 简体中文,
    /// not "Simplified Chinese" — so somebody looking for their own language
    /// never has to read the one they are trying to leave to find it.
    private var languageCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L10n.Settings.Language.title)
                .auspexLabel(AuspexType.label)
                .foregroundStyle(AuspexPalette.textTertiary)

            Picker(
                L10n.Settings.Language.title,
                selection: Binding(
                    get: { catalog.language },
                    set: { catalog.setLanguage($0) }
                )
            ) {
                ForEach(AppLanguage.allCases) { language in
                    Text(language.endonym ?? L10n.Settings.Language.system).tag(language)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 300, alignment: .leading)

            Text(L10n.Settings.Language.caption)
                .font(AuspexType.caption)
                .foregroundStyle(AuspexPalette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(SettingsCard())
    }

    private var note: some View {
        Text(L10n.Settings.General.note)
        .font(AuspexType.caption)
        .foregroundStyle(AuspexPalette.textTertiary)
        .fixedSize(horizontal: false, vertical: true)
    }
}
