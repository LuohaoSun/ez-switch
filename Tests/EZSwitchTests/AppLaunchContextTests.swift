import AppKit
import Carbon
import Testing
@testable import EZSwitch

@Suite("App launch context")
struct AppLaunchContextTests {
    @Test
    func ordinaryLaunchShowsPanel() {
        let event = NSAppleEventDescriptor.appleEvent(withEventClass: kCoreEventClass,
                                                       eventID: kAEOpenApplication,
                                                       targetDescriptor: nil,
                                                       returnID: AEReturnID(kAutoGenerateReturnID),
                                                       transactionID: AETransactionID(kAnyTransactionID))
        #expect(AppLaunchContext.shouldShowPanel(for: event))
        #expect(AppLaunchContext.shouldShowPanel(for: nil))
    }

    @Test
    func loginLaunchLeavesPanelClosed() {
        let event = NSAppleEventDescriptor.appleEvent(withEventClass: kCoreEventClass,
                                                       eventID: kAEOpenApplication,
                                                       targetDescriptor: nil,
                                                       returnID: AEReturnID(kAutoGenerateReturnID),
                                                       transactionID: AETransactionID(kAnyTransactionID))
        event.setParam(NSAppleEventDescriptor(enumCode: keyAELaunchedAsLogInItem),
                       forKeyword: keyAEPropData)
        #expect(!AppLaunchContext.shouldShowPanel(for: event))
    }

    @Test
    func loginLaunchFlagLeavesPanelClosed() {
        let event = NSAppleEventDescriptor.appleEvent(withEventClass: kCoreEventClass,
                                                       eventID: kAEOpenApplication,
                                                       targetDescriptor: nil,
                                                       returnID: AEReturnID(kAutoGenerateReturnID),
                                                       transactionID: AETransactionID(kAnyTransactionID))
        event.setParam(NSAppleEventDescriptor(boolean: true), forKeyword: keyAELaunchedAsLogInItem)
        #expect(!AppLaunchContext.shouldShowPanel(for: event))
    }
}
