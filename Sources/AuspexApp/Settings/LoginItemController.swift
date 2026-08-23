import AuspexCore
import Foundation
import Observation
import ServiceManagement

/// Auspex's vocabulary for the four states macOS exposes for a login item.
/// Kept independent of ServiceManagement so the state machine can be tested
/// without registering the test runner with launchd.
enum LoginItemStatus: Equatable, Sendable {
    case notRegistered
    case enabled
    case requiresApproval
    case notFound
    case unknown

    var isRequestedOrEnabled: Bool {
        self == .enabled || self == .requiresApproval
    }
}

/// What launch reconciliation asks the settings owner to persist. It contains
/// no command: registration remains reachable only through `setEnabled`, the
/// explicit person-click path.
struct LoginItemReconciliation: Equatable, Sendable {
    var enabled: Bool
    var registration: LoginItemRegistrationReceipt?
}

enum LoginItemBundleReceipt {
    static func current(bundle: Bundle = .main) -> LoginItemRegistrationReceipt? {
        guard let identifier = bundle.bundleIdentifier,
              let shortVersion = bundle.object(
                  forInfoDictionaryKey: "CFBundleShortVersionString"
              ) as? String,
              let buildVersion = bundle.object(
                  forInfoDictionaryKey: "CFBundleVersion"
              ) as? String else { return nil }
        return LoginItemRegistrationReceipt(
            bundleIdentifier: identifier,
            bundlePath: bundle.bundleURL.standardizedFileURL.path,
            shortVersion: shortVersion,
            buildVersion: buildVersion
        )
    }
}

@MainActor
protocol LoginItemServicing {
    var status: LoginItemStatus { get }
    func register() throws
    func unregister() throws
    func openSystemSettings()
}

/// The only type that talks to ServiceManagement. Registration and removal
/// are reached solely from a Settings click.
@MainActor
struct SystemLoginItemService: LoginItemServicing {
    var status: LoginItemStatus {
        switch SMAppService.mainApp.status {
        case .notRegistered: .notRegistered
        case .enabled: .enabled
        case .requiresApproval: .requiresApproval
        case .notFound: .notFound
        @unknown default: .unknown
        }
    }

    func register() throws { try SMAppService.mainApp.register() }
    func unregister() throws { try SMAppService.mainApp.unregister() }
    func openSystemSettings() { SMAppService.openSystemSettingsLoginItems() }
}

/// An unavailable service for demo renders. A fabricated board must not quote
/// or mutate this Mac's real Login Items state.
@MainActor
private struct PreviewLoginItemService: LoginItemServicing {
    var status: LoginItemStatus { .notFound }
    func register() throws {}
    func unregister() throws {}
    func openSystemSettings() {}
}

/// Observable login-item state shared by both Settings surfaces.
@MainActor
@Observable
final class LoginItemController {
    @ObservationIgnored private let service: any LoginItemServicing
    @ObservationIgnored private let currentRegistration: LoginItemRegistrationReceipt?

    private(set) var status: LoginItemStatus
    private(set) var errorDescription: String?
    private(set) var reconciliationDescription: String?

    init(
        service: any LoginItemServicing = SystemLoginItemService(),
        currentRegistration: LoginItemRegistrationReceipt? = LoginItemBundleReceipt.current()
    ) {
        self.service = service
        self.currentRegistration = currentRegistration
        self.status = service.status
    }

    static func preview() -> LoginItemController {
        LoginItemController(service: PreviewLoginItemService(), currentRegistration: nil)
    }

    /// What the toggle draws. macOS is authoritative whenever it has an
    /// answer. Unknown/unavailable states fail closed instead of drawing a
    /// stale durable value as though macOS had accepted it.
    func isOn(desired: Bool) -> Bool {
        switch status {
        case .enabled, .requiresApproval: true
        case .notRegistered, .notFound, .unknown: false
        }
    }

    func refresh() {
        status = service.status
    }

    /// Applies an explicit Settings click. Returns true only when macOS
    /// accepted the action (or already held that state), which is the caller's
    /// signal to persist the requested value.
    @discardableResult
    func setEnabled(_ enabled: Bool) -> Bool {
        refresh()
        reconciliationDescription = nil
        do {
            if enabled {
                guard !status.isRequestedOrEnabled else {
                    errorDescription = nil
                    return true
                }
                try service.register()
            } else {
                guard status.isRequestedOrEnabled else {
                    errorDescription = nil
                    return true
                }
                try service.unregister()
            }
            refresh()
            errorDescription = nil
            return true
        } catch {
            refresh()
            errorDescription = error.localizedDescription
            return false
        }
    }

    /// Reconciles the persisted mirror with macOS without changing the login
    /// item itself.
    ///
    /// `.notRegistered` is authoritative even if the old settings file says
    /// on: the person may have disabled Auspex in System Settings, so launch
    /// must never turn it back on. When the service is still enabled after an
    /// in-place bundle update, the changed version plus the same identifier
    /// and path prove replacement and allow only the receipt to be refreshed.
    func reconcileDesiredState(
        _ enabled: Bool,
        registration previousRegistration: LoginItemRegistrationReceipt?
    ) -> LoginItemReconciliation? {
        refresh()
        reconciliationDescription = nil

        switch status {
        case .notRegistered:
            guard enabled || previousRegistration != nil else { return nil }
            reconciliationDescription =
                "macOS has Launch at Login turned off. Auspex left it off."
            return LoginItemReconciliation(enabled: false, registration: nil)

        case .enabled, .requiresApproval:
            // A current enabled state is itself authority to mirror `true`.
            // Refreshing an existing receipt after replacement additionally
            // requires evidence that the bundle changed in place.
            let registration: LoginItemRegistrationReceipt?
            if let previousRegistration,
               let currentRegistration,
               previousRegistration.provesInPlaceReplacement(by: currentRegistration) {
                registration = currentRegistration
                reconciliationDescription =
                    "Auspex was updated and macOS kept Launch at Login enabled."
            } else if previousRegistration == nil || !enabled {
                registration = currentRegistration
            } else {
                registration = previousRegistration
            }

            let result = LoginItemReconciliation(
                enabled: true,
                registration: registration
            )
            guard !enabled || previousRegistration != registration else { return nil }
            return result

        case .notFound, .unknown:
            // There is no trustworthy state to adopt and no supported repair
            // operation. Keep the old receipt as inert history, draw the
            // toggle off, and wait for an explicit click or a later valid
            // ServiceManagement result.
            return nil
        }
    }

    var registrationForPersistence: LoginItemRegistrationReceipt? {
        status.isRequestedOrEnabled ? currentRegistration : nil
    }

    func openSystemSettings() {
        service.openSystemSettings()
    }

    var statusDescription: String {
        switch status {
        case .enabled:
            "Auspex will start quietly when you log in."
        case .requiresApproval:
            "Waiting for approval in System Settings → General → Login Items."
        case .notRegistered:
            "Off in macOS. Auspex will not turn it back on unless you click this switch."
        case .notFound:
            "Unavailable in this copy. Move the packaged Auspex.app to Applications and open it once."
        case .unknown:
            "macOS returned an unknown Login Items state."
        }
    }
}
