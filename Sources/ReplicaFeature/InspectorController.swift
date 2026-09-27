// The inspector: the selected task's fields, written as each is finished, over the Replica's path.
import AppKit
import ComposableArchitecture
import Models
import SwiftNavigation
import Taskrc

/// Edits the inspected task's non-date fields, writing each when you finish editing it, with no
/// Save. Below them, the Replica's full path, which the window's subtitle cuts short.
final class InspectorController: NSViewController, NSMenuDelegate, NSTextFieldDelegate {
	private let annotationField = editableField(placeholder: String(localized: "Add Annotation"))
	private let annotationList = verticalStack()
	private let blockingList = verticalStack()
	private let blockingSection = verticalStack()
	private let dependencyList = verticalStack()
	private let dependencyPopUp = NSPopUpButton(frame: .zero, pullsDown: true)
	private let descriptionField = editableField(placeholder: String(localized: "Description"))
	/// The task a field's edit belongs to, from its first keystroke, so a click on another row writes
	/// it to the task it was typed for. Nil while no field has changed, which writes nothing.
	private var editingTask: Models.Task.ID?
	private let noSelectionView = EmptyStateView(
		symbolName: "sidebar.trailing",
		title: String(localized: "No Selection"),
	)
	private let notInViewNote = captionLabel(
		String(localized: "Not in this view"),
		color: .secondaryLabelColor,
	)
	private let orphanList = verticalStack()
	private let orphanSection = verticalStack()
	private let pathField = WrappingLabel(wrappingLabelWithString: "")
	private let pathSection = NSStackView()
	private let projectField = editableField(placeholder: String(localized: "None"))
	private let recurrenceLabel = WrappingLabel(wrappingLabelWithString: "")
	private let recurrenceSection = verticalStack()
	/// What the lists last showed, so a store change that leaves them alone, such as a search, doesn't
	/// build their rows again.
	private var shownLists: InspectedLists?
	/// The task the fields show.
	private var shownTask: Models.Task.ID?
	private let store: StoreOf<ReplicaFeature>
	private let tagField = editableField(placeholder: String(localized: "Add Tag"))
	private let tagList = verticalStack()
	private let taskForm = verticalStack()
	/// Each editable UDA's control, kept across Taskrc reloads that leave its definition alone, so a
	/// half-edited value survives them.
	private var udaControls: [String: UDAControl] = [:]
	private let udaStack = verticalStack()

	/// The inspector's pane in the window's split view.
	private var splitViewItem: NSSplitViewItem? {
		(parent as? NSSplitViewController)?.splitViewItem(for: self)
	}

	init(store: StoreOf<ReplicaFeature>) {
		self.store = store
		super.init(nibName: nil, bundle: nil)
	}

	@available(*, unavailable)
	required init?(coder: NSCoder) {
		fatalError("init(coder:) has not been implemented")
	}

	override func loadView() {
		for field in [annotationField, descriptionField, projectField, tagField] {
			field.delegate = self
		}
		// A pull-down's first item is its title.
		dependencyPopUp.addItem(withTitle: addDependencyTitle)
		dependencyPopUp.menu?.delegate = self
		recurrenceLabel.isSelectable = true
		blockingSection.setViews([heading(String(localized: "Blocking")), blockingList], in: .top)
		orphanSection.setViews([heading(String(localized: "Other Attributes")), orphanList], in: .top)
		recurrenceSection.setViews([heading(String(localized: "Repeats")), recurrenceLabel], in: .top)
		taskForm.spacing = 16
		taskForm.setViews(
			[
				notInViewNote,
				section(String(localized: "Description"), [descriptionField]),
				section(String(localized: "Project"), [projectField]),
				section(String(localized: "Tags"), [tagList, tagField]),
				udaStack,
				recurrenceSection,
				section(String(localized: "Depends On"), [dependencyList, dependencyPopUp]),
				blockingSection,
				section(String(localized: "Annotations"), [annotationList, annotationField]),
				orphanSection,
			],
			in: .top,
		)
		udaStack.isHidden = true
		udaStack.spacing = 16

		// A path has few spaces to break at.
		pathField.lineBreakMode = .byCharWrapping
		pathField.isSelectable = true
		let reveal = NSButton(
			title: String(localized: "Reveal in Finder"),
			target: self,
			action: #selector(revealInFinderButtonClicked(_:)),
		)
		reveal.controlSize = .small
		let replicaHeading = heading(String(localized: "Replica"))
		pathSection.alignment = .leading
		pathSection.orientation = .vertical
		pathSection.setViews([replicaHeading, pathField, reveal], in: .top)
		pathSection.setCustomSpacing(4, after: replicaHeading)

		let content = FlippedView()
		let stack = verticalStack()
		stack.spacing = 24
		stack.setViews([taskForm, pathSection], in: .top)
		stack.translatesAutoresizingMaskIntoConstraints = false
		content.addSubview(stack)
		let scrollView = NSScrollView()
		scrollView.documentView = content
		scrollView.drawsBackground = false
		scrollView.hasVerticalScroller = true
		content.translatesAutoresizingMaskIntoConstraints = false

		let view = NSView()
		for subview in [scrollView, noSelectionView] {
			subview.translatesAutoresizingMaskIntoConstraints = false
			view.addSubview(subview)
		}
		let safeArea = view.safeAreaLayoutGuide
		NSLayoutConstraint.activate([
			content.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
			content.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
			content.trailingAnchor.constraint(equalTo: scrollView.contentView.trailingAnchor),
			noSelectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
			noSelectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
			noSelectionView.topAnchor.constraint(equalTo: pathSection.bottomAnchor),
			noSelectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
			pathField.widthAnchor.constraint(equalTo: pathSection.widthAnchor),
			pathSection.widthAnchor.constraint(equalTo: stack.widthAnchor),
			scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
			scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
			scrollView.topAnchor.constraint(equalTo: safeArea.topAnchor),
			scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
			stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
			stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
			stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
			stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
		])
		self.view = view
	}

	override func viewDidLoad() {
		super.viewDidLoad()
		observe { [weak self] in
			guard let self else {
				return
			}
			let path = store.directory?.path(percentEncoded: false)
			pathField.stringValue = path ?? ""
			pathSection.isHidden = path == nil
		}
		observe { [weak self] in
			self?.updateTask()
		}
	}

	func controlTextDidBeginEditing(_: Notification) {
		editingTask = shownTask
	}

	/// Writes the field to the task it was editing, once you've typed in it.
	func controlTextDidEndEditing(_ notification: Notification) {
		let id = editingTask
		editingTask = nil
		guard
			let field = notification.object as? NSTextField,
			let id,
			let task = store.allRows.first(where: { $0.id == id })?.task
		else {
			return
		}
		let text = field.stringValue
		switch field {
		case annotationField:
			field.stringValue = ""
			guard !text.trimmingCharacters(in: .whitespaces).isEmpty else {
				return
			}
			store.send(.annotationSubmitted(id, text))

		case descriptionField:
			submit(.string(text), for: "description", of: id)

		case projectField:
			submit(.string(text), for: "project", of: id)

		case tagField:
			field.stringValue = ""
			// Tags hold no spaces, so each word is one, as `task modify +a +b` adds them.
			for word in text.split(whereSeparator: \.isWhitespace) {
				let tag = String(word.drop { $0 == "+" })
				guard !tag.isEmpty else {
					continue
				}
				store.send(.inspectorFieldSubmitted(id, .addTag(tag)))
			}

		default:
			guard let name = field.identifier?.rawValue, let column = udaControls[name]?.column else {
				return
			}
			guard let value = udaValue(text, type: column.type) else {
				// Not a value of the UDA's type, which `task modify` refuses too.
				NSSound.beep()
				field.stringValue = task.properties[name] ?? ""
				return
			}
			submit(value, for: name, of: id)
		}
	}

	/// Lists the tasks the inspected task can come to depend on, in the table's order: open ones that
	/// don't already depend on it, however indirectly, since TW refuses the cycle that would make.
	func menuNeedsUpdate(_ menu: NSMenu) {
		menu.removeAllItems()
		menu.addItem(withTitle: addDependencyTitle, action: nil, keyEquivalent: "")
		guard let task = store.inspectedRow?.task else {
			return
		}
		let rows = store.allRows
		var dependents: Set = [task.id]
		var isGrowing = true
		while isGrowing {
			isGrowing = false
			for row in rows where !dependents.contains(row.id) {
				guard !row.task.dependencies.isDisjoint(with: dependents) else {
					continue
				}
				dependents.insert(row.id)
				isGrowing = true
			}
		}
		for row in rows where row.task.status.isOpen && !dependents.contains(row.id) {
			guard !task.dependencies.contains(row.id) else {
				continue
			}
			let item = NSMenuItem(
				title: row.inspectorTitle,
				action: #selector(dependencyChosen(_:)),
				keyEquivalent: "",
			)
			item.representedObject = row.id
			item.target = self
			menu.addItem(item)
		}
	}

	@objc
	func revealInFinderButtonClicked(_: Any?) {
		guard let directory = store.directory else {
			return
		}
		NSWorkspace.shared.activateFileViewerSelecting([directory])
	}

	@objc
	private func dependencyChosen(_ item: NSMenuItem) {
		guard
			let id = store.inspectedTask,
			let dependency = item.representedObject as? Models.Task.ID
		else {
			return
		}
		store.send(.dependencyChosen(id, dependency: dependency))
	}

	@objc
	private func udaValueChosen(_ popUp: NSPopUpButton) {
		guard
			let task = store.inspectedRow?.task,
			let name = popUp.identifier?.rawValue,
			let value = popUp.selectedItem?.representedObject as? String
		else {
			return
		}
		submit(.string(value), for: name, of: task.id)
	}

	/// Shows `value` in `field`, unless you're editing it, so the CLI changing it doesn't interrupt
	/// you. A field showing another task drops the edit, keeping the cursor in it.
	private func show(_ value: String, in field: NSTextField, isAnotherTask: Bool) {
		guard field.currentEditor() != nil else {
			field.stringValue = value
			return
		}
		guard isAnotherTask else {
			return
		}
		field.abortEditing()
		field.stringValue = value
		view.window?.makeFirstResponder(field)
	}

	/// Writes `value` to `property` of the task `id`. The last writer wins: the write plans against
	/// the tasks as last read, whatever the CLI did while you typed. A value the task already shows
	/// is still sent, since an edit still writing may be about to change it; a write that changes
	/// nothing commits nothing.
	private func submit(_ value: UDAValue, for property: String, of id: Models.Task.ID) {
		store.send(.inspectorFieldSubmitted(id, .set(property, value)))
	}

	/// Shows the inspected task's lists and read-only sections, and its UDAs' menus.
	private func updateLists(_ lists: InspectedLists) {
		let task = lists.task
		tagList.setViews(
			task.tags.sorted().map { tag in
				removableRow(selectableLabel(tag)) { [store] in
					store.send(.tagRemoveButtonTapped(task.id, tag: tag))
				}
			},
			in: .top,
		)

		for (name, uda) in udaControls {
			guard let popUp = uda.control as? NSPopUpButton else {
				continue
			}
			updateValues(of: popUp, column: uda.column, stored: task.properties[name] ?? "")
		}

		recurrenceSection.isHidden = task.recur == nil
		if let recur = task.recur {
			let ends = task.until.map {
				"\n" + String(localized: "Series ends \($0.formatted(date: .abbreviated, time: .omitted))")
			}
			recurrenceLabel.stringValue = recur + (ends ?? "")
		}

		dependencyList.setViews(
			lists.dependencies.map { dependency in
				let label = selectableLabel(dependency.title ?? dependency.uuid.uuidString.lowercased())
				return removableRow(label) { [store] in
					store.send(.dependencyRemoveButtonTapped(task.id, dependency: dependency.uuid))
				}
			},
			in: .top,
		)
		blockingList.setViews(lists.blocking.map(selectableLabel), in: .top)
		blockingSection.isHidden = lists.blocking.isEmpty

		annotationList.setViews(
			task.annotations.map { annotation in
				let date = captionLabel(
					annotation.entry.formatted(date: .abbreviated, time: .shortened),
					color: .secondaryLabelColor,
				)
				let entry = verticalStack()
				entry.spacing = 2
				entry.setViews([date, selectableLabel(annotation.description)], in: .top)
				return removableRow(entry) { [store] in
					store.send(.annotationDeleteButtonTapped(task.id, entry: annotation.entry))
				}
			},
			in: .top,
		)

		let orphans = task.orphans.sorted { $0.key < $1.key }
		orphanList.setViews(orphans.map { selectableLabel("\($0.key): \($0.value)") }, in: .top)
		orphanSection.isHidden = orphans.isEmpty
	}

	/// Shows the inspected task's fields, or why there's none.
	private func updateTask() {
		if updateUDAControls() {
			shownLists = nil
		}
		let row = store.inspectedRow
		let isAnotherTask = row?.id != shownTask
		shownTask = row?.id
		noSelectionView.isHidden = row != nil || store.selection.count > 1
		taskForm.isHidden = row == nil
		guard let row else {
			return
		}
		let task = row.task
		notInViewNote.isHidden = store.rows[id: task.id] != nil

		show(task.description, in: descriptionField, isAnotherTask: isAnotherTask)
		show(task.project ?? "", in: projectField, isAnotherTask: isAnotherTask)
		show("", in: tagField, isAnotherTask: isAnotherTask)
		show("", in: annotationField, isAnotherTask: isAnotherTask)
		for (name, uda) in udaControls {
			guard let field = uda.control as? NSTextField else {
				continue
			}
			show(task.properties[name] ?? "", in: field, isAnotherTask: isAnotherTask)
		}

		let rows = store.allRows
		let lists = InspectedLists(
			blocking: rows
				.filter { $0.task.status.isOpen && $0.task.dependencies.contains(task.id) }
				.map(\.inspectorTitle),
			dependencies: task.dependencies.sorted { $0.uuidString < $1.uuidString }.map { dependency in
				InspectedLists.Dependency(
					title: rows.first { $0.id == dependency }?.inspectorTitle,
					uuid: dependency,
				)
			},
			task: task,
		)
		if lists != shownLists {
			shownLists = lists
			updateLists(lists)
		}

		// New Task leaves you in the new task's description, so a collapsed inspector expands for it.
		if isAnotherTask, store.focusesDescription, let splitViewItem {
			splitViewItem.isCollapsed = false
			view.window?.makeFirstResponder(descriptionField)
		}
	}

	/// Makes a control for each UDA the inspector edits, reusing one whose definition is unchanged.
	/// Only the sections that changed come and go, since moving the one being edited would end its
	/// edit. Dates and durations are left for the date editor. Returns whether it made any.
	private func updateUDAControls() -> Bool {
		let columns = store.udaColumns.filter { $0.type != .date && $0.type != .duration }
		guard columns != udaControls.values.map(\.column).sorted(by: { $0.name < $1.name }) else {
			return false
		}
		var controls: [String: UDAControl] = [:]
		for column in columns {
			if let existing = udaControls[column.name], existing.column == column {
				controls[column.name] = existing
				continue
			}
			let control: NSControl
			if column.values.isEmpty {
				let field = editableField(placeholder: String(localized: "None"))
				field.delegate = self
				control = field
			} else {
				let popUp = NSPopUpButton(frame: .zero, pullsDown: false)
				popUp.action = #selector(udaValueChosen(_:))
				popUp.target = self
				control = popUp
			}
			control.identifier = NSUserInterfaceItemIdentifier(column.name)
			controls[column.name] = UDAControl(
				column: column,
				control: control,
				section: section(column.label, [control]),
			)
		}
		udaControls = controls
		let sections = columns.compactMap { controls[$0.name]?.section }
		for view in udaStack.arrangedSubviews where !sections.contains(view) {
			view.removeFromSuperview()
		}
		// The sections kept are already in order, so each new one goes in at its own index.
		for (index, section) in sections.enumerated() where !udaStack.arrangedSubviews.contains(section) {
			udaStack.insertArrangedSubview(section, at: index)
			section.widthAnchor.constraint(equalTo: udaStack.widthAnchor).isActive = true
		}
		udaStack.isHidden = columns.isEmpty
		return true
	}

	/// Lists `column`'s values in `popUp`, then None, which removes the UDA as `task modify <name>:`
	/// does, and a stored value the list doesn't name, then selects `stored`.
	private func updateValues(of popUp: NSPopUpButton, column: UDAColumn, stored: String) {
		var values = column.values
		for value in ["", stored] where !values.contains(value) {
			values.append(value)
		}
		popUp.removeAllItems()
		for value in values {
			popUp.addItem(withTitle: value.isEmpty ? String(localized: "None") : value)
			popUp.lastItem?.representedObject = value
		}
		popUp.selectItem(at: values.firstIndex(of: stored) ?? 0)
	}
}

extension TaskRow {
	/// The task as the inspector names it: its ID, where it has one, before its description.
	fileprivate var inspectorTitle: String {
		task.workingSetID.map { "\($0) \(task.description)" } ?? task.description
	}
}

private let addDependencyTitle = String(localized: "Add Dependency…")

/// A single-line field, edited in place, that wraps what it shows.
@MainActor
private func editableField(placeholder: String) -> NSTextField {
	let field = WrappingLabel(string: "")
	field.cell?.wraps = true
	field.cell?.isScrollable = false
	field.placeholderString = placeholder
	return field
}

@MainActor
private func heading(_ title: String) -> NSTextField {
	let heading = NSTextField(labelWithString: title)
	heading.font = .boldSystemFont(ofSize: NSFont.smallSystemFontSize)
	heading.textColor = .secondaryLabelColor
	return heading
}

/// `view`, with a button after it that calls `remove`.
@MainActor
private func removableRow(_ view: NSView, remove: @escaping @MainActor () -> Void) -> NSView {
	let button = ClosureButton(
		image: NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: nil)!,
		action: remove,
	)
	button.contentTintColor = .tertiaryLabelColor
	button.isBordered = false
	button.setAccessibilityLabel(String(localized: "Remove"))
	button.setContentHuggingPriority(.required, for: .horizontal)
	let row = NSStackView(views: [view, button])
	row.alignment = .top
	return row
}

/// A heading over `views`.
@MainActor
private func section(_ title: String, _ views: [NSView]) -> NSStackView {
	let title = heading(title)
	let stack = verticalStack()
	stack.setViews([title] + views, in: .top)
	stack.setCustomSpacing(4, after: title)
	return stack
}

@MainActor
private func selectableLabel(_ text: String) -> NSTextField {
	let label = WrappingLabel(wrappingLabelWithString: text)
	label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
	return label
}

/// The value typed into a UDA's field, or nil where it doesn't read as one of `type`. Empty text
/// removes the UDA.
private func udaValue(_ text: String, type: UDAType) -> UDAValue? {
	guard !text.isEmpty else {
		return .string("")
	}
	let value = UDAValue(text, as: type)
	// Text that doesn't read as the UDA's type comes back as a string, which `task modify` refuses.
	if case .string = value, type != .string {
		return nil
	}
	return value
}

/// A stack laying out its views top to bottom at its full width.
@MainActor
private func verticalStack() -> NSStackView {
	let stack = ColumnStack()
	stack.alignment = .leading
	stack.orientation = .vertical
	return stack
}

/// A button that calls a closure, for rows that each act on their own value.
private final class ClosureButton: NSButton {
	private var onClick: @MainActor () -> Void = {}

	convenience init(image: NSImage, action: @escaping @MainActor () -> Void) {
		self.init(image: image, target: nil, action: nil)
		onClick = action
		target = self
		self.action = #selector(clicked(_:))
	}

	@objc
	private func clicked(_: Any?) {
		onClick()
	}
}

/// A vertical stack that sizes its views to its own width, which an alignment alone doesn't.
private final class ColumnStack: NSStackView {
	private var widthConstraints: [NSLayoutConstraint] = []

	override func setViews(_ views: [NSView], in gravity: NSStackView.Gravity) {
		super.setViews(views, in: gravity)
		NSLayoutConstraint.deactivate(widthConstraints)
		widthConstraints = views.map { $0.widthAnchor.constraint(equalTo: widthAnchor) }
		NSLayoutConstraint.activate(widthConstraints)
	}
}

/// Lays the scroll view's content out from the top.
private final class FlippedView: NSView {
	override var isFlipped: Bool {
		true
	}
}

/// What the inspector's lists show: the task, and the titles of the tasks it depends on and blocks.
private struct InspectedLists: Equatable {
	struct Dependency: Equatable {
		var title: String?
		var uuid: UUID
	}

	var blocking: [String]
	/// Each dependency's title, where the Replica still has it, beside its UUID.
	var dependencies: [Dependency]
	var task: Models.Task
}

/// A UDA's control in the inspector, under its heading, with the definition it was made for.
private struct UDAControl {
	var column: UDAColumn
	var control: NSControl
	var section: NSView
}
