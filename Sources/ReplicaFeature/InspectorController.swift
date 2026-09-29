// The inspector: the selected task's fields, or the project and tags of several, written as each
// is finished, over the Replica's path.
import AppKit
import ComposableArchitecture
import Models
import SwiftNavigation
import Taskrc

/// Edits the inspected task's fields, writing each when you finish editing it, with no Save. With
/// several tasks selected, it's a bulk panel: their project and tags, with Done and Delete. Below
/// either, the Replica's full path, which the window's subtitle cuts short.
final class InspectorController: NSViewController, NSMenuDelegate, NSTextFieldDelegate {
	/// A field Set Project… or Add Tag… puts the cursor in.
	enum Field {
		case project
		case tag
	}

	private let annotationField = editableField(placeholder: String(localized: "Add Annotation"))
	private let annotationList = verticalStack()
	private let blockingList = verticalStack()
	private let blockingSection = verticalStack()
	private let bulkDeleteButton = commandButton(.delete)
	private let bulkDoneButton = commandButton(.done)
	/// The bulk panel's count and its Done and Delete, over the project and tags.
	private let bulkHeader = verticalStack()
	private let bulkTitle = NSTextField(labelWithString: "")
	/// The built-in date attributes' editors under their headings, in the order they show.
	private let dateEditors: [(title: String, editor: DateEditor)]
	private let dependencyList = verticalStack()
	private let dependencyPopUp = NSPopUpButton(frame: .zero, pullsDown: true)
	private let descriptionField = editableField(placeholder: String(localized: "Description"))
	private let descriptionSection: NSStackView
	/// The sections below the tags, which only one task shows.
	private let detailStack = verticalStack()
	/// The tasks a field's edit belongs to, from its first keystroke, so a click on another row writes
	/// it to the tasks it was typed for. Empty while no field has changed, which writes nothing.
	private var editingTasks: [Models.Task.ID] = []
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
	private let projectField = editableField(placeholder: noneTitle)
	private let recurrenceLabel = WrappingLabel(wrappingLabelWithString: "")
	private let recurrenceSection = verticalStack()
	/// What the lists last showed, so a store change that leaves them alone, such as a search, doesn't
	/// build their rows again.
	private var shownLists: InspectedLists?
	/// The tags the bulk panel's list shows, as `shownLists` is for one task.
	private var shownTags: [String] = []
	/// The tasks the fields show: the inspected one, or the selected ones in the table's order.
	private var shownTasks: [Models.Task.ID] = []
	private let store: StoreOf<ReplicaFeature>
	private let tagField = editableField(placeholder: String(localized: "Add Tag"))
	private let tagList = verticalStack()
	private let taskForm = verticalStack()
	@Dependency(\.timeZone) private var timeZone
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
		dateEditors = [
			(String(localized: "Due"), "due"),
			(String(localized: "Scheduled"), "scheduled"),
			(String(localized: "Wait"), "wait"),
			(String(localized: "Until"), "until"),
		].map { title, property in
			(title, dateEditor(property, kind: .date, store: store))
		}
		descriptionSection = section(String(localized: "Description"), [descriptionField])
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
		bulkTitle.font = .boldSystemFont(ofSize: NSFont.preferredFont(forTextStyle: .title3).pointSize)
		let bulkButtons = NSStackView(views: [bulkDoneButton, bulkDeleteButton])
		bulkButtons.alignment = .centerY
		bulkHeader.spacing = 8
		bulkHeader.setViews([bulkTitle, bulkButtons], in: .top)
		detailStack.spacing = 16
		detailStack.setViews(
			dateEditors.map { section($0.title, [$0.editor]) } + [
				udaStack,
				recurrenceSection,
				section(String(localized: "Depends On"), [dependencyList, dependencyPopUp]),
				blockingSection,
				section(String(localized: "Annotations"), [annotationList, annotationField]),
				orphanSection,
			],
			in: .top,
		)
		taskForm.spacing = 16
		taskForm.setViews(
			[
				notInViewNote,
				bulkHeader,
				descriptionSection,
				section(String(localized: "Project"), [projectField]),
				section(String(localized: "Tags"), [tagList, tagField]),
				detailStack,
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
		// Below the Replica's path where it can be, but pinned to the pane, not to the scrolling
		// content: a long task form scrolls the path past the pane's bottom.
		let belowPath = noSelectionView.topAnchor.constraint(equalTo: pathSection.bottomAnchor)
		belowPath.priority = .defaultHigh
		NSLayoutConstraint.activate([
			belowPath,
			content.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
			content.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
			content.trailingAnchor.constraint(equalTo: scrollView.contentView.trailingAnchor),
			noSelectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
			noSelectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
			noSelectionView.topAnchor.constraint(greaterThanOrEqualTo: safeArea.topAnchor),
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

	/// Puts the cursor in `field` for the tasks the inspector shows, expanding a collapsed inspector.
	func beginEditing(_ field: Field) {
		splitViewItem?.isCollapsed = false
		let target =
			switch field {
			case .project: projectField
			case .tag: tagField
			}
		view.window?.makeFirstResponder(target)
	}

	func controlTextDidBeginEditing(_: Notification) {
		editingTasks = shownTasks
	}

	/// Writes the field to the tasks it was editing, once you've typed in it. Only the project and
	/// tag fields show for several; the rest edit the one task.
	func controlTextDidEndEditing(_ notification: Notification) {
		let ids = editingTasks
		editingTasks = []
		guard
			let field = notification.object as? NSTextField,
			let id = ids.first,
			let task = store.allRows.first(where: { $0.id == id })?.task
		else {
			return
		}
		let text = field.stringValue
		switch field {
		case annotationField:
			field.stringValue = ""
			// Spaces alone are what the planner refuses as blank; tabs and no-break spaces are text
			// `task annotate` keeps.
			guard !text.allSatisfy({ $0 == " " }) else {
				return
			}
			store.send(.annotationSubmitted(id, text))

		case descriptionField:
			submit(.string(text), for: "description", of: ids)

		case projectField:
			submit(.string(text), for: "project", of: ids)

		case tagField:
			field.stringValue = ""
			// One write, so one Undo point, however many tags you typed.
			let tags = tags(in: text)
			guard !tags.isEmpty else {
				return
			}
			store.send(.inspectorFieldSubmitted(ids, .addTags(tags)))

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
			submit(value, for: name, of: ids)
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
		submit(.string(value), for: name, of: [task.id])
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

	/// Writes `value` to `property` of the tasks `ids`. The last writer wins: the write plans against
	/// the tasks as last read, whatever the CLI did while you typed. A value the task already shows
	/// is still sent, since an edit still writing may be about to change it; a write that changes
	/// nothing commits nothing.
	private func submit(_ value: UDAValue, for property: String, of ids: [Models.Task.ID]) {
		store.send(.inspectorFieldSubmitted(ids, .set(property, value)))
	}

	/// A row for each of `tags`, whose button removes it from the tasks `ids`.
	private func tagRows(_ tags: [String], of ids: [Models.Task.ID]) -> [NSView] {
		tags.map { tag in
			removableRow(selectableLabel(tag)) { [store] in
				store.send(.tagRemoveButtonTapped(ids, tag: tag))
			}
		}
	}

	/// Shows the inspected task's lists and read-only sections, and its UDAs' menus.
	private func updateLists(_ lists: InspectedLists) {
		let task = lists.task
		tagList.setViews(tagRows(task.tags.sorted(), of: [task.id]), in: .top)

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

	/// Shows the inspected task's fields, the selected tasks' project and tags, or why there's
	/// neither.
	private func updateTask() {
		if updateUDAControls() {
			shownLists = nil
		}
		let isBulk = store.selection.count > 1
		let row = isBulk ? nil : store.inspectedRow
		// The table's order only matters, and is only worth scanning the rows for, with several.
		let tasks = isBulk ? store.selectedIDs : row.map { [$0.id] } ?? []
		// By membership: the same tasks reordered, as an Urgency change can, keep what you're typing.
		let isAnotherTask = Set(tasks) != Set(shownTasks)
		shownTasks = tasks
		noSelectionView.isHidden = !tasks.isEmpty
		taskForm.isHidden = tasks.isEmpty
		bulkHeader.isHidden = !isBulk
		descriptionSection.isHidden = isBulk
		detailStack.isHidden = isBulk
		if isBulk {
			notInViewNote.isHidden = true
			showSelection(tasks, isAnotherSelection: isAnotherTask)
			return
		}
		guard let row else {
			return
		}
		projectField.placeholderString = noneTitle
		let task = row.task
		notInViewNote.isHidden = store.rows[id: task.id] != nil

		// What you typed stays while its write runs, and while a failed one's alert is up, rather than
		// showing the value it replaces.
		if isAnotherTask || store.writeProgress == nil {
			showFields(of: task, isAnotherTask: isAnotherTask)
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

	/// Shows `task`'s values in its fields, date editors and UDA controls.
	private func showFields(of task: Models.Task, isAnotherTask: Bool) {
		show(task.description, in: descriptionField, isAnotherTask: isAnotherTask)
		show(task.project ?? "", in: projectField, isAnotherTask: isAnotherTask)
		show("", in: tagField, isAnotherTask: isAnotherTask)
		show("", in: annotationField, isAnotherTask: isAnotherTask)
		let planner = WritePlanner(taskrc: store.runningTaskrc, timeZone: timeZone)
		for (_, editor) in dateEditors {
			editor.show(task, isAnotherTask: isAnotherTask, planner: planner)
		}
		for (name, uda) in udaControls {
			switch uda.control {
			case let editor as DateEditor:
				editor.show(task, isAnotherTask: isAnotherTask, planner: planner)

			case let field as NSTextField:
				show(task.properties[name] ?? "", in: field, isAnotherTask: isAnotherTask)

			default:
				continue
			}
		}
	}

	/// Shows the selected tasks `ids`' project where they share one, and every tag any of them has,
	/// with Done and Delete for them all.
	private func showSelection(_ ids: [Models.Task.ID], isAnotherSelection: Bool) {
		// The lists show several tasks' tags now, so one task's are shown afresh.
		shownLists = nil
		bulkTitle.stringValue = String(localized: "\(ids.count) Tasks Selected")
		let enabled = store.enabledCommands
		bulkDeleteButton.isEnabled = enabled.contains(.delete)
		bulkDoneButton.isEnabled = enabled.contains(.done)

		let projects = store.selectedProjects
		// Nil where they differ, else the project they share, which may be none.
		let project = projects.count == 1 ? projects.first : nil
		projectField.placeholderString = project == nil ? String(localized: "Multiple Values") : noneTitle
		// As one task's fields keep what you typed while its write runs.
		if isAnotherSelection || store.writeProgress == nil {
			show(project.flatMap(\.self) ?? "", in: projectField, isAnotherTask: isAnotherSelection)
			show("", in: tagField, isAnotherTask: isAnotherSelection)
		}

		let tags = store.selectedTags
		guard isAnotherSelection || tags != shownTags else {
			return
		}
		shownTags = tags
		tagList.setViews(tagRows(tags, of: ids), in: .top)
	}

	/// Makes a control for each UDA the inspector edits, reusing one whose definition is unchanged.
	/// Only the sections that changed come and go, since moving the one being edited would end its
	/// edit. Returns whether it made any.
	private func updateUDAControls() -> Bool {
		let columns = store.udaColumns
		guard columns != udaControls.values.map(\.column).sorted(by: { $0.name < $1.name }) else {
			return false
		}
		var controls: [String: UDAControl] = [:]
		for column in columns {
			if let existing = udaControls[column.name], existing.column == column {
				controls[column.name] = existing
				continue
			}
			let control: NSView
			if column.type == .date || column.type == .duration {
				control = dateEditor(column.name, kind: column.type, store: store)
			} else if column.values.isEmpty {
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

/// An empty field's placeholder, as for a task with no project.
private let noneTitle = String(localized: "None")

/// A button that sends `command` along the responder chain, as the toolbar's do.
@MainActor
private func commandButton(_ command: ReplicaFeature.TaskCommand) -> NSButton {
	NSButton(title: command.title, target: nil, action: command.action)
}

/// An editor of the date or duration `property` that sends its edits to `store`.
@MainActor
private func dateEditor(
	_ property: String,
	kind: UDAType,
	store: StoreOf<ReplicaFeature>,
) -> DateEditor {
	DateEditor(property: property, kind: kind) { store.send(.inspectorFieldSubmitted([$0], $1)) }
}

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

/// The tags typed into a tag field. Tags hold no spaces, so each word is one, as
/// `task modify +a +b` adds them, with any leading `+` dropped.
private func tags(in text: String) -> [String] {
	text.split(whereSeparator: \.isWhitespace)
		.map { String($0.drop { $0 == "+" }) }
		.filter { !$0.isEmpty }
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
	var control: NSView
	var section: NSView
}
