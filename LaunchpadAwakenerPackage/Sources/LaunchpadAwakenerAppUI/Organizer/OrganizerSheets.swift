import AppKit
import AppKitNavigation
import AppKitPlus
import LaunchpadAwakenerAppCore
import SnapKit
import UIFoundation
import UIFoundationToolbox

/// Asks for a folder's name: a new folder for selected applications, or an existing one's new name.
final class FolderNameViewController: XiblessViewController<XiblessView>, NSTextFieldDelegate {
    private let naming: LaunchpadOrganizerViewModel.FolderNaming
    private let commit: (String) -> Void
    private let nameField = NSTextField()
    private let confirmButton = NSButton(title: "", target: nil, action: nil)

    init(naming: LaunchpadOrganizerViewModel.FolderNaming, commit: @escaping (String) -> Void) {
        self.naming = naming
        self.commit = commit
        super.init()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        let titleLabel = NSTextField(labelWithString: naming.title)
        titleLabel.font = .preferredFont(forTextStyle: .headline)
        nameField.stringValue = naming.initialName
        nameField.placeholderString = "Name"
        nameField.bezelStyle = .roundedBezel
        nameField.delegate = self

        let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
        cancelButton.keyEquivalent = "\u{1b}"
        cancelButton.box.setAction { [weak self] _ in
            self?.dismiss(nil)
        }
        confirmButton.title = naming.confirmationTitle
        confirmButton.keyEquivalent = "\r"
        confirmButton.box.setAction { [weak self] _ in
            self?.submit()
        }
        let buttonStack = NSStackView(views: [cancelButton, confirmButton])
        buttonStack.orientation = .horizontal
        buttonStack.spacing = 8

        hierarchy {
            titleLabel
            nameField
            buttonStack
        }
        titleLabel.snp.makeConstraints { make in
            make.top.leading.equalToSuperview().inset(20)
        }
        nameField.snp.makeConstraints { make in
            make.top.equalTo(titleLabel.snp.bottom).offset(12)
            make.leading.trailing.equalToSuperview().inset(20)
        }
        buttonStack.snp.makeConstraints { make in
            make.top.equalTo(nameField.snp.bottom).offset(12)
            make.trailing.bottom.equalToSuperview().inset(20)
        }
        view.snp.makeConstraints { make in
            make.width.equalTo(320)
        }
        updateConfirmButton()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(nameField)
        nameField.currentEditor()?.selectAll(nil)
    }

    func controlTextDidChange(_ notification: Notification) {
        updateConfirmButton()
    }

    private var trimmedName: String {
        nameField.stringValue.trimmingCharacters(in: .whitespaces)
    }

    private func updateConfirmButton() {
        confirmButton.isEnabled = !trimmedName.isEmpty
    }

    private func submit() {
        guard !trimmedName.isEmpty else { return }
        commit(nameField.stringValue)
        dismiss(nil)
    }
}

/// What grouping by category would do, shown before it is done.
final class CategoryGroupingViewController: XiblessViewController<XiblessView> {
    private let grouping: LaunchpadOrganizerViewModel.CategoryGrouping
    private let confirm: () -> Void

    init(grouping: LaunchpadOrganizerViewModel.CategoryGrouping, confirm: @escaping () -> Void) {
        self.grouping = grouping
        self.confirm = confirm
        super.init()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        let titleLabel = NSTextField(labelWithString: "Group by Category")
        titleLabel.font = .preferredFont(forTextStyle: .headline)
        let explanationLabel = NSTextField(wrappingLabelWithString: grouping.groups.isEmpty
            ? "No application outside a folder shares a category with another, or with a folder of that name."
            : "Applications outside folders go into folders named after their App Store category.")
        explanationLabel.textColor = .secondaryLabelColor
        explanationLabel.isSelectable = false
        explanationLabel.preferredMaxLayoutWidth = 420

        let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
        cancelButton.keyEquivalent = "\u{1b}"
        cancelButton.box.setAction { [weak self] _ in
            self?.dismiss(nil)
        }
        let groupButton = NSButton(title: "Group", target: nil, action: nil)
        groupButton.keyEquivalent = "\r"
        groupButton.isEnabled = !grouping.groups.isEmpty
        groupButton.box.setAction { [weak self] _ in
            self?.confirm()
            self?.dismiss(nil)
        }
        let buttonStack = NSStackView(views: [cancelButton, groupButton])
        buttonStack.orientation = .horizontal
        buttonStack.spacing = 8

        hierarchy {
            titleLabel
            explanationLabel
            buttonStack
        }
        titleLabel.snp.makeConstraints { make in
            make.top.leading.equalToSuperview().inset(20)
        }
        explanationLabel.snp.makeConstraints { make in
            make.top.equalTo(titleLabel.snp.bottom).offset(12)
            make.leading.trailing.equalToSuperview().inset(20)
        }
        view.snp.makeConstraints { make in
            make.width.equalTo(460)
        }

        guard !grouping.groups.isEmpty else {
            buttonStack.snp.makeConstraints { make in
                make.top.equalTo(explanationLabel.snp.bottom).offset(12)
                make.trailing.bottom.equalToSuperview().inset(20)
            }
            return
        }
        let groupList = NSScrollViewController(documentView: CategoryGroupListView(groups: grouping.groups))
        hierarchy {
            groupList
        }
        groupList.view.snp.makeConstraints { make in
            make.top.equalTo(explanationLabel.snp.bottom).offset(12)
            make.leading.trailing.equalToSuperview().inset(20)
            make.height.greaterThanOrEqualTo(220)
        }
        buttonStack.snp.makeConstraints { make in
            make.top.equalTo(groupList.view.snp.bottom).offset(12)
            make.trailing.bottom.equalToSuperview().inset(20)
        }
    }
}

/// The groups of the category sheet, one under the other: the folder each makes or joins, and the
/// applications that go into it.
private final class CategoryGroupListView: XiblessView {
    init(groups: [LaunchpadOrganizer.CategoryGroup]) {
        super.init(frame: .zero)
        // The scroll view controller sizes an Auto Layout document to the visible width; a document left on
        // its frame stays at its zero frame, and the list shows nothing.
        translatesAutoresizingMaskIntoConstraints = false
        let rows = groups.enumerated().map { index, group in
            CategoryGroupRowView(group: group, showsSeparator: index < groups.count - 1)
        }
        let stackView = NSStackView(views: rows)
        stackView.orientation = .vertical
        stackView.alignment = .leading
        stackView.spacing = 0
        hierarchy {
            stackView
        }
        stackView.snp.makeConstraints { make in
            make.top.leading.trailing.equalToSuperview()
            make.bottom.lessThanOrEqualToSuperview()
        }
        for row in rows {
            row.snp.makeConstraints { make in
                make.width.equalTo(stackView)
            }
        }
    }
}

private final class CategoryGroupRowView: XiblessView {
    private let applicationsLabel: NSTextField

    init(group: LaunchpadOrganizer.CategoryGroup, showsSeparator: Bool) {
        applicationsLabel = NSTextField(wrappingLabelWithString: group.applications.map(\.title).joined(separator: ", "))
        super.init(frame: .zero)
        let titleLabel = NSTextField(labelWithString: group.existingFolder == nil ? "New folder “\(group.title)”" : "Into “\(group.title)”")
        titleLabel.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .medium)
        applicationsLabel.font = .preferredFont(forTextStyle: .callout)
        applicationsLabel.textColor = .secondaryLabelColor
        applicationsLabel.isSelectable = false
        let separatorView = NSBox()
        separatorView.boxType = .separator
        separatorView.isHidden = !showsSeparator

        hierarchy {
            titleLabel
            applicationsLabel
            separatorView
        }
        titleLabel.snp.makeConstraints { make in
            make.top.equalToSuperview().offset(6)
            make.leading.equalToSuperview().offset(16)
            make.trailing.lessThanOrEqualToSuperview().offset(-16)
        }
        applicationsLabel.snp.makeConstraints { make in
            make.top.equalTo(titleLabel.snp.bottom).offset(2)
            make.leading.trailing.equalToSuperview().inset(16)
            make.bottom.equalToSuperview().offset(-6)
        }
        separatorView.snp.makeConstraints { make in
            make.leading.trailing.equalToSuperview().inset(16)
            make.bottom.equalToSuperview()
        }
    }

    override func layout() {
        super.layout()
        let applicationsWidth = applicationsLabel.frame.width
        if applicationsWidth > 0, applicationsLabel.preferredMaxLayoutWidth != applicationsWidth {
            applicationsLabel.preferredMaxLayoutWidth = applicationsWidth
            needsLayout = true
        }
    }
}

/// Confirming that a folder is dissolved: its applications take its place on the page.
enum FolderDissolveConfirmation {
    /// An alert asking whether to dissolve `folder`. Its first button dissolves, and Return does not
    /// press it: Escape and Return both leave the folder alone.
    @MainActor
    static func alert(for folder: LaunchpadOrganizer.Folder) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = "Dissolve “\(folder.title)”?"
        alert.informativeText = "Its applications take its place on the page."
        let dissolveButton = alert.addButton(withTitle: "Dissolve")
        dissolveButton.hasDestructiveAction = true
        dissolveButton.keyEquivalent = ""
        let cancelButton = alert.addButton(withTitle: "Cancel")
        cancelButton.keyEquivalent = "\u{1b}"
        return alert
    }
}
