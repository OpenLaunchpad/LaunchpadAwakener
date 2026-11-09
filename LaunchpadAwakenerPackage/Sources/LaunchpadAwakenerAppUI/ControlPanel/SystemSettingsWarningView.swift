import AppKit
import SnapKit
import UIFoundation

/// A login item the user switched off, which only System Settings can switch back on: an orange warning
/// and a button that opens the Login Items pane.
final class SystemSettingsWarningView: XiblessView {
    private let textLabel: NSTextField

    init(text: String, openLoginItems: @escaping () -> Void) {
        let font = NSFont.preferredFont(forTextStyle: .callout)
        textLabel = NSTextField(wrappingLabelWithString: text)
        super.init(frame: .zero)

        let iconView = NSImageView()
        iconView.image = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: nil)
        iconView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: font.pointSize, weight: .regular)
        iconView.contentTintColor = .systemOrange
        iconView.setContentHuggingPriority(.required, for: .horizontal)

        textLabel.font = font
        textLabel.textColor = .systemOrange
        textLabel.isSelectable = false
        textLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        textLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let button = NSButton(title: "Open Login Items", target: nil, action: nil)
        button.bezelStyle = .push
        button.controlSize = .small
        button.font = .systemFont(ofSize: NSFont.systemFontSize(for: .small))
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
        button.box.setAction { _ in
            openLoginItems()
        }

        let stackView = NSStackView(views: [iconView, textLabel, button])
        stackView.orientation = .horizontal
        stackView.alignment = .centerY
        stackView.distribution = .fill
        stackView.spacing = 8
        stackView.setCustomSpacing(6, after: iconView)

        hierarchy {
            stackView
        }
        stackView.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }
    }

    override func layout() {
        super.layout()
        let textWidth = textLabel.frame.width
        if textWidth > 0, textLabel.preferredMaxLayoutWidth != textWidth {
            textLabel.preferredMaxLayoutWidth = textWidth
            needsLayout = true
        }
    }
}
