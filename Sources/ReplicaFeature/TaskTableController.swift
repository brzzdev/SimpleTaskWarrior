// The task table: an NSTableView over the Replica's rows, whose layout AppKit autosaves.
import AppKit
import ComposableArchitecture
import Models
import SwiftNavigation
import Taskrc

/// Shows the rows in the reducer's order, under the new-task row while New Task has it open, and
/// sends back the selection and the sort. AppKit autosaves the columns' widths, order and
/// visibility, and the sort, under the Replica's name.
final class TaskTableController: NSViewController, NSMenuDelegate, NSTableViewDataSource,
	NSTableViewDelegate, NSTextFieldDelegate
{
	private let autosaveName: String
	private var highestUrgency = 0.0
	/// The sort a Replica starts with, which a saved one replaces. Kept from the start, since
	/// reading the store's in `updateColumns` would run it again on every sort.
	private let initialSortOrder: [TaskSort]
	/// Set while the table follows the store, so the changes it makes aren't sent back.
	private var isFollowingStore = false
	private var isNewTaskRowPresented = false
	private let rowMenu = NSMenu()
	private var rows: IdentifiedArrayOf<TaskRow> = []
	private let store: StoreOf<ReplicaFeature>
	private let table = NSTableView()

	/// How many rows the new-task row puts above the tasks.
	private var rowOffset: Int {
		isNewTaskRowPresented ? 1 : 0
	}

	init(autosaveName: String, store: StoreOf<ReplicaFeature>) {
		self.autosaveName = autosaveName
		initialSortOrder = store.sortOrder
		self.store = store
		super.init(nibName: nil, bundle: nil)
	}

	@available(*, unavailable)
	required init?(coder: NSCoder) {
		fatalError("init(coder:) has not been implemented")
	}

	override func loadView() {
		let scrollView = NSScrollView()
		scrollView.documentView = table
		scrollView.hasHorizontalScroller = true
		scrollView.hasVerticalScroller = true
		// Shown once the Replica's layout is restored, so the default layout never draws first.
		scrollView.isHidden = true
		view = scrollView
	}

	override func viewDidLoad() {
		super.viewDidLoad()
		table.allowsMultipleSelection = true
		// With only Description autoresizing, it alone takes the width the table gains or loses.
		table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
		table.style = .inset
		table.usesAlternatingRowBackgroundColors = true
		for tableColumn in builtInColumns() {
			let column = TaskColumn(identifier: tableColumn.identifier.rawValue)
			addColumn(tableColumn, widestCell: column.flatMap(sampleCell))
		}
		let headerMenu = NSMenu()
		headerMenu.delegate = self
		table.headerView?.menu = headerMenu
		rowMenu.items = ReplicaWindowController.taskCommandMenuItems()
		rowMenu.delegate = self
		table.menu = rowMenu
		table.dataSource = self
		table.delegate = self

		observe { [weak self] in
			self?.updateColumns()
		}
		observe { [weak self] in
			self?.updateRows()
		}
		observe { [weak self] in
			self?.updateVisibility()
		}
	}

	@objc
	func columnVisibilityMenuItemSelected(_ menuItem: NSMenuItem) {
		guard let column = menuItem.representedObject as? NSTableColumn else {
			return
		}
		column.isHidden.toggle()
	}

	func control(_: NSControl, textView _: NSTextView, doCommandBy selector: Selector) -> Bool {
		guard selector == #selector(cancelOperation(_:)) else {
			return false
		}
		store.send(.newTaskEditingCancelled)
		return true
	}

	/// Ends the new-task row with its description, unless Escape ended it first.
	func controlTextDidEndEditing(_ notification: Notification) {
		guard store.isNewTaskRowPresented, let field = notification.object as? NSTextField else {
			return
		}
		store.send(.newTaskDescriptionSubmitted(field.stringValue))
	}

	func menuNeedsUpdate(_ menu: NSMenu) {
		guard menu !== rowMenu else {
			updateRowMenu()
			return
		}
		menu.removeAllItems()
		for column in table.tableColumns where column.identifier.rawValue != descriptionIdentifier {
			let item = NSMenuItem(
				title: column.title,
				action: #selector(columnVisibilityMenuItemSelected(_:)),
				keyEquivalent: "",
			)
			item.representedObject = column
			item.state = column.isHidden ? .off : .on
			item.target = self
			menu.addItem(item)
		}
	}

	func numberOfRows(in _: NSTableView) -> Int {
		rows.count + rowOffset
	}

	func tableView(_: NSTableView, shouldSelectRow row: Int) -> Bool {
		self.row(at: row) != nil
	}

	func tableView(
		_: NSTableView,
		sortDescriptorsDidChange _: [NSSortDescriptor],
	) {
		guard !isFollowingStore else {
			return
		}
		sendSortOrder()
	}

	func tableView(_: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
		guard
			let tableColumn,
			let column = TaskColumn(identifier: tableColumn.identifier.rawValue)
		else {
			return nil
		}
		guard let row = self.row(at: row) else {
			guard column == .description else {
				return nil
			}
			let cell = table.reusedCell(NewTaskCell.init)
			cell.textField?.delegate = self
			cell.textField?.stringValue = ""
			return cell
		}
		switch column {
		case .age, .due, .id, .project, .scheduled, .tags, .uda, .until, .wait:
			let cell = table.reusedCell(TextCell.init)
			cell.configure(column, of: row)
			return cell

		case .description:
			let cell = table.reusedCell(DescriptionCell.init)
			cell.configure(row)
			return cell

		case .urgency:
			let cell = table.reusedCell(UrgencyCell.init)
			cell.configure(urgency: row.urgency, highest: highestUrgency)
			return cell
		}
	}

	func tableViewSelectionDidChange(_: Notification) {
		guard !isFollowingStore else {
			return
		}
		let selection = Set(table.selectedRowIndexes.compactMap { row(at: $0)?.id })
		store.send(.binding(.set(\.selection, selection)))
	}

	/// Adds `tableColumn`, starting fitted to `widestCell` where one is given.
	private func addColumn(_ tableColumn: NSTableColumn, widestCell: NSView?) {
		setMinimumWidth(of: tableColumn, widestCell: widestCell)
		if widestCell != nil {
			tableColumn.width = tableColumn.minWidth
		}
		table.addTableColumn(tableColumn)
	}

	/// Scrolls to the new-task row and puts the cursor in it.
	private func beginNewTask() {
		table.scrollRowToVisible(0)
		let column = table.column(withIdentifier: NSUserInterfaceItemIdentifier(descriptionIdentifier))
		guard
			column >= 0,
			let cell = table.view(atColumn: column, row: 0, makeIfNecessary: true) as? NewTaskCell
		else {
			return
		}
		view.window?.makeFirstResponder(cell.textField)
	}

	/// The task a table row shows, or nil for the new-task row.
	private func row(at index: Int) -> TaskRow? {
		let index = index - rowOffset
		return rows.indices.contains(index) ? rows.elements[index] : nil
	}

	/// Tells the reducer the sort the table shows.
	private func sendSortOrder() {
		store.send(.sortOrderChanged(table.sortDescriptors.compactMap(TaskSort.init)))
	}

	/// Keeps `tableColumn` wide enough for its whole title with the sort arrow, above `widestCell`.
	/// Also the floor Description shrinks to as the window narrows, past which the table scrolls.
	private func setMinimumWidth(of tableColumn: NSTableColumn, widestCell: NSView?) {
		let header = tableColumn.headerCell
		// Any width does: the arrow sits a fixed distance from the header's trailing edge.
		let bounds = NSRect(x: 0, y: 0, width: 100, height: 20)
		let arrowWidth = bounds.maxX - header.sortIndicatorRect(forBounds: bounds).minX
		let headerWidth = header.cellSize.width + arrowWidth
		// A cell sits the table's spacing narrower than its column.
		let cellWidth = widestCell.map { $0.fittingSize.width + table.intercellSpacing.width } ?? 0
		// The larger, not the sum, since the header sits above the cells rather than beside them.
		tableColumn.minWidth = max(headerWidth, cellWidth)
	}

	/// Keeps a column per UDA the Taskrc defines, then names the table's autosave once the first
	/// Taskrc has loaded. Autosave restores only the columns that exist when it's named, so a UDA
	/// column added later starts from the defaults.
	private func updateColumns() {
		let udaColumns = store.udaColumns
		let udaIdentifiers = Set(udaColumns.map { TaskColumn.uda($0.name).identifier })
		var removedColumn = false
		for column in table.tableColumns {
			guard
				case .uda? = TaskColumn(identifier: column.identifier.rawValue),
				!udaIdentifiers.contains(column.identifier.rawValue)
			else {
				continue
			}
			table.removeTableColumn(column)
			removedColumn = true
		}
		for uda in udaColumns {
			let column = TaskColumn.uda(uda.name)
			// Descending first where `values` lists the order, so the first click shows the list as
			// written, while each direction still sorts as the CLI's `<name>-` and `<name>+` do.
			let firstOrder: SortOrder = uda.values.isEmpty ? .forward : .reverse
			// A date UDA shows its dates as Due does.
			let widestCell = uda.type == .date ? sampleCell(.due) : nil
			if
				let existing = table
					.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier(column.identifier))
			{
				existing.sortDescriptorPrototype = TaskSort(column, order: firstOrder).descriptor
				existing.title = uda.label
				setMinimumWidth(of: existing, widestCell: widestCell)
				continue
			}
			let tableColumn = makeColumn(column, firstOrder: firstOrder, title: uda.label)
			tableColumn.isHidden = true
			addColumn(tableColumn, widestCell: widestCell)
		}
		// Removing a column drops any sort by it without telling the delegate, so the reducer would
		// go on sorting by a UDA the Taskrc no longer has.
		if removedColumn, table.autosaveName != nil {
			sendSortOrder()
		}

		// The name also records that the layout was restored, so it happens once.
		guard table.autosaveName == nil, store.taskrc != nil else {
			return
		}
		// Sent once below, whichever of these two sets the sort.
		isFollowingStore = true
		table.sortDescriptors = initialSortOrder.map(\.descriptor)
		table.autosaveName = autosaveName
		table.autosaveTableColumns = true
		isFollowingStore = false
		updateVisibility()
		// The table fits its columns to its width only when that width changes. Without this, the
		// defaults, or a layout saved in a wider window, would start wider than the table. A layout
		// that already fits comes through unchanged.
		view.layoutSubtreeIfNeeded()
		table.sizeToFit()
		sendSortOrder()
	}

	/// Acts on the right-clicked row, selecting it first where it isn't already, as Finder does. Lists
	/// the commands the toolbar does.
	private func updateRowMenu() {
		let clicked = table.clickedRow
		if row(at: clicked) != nil, !table.selectedRowIndexes.contains(clicked) {
			table.selectRowIndexes(IndexSet(integer: clicked), byExtendingSelection: false)
		}
		for item in rowMenu.items {
			let command = ReplicaFeature.TaskCommand(action: item.action)
			item.isHidden = command.map { !store.state.isOffered($0) } ?? false
		}
	}

	/// Shows the store's rows and selection, reloading only when the rows changed. Scrolls to a task
	/// the store selects, such as one New Task created, and to the new-task row as it opens.
	private func updateRows() {
		let rows = store.rows
		let highestUrgency = store.highestUrgency
		let isNewTaskRowPresented = store.isNewTaskRowPresented
		isFollowingStore = true
		defer {
			isFollowingStore = false
		}
		let opensNewTaskRow = isNewTaskRowPresented && !self.isNewTaskRowPresented
		let keepsNewTaskRow = isNewTaskRowPresented && self.isNewTaskRowPresented
		if
			rows != self.rows || highestUrgency != self.highestUrgency
			|| isNewTaskRowPresented != self.isNewTaskRowPresented
		{
			self.rows = rows
			self.highestUrgency = highestUrgency
			self.isNewTaskRowPresented = isNewTaskRowPresented
			if keepsNewTaskRow {
				// Reloading the new-task row would end its editing and submit the draft early.
				table.noteNumberOfRowsChanged()
				table.reloadData(
					forRowIndexes: IndexSet(integersIn: rowOffset ..< table.numberOfRows),
					columnIndexes: IndexSet(integersIn: 0 ..< table.numberOfColumns),
				)
			} else {
				table.reloadData()
			}
		}
		let selection = IndexSet(store.selection.compactMap { rows.index(id: $0).map { $0 + rowOffset } })
		if table.selectedRowIndexes != selection {
			let added = selection.subtracting(table.selectedRowIndexes)
			table.selectRowIndexes(selection, byExtendingSelection: false)
			if let first = added.first {
				table.scrollRowToVisible(first)
			}
		}
		if opensNewTaskRow {
			beginNewTask()
		}
	}

	/// Shows the table once its layout is restored, so the default never draws first, and while the
	/// Replica is open, since a failure takes its place.
	private func updateVisibility() {
		view.isHidden = table.autosaveName == nil || store.failure != nil
	}
}

private let descriptionIdentifier = TaskColumn.description.identifier

/// The columns every Taskrc has, in their default order. The dates past Due start hidden.
@MainActor
private func builtInColumns() -> [NSTableColumn] {
	let hidden = [
		makeColumn(.age, title: String(localized: "Age")),
		makeColumn(.scheduled, title: String(localized: "Scheduled")),
		makeColumn(.wait, title: String(localized: "Wait")),
		makeColumn(.until, title: String(localized: "Until")),
	]
	for column in hidden {
		column.isHidden = true
	}
	return [
		makeColumn(.id, title: String(localized: "ID")),
		makeColumn(.urgency, firstOrder: .reverse, title: String(localized: "Urgency")),
		makeColumn(.description, title: String(localized: "Description")),
		makeColumn(.project, title: String(localized: "Project")),
		makeColumn(.tags, title: String(localized: "Tags")),
		makeColumn(.due, title: String(localized: "Due")),
	] + hidden
}

/// A column for `column`, whose header sorts in `firstOrder` when first clicked.
@MainActor
private func makeColumn(
	_ column: TaskColumn,
	firstOrder: SortOrder = .forward,
	title: String,
) -> NSTableColumn {
	let tableColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(column.identifier))
	// Every other column keeps its width until it's resized by hand.
	tableColumn.resizingMask =
		column == .description ? [.autoresizingMask, .userResizingMask] : .userResizingMask
	tableColumn.sortDescriptorPrototype = TaskSort(column, order: firstOrder).descriptor
	tableColumn.title = title
	return tableColumn
}

/// A cell showing `column` for `sampleRow`, or nil where no content sets a floor.
@MainActor
private func sampleCell(_ column: TaskColumn) -> NSView? {
	switch column {
	case .age, .due, .id, .scheduled, .until, .wait:
		let cell = TextCell()
		cell.configure(column, of: sampleRow)
		return cell

	case .description:
		let cell = DescriptionCell()
		cell.configure(sampleRow)
		return cell

	case .project, .tags, .uda:
		return nil

	case .urgency:
		let cell = UrgencyCell()
		cell.configure(urgency: sampleRow.urgency, highest: 0)
		return cell
	}
}

/// A row as wide as the table expects in each column that has a sample cell: every marker with a
/// two-digit annotation count, and a few characters of description beside them.
private let sampleRow: TaskRow = {
	// 28 December 2026, whose day and month take two digits in every zone and numeric date style.
	let date = Date(timeIntervalSince1970: 1_798_459_200)
	// Three digits, as a working set of up to 999 pending tasks shows.
	var task = Models.Task(description: "Buy milk", id: UUID(), status: .pending, workingSetID: 999)
	task.annotations = Array(
		repeating: Models.Task.Annotation(description: "", entry: date),
		count: 10,
	)
	task.due = date
	// Its Age reads in months, the widest unit it's likely to show.
	task.entry = Date.now.addingTimeInterval(-335 * 24 * 60 * 60)
	task.parent = ""
	task.scheduled = date
	task.start = date
	task.until = date
	task.wait = date
	// Two whole digits and a sign, wider than all but the rarest Urgency.
	return TaskRow(isBlocked: true, task: task, udaColumns: [], urgency: -99.9, view: .pending)
}()

/// What a plain text cell shows for `column`.
private func text(_ column: TaskColumn, of row: TaskRow) -> String {
	switch column {
	case .age:
		row.task.entry?.formatted(.relative(presentation: .numeric, unitsStyle: .narrow)) ?? ""

	case .description:
		row.task.description

	case .due:
		dateText(row.task.due)

	case .id:
		row.task.workingSetID.map(String.init) ?? ""

	case .project:
		row.task.project ?? ""

	case .scheduled:
		dateText(row.task.scheduled)

	case .tags:
		row.tags

	case let .uda(name):
		udaText(row.task.udas[name])

	case .until:
		dateText(row.task.until)

	case .urgency:
		row.urgency.formatted(.number.precision(.fractionLength(1)))

	case .wait:
		dateText(row.task.wait)
	}
}

private func dateText(_ date: Date?) -> String {
	date?.formatted(date: .numeric, time: .omitted) ?? ""
}

private func udaText(_ value: UDAValue?) -> String {
	switch value {
	case nil:
		""

	case let .date(date):
		dateText(date)

	case let .duration(duration):
		duration.description

	case let .numeric(number):
		number.formatted()

	case let .string(string):
		string

	case let .uuid(uuid):
		uuid.uuidString.lowercased()
	}
}

/// One line of text, centred in its row.
private final class TextCell: NSTableCellView {
	init() {
		super.init(frame: .zero)
		let label = truncatingLabel()
		label.translatesAutoresizingMaskIntoConstraints = false
		addSubview(label)
		NSLayoutConstraint.activate([
			label.centerYAnchor.constraint(equalTo: centerYAnchor),
			label.leadingAnchor.constraint(equalTo: leadingAnchor),
			label.trailingAnchor.constraint(equalTo: trailingAnchor),
		])
		textField = label
	}

	@available(*, unavailable)
	required init?(coder: NSCoder) {
		fatalError("init(coder:) has not been implemented")
	}

	func configure(_ column: TaskColumn, of row: TaskRow) {
		textField?.font =
			column == .id
				? .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
				: .systemFont(ofSize: NSFont.systemFontSize)
		textField?.stringValue = text(column, of: row)
	}
}

/// The description, with a dot before an active task and markers after it.
private final class DescriptionCell: NSTableCellView {
	private let activeDot = NSBox()
	private let annotationCount = captionLabel("", color: .secondaryLabelColor)
	private let annotations: NSStackView
	private let blocked = captionLabel(String(localized: "Blocked"), color: .systemRed)
	private let repeats = NSTextField(labelWithString: "↻")

	init() {
		let annotationImage = NSImageView()
		annotationImage.image = NSImage(systemSymbolName: "text.bubble", accessibilityDescription: nil)
		annotationImage.contentTintColor = .secondaryLabelColor
		annotationImage.symbolConfiguration = NSImage.SymbolConfiguration(textStyle: .caption1)
		annotations = NSStackView(views: [annotationImage, annotationCount])
		annotations.spacing = 2
		annotations.setAccessibilityElement(true)
		annotations.setAccessibilityRole(.staticText)
		super.init(frame: .zero)

		// A custom box redraws its fill color for each appearance, where a layer's `CGColor` would
		// stay fixed.
		activeDot.borderWidth = 0
		activeDot.boxType = .custom
		activeDot.cornerRadius = activeDotSize / 2
		activeDot.fillColor = .systemGreen
		activeDot.titlePosition = .noTitle
		activeDot.setAccessibilityElement(true)
		activeDot.setAccessibilityLabel(String(localized: "Active"))
		activeDot.setAccessibilityRole(.image)
		repeats.setAccessibilityLabel(String(localized: "Repeats"))
		repeats.textColor = .secondaryLabelColor
		let description = truncatingLabel()
		let stack = NSStackView(views: [activeDot, description, blocked, annotations, repeats])
		stack.spacing = 6
		stack.translatesAutoresizingMaskIntoConstraints = false
		addSubview(stack)
		NSLayoutConstraint.activate([
			activeDot.heightAnchor.constraint(equalToConstant: activeDotSize),
			activeDot.widthAnchor.constraint(equalToConstant: activeDotSize),
			stack.centerYAnchor.constraint(equalTo: centerYAnchor),
			stack.leadingAnchor.constraint(equalTo: leadingAnchor),
			stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
		])
		textField = description
	}

	@available(*, unavailable)
	required init?(coder: NSCoder) {
		fatalError("init(coder:) has not been implemented")
	}

	func configure(_ row: TaskRow) {
		let count = row.task.annotations.count
		activeDot.isHidden = row.task.start == nil
		annotationCount.stringValue = "\(count)"
		annotations.isHidden = count == 0
		annotations.setAccessibilityLabel(
			String(AttributedString(localized: "^[\(count) annotation](inflect: true)").characters),
		)
		blocked.isHidden = !row.isBlocked
		repeats.isHidden = !row.task.isInstance
		textField?.stringValue = row.task.description
	}
}

private let activeDotSize: CGFloat = 7

/// The new-task row's description, which takes the cursor as the row opens.
private final class NewTaskCell: NSTableCellView {
	init() {
		super.init(frame: .zero)
		let field = NSTextField()
		field.cell?.isScrollable = true
		field.placeholderString = newTaskTitle
		field.translatesAutoresizingMaskIntoConstraints = false
		addSubview(field)
		NSLayoutConstraint.activate([
			field.centerYAnchor.constraint(equalTo: centerYAnchor),
			field.leadingAnchor.constraint(equalTo: leadingAnchor),
			field.trailingAnchor.constraint(equalTo: trailingAnchor),
		])
		textField = field
	}

	@available(*, unavailable)
	required init?(coder: NSCoder) {
		fatalError("init(coder:) has not been implemented")
	}
}

/// Urgency to one decimal, over a thin bar scaled to the list's highest. Urgency of 0 or less
/// draws no bar.
private final class UrgencyCell: NSTableCellView {
	private let bar = CALayer()
	/// The bar's share of the cell's width.
	private var fraction = 0.0

	init() {
		super.init(frame: .zero)
		wantsLayer = true
		bar.cornerRadius = urgencyBarHeight / 2
		layer?.addSublayer(bar)
		let label = NSTextField(labelWithString: "")
		label.alignment = .right
		label.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
		label.translatesAutoresizingMaskIntoConstraints = false
		addSubview(label)
		NSLayoutConstraint.activate([
			label.centerYAnchor.constraint(equalTo: centerYAnchor),
			label.leadingAnchor.constraint(equalTo: leadingAnchor),
			label.trailingAnchor.constraint(equalTo: trailingAnchor),
		])
		textField = label
	}

	@available(*, unavailable)
	required init?(coder: NSCoder) {
		fatalError("init(coder:) has not been implemented")
	}

	override func layout() {
		super.layout()
		guard let label = textField else {
			return
		}
		// Under the text, as a background aligned to its bottom.
		bar.frame = CGRect(
			x: label.frame.minX,
			y: label.frame.minY,
			width: label.frame.width * fraction,
			height: urgencyBarHeight,
		)
		effectiveAppearance.performAsCurrentDrawingAppearance {
			bar.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.4).cgColor
		}
	}

	override func viewDidChangeEffectiveAppearance() {
		super.viewDidChangeEffectiveAppearance()
		needsLayout = true
	}

	func configure(urgency: Double, highest: Double) {
		fraction = urgency > 0 && highest > 0 ? urgency / highest : 0
		textField?.stringValue = urgency.formatted(.number.precision(.fractionLength(1)))
		needsLayout = true
	}
}

private let urgencyBarHeight: CGFloat = 2
