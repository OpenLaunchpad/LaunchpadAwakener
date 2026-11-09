import AppKit
import Testing
@testable import LaunchpadAwakenerSharedUI

/// Telling a launch at login from one the user started: only the former is allowed to keep the
/// injected app's window closed.
struct ApplicationLaunchTests {
    private static func openApplicationEvent(propertyData: NSAppleEventDescriptor?) -> NSAppleEventDescriptor {
        let event = NSAppleEventDescriptor(
            eventClass: AEEventClass(kCoreEventClass),
            eventID: AEEventID(kAEOpenApplication),
            targetDescriptor: nil,
            returnID: AEReturnID(kAutoGenerateReturnID),
            transactionID: AETransactionID(kAnyTransactionID)
        )
        if let propertyData {
            event.setParam(propertyData, forKeyword: AEKeyword(keyAEPropData))
        }
        return event
    }

    @Test
    func openEventOfALoginItemIsALaunchAtLogin() {
        let event = Self.openApplicationEvent(propertyData: NSAppleEventDescriptor(enumCode: OSType(keyAELaunchedAsLogInItem)))
        #expect(ApplicationLaunch.isLaunchAtLogin(openEvent: event))
    }

    @Test
    func openEventFromTheFinderIsNot() {
        let event = Self.openApplicationEvent(propertyData: nil)
        #expect(!ApplicationLaunch.isLaunchAtLogin(openEvent: event))
    }

    @Test
    func otherPropertyDataIsNot() {
        let event = Self.openApplicationEvent(propertyData: NSAppleEventDescriptor(enumCode: OSType(keyAELaunchedAsServiceItem)))
        #expect(!ApplicationLaunch.isLaunchAtLogin(openEvent: event))
    }

    @Test
    func reopenEventIsNot() {
        let event = NSAppleEventDescriptor(
            eventClass: AEEventClass(kCoreEventClass),
            eventID: AEEventID(kAEReopenApplication),
            targetDescriptor: nil,
            returnID: AEReturnID(kAutoGenerateReturnID),
            transactionID: AETransactionID(kAnyTransactionID)
        )
        event.setParam(NSAppleEventDescriptor(enumCode: OSType(keyAELaunchedAsLogInItem)), forKeyword: AEKeyword(keyAEPropData))
        #expect(!ApplicationLaunch.isLaunchAtLogin(openEvent: event))
    }

    @Test
    func noEventIsNot() {
        #expect(!ApplicationLaunch.isLaunchAtLogin(openEvent: nil))
    }
}
