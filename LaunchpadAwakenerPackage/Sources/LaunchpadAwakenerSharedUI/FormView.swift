import AppKit
import AppKitPlus
import SnapKit
import UIFoundation

/// A System Settings–style grouped form: what SwiftUI's `Form` draws with `.formStyle(.grouped)` —
/// sections, each a header over a rounded group of rows.
///
/// The form only stacks its sections. Put it in an `NSScrollViewController` as the document view where
/// it may be taller than its window; it reports the height it needs through
/// ``fittingHeight(forWidth:)``.
///
/// The metrics were measured on SwiftUI's grouped form in macOS 27.2: 20 points around the sections,
/// 30 between one group and the next section's header.
public final class FormView: XiblessView {
    /// Space between the form's edges and its sections.
    public static let contentInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)

    /// Space between one section's group and the next section's header.
    public static let sectionSpacing: CGFloat = 30

    public var sections: [FormSectionView] {
        didSet {
            installSections()
        }
    }

    private let sectionStack = NSStackView()

    public init(sections: [FormSectionView] = []) {
        self.sections = sections
        super.init(frame: .zero)

        sectionStack.orientation = .vertical
        sectionStack.alignment = .leading
        sectionStack.spacing = Self.sectionSpacing
        sectionStack.detachesHiddenViews = true

        hierarchy {
            sectionStack
        }
        sectionStack.snp.makeConstraints { make in
            make.top.equalToSuperview().offset(Self.contentInsets.top)
            make.leading.equalToSuperview().offset(Self.contentInsets.left)
            make.trailing.equalToSuperview().offset(-Self.contentInsets.right)
            // At most: inside a scroll view the form is stretched to fill what is visible, and the sections
            // stay at the top rather than spreading out.
            make.bottom.lessThanOrEqualToSuperview().offset(-Self.contentInsets.bottom)
        }
        // As tall as the sections when nothing stretches the form.
        snp.makeConstraints { make in
            make.height.equalTo(sectionStack).offset(Self.contentInsets.top + Self.contentInsets.bottom).priority(.low)
        }
        installSections()
    }

    private func installSections() {
        sectionStack.setViews(sections, in: .top)
        for section in sections {
            section.snp.makeConstraints { make in
                make.width.equalTo(sectionStack)
            }
        }
    }

    /// The height that shows every section without scrolling, laid out `width` points wide.
    public func fittingHeight(forWidth width: CGFloat) -> CGFloat {
        let widthConstraint = widthAnchor.constraint(equalToConstant: width)
        widthConstraint.isActive = true
        defer { widthConstraint.isActive = false }
        // Twice: the first pass gives wrapping labels their widths, the second measures their heights.
        layoutSubtreeIfNeeded()
        layoutSubtreeIfNeeded()
        return sectionStack.fittingSize.height + Self.contentInsets.top + Self.contentInsets.bottom
    }
}

/// One section of a ``FormView``: an optional header — a symbol and a title — over a rounded group of
/// rows separated by hairlines. A hidden row takes its separator with it.
public final class FormSectionView: XiblessView {
    /// Corner radius of the group, measured on SwiftUI's grouped form.
    public static let groupCornerRadius: CGFloat = 12

    /// Space between the header and the group.
    public static let headerSpacing: CGFloat = 10

    public var rows: [FormRowView] {
        didSet {
            rowStack.setViews(rows, in: .top)
            constrainRowWidths()
            needsLayout = true
        }
    }

    /// Colours the header's symbol and title; nil leaves them in the label colour. The Last Error
    /// section's header is red.
    public var headerTintColor: NSColor? {
        didSet {
            headerImageView.contentTintColor = headerTintColor ?? .labelColor
            headerLabel.textColor = headerTintColor ?? .labelColor
        }
    }

    private let headerImageView = NSImageView()
    private let headerLabel = NSTextField(labelWithString: "")
    private let headerStack = NSStackView()
    private let groupView = XiblessView()
    private let rowStack = NSStackView()

    public init(title: String? = nil, symbolName: String? = nil, rows: [FormRowView] = []) {
        self.rows = rows
        super.init(frame: .zero)

        let headerFont = NSFont.preferredFont(forTextStyle: .headline)
        headerLabel.font = headerFont
        headerLabel.stringValue = title ?? ""
        headerLabel.textColor = .labelColor
        headerImageView.image = symbolName.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) }
        headerImageView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: headerFont.pointSize, weight: .bold)
        headerImageView.contentTintColor = .labelColor
        headerImageView.isHidden = symbolName == nil
        headerStack.orientation = .horizontal
        headerStack.spacing = 8
        headerStack.setViews([headerImageView, headerLabel], in: .leading)
        headerStack.isHidden = title == nil

        groupView.backgroundColor = .tertiarySystemFill
        groupView.cornerRadius = Self.groupCornerRadius
        groupView.cornerCurve = .continuous

        rowStack.orientation = .vertical
        rowStack.alignment = .leading
        rowStack.spacing = 0
        rowStack.detachesHiddenViews = true
        rowStack.setViews(rows, in: .top)

        let outerStack = NSStackView(views: [headerStack, groupView])
        outerStack.orientation = .vertical
        outerStack.alignment = .leading
        outerStack.spacing = Self.headerSpacing
        outerStack.detachesHiddenViews = true

        hierarchy {
            outerStack
        }
        groupView.hierarchy {
            rowStack
        }
        outerStack.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }
        headerStack.snp.makeConstraints { make in
            make.leading.equalToSuperview().offset(FormRowView.contentInsets.left)
        }
        groupView.snp.makeConstraints { make in
            make.width.equalToSuperview()
        }
        rowStack.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }
        constrainRowWidths()
    }

    private func constrainRowWidths() {
        for row in rows {
            row.snp.makeConstraints { make in
                make.width.equalTo(rowStack)
            }
        }
    }

    override public func layout() {
        super.layout()
        // Only rows after the first visible one have a separator above them.
        var hasSeenVisibleRow = false
        for row in rows {
            row.showsSeparator = hasSeenVisibleRow
            if !row.isHidden {
                hasSeenVisibleRow = true
            }
        }
    }
}

/// A row of a ``FormSectionView``: what `LabeledContent` and `Toggle` render as in a grouped `Form` — a
/// title, optionally with a smaller line under it, on the leading side and an accessory on the
/// trailing side; or one view across the whole row.
public final class FormRowView: XiblessView {
    /// Space between the row's edges and its content.
    public static let contentInsets = NSEdgeInsets(top: 10, left: 10, bottom: 10, right: 10)

    /// Space between the title and the line under it.
    public static let subtitleSpacing: CGFloat = 2.5

    /// Space between the leading text and the trailing accessory.
    public static let accessorySpacing: CGFloat = 12

    public var title: String {
        get { titleLabel.stringValue }
        set { titleLabel.stringValue = newValue }
    }

    /// The smaller line under the title; nil hides it.
    public var subtitle: String? {
        get { subtitleLabel.isHidden ? nil : subtitleLabel.stringValue }
        set {
            subtitleLabel.stringValue = newValue ?? ""
            subtitleLabel.isHidden = newValue == nil
            titleOnlyConstraint?.isActive = newValue == nil
            titleWithSubtitleConstraints.forEach { $0.isActive = newValue != nil }
        }
    }

    public var subtitleTextColor: NSColor = .secondaryLabelColor {
        didSet {
            updateTextColors()
        }
    }

    /// Dims the row's text, as a disabled control's label is dimmed. The accessory is the caller's to
    /// disable.
    public var isEnabled = true {
        didSet {
            updateTextColors()
        }
    }

    /// Whether a hairline separates this row from the one above. Set by the section.
    var showsSeparator = false {
        didSet {
            separatorView.isHidden = !showsSeparator
        }
    }

    private let titleLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(wrappingLabelWithString: "")
    private let separatorView = XiblessView()
    private var titleOnlyConstraint: NSLayoutConstraint?
    private var titleWithSubtitleConstraints: [NSLayoutConstraint] = []

    /// A row with a title, an optional line under it, and an accessory such as a switch, a button or a
    /// status, on the trailing side.
    public init(title: String, subtitle: String? = nil, accessoryView: NSView? = nil) {
        super.init(frame: .zero)
        setUpRow()

        titleLabel.stringValue = title
        titleLabel.font = .preferredFont(forTextStyle: .body)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        subtitleLabel.font = .preferredFont(forTextStyle: .subheadline)
        subtitleLabel.isSelectable = false
        subtitleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        updateTextColors()

        // The text area runs from the leading inset to the accessory, so a wrapping line under the title
        // has a width to wrap at.
        let textArea = NSView()
        hierarchy {
            textArea
        }
        textArea.hierarchy {
            titleLabel
            subtitleLabel
        }
        titleLabel.snp.makeConstraints { make in
            make.top.leading.equalToSuperview()
            make.trailing.lessThanOrEqualToSuperview()
        }
        subtitleLabel.snp.makeConstraints { make in
            make.leading.trailing.bottom.equalToSuperview()
        }
        titleOnlyConstraint = titleLabel.bottomAnchor.constraint(equalTo: textArea.bottomAnchor)
        titleWithSubtitleConstraints = [subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: Self.subtitleSpacing)]
        self.subtitle = subtitle

        textArea.snp.makeConstraints { make in
            make.leading.equalToSuperview().offset(Self.contentInsets.left)
            make.top.greaterThanOrEqualToSuperview().offset(Self.contentInsets.top)
            make.bottom.lessThanOrEqualToSuperview().offset(-Self.contentInsets.bottom)
            make.centerY.equalToSuperview()
        }
        guard let accessoryView else {
            textArea.snp.makeConstraints { make in
                make.trailing.equalToSuperview().offset(-Self.contentInsets.right)
            }
            return
        }
        hierarchy {
            accessoryView
        }
        accessoryView.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        accessoryView.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        accessoryView.snp.makeConstraints { make in
            make.leading.equalTo(textArea.snp.trailing).offset(Self.accessorySpacing)
            make.trailing.equalToSuperview().offset(-Self.contentInsets.right)
            make.top.greaterThanOrEqualToSuperview().offset(Self.contentInsets.top)
            make.bottom.lessThanOrEqualToSuperview().offset(-Self.contentInsets.bottom)
            make.centerY.equalToSuperview()
        }
    }

    /// A row that is one view across its whole width, such as a warning with its button.
    public init(contentView: NSView) {
        super.init(frame: .zero)
        setUpRow()
        hierarchy {
            contentView
        }
        contentView.snp.makeConstraints { make in
            make.edges.equalToSuperview().inset(Self.contentInsets)
        }
    }

    private func setUpRow() {
        // Content sets a row's height only from below; this decides it when nothing else does, so that a
        // row stays as short as its content instead of taking whatever height the layout happens to pick.
        snp.makeConstraints { make in
            make.height.equalTo(0).priority(1)
        }
        // Half the opacity of the system separator: what the grouped form draws between its rows.
        separatorView.backgroundColor = NSColor.separatorColor.withAlphaComponent(0.5)
        separatorView.isHidden = true
        hierarchy {
            separatorView
        }
        separatorView.snp.makeConstraints { make in
            make.top.equalToSuperview()
            make.leading.equalToSuperview().offset(Self.contentInsets.left)
            make.trailing.equalToSuperview().offset(-Self.contentInsets.right)
            make.height.equalTo(1)
        }
    }

    private func updateTextColors() {
        titleLabel.textColor = isEnabled ? .labelColor : .tertiaryLabelColor
        subtitleLabel.textColor = isEnabled ? subtitleTextColor : .tertiaryLabelColor
    }

    override public func layout() {
        super.layout()
        // A wrapping label measures its height against `preferredMaxLayoutWidth`; give it the width it
        // was laid out at, and measure again when that changed.
        let subtitleWidth = subtitleLabel.frame.width
        if subtitleWidth > 0, subtitleLabel.preferredMaxLayoutWidth != subtitleWidth {
            subtitleLabel.preferredMaxLayoutWidth = subtitleWidth
            needsLayout = true
        }
    }
}
