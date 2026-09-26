// The task table: an NSTableView over the Replica's rows, whose layout AppKit autosaves.
import AppKit
import ComposableArchitecture
import Models
import SwiftNavigation
import Taskrc

/// Shows the rows in the reducer's order, and sends back the selection and the sort. AppKit
/// autosaves the columns' widths, order and visibility, and the sort, under the Replica's name.
final class TaskTableController: NSViewController, NSMenuDelegate, NSTableViewDataSource,
	NSTableViewDelegate
{
	private let autosaveName: String
	private var highestUrgency = 0.0
	/// The sort a Replica starts with, which a saved one replaces. Kept from the start, since
	/// reading the store's in `updateColumns` would run it again on every sort.
	private let initialSortOrder: [TaskSort]
	/// Set while the table follows the store, so the changes it makes aren't sent back.
	private var isFollowingStore = false
	private var rows: IdentifiedArrayOf<TaskRow> = []
	private let store: StoreOf<ReplicaFeature>
	private let table = NSTableView()

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
		table.style = .inset
		table.usesAlternatingRowBackgroundColors = true
		for column in builtInColumns() {
			table.addTableColumn(column)
		}
		let headerMenu = NSMenu()
		headerMenu.delegate = self
		table.headerView?.menu = headerMenu
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

	func menuNeedsUpdate(_ menu: NSMenu) {
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
		rows.count
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
		let row = rows.elements[row]
		switch column {
		case .age, .due, .id, .project, .scheduled, .tags, .uda, .until, .wait:
			let cell = reusedCell(TextCell.init)
			cell.textField?.font =
				column == .id
					? .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
					: .systemFont(ofSize: NSFont.systemFontSize)
			cell.textField?.stringValue = text(column, of: row)
			return cell

		case .description:
			let cell = reusedCell(DescriptionCell.init)
			cell.configure(row)
			return cell

		case .urgency:
			let cell = reusedCell(UrgencyCell.init)
			cell.configure(urgency: row.urgency, highest: highestUrgency)
			return cell
		}
	}

	func tableViewSelectionDidChange(_: Notification) {
		guard !isFollowingStore else {
			return
		}
		let selection = Set(table.selectedRowIndexes.map { rows.elements[$0].id })
		store.send(.binding(.set(\.selection, selection)))
	}

	/// A cell the table can reuse, or a new one from `make`.
	private func reusedCell<Cell: NSView>(_ make: () -> Cell) -> Cell {
		let identifier = NSUserInterfaceItemIdentifier(String(describing: Cell.self))
		if let cell = table.makeView(withIdentifier: identifier, owner: nil) as? Cell {
			return cell
		}
		let cell = make()
		cell.identifier = identifier
		return cell
	}

	/// Tells the reducer the sort the table shows.
	private func sendSortOrder() {
		store.send(.sortOrderChanged(table.sortDescriptors.compactMap(TaskSort.init)))
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
			if
				let existing = table
					.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier(column.identifier))
			{
				existing.sortDescriptorPrototype = TaskSort(column, order: firstOrder).descriptor
				existing.title = uda.label
				continue
			}
			let tableColumn = makeColumn(
				column,
				firstOrder: firstOrder,
				minWidth: uda.type == .date ? dateColumnMinimumWidth : columnMinimumWidth,
				title: uda.label,
			)
			tableColumn.isHidden = true
			table.addTableColumn(tableColumn)
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

	/// Shows the store's rows and selection, reloading only when the rows changed.
	private func updateRows() {
		let rows = store.rows
		let highestUrgency = store.highestUrgency
		let selection = IndexSet(store.selection.compactMap { rows.index(id: $0) })
		isFollowingStore = true
		defer {
			isFollowingStore = false
		}
		if rows != self.rows || highestUrgency != self.highestUrgency {
			self.rows = rows
			self.highestUrgency = highestUrgency
			table.reloadData()
		}
		if table.selectedRowIndexes != selection {
			table.selectRowIndexes(selection, byExtendingSelection: false)
		}
	}

	/// Shows the table once its layout is restored, so the default never draws first, and while the
	/// Replica is open, since a failure takes its place.
	private func updateVisibility() {
		view.isHidden = table.autosaveName == nil || store.failure != nil
	}
}

/// Wide enough for a short project, tag list or UDA value, where no other floor applies.
private let columnMinimumWidth: CGFloat = 48

/// Wide enough for a date in full, numeric or relative.
private let dateColumnMinimumWidth: CGFloat = 80

private let descriptionIdentifier = TaskColumn.description.identifier

/// The columns every Taskrc has, in their default order. The dates past Due start hidden.
private func builtInColumns() -> [NSTableColumn] {
	let id = makeColumn(.id, minWidth: 32, title: String(localized: "ID"))
	id.width = 40
	id.maxWidth = 64
	let urgency = makeColumn(
		.urgency,
		firstOrder: .reverse,
		// Its title and the sort indicator it usually shows.
		minWidth: 80,
		title: String(localized: "Urgency"),
	)
	urgency.width = 80
	urgency.maxWidth = 96
	let description = makeColumn(.description, minWidth: 100, title: String(localized: "Description"))
	description.width = 240
	let hidden = [
		makeColumn(.age, minWidth: dateColumnMinimumWidth, title: String(localized: "Age")),
		makeColumn(.scheduled, minWidth: dateColumnMinimumWidth, title: String(localized: "Scheduled")),
		makeColumn(.wait, minWidth: dateColumnMinimumWidth, title: String(localized: "Wait")),
		makeColumn(.until, minWidth: dateColumnMinimumWidth, title: String(localized: "Until")),
	]
	for column in hidden {
		column.isHidden = true
	}
	return [
		id,
		urgency,
		description,
		makeColumn(.project, minWidth: columnMinimumWidth, title: String(localized: "Project")),
		makeColumn(.tags, minWidth: columnMinimumWidth, title: String(localized: "Tags")),
		makeColumn(.due, minWidth: dateColumnMinimumWidth, title: String(localized: "Due")),
	] + hidden
}

/// A column for `column`, whose header sorts in `firstOrder` when first clicked.
private func makeColumn(
	_ column: TaskColumn,
	firstOrder: SortOrder = .forward,
	minWidth: CGFloat,
	title: String,
) -> NSTableColumn {
	let tableColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(column.identifier))
	// Also the floor a column shrinks to as others appear or the window narrows.
	tableColumn.minWidth = minWidth
	tableColumn.sortDescriptorPrototype = TaskSort(column, order: firstOrder).descriptor
	tableColumn.title = title
	return tableColumn
}

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

/// A label that tail-truncates.
private func truncatingLabel() -> NSTextField {
	let label = NSTextField(labelWithString: "")
	label.lineBreakMode = .byTruncatingTail
	label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
	return label
}

/// A caption-sized label, as the description's markers are.
private func captionLabel(_ string: String, color: NSColor) -> NSTextField {
	let label = NSTextField(labelWithString: string)
	label.font = .preferredFont(forTextStyle: .caption1)
	label.textColor = color
	return label
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
}

/// The description, with a dot before an active task and markers after it.
private final class DescriptionCell: NSTableCellView {
	private let activeDot = NSView()
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

		activeDot.wantsLayer = true
		activeDot.layer?.cornerRadius = activeDotSize / 2
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

	override func viewDidChangeEffectiveAppearance() {
		super.viewDidChangeEffectiveAppearance()
		effectiveAppearance.performAsCurrentDrawingAppearance {
			activeDot.layer?.backgroundColor = NSColor.systemGreen.cgColor
		}
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
