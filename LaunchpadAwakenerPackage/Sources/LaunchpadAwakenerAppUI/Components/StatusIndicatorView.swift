import AppKit
import LaunchpadAwakenerAppCore
import SnapKit
import UIFoundation

/// A coloured dot next to a status string.
///
/// The dot carries the state at a glance; the text spells it out for anyone who cannot rely on the
/// colour alone, which is why both are always present.
final class StatusIndicatorView: XiblessView {
    private static let dotDiameter: CGFloat = 8

    private let dotView = XiblessView()
    private let textLabel = NSTextField(labelWithString: "")

    override init(frame frameRect: CGRect) {
        super.init(frame: frameRect)
        dotView.cornerRadius = Self.dotDiameter / 2
        textLabel.font = .preferredFont(forTextStyle: .body)
        textLabel.textColor = .secondaryLabelColor
        textLabel.lineBreakMode = .byTruncatingMiddle
        textLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        hierarchy {
            dotView
            textLabel
        }
        dotView.snp.makeConstraints { make in
            make.leading.equalToSuperview()
            make.centerY.equalTo(textLabel)
            make.size.equalTo(Self.dotDiameter)
        }
        textLabel.snp.makeConstraints { make in
            make.leading.equalTo(dotView.snp.trailing).offset(6)
            make.top.bottom.trailing.equalToSuperview()
        }
    }

    func show(text: String, tint: StatusTint) {
        textLabel.stringValue = text
        dotView.backgroundColor = tint.color
    }

    func show(_ statusLine: StatusLine) {
        show(text: statusLine.text, tint: statusLine.tint)
    }
}
