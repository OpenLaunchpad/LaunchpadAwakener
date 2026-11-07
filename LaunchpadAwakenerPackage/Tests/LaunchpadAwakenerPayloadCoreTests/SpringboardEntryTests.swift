import LaunchpadAwakenerPayloadCore
import Testing

/// A request to open Apps toggles the springboard, as macOS 15's Launchpad icon and key did — including
/// the click on the Apps icon that has just closed it.
@Suite("Requests to open Apps")
struct SpringboardEntryTests {
    @Test("a request while the springboard shows closes it")
    func requestWhileShown() {
        #expect(SpringboardEntry.response(isVisible: true, sinceDockClickDismissal: nil) == .hide)
    }

    @Test("a request while the springboard is hidden opens it")
    func requestWhileHidden() {
        #expect(SpringboardEntry.response(isVisible: false, sinceDockClickDismissal: nil) == .show)
    }

    @Test("the Apps icon's request just after its click closed the springboard keeps it closed")
    func appsIconRequestAfterItsClick() {
        // 27.2's Dock queues the Apps icon's request on the main queue straight after the click.
        #expect(SpringboardEntry.response(isVisible: false, sinceDockClickDismissal: .milliseconds(20)) == .stayHidden)
    }

    @Test("a request well after a click on the Dock closed the springboard opens it")
    func requestWellAfterDockClick() {
        #expect(SpringboardEntry.response(isVisible: false, sinceDockClickDismissal: .seconds(2)) == .show)
    }
}
