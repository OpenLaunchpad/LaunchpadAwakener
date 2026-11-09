import AppKit
import LaunchpadAwakenerAppCore
import SnapKit
import UIFoundation

/// The one thing to read first: is this working right now, and if not, what is the next step — with a
/// button for it where there is one.
///
/// Its tinted background and outline are drawn on the banner's own layer rather than by a view laid over
/// the button: under the macOS 27 SDK a system control covered by a sibling view no longer receives
/// clicks.
final class ReadinessBannerView: XiblessView {
    private static let symbolPointSize: CGFloat = 28
    private static let symbolColumnWidth: CGFloat = 34
    private static let padding: CGFloat = 12
    private static let spacing: CGFloat = 14

    /// Called when the user clicks the banner's button, with the step it showed.
    var performAction: ((ReadinessAction) -> Void)?

    private let symbolImageView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let nextStepLabel = NSTextField(wrappingLabelWithString: "")
    private let actionButton = NSButton(title: "", target: nil, action: nil)
    private var shownAction: ReadinessAction?
    private var shownSymbolName: String?

    override init(frame frameRect: CGRect) {
        super.init(frame: frameRect)
        cornerRadius = 12
        cornerCurve = .continuous
        borderWidth = 1

        symbolImageView.imageScaling = .scaleNone
        symbolImageView.imageAlignment = .alignCenter
        titleLabel.font = .preferredFont(forTextStyle: .headline)
        nextStepLabel.font = .preferredFont(forTextStyle: .subheadline)
        nextStepLabel.textColor = .secondaryLabelColor
        nextStepLabel.isSelectable = true
        actionButton.bezelStyle = .push
        actionButton.setContentHuggingPriority(.required, for: .horizontal)
        actionButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        actionButton.box.setAction { [weak self] _ in
            guard let self, let shownAction else { return }
            performAction?(shownAction)
        }

        let textArea = NSView()
        textArea.setContentHuggingPriority(.defaultLow, for: .horizontal)
        textArea.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        textArea.hierarchy {
            titleLabel
            nextStepLabel
        }
        titleLabel.snp.makeConstraints { make in
            make.top.leading.equalToSuperview()
            make.trailing.lessThanOrEqualToSuperview()
        }
        nextStepLabel.snp.makeConstraints { make in
            make.top.equalTo(titleLabel.snp.bottom).offset(2)
            make.leading.trailing.bottom.equalToSuperview()
        }

        // Symbol, text and button side by side; a hidden button leaves its space to the text.
        let stackView = NSStackView(views: [symbolImageView, textArea, actionButton])
        stackView.orientation = .horizontal
        stackView.alignment = .centerY
        stackView.distribution = .fill
        stackView.spacing = Self.spacing
        stackView.detachesHiddenViews = true
        stackView.edgeInsets = NSEdgeInsets(top: Self.padding, left: Self.padding, bottom: Self.padding, right: Self.padding)

        hierarchy {
            stackView
        }
        stackView.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }
        symbolImageView.snp.makeConstraints { make in
            make.width.equalTo(Self.symbolColumnWidth)
        }
    }

    /// Shows `presentation`, with its button enabled or not.
    func show(_ presentation: ReadinessPresentation, isActionEnabled: Bool) {
        let tintColor = presentation.tint.color
        backgroundColor = tintColor.withAlphaComponent(0.12)
        borderColor = tintColor.withAlphaComponent(0.28)

        let symbolConfiguration = NSImage.SymbolConfiguration(pointSize: Self.symbolPointSize, weight: .regular)
            .applying(NSImage.SymbolConfiguration(hierarchicalColor: tintColor))
        if let image = NSImage(systemSymbolName: presentation.symbolName, accessibilityDescription: presentation.title)?.withSymbolConfiguration(symbolConfiguration) {
            if shownSymbolName == nil || shownSymbolName == presentation.symbolName {
                symbolImageView.image = image
            } else {
                // A different state swaps the symbol with the replace effect, as the SwiftUI banner did.
                symbolImageView.setSymbolImage(image, contentTransition: .replace)
            }
            shownSymbolName = presentation.symbolName
        }

        titleLabel.stringValue = presentation.title
        nextStepLabel.stringValue = presentation.nextStep

        shownAction = presentation.action
        actionButton.isHidden = presentation.action == nil
        actionButton.title = presentation.action?.title ?? ""
        actionButton.isEnabled = isActionEnabled
        actionButton.bezelColor = tintColor
        if #available(macOS 26.0, *) {
            actionButton.tintProminence = .primary
        }
    }

    override func layout() {
        super.layout()
        let nextStepWidth = nextStepLabel.frame.width
        if nextStepWidth > 0, nextStepLabel.preferredMaxLayoutWidth != nextStepWidth {
            nextStepLabel.preferredMaxLayoutWidth = nextStepWidth
            needsLayout = true
        }
    }
}
