// The window over one Replica: a sidebar, the task table and an inspector, under a toolbar.
public import AppKit
import ComposableArchitecture
public import Foundation
import SwiftNavigation
import Taskrc
import UniformTypeIdentifiers

/// Shows one Replica, and handles the menu bar's Taskrc and task commands while its window is in
/// front.
public final class ReplicaWindowController: NSWindowController, NSMenuItemValidation,
	NSToolbarDelegate, NSWindowDelegate
{
	private let store: StoreOf<ReplicaFeature>

	/// The alert on screen, for a failed write or a broken chain, so a store change while it's up
	/// doesn't show a second.
	private var alert: NSAlert?
	private let commandItems = Dictionary(
		uniqueKeysWithValues: ReplicaFeature.TaskCommand.all.map { command in
			(
				command,
				commandItem(
					command.identifier,
					action: command.action,
					label: command.title,
					symbolName: command.symbolName,
				),
			)
		},
	)
	private var fetch: _Concurrency.Task<Void, Never>?
	private let inspector: InspectorController
	private let newTaskItem = commandItem(
		newTaskIdentifier,
		action: #selector(newTask(_:)),
		label: newTaskTitle,
		symbolName: "square.and.pencil",
	)
	private let onClose: @MainActor () -> Void
	/// The file panel on screen, so a store change while it's up doesn't open a second.
	private var openPanel: NSOpenPanel?
	private let searchItem = NSSearchToolbarItem(itemIdentifier: searchIdentifier)

	/// Every tag any selected task has, which Remove Tag lists.
	fileprivate var selectedTags: [String] {
		store.selectedTags
	}

	/// A controller for the Replica `bookmark` locates, which autosaves the layout of its split
	/// view and table under `autosaveName`. It calls `onClose` as its window closes.
	public init(
		autosaveName: String,
		bookmark: Data,
		onClose: @escaping @MainActor () -> Void,
	) {
		self.onClose = onClose
		store = Store(initialState: ReplicaFeature.State(bookmark: bookmark)) {
			ReplicaFeature()
		}
		inspector = InspectorController(store: store)
		let window = ReplicaWindow(
			contentRect: NSRect(origin: .zero, size: windowSize),
			styleMask: [.closable, .fullSizeContentView, .miniaturizable, .resizable, .titled],
			backing: .buffered,
			defer: false,
		)
		// The controller owns the window, and ARC releases it.
		window.isReleasedWhenClosed = false
		window.toolbarStyle = .unified
		super.init(window: window)

		let sidebar = NSSplitViewItem(sidebarWithViewController: SidebarController(store: store))
		// Wide enough for every fixed view's title beside its count.
		sidebar.minimumThickness = 170
		let inspectorItem = NSSplitViewItem(inspectorWithViewController: inspector)
		// An inspector's maximum defaults to its minimum, which leaves its divider nothing to drag. The
		// cap leaves the table room at the default window size.
		inspectorItem.maximumThickness = 400
		let split = NSSplitViewController()
		split.splitViewItems = [
			sidebar,
			NSSplitViewItem(
				viewController: ReplicaContentController(autosaveName: autosaveName, store: store),
			),
			inspectorItem,
		]
		// Keeps the divider positions and whether the inspector is collapsed.
		split.splitView.autosaveName = autosaveName
		window.contentViewController = split
		// Setting the content view controller sizes the window to its content, which has no size yet.
		window.setContentSize(windowSize)
		window.delegate = self

		searchItem.searchField.action = #selector(searchFieldChanged(_:))
		searchItem.searchField.target = self
		let toolbar = NSToolbar(identifier: "replica")
		toolbar.allowsDisplayModeCustomization = false
		toolbar.delegate = self
		toolbar.displayMode = .iconOnly
		window.toolbar = toolbar

		observe { [weak self] in
			guard let self, let window = self.window else {
				return
			}
			window.subtitle =
				store.writeProgress == .saving
					? String(localized: "Saving…")
					: store.directory?.path(percentEncoded: false) ?? ""
			window.title = store.directory?.lastPathComponent ?? ""
		}
		observe { [weak self] in
			self?.updateCommandItems()
		}
		observe { [weak self] in
			guard let self, let fileImporter = store.fileImporter else {
				return
			}
			beginOpenPanel(for: fileImporter)
		}
		observe { [weak self] in
			guard let self, case let .failed(failure)? = store.writeProgress else {
				return
			}
			beginAlert(for: failure)
		}
		observe { [weak self] in
			guard let self, let prompt = store.chainRepairPrompt else {
				return
			}
			beginAlert(for: prompt)
		}
		// The store clears a search that would hide the task New Task created.
		observe { [weak self] in
			guard let self, searchItem.searchField.stringValue != store.searchText else {
				return
			}
			searchItem.searchField.stringValue = store.searchText
		}
		fetch = _Concurrency.Task { [store] in
			await store.send(.fetchRequested).finish()
		}
	}

	@available(*, unavailable)
	required init?(coder: NSCoder) {
		fatalError("init(coder:) has not been implemented")
	}

	/// The bookmark a window encoded for restoration after a relaunch.
	public static func bookmark(restoredFrom state: NSCoder) -> Data? {
		state.decodeObject(of: NSData.self, forKey: bookmarkKey) as Data?
	}

	/// The task commands, then Set Project…, Add Tag… and Remove Tag, as the menu bar's Task menu
	/// and a row's context menu list them.
	public static func taskCommandMenuItems() -> [NSMenuItem] {
		let removeTag = NSMenu(title: String(localized: "Remove Tag"))
		removeTag.delegate = removeTagMenuDelegate
		let removeTagItem = NSMenuItem(title: removeTag.title, action: nil, keyEquivalent: "")
		removeTagItem.submenu = removeTag
		return ReplicaFeature.TaskCommand.all.map { command in
			NSMenuItem(title: command.title, action: command.action, keyEquivalent: command.keyEquivalent)
		} + [
			.separator(),
			NSMenuItem(
				title: String(localized: "Set Project…"),
				action: #selector(setProject(_:)),
				keyEquivalent: "",
			),
			NSMenuItem(
				title: String(localized: "Add Tag…"),
				action: #selector(addTag(_:)),
				keyEquivalent: "",
			),
			removeTagItem,
		]
	}

	/// Puts the cursor in the tag field for the selected tasks.
	@objc
	public func addTag(_: Any?) {
		inspector.beginEditing(.tag)
	}

	@objc
	public func chooseTaskrc(_: Any?) {
		store.send(.chooseTaskrcButtonTapped)
	}

	@objc
	public func deleteTasks(_: Any?) {
		store.send(.deleteButtonTapped)
	}

	/// Puts the cursor in the search field.
	@objc
	public func find(_: Any?) {
		searchItem.beginSearchInteraction()
	}

	@objc
	public func markDone(_: Any?) {
		store.send(.doneButtonTapped)
	}

	@objc
	public func markPending(_: Any?) {
		store.send(.markPendingButtonTapped)
	}

	@objc
	public func newTask(_: Any?) {
		store.send(.newTaskButtonTapped)
	}

	/// Re-applies the Undo point the window last undid.
	@objc
	public func redo(_: Any?) {
		store.send(.redoButtonTapped)
	}

	/// Removes the tag a Remove Tag item names from every selected task.
	@objc
	public func removeTag(_ sender: Any?) {
		guard let tag = (sender as? NSMenuItem)?.representedObject as? String else {
			return
		}
		store.send(.tagRemoveButtonTapped(store.selectedIDs, tag: tag))
	}

	@objc
	public func selectNextTask(_: Any?) {
		selectAdjacentTask(.nextTaskButtonTapped)
	}

	@objc
	public func selectPreviousTask(_: Any?) {
		selectAdjacentTask(.previousTaskButtonTapped)
	}

	/// Puts the cursor in the project field for the selected tasks.
	@objc
	public func setProject(_: Any?) {
		inspector.beginEditing(.project)
	}

	@objc
	public func showCompleted(_: Any?) {
		show(.completed)
	}

	@objc
	public func showDeleted(_: Any?) {
		show(.deleted)
	}

	@objc
	public func showPending(_: Any?) {
		show(.pending)
	}

	@objc
	public func showWaiting(_: Any?) {
		show(.waiting)
	}

	@objc
	public func startOrStop(_: Any?) {
		store.send(.startStopButtonTapped)
	}

	public func toolbar(
		_: NSToolbar,
		itemForItemIdentifier identifier: NSToolbarItem.Identifier,
		willBeInsertedIntoToolbar _: Bool,
	) -> NSToolbarItem? {
		(Array(commandItems.values) + [newTaskItem, searchItem])
			.first { $0.itemIdentifier == identifier }
	}

	public func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
		toolbarDefaultItemIdentifiers(toolbar)
	}

	public func toolbarDefaultItemIdentifiers(_: NSToolbar) -> [NSToolbarItem.Identifier] {
		// The tracking separators give the title bar the content's section, where the subtitle
		// tail-truncates rather than running over the inspector.
		[
			.toggleSidebar,
			.sidebarTrackingSeparator,
			newTaskIdentifier,
			.flexibleSpace,
		] + ReplicaFeature.TaskCommand.all.map(\.identifier) + [
			searchIdentifier,
			.inspectorTrackingSeparator,
			.flexibleSpace,
			.toggleInspector,
		]
	}

	/// Undoes the window's newest Undo point.
	@objc
	public func undo(_: Any?) {
		store.send(.undoButtonTapped)
	}

	@objc
	public func useTaskwarriorDefaults(_: Any?) {
		store.send(.useTaskwarriorDefaultsButtonTapped)
	}

	public func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
		if let command = ReplicaFeature.TaskCommand(action: menuItem.action) {
			return validate(menuItem, for: command)
		}
		return switch menuItem.action {
		case #selector(addTag(_:)), #selector(removeTag(_:)), #selector(setProject(_:)):
			store.canEditSelection

		case #selector(newTask(_:)):
			store.canCreateTask

		case #selector(redo(_:)):
			validate(
				menuItem,
				title: store.redoName.map { String(localized: "Redo \($0)") }
					?? String(localized: "Can’t Redo"),
				isEnabled: store.canRedo,
			)

		case #selector(selectNextTask(_:)):
			store.state.adjacentTask(1) != nil

		case #selector(selectPreviousTask(_:)):
			store.state.adjacentTask(-1) != nil

		case #selector(undo(_:)):
			validate(
				menuItem,
				title: store.undoName.map { String(localized: "Undo \($0)") }
					?? String(localized: "Can’t Undo"),
				isEnabled: store.canUndo,
			)

		case #selector(useTaskwarriorDefaults(_:)):
			store.hasTaskrc

		default:
			true
		}
	}

	public func window(_: NSWindow, willEncodeRestorableState state: NSCoder) {
		state.encode(store.bookmark as NSData, forKey: bookmarkKey)
	}

	public func windowWillClose(_: Notification) {
		fetch?.cancel()
		onClose()
	}

	@objc
	func searchFieldChanged(_ searchField: NSSearchField) {
		store.send(.binding(.set(\.searchText, searchField.stringValue)))
	}

	/// Sends `action`, which selects another task, first ending the edit in progress, which writes it
	/// to the task it was typed for. Whatever had the cursor keeps it, so a field in the inspector
	/// goes on to the next task's value.
	private func selectAdjacentTask(_ action: ReplicaFeature.Action) {
		guard let window else {
			return
		}
		var responder = window.firstResponder
		if let editor = responder as? NSText, let field = editor.delegate as? NSControl {
			responder = field
			window.makeFirstResponder(nil)
		}
		store.send(action)
		window.makeFirstResponder(responder)
	}

	/// Selects `view` alone in the sidebar, as a click on it does.
	private func show(_ view: TaskView) {
		store.send(.binding(.set(\.sidebarSelection, [.view(view)])))
	}

	/// Shows the alert for `failure` as a sheet on the window, and reports the button clicked.
	private func beginAlert(for failure: ReplicaFeature.WriteFailure) {
		guard alert == nil, let window else {
			return
		}
		let alert = NSAlert()
		alert.messageText = failure.title
		alert.informativeText = failure.reason
		if failure.retry == nil {
			alert.addButton(withTitle: String(localized: "OK"))
		} else {
			alert.addButton(withTitle: String(localized: "Try Again"))
			alert.addButton(withTitle: String(localized: "Cancel"))
		}
		self.alert = alert
		alert.beginSheetModal(for: window) { [weak self] response in
			guard let self else {
				return
			}
			self.alert = nil
			guard failure.retry != nil, response == .alertFirstButtonReturn else {
				store.send(.writeFailureDismissed)
				return
			}
			store.send(.writeFailureTryAgainButtonTapped)
		}
	}

	/// Asks as a sheet on the window whether to repair the chains `prompt` breaks, and reports the
	/// answer.
	private func beginAlert(for prompt: ReplicaFeature.ChainRepairPrompt) {
		guard alert == nil, let window else {
			return
		}
		let alert = NSAlert()
		alert.messageText = prompt.title
		alert.informativeText = prompt.message
		alert.addButton(withTitle: String(localized: "Repair"))
		alert.addButton(withTitle: String(localized: "Don't Repair"))
		alert.addButton(withTitle: String(localized: "Cancel"))
		self.alert = alert
		alert.beginSheetModal(for: window) { [weak self] response in
			guard let self else {
				return
			}
			self.alert = nil
			switch response {
			case .alertFirstButtonReturn:
				store.send(.repairChainButtonTapped)

			case .alertSecondButtonReturn:
				store.send(.dontRepairChainButtonTapped)

			default:
				store.send(.chainRepairDismissed)
			}
		}
	}

	/// Opens the file panel `fileImporter` asks for as a sheet on the window, and reports the file
	/// chosen, or that it was cancelled.
	private func beginOpenPanel(for fileImporter: ReplicaFeature.FileImporter) {
		guard openPanel == nil, let window else {
			return
		}
		let panel = NSOpenPanel()
		// Files, and the symlinks dotfile managers make of them. Folders and packages are neither.
		panel.allowedContentTypes = [.data, .symbolicLink]
		panel.canChooseDirectories = false
		panel.directoryURL = fileImporter.directory
		panel.message = fileImporter.message
		panel.showsHiddenFiles = true
		openPanel = panel
		panel.beginSheetModal(for: window) { [weak self] response in
			guard let self else {
				return
			}
			openPanel = nil
			guard response == .OK, let file = panel.url else {
				store.send(.binding(.set(\.fileImporter, nil)))
				return
			}
			store.send(.fileChosen(file, for: fileImporter))
		}
	}

	/// Shows and enables each toolbar item as the store says, and titles Start/Stop for what it
	/// will do.
	private func updateCommandItems() {
		let enabled = store.enabledCommands
		for (command, item) in commandItems {
			item.isEnabled = enabled.contains(command)
			item.isHidden = !store.state.isOffered(command)
		}
		newTaskItem.isEnabled = store.canCreateTask
		guard let startStopItem = commandItems[.startStop] else {
			return
		}
		let isStopping = store.isStopping
		startStopItem.image = NSImage(
			systemSymbolName: startStopSymbolName(isStopping: isStopping),
			accessibilityDescription: nil,
		)
		startStopItem.label = startStopTitle(isStopping: isStopping)
		startStopItem.toolTip = startStopItem.label
	}

	/// Titles Undo or Redo for the Undo point it acts on, returning whether it's enabled.
	private func validate(_ menuItem: NSMenuItem, title: String, isEnabled: Bool) -> Bool {
		menuItem.title = title
		return isEnabled
	}

	/// Whether a task command's menu item is enabled, titling Start/Stop for what it will do.
	private func validate(_ menuItem: NSMenuItem, for command: ReplicaFeature.TaskCommand) -> Bool {
		if command == .startStop {
			menuItem.title = startStopTitle(isStopping: store.isStopping)
		}
		// ⌘⌫ deletes text while a field is being edited, so it's left for the field.
		if command == .delete, window?.firstResponder is NSText {
			return false
		}
		// The menu keeps the commands Mark Pending replaces, disabled, where the toolbar hides them.
		return store.enabledCommands.contains(command) && store.state.isOffered(command)
	}
}

/// Lists the tags of the tasks selected in the window Remove Tag's items go to, as it opens.
@MainActor
private final class RemoveTagMenuDelegate: NSObject, NSMenuDelegate {
	func menuNeedsUpdate(_ menu: NSMenu) {
		menu.removeAllItems()
		let action = #selector(ReplicaWindowController.removeTag(_:))
		let controller = NSApp.target(forAction: action) as? ReplicaWindowController
		let tags = controller?.selectedTags ?? []
		guard !tags.isEmpty else {
			menu.addItem(withTitle: String(localized: "No Tags"), action: nil, keyEquivalent: "")
			return
		}
		for tag in tags {
			let item = NSMenuItem(title: tag, action: action, keyEquivalent: "")
			item.representedObject = tag
			menu.addItem(item)
		}
	}
}

/// Shared by every Remove Tag menu, since a menu holds its delegate weakly.
@MainActor private let removeTagMenuDelegate = RemoveTagMenuDelegate()

/// Leaves ⌘Z and ⌘⇧Z to the window's own undo manager while a field being edited has typing to
/// undo or redo. Otherwise the window disowns them, so they reach the controller, which undoes the
/// Replica's changes: `NSWindow` handles `undo:` and `redo:` itself, ahead of its controller. A
/// field can keep the cursor once its edit is written, as a date field does after Return, so it's
/// the typing that decides, not the cursor.
private final class ReplicaWindow: NSWindow {
	override func responds(to selector: Selector!) -> Bool {
		let isUndo = selector == #selector(ReplicaWindowController.undo(_:))
		guard isUndo || selector == #selector(ReplicaWindowController.redo(_:)) else {
			return super.responds(to: selector)
		}
		// Only AppKit's search for an action's target asks about these, on the main thread.
		return MainActor.assumeIsolated {
			// The field editor's own undo manager, which its field may supply, not the window's.
			guard let undoManager = (firstResponder as? NSText)?.undoManager else {
				return false
			}
			return isUndo ? undoManager.canUndo : undoManager.canRedo
		}
	}
}

extension ReplicaFeature.FileImporter {
	/// Where the panel opens: in the home folder, where the CLI looks for `.taskrc`.
	fileprivate var directory: URL? {
		switch self {
		case .taskrc:
			Taskrc.Environment.live.variables["HOME"].map { URL(filePath: $0, directoryHint: .isDirectory) }
		}
	}

	fileprivate var message: String {
		switch self {
		case .taskrc:
			String(localized: "Choose the Taskrc to use with this Replica.")
		}
	}
}

extension ReplicaFeature.TaskCommand {
	/// In the order the Task menu and the toolbar list them.
	static let all: [Self] = [.startStop, .done, .delete, .markPending]

	var action: Selector {
		switch self {
		case .delete: #selector(ReplicaWindowController.deleteTasks(_:))
		case .done: #selector(ReplicaWindowController.markDone(_:))
		case .markPending: #selector(ReplicaWindowController.markPending(_:))
		case .startStop: #selector(ReplicaWindowController.startOrStop(_:))
		}
	}

	/// Start/Stop's title until validation says which it is.
	var title: String {
		switch self {
		case .delete: String(localized: "Delete")
		case .done: String(localized: "Done")
		case .markPending: String(localized: "Mark Pending")
		case .startStop: startStopTitle(isStopping: false)
		}
	}

	fileprivate var identifier: NSToolbarItem.Identifier {
		switch self {
		case .delete: NSToolbarItem.Identifier("delete")
		case .done: NSToolbarItem.Identifier("done")
		case .markPending: NSToolbarItem.Identifier("markPending")
		case .startStop: NSToolbarItem.Identifier("startStop")
		}
	}

	/// ⌘ and this key. An uppercase letter adds ⇧.
	fileprivate var keyEquivalent: String {
		switch self {
		case .delete: backspace
		case .done: "\r"
		case .markPending: "P"
		case .startStop: "s"
		}
	}

	fileprivate var symbolName: String {
		switch self {
		case .delete: "trash"
		case .done: "checkmark.circle"
		case .markPending: "arrow.uturn.backward.circle"
		case .startStop: startStopSymbolName(isStopping: false)
		}
	}

	/// The command a menu item or toolbar item sends `action` for.
	init?(action: Selector?) {
		guard let command = Self.all.first(where: { $0.action == action }) else {
			return nil
		}
		self = command
	}
}

/// A toolbar button that sends `action` along the responder chain. The store enables it, rather
/// than AppKit's validation, which runs only after events and so misses a write finishing.
@MainActor
private func commandItem(
	_ identifier: NSToolbarItem.Identifier,
	action: Selector,
	label: String,
	symbolName: String,
) -> NSToolbarItem {
	let item = NSToolbarItem(itemIdentifier: identifier)
	item.action = action
	item.autovalidates = false
	item.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)
	item.isBordered = true
	item.label = label
	item.toolTip = label
	return item
}

private func startStopSymbolName(isStopping: Bool) -> String {
	isStopping ? "stop" : "play"
}

private func startStopTitle(isStopping: Bool) -> String {
	isStopping ? String(localized: "Stop") : String(localized: "Start")
}

/// ⌘⌫'s key equivalent.
private let backspace = "\u{8}"

private let bookmarkKey = "bookmark"

private let newTaskIdentifier = NSToolbarItem.Identifier("newTask")

/// New Task's toolbar label, and the new-task row's placeholder.
let newTaskTitle = String(localized: "New Task")

private let searchIdentifier = NSToolbarItem.Identifier("search")

private let windowSize = NSSize(width: 1_000, height: 600)
