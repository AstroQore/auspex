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
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear { loginItem.refresh() }
    }

    private var header: some View {
        Text(
            "The board can only catch work that happens while Auspex is running. "
                + "macOS can start it at login with the menu bar and observation pipeline ready, "
                + "without opening the board in front of whatever you were doing."
        )
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
                        catalog.setLaunchAtLogin(enabled)
                    }
                )
            ) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Launch at login")
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
                Button("Open Login Items", systemImage: "gear") {
                    loginItem.openSystemSettings()
                }
                .buttonStyle(.auspex)
                .controlSize(.small)
            }

            if let error = loginItem.errorDescription {
                Text("macOS did not change the login item: \(error)")
                    .font(AuspexType.caption)
                    .foregroundStyle(AuspexPalette.statePermission)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(SettingsCard())
    }

    private var note: some View {
        Text(
            "This registers the signed main application through ServiceManagement. "
                + "It does not install a helper, add a LaunchAgent, change the empty entitlements, "
                + "or grant Auspex any new access to the disk."
        )
        .font(AuspexType.caption)
        .foregroundStyle(AuspexPalette.textTertiary)
        .fixedSize(horizontal: false, vertical: true)
    }
}
