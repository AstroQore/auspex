import AppKit
import CoreServices
import Testing

@testable import AuspexApp

@Suite("Application launch context")
struct ApplicationLifecycleTests {
    @Test("the login-item Apple-event marker suppresses a main-window launch")
    func loginItemMarker() {
        let event = NSAppleEventDescriptor(
            eventClass: AEEventClass(kCoreEventClass),
            eventID: AEEventID(kAEOpenApplication),
            targetDescriptor: nil,
            returnID: AEReturnID(kAutoGenerateReturnID),
            transactionID: AETransactionID(kAnyTransactionID)
        )
        event.setParam(
            NSAppleEventDescriptor(boolean: true),
            forKeyword: AEKeyword(keyAELaunchedAsLogInItem)
        )

        #expect(ApplicationLaunchContext.isLoginItem(event))
    }

    @Test("an ordinary open-application event remains foreground")
    func ordinaryLaunch() {
        let event = NSAppleEventDescriptor(
            eventClass: AEEventClass(kCoreEventClass),
            eventID: AEEventID(kAEOpenApplication),
            targetDescriptor: nil,
            returnID: AEReturnID(kAutoGenerateReturnID),
            transactionID: AETransactionID(kAnyTransactionID)
        )
        #expect(!ApplicationLaunchContext.isLoginItem(event))
        #expect(!ApplicationLaunchContext.isLoginItem(nil))
    }

    @Test("a Finder reopen reveals the hidden login-launch window")
    func reopenRevealsHiddenWindow() {
        #expect(
            ApplicationReopenPlan.resolve(
                isAccessory: true,
                hasHiddenMainWindow: true
            ) == .revealHiddenMainWindow
        )
    }

    @Test("a Finder reopen requests a window when login launch made none")
    func reopenRequestsWindow() {
        #expect(
            ApplicationReopenPlan.resolve(
                isAccessory: true,
                hasHiddenMainWindow: false
            ) == .requestMainWindow
        )
    }

    @Test("ordinary foreground reopens remain AppKit's decision")
    func ordinaryReopen() {
        #expect(
            ApplicationReopenPlan.resolve(
                isAccessory: false,
                hasHiddenMainWindow: true
            ) == .appKitDefault
        )
    }
}
