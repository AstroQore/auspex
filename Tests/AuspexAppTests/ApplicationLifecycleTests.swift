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
}
