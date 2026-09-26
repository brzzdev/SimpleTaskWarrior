// The sidebar: fixed views, the project tree and tags, which narrow the table, over the Context.
import AppKit
import ComposableArchitecture
import SwiftNavigation
import Taskrc

/// A source list of the store's sidebar, which sends back its selection, and a footer naming the
/// active Context.
final class SidebarController: NSViewController, NSOutlineViewDataSource, NSOutlineViewDelegate {
	private let contextFooter = NSStackView()
	private let contextLabel = truncatingLabel()
	/// Kept here, since a reload makes new nodes and forgets which were expanded.
	private var expandedProjects: Set<String> = []
	/// Set while the outline follows the store, so the changes it makes aren't sent back.
	private var isFollowingStore = false
	private var nodes: [SidebarNode] = []
	private let outline = NSOutlineView()
	private var sidebar: Sidebar?
	private let store: StoreOf<ReplicaFeature>

	init(store: StoreOf<ReplicaFeature>) {
		self.store = store
		super.init(nibName: nil, bundle: nil)
	}

	@available(*, unavailable)
	required init?(coder: NSCoder) {
		fatalError("init(coder:) has not been implemented")
	}

	override func loadView() {
		let view = NSView()
		let scrollView = NSScrollView()
		scrollView.documentView = outline
		scrollView.drawsBackground = false
		scrollView.hasVerticalScroller = true
		let info = NSButton(
			image: NSImage(systemSymbolName: "info.circle", accessibilityDescription: nil)!,
			target: self,
			action: #selector(contextInfoButtonClicked(_:)),
		)
		info.isBordered = false
		info.setAccessibilityLabel(String(localized: "About the Context"))
		contextLabel.textColor = .secondaryLabelColor
		contextFooter.edgeInsets = NSEdgeInsets(top: 8, left: 16, bottom: 8, right: 16)
		contextFooter.setViews([contextLabel, info], in: .leading)
		for subview in [contextFooter, scrollView] {
			subview.translatesAutoresizingMaskIntoConstraints = false
			view.addSubview(subview)
		}
		NSLayoutConstraint.activate([
			contextFooter.bottomAnchor.constraint(equalTo: view.bottomAnchor),
			contextFooter.leadingAnchor.constraint(equalTo: view.leadingAnchor),
			contextFooter.trailingAnchor.constraint(equalTo: view.trailingAnchor),
			scrollView.bottomAnchor.constraint(equalTo: contextFooter.topAnchor),
			scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
			scrollView.topAnchor.constraint(equalTo: view.topAnchor),
			scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
		])
		self.view = view
	}

	override func viewDidLoad() {
		super.viewDidLoad()
		let column = NSTableColumn()
		outline.addTableColumn(column)
		outline.outlineTableColumn = column
		outline.allowsEmptySelection = true
		outline.allowsMultipleSelection = true
		outline.floatsGroupRows = false
		outline.headerView = nil
		outline.style = .sourceList
		outline.dataSource = self
		outline.delegate = self

		observe { [weak self] in
			self?.updateOutline()
		}
		observe { [weak self] in
			guard let self else {
				return
			}
			let context = store.activeContext
			contextFooter.isHidden = context == nil
			contextLabel.stringValue = context.map { String(localized: "Context: \($0)") } ?? ""
		}
	}

	@objc
	func contextInfoButtonClicked(_ sender: NSButton) {
		let label = WrappingLabel(wrappingLabelWithString: contextSummary(
			skipped: store.runningTaskrc.contextWrite.skipped,
		))
		label.translatesAutoresizingMaskIntoConstraints = false
		let content = NSView()
		content.addSubview(label)
		NSLayoutConstraint.activate([
			label.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12),
			label.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
			label.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
			label.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
			label.widthAnchor.constraint(equalToConstant: contextPopoverWidth),
		])
		let controller = NSViewController()
		controller.view = content
		let popover = NSPopover()
		popover.behavior = .transient
		popover.contentViewController = controller
		// Above the button, which sits at the window's bottom. A button is flipped, so that's `minY`.
		popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
	}

	func outlineView(_: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
		children(of: item)[index]
	}

	func outlineView(_: NSOutlineView, isGroupItem item: Any) -> Bool {
		(item as? SidebarNode)?.item == nil
	}

	func outlineView(_: NSOutlineView, isItemExpandable item: Any) -> Bool {
		!children(of: item).isEmpty
	}

	func outlineView(_: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
		children(of: item).count
	}

	func outlineView(_: NSOutlineView, shouldSelectItem item: Any) -> Bool {
		(item as? SidebarNode)?.item != nil
	}

	func outlineView(_: NSOutlineView, viewFor _: NSTableColumn?, item: Any) -> NSView? {
		guard let node = item as? SidebarNode else {
			return nil
		}
		guard let item = node.item else {
			let cell = outline.reusedCell(HeaderCell.init)
			cell.textField?.stringValue = node.title
			return cell
		}
		let cell = outline.reusedCell(ItemCell.init)
		cell.configure(item, count: node.count)
		return cell
	}

	func outlineViewItemDidCollapse(_ notification: Notification) {
		guard case let .project(name)? = expandedNode(in: notification)?.item else {
			return
		}
		expandedProjects.remove(name)
	}

	func outlineViewItemDidExpand(_ notification: Notification) {
		guard case let .project(name)? = expandedNode(in: notification)?.item else {
			return
		}
		expandedProjects.insert(name)
	}

	func outlineViewSelectionDidChange(_: Notification) {
		guard !isFollowingStore else {
			return
		}
		let selection = Set(outline.selectedRowIndexes.compactMap {
			(outline.item(atRow: $0) as? SidebarNode)?.item
		})
		store.send(.binding(.set(\.sidebarSelection, selection)))
	}

	private func children(of item: Any?) -> [SidebarNode] {
		guard let node = item as? SidebarNode else {
			return nodes
		}
		return node.children
	}

	/// The node a expand or collapse notification is about.
	private func expandedNode(in notification: Notification) -> SidebarNode? {
		notification.userInfo?[outlineItemKey] as? SidebarNode
	}

	/// Shows the store's sidebar and its selection, reloading only when the sidebar changed, and
	/// keeping expanded the projects that were, and those above a selected one.
	private func updateOutline() {
		let sidebar = store.sidebar
		let selection = store.sidebarSelection
		isFollowingStore = true
		defer {
			isFollowingStore = false
		}
		if sidebar != self.sidebar {
			self.sidebar = sidebar
			nodes = SidebarNode.sections(of: sidebar)
			outline.reloadData()
		}
		for case let .project(name) in selection {
			expandedProjects.formUnion(name.ancestry.dropLast())
		}
		var rows = IndexSet()
		// Top down, so a node's parent is expanded, and the node has a row, by the time it's reached.
		func follow(_ nodes: [SidebarNode]) {
			for node in nodes {
				if let item = node.item, selection.contains(item) {
					let row = outline.row(forItem: node)
					if row >= 0 {
						rows.insert(row)
					}
				}
				if case let .project(name)? = node.item, !expandedProjects.contains(name) {
					continue
				}
				outline.expandItem(node)
				follow(node.children)
			}
		}
		follow(nodes)
		if outline.selectedRowIndexes != rows {
			outline.selectRowIndexes(rows, byExtendingSelection: false)
		}
	}
}

/// A row of the outline: a section header where `item` is nil. A class, since the outline tells
/// its rows apart by identity.
private final class SidebarNode {
	let children: [SidebarNode]
	/// 0 for a section header, which shows none.
	let count: Int
	let item: SidebarItem?
	let title: String

	/// A section header.
	init(title: String, children: [SidebarNode]) {
		self.children = children
		count = 0
		item = nil
		self.title = title
	}

	init(_ item: SidebarItem, count: Int, children: [SidebarNode] = []) {
		self.children = children
		self.count = count
		self.item = item
		title = item.title
	}

	/// The fixed views, then a Projects and a Tags section where either has any.
	static func sections(of sidebar: Sidebar) -> [SidebarNode] {
		var sections = sidebar.views.map { SidebarNode($0.item, count: $0.count) }
		if !sidebar.projects.isEmpty {
			sections.append(
				SidebarNode(title: String(localized: "Projects"), children: sidebar.projects.map(project)),
			)
		}
		if !sidebar.tags.isEmpty {
			sections.append(
				SidebarNode(
					title: String(localized: "Tags"),
					children: sidebar.tags.map { SidebarNode($0.item, count: $0.count) },
				),
			)
		}
		return sections
	}

	private static func project(_ project: Sidebar.Project) -> SidebarNode {
		SidebarNode(
			.project(project.name),
			count: project.count,
			children: project.children.map(Self.project),
		)
	}
}

extension SidebarItem {
	fileprivate var symbolName: String {
		switch self {
		case .project: "folder"
		case .tag: "tag"
		case .view(.completed): "checkmark.circle"
		case .view(.deleted): "trash"
		case .view(.pending): "tray"
		case .view(.waiting): "hourglass"
		}
	}

	/// A project by its last segment, since the tree shows the rest.
	fileprivate var title: String {
		switch self {
		case let .project(name): name.components(separatedBy: ".").last ?? name
		case let .tag(tag): tag
		case .view(.completed): String(localized: "Completed")
		case .view(.deleted): String(localized: "Deleted")
		case .view(.pending): String(localized: "Pending")
		case .view(.waiting): String(localized: "Waiting")
		}
	}
}

/// A section's title.
private final class HeaderCell: NSTableCellView {
	init() {
		super.init(frame: .zero)
		let label = NSTextField(labelWithString: "")
		label.translatesAutoresizingMaskIntoConstraints = false
		addSubview(label)
		NSLayoutConstraint.activate([
			label.centerYAnchor.constraint(equalTo: centerYAnchor),
			label.leadingAnchor.constraint(equalTo: leadingAnchor),
			label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
		])
		textField = label
	}

	@available(*, unavailable)
	required init?(coder: NSCoder) {
		fatalError("init(coder:) has not been implemented")
	}
}

/// A symbol, a title and a count.
private final class ItemCell: NSTableCellView {
	private let countLabel = NSTextField(labelWithString: "")

	init() {
		super.init(frame: .zero)
		let symbol = NSImageView()
		let title = truncatingLabel()
		// So the title takes the row's spare width, and the count sits at its trailing edge.
		title.setContentHuggingPriority(.defaultLow, for: .horizontal)
		countLabel.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
		countLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
		let stack = NSStackView(views: [symbol, title, countLabel])
		stack.distribution = .fill
		stack.setCustomSpacing(4, after: symbol)
		stack.translatesAutoresizingMaskIntoConstraints = false
		addSubview(stack)
		NSLayoutConstraint.activate([
			stack.centerYAnchor.constraint(equalTo: centerYAnchor),
			stack.leadingAnchor.constraint(equalTo: leadingAnchor),
			stack.trailingAnchor.constraint(equalTo: trailingAnchor),
			// Symbols differ in width, and the titles line up only past a fixed one.
			symbol.widthAnchor.constraint(equalToConstant: symbolWidth),
		])
		imageView = symbol
		textField = title
	}

	@available(*, unavailable)
	required init?(coder: NSCoder) {
		fatalError("init(coder:) has not been implemented")
	}

	func configure(_ item: SidebarItem, count: Int) {
		countLabel.stringValue = String(count)
		// A fixed view's count reads brighter than a project's or tag's.
		if case .view = item {
			countLabel.textColor = .secondaryLabelColor
		} else {
			countLabel.textColor = .tertiaryLabelColor
		}
		imageView?.image = NSImage(systemSymbolName: item.symbolName, accessibilityDescription: nil)
		textField?.stringValue = item.title
	}
}

/// What the Context's popover says: which of its parts apply, and the write defaults skipped.
private func contextSummary(skipped: [String]) -> String {
	let applies = String(
		localized: "The Context’s rc.* overrides and write defaults apply. Its read filter doesn’t: the sidebar and search narrow the list instead.",
	)
	guard !skipped.isEmpty else {
		return applies
	}
	let list = ListFormatter.localizedString(byJoining: skipped)
	return applies + " " + String(localized: "New tasks skip these write defaults: \(list).")
}

private let contextPopoverWidth: CGFloat = 260

/// Where an outline's expand and collapse notifications carry the item, as `NSOutlineView`
/// documents.
private let outlineItemKey = "NSObject"

private let symbolWidth: CGFloat = 20
