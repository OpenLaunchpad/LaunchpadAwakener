import AppKit
import LaunchpadAwakenerShared

/// The deletion confirmation's content, laid out as the view in the `MainMenu` nib of 15's
/// `com.apple.dock.ecap` service: 400 points wide, the icon at 64 points 10 in from the top left, the
/// question beside it in 13-point text at most 304 wide, Cancel and Delete at the bottom right with Delete
/// the default button. The nib's view is 84 points high; the height here follows the question and the
/// buttons of the system the helper runs on, never below that.
@MainActor
final class DeletionConfirmationViewController: NSViewController {
    static let width: CGFloat = 400
    static let minimumHeight: CGFloat = 84
    static let iconSide: CGFloat = 64
    static let messageMaximumWidth: CGFloat = 304

    /// Called with the button pressed.
    var answerHandler: ((DeletionConfirmationAnswer) -> Void)?

    let iconView = NSImageView()
    let messageField = NSTextField(wrappingLabelWithString: "")
    let cancelButton = NSButton(title: "", target: nil, action: nil)
    let deleteButton = NSButton(title: "", target: nil, action: nil)

    override func loadView() {
        let contentView = NSView(frame: NSRect(x: 0, y: 0, width: Self.width, height: Self.minimumHeight))
        iconView.imageScaling = .scaleProportionallyUpOrDown
        messageField.font = .systemFont(ofSize: 13)
        messageField.textColor = .labelColor
        messageField.isSelectable = false
        messageField.preferredMaxLayoutWidth = Self.messageMaximumWidth
        for button in [cancelButton, deleteButton] {
            button.bezelStyle = .push
            button.font = .systemFont(ofSize: 13)
            button.target = self
        }
        cancelButton.action = #selector(pressCancel(_:))
        deleteButton.action = #selector(pressDelete(_:))
        // The nib's Delete has Return as its key equivalent, which makes it the default button; Cancel has
        // none. The keys themselves never come here: the Dock reads them.
        deleteButton.keyEquivalent = "\r"
        for subview in [iconView, messageField, cancelButton, deleteButton] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            contentView.addSubview(subview)
        }
        // The nib's constraints, between alignment rectangles.
        let messageMinimumHeight = messageField.heightAnchor.constraint(greaterThanOrEqualToConstant: 34)
        messageMinimumHeight.priority = NSLayoutConstraint.Priority(999)
        NSLayoutConstraint.activate([
            contentView.widthAnchor.constraint(equalToConstant: Self.width),
            contentView.heightAnchor.constraint(greaterThanOrEqualToConstant: Self.minimumHeight),
            iconView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 10),
            iconView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 10),
            iconView.widthAnchor.constraint(equalToConstant: Self.iconSide),
            iconView.heightAnchor.constraint(equalToConstant: Self.iconSide),
            messageField.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 10),
            messageField.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 10),
            messageField.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -12),
            messageField.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -40),
            messageMinimumHeight,
            deleteButton.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -12),
            deleteButton.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -10),
            cancelButton.trailingAnchor.constraint(equalTo: deleteButton.leadingAnchor, constant: -10),
            cancelButton.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -10),
        ])
        view = contentView
    }

    /// Fills the view in and sizes it to what it holds.
    func configure(with configuration: DeletionConfirmationConfiguration) {
        loadViewIfNeeded()
        iconView.image = configuration.iconPNGData.flatMap(NSImage.init(data:))
            ?? NSWorkspace.shared.icon(forFile: configuration.bundlePath)
        messageField.stringValue = configuration.message
        cancelButton.title = configuration.cancelButtonTitle
        deleteButton.title = configuration.deleteButtonTitle
        view.layoutSubtreeIfNeeded()
        let size = view.fittingSize
        view.setFrameSize(size)
        preferredContentSize = size
    }

    @objc private func pressCancel(_ sender: Any?) {
        answerHandler?(.cancel)
    }

    @objc private func pressDelete(_ sender: Any?) {
        answerHandler?(.delete)
    }
}
