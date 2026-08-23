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

@MainActor
protocol LoginItemServicing {
    var status: LoginItemStatus { get }
    func register() throws
    func unregister() throws
    func openSystemSettings()
}

/// The only type that talks to ServiceManagement. Registration and removal
/// are reached solely from a Settings click, except for repairing a durable
/// request the person already made before an app bundle was replaced.
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

    private(set) var status: LoginItemStatus
    private(set) var errorDescription: String?

    init(service: any LoginItemServicing = SystemLoginItemService()) {
        self.service = service
        self.status = service.status
    }

    static func preview() -> LoginItemController {
        LoginItemController(service: PreviewLoginItemService())
    }

    /// What the toggle draws. macOS is authoritative whenever it has an
    /// answer; a broken/unavailable registration keeps showing the durable
    /// request so the UI does not silently erase what the person asked for.
    func isOn(desired: Bool) -> Bool {
        switch status {
        case .enabled, .requiresApproval: true
        case .notRegistered: false
        case .notFound, .unknown: desired
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

    /// Repairs a registration lost when the signed app bundle was replaced.
    /// It never creates a new permission request unless the durable setting
    /// proves the person previously clicked "Launch at login". A false value
    /// is left alone: external Login Items state is not silently removed on
    /// launch.
    func reconcileDesiredState(_ enabled: Bool) {
        refresh()
        guard enabled, !status.isRequestedOrEnabled else { return }
        _ = setEnabled(true)
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
            "Off. Auspex starts only when you open it."
        case .notFound:
            "Unavailable in this copy. Move the packaged Auspex.app to Applications and open it once."
        case .unknown:
            "macOS returned an unknown Login Items state."
        }
    }
}
