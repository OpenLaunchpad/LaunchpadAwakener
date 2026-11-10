import CoreGraphics
import Foundation
import ImageIO
import LaunchpadAwakenerShared
import LaunchpadAwakenerSpringboardCore
import OSToolbox

/// The confirmation asked before deleting an application, shown by the text input helper as macOS 15's
/// Dock had its `com.apple.dock.ecap` service show it (`ECAlertPanel`): a popover whose own window goes on
/// screen over Launchpad's. Nothing here shows it, and the clicks on it go straight to the helper; the
/// helper only reports the button pressed, and this closes the popover when the springboard says so.
@Loggable(subsystem: "com.MxIris.LaunchpadAwakener", category: "SpringboardRemoteDeletionConfirmation")
@MainActor
final class SpringboardRemoteDeletionConfirmation {
    typealias Configuration = SpringboardHostedDeletionConfirmationConfiguration

    let configuration: Configuration
    private let client: TextInputHelperClient
    var answerHandler: ((SpringboardDeletionChoice) -> Void)?
    var presentationDidFail: (() -> Void)?
    var interruptionHandler: (() -> Void)?

    /// The helper said the popover is on screen.
    private var isShown = false
    /// Dismissed, failed or gone: nothing more is reported.
    private var isEnded = false

    init(configuration: Configuration, client: TextInputHelperClient = .shared) {
        self.configuration = configuration
        self.client = client
    }

    func present() {
        client.deletionConfirmationAnswerHandler = { [weak self] answer in
            self?.receive(answer)
        }
        client.deletionConfirmationInterruptionHandler = { [weak self] in
            self?.helperDidGoAway()
        }
        client.presentDeletionConfirmation(Self.message(for: configuration)) { [weak self] isShown in
            self?.didPresent(isShown: isShown)
        }
    }

    /// Closes the popover — even one the helper has not answered for yet, as the requests reach it in order.
    func dismiss() {
        guard !isEnded else { return }
        isEnded = true
        client.dismissDeletionConfirmation()
    }

    private func didPresent(isShown: Bool) {
        guard !isEnded else { return }
        guard isShown else {
            isEnded = true
            presentationDidFail?()
            return
        }
        self.isShown = true
        #log(.info, "The text input helper shows the deletion confirmation")
    }

    private func receive(_ answer: DeletionConfirmationAnswer) {
        guard !isEnded, isShown else { return }
        answerHandler?(answer == .delete ? .delete : .cancel)
    }

    /// The helper exited: a popover it showed is gone, and one it never showed never will be.
    private func helperDidGoAway() {
        guard !isEnded else { return }
        isEnded = true
        if isShown {
            #log(.error, "The text input helper went away while it showed the deletion confirmation")
            interruptionHandler?()
        } else {
            presentationDidFail?()
        }
    }

    /// What the helper is sent. The icon goes as PNG, as 15's Dock encoded it for its service
    /// (`-[ECAlertPanel _ensureConnection]`, 15.5 `0x10007B5B0`).
    static func message(for configuration: Configuration) -> DeletionConfirmationConfiguration {
        DeletionConfirmationConfiguration(
            iconPNGData: configuration.icon.flatMap(pngData(of:)),
            bundlePath: configuration.bundleURL.path,
            message: configuration.message,
            cancelButtonTitle: configuration.cancelButtonTitle,
            deleteButtonTitle: configuration.deleteButtonTitle,
            iconCenterX: Double(configuration.screenIconCenter.x),
            iconCenterY: Double(configuration.screenIconCenter.y)
        )
    }

    static func pngData(of image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}
