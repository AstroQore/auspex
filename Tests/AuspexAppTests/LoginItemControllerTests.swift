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

    @Test("a durable request repairs a lost registration after replacement")
    func reconcileReplacement() {
        let service = LoginItemServiceDouble(status: .notFound)
        service.statusAfterRegister = .enabled
        let controller = LoginItemController(service: service)

        controller.reconcileDesiredState(true)
        #expect(service.registerCount == 1)
        #expect(controller.status == .enabled)
    }

    @Test("launch reconciliation never invents an opt-in")
    func noSilentOptIn() {
        let service = LoginItemServiceDouble(status: .notRegistered)
        let controller = LoginItemController(service: service)

        controller.reconcileDesiredState(false)
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
