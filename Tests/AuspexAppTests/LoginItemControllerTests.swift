import AuspexCore
import Foundation
import Testing

@testable import AuspexApp

@Suite("Launch at login controller")
@MainActor
struct LoginItemControllerTests {
    @Test("enabling registers once and adopts macOS state")
    func enable() {
        let service = LoginItemServiceDouble(status: .notRegistered)
        service.statusAfterRegister = .enabled
        let controller = LoginItemController(service: service)

        #expect(controller.setEnabled(true))
        #expect(service.registerCount == 1)
        #expect(controller.status == .enabled)
        #expect(controller.isOn(desired: false))

        #expect(controller.setEnabled(true))
        #expect(service.registerCount == 1)
    }

    @Test("approval is an on state and is not registered twice")
    func approval() {
        let service = LoginItemServiceDouble(status: .requiresApproval)
        let controller = LoginItemController(service: service)

        #expect(controller.isOn(desired: false))
        #expect(controller.setEnabled(true))
        #expect(service.registerCount == 0)
        #expect(controller.statusDescription.contains("Waiting for approval"))
    }

    @Test("disabling unregisters and leaves this process running")
    func disable() {
        let service = LoginItemServiceDouble(status: .enabled)
        service.statusAfterUnregister = .notRegistered
        let controller = LoginItemController(service: service)

        #expect(controller.setEnabled(false))
        #expect(service.unregisterCount == 1)
        #expect(controller.status == .notRegistered)
        #expect(!controller.isOn(desired: true))
    }

    @Test("launch reconciliation respects a macOS-off state")
    func reconciliationDoesNotOverrideSystemOff() {
        let service = LoginItemServiceDouble(status: .notRegistered)
        let controller = LoginItemController(
            service: service,
            currentRegistration: currentReceipt
        )

        let result = controller.reconcileDesiredState(
            true,
            registration: previousReceipt
        )
        #expect(service.registerCount == 0)
        #expect(service.unregisterCount == 0)
        #expect(result == LoginItemReconciliation(enabled: false, registration: nil))
        #expect(controller.reconciliationDescription?.contains("left it off") == true)
    }

    @Test("an enabled in-place replacement refreshes only its receipt")
    func reconcileReplacementReceipt() {
        let service = LoginItemServiceDouble(status: .enabled)
        let controller = LoginItemController(
            service: service,
            currentRegistration: currentReceipt
        )

        let result = controller.reconcileDesiredState(
            true,
            registration: previousReceipt
        )
        #expect(service.registerCount == 0)
        #expect(service.unregisterCount == 0)
        #expect(
            result == LoginItemReconciliation(
                enabled: true,
                registration: currentReceipt
            )
        )
        #expect(controller.reconciliationDescription?.contains("updated") == true)
    }

    @Test("a moved or unrelated receipt is not rewritten as an update")
    func unprovenReplacementIsNotAdopted() {
        let service = LoginItemServiceDouble(status: .enabled)
        let controller = LoginItemController(
            service: service,
            currentRegistration: currentReceipt
        )
        let movedReceipt = LoginItemRegistrationReceipt(
            bundleIdentifier: previousReceipt.bundleIdentifier,
            bundlePath: "/Applications/Utilities/Auspex.app",
            shortVersion: previousReceipt.shortVersion,
            buildVersion: previousReceipt.buildVersion
        )

        let result = controller.reconcileDesiredState(
            true,
            registration: movedReceipt
        )
        #expect(result == nil)
        #expect(service.registerCount == 0)
        #expect(controller.reconciliationDescription == nil)
    }

    @Test("an unavailable service never attempts speculative repair")
    func noSpeculativeRepair() {
        let service = LoginItemServiceDouble(status: .notFound)
        let controller = LoginItemController(
            service: service,
            currentRegistration: currentReceipt
        )

        let result = controller.reconcileDesiredState(
            true,
            registration: previousReceipt
        )
        #expect(result == nil)
        #expect(service.registerCount == 0)
        #expect(service.unregisterCount == 0)
        #expect(!controller.isOn(desired: true))
    }

    @Test("launch reconciliation never invents an opt-in")
    func noSilentOptIn() {
        let service = LoginItemServiceDouble(status: .notRegistered)
        let controller = LoginItemController(service: service)

        let result = controller.reconcileDesiredState(false, registration: nil)
        #expect(result == nil)
        #expect(service.registerCount == 0)
        #expect(service.unregisterCount == 0)
    }

    @Test("a ServiceManagement failure remains visible and does not claim success")
    func failure() {
        let service = LoginItemServiceDouble(status: .notRegistered)
        service.registerError = LoginItemTestError.refused
        let controller = LoginItemController(service: service)

        #expect(!controller.setEnabled(true))
        #expect(service.registerCount == 1)
        #expect(controller.status == .notRegistered)
        #expect(controller.errorDescription?.contains("refused") == true)
    }

    @Test("opening Login Items is an explicit forwarded gesture")
    func openSettings() {
        let service = LoginItemServiceDouble(status: .requiresApproval)
        let controller = LoginItemController(service: service)
        controller.openSystemSettings()
        #expect(service.openSettingsCount == 1)
    }
}

private let previousReceipt = LoginItemRegistrationReceipt(
    bundleIdentifier: "com.example.Auspex",
    bundlePath: "/Applications/Auspex.app",
    shortVersion: "1.0.0",
    buildVersion: "10"
)

private let currentReceipt = LoginItemRegistrationReceipt(
    bundleIdentifier: "com.example.Auspex",
    bundlePath: "/Applications/Auspex.app",
    shortVersion: "1.1.0",
    buildVersion: "11"
)

@MainActor
private final class LoginItemServiceDouble: LoginItemServicing {
    var status: LoginItemStatus
    var statusAfterRegister: LoginItemStatus?
    var statusAfterUnregister: LoginItemStatus?
    var registerError: Error?
    var unregisterError: Error?
    var registerCount = 0
    var unregisterCount = 0
    var openSettingsCount = 0

    init(status: LoginItemStatus) {
        self.status = status
    }

    func register() throws {
        registerCount += 1
        if let registerError { throw registerError }
        if let statusAfterRegister { status = statusAfterRegister }
    }

    func unregister() throws {
        unregisterCount += 1
        if let unregisterError { throw unregisterError }
        if let statusAfterUnregister { status = statusAfterUnregister }
    }

    func openSystemSettings() {
        openSettingsCount += 1
    }
}

private enum LoginItemTestError: LocalizedError {
    case refused

    var errorDescription: String? { "Registration refused for this test." }
}
