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
	private let store: StoreOf<ReplicaFeature>

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
		let inspector = NSSplitViewItem(
			inspectorWithViewController: InspectorController(store: store),
		)
		// An inspector's maximum defaults to its minimum, which leaves its divider nothing to drag. The
		// cap leaves the table room at the default window size.
		inspector.maximumThickness = 400
		let split = NSSplitViewController()
		split.splitViewItems = [
			sidebar,
			NSSplitViewItem(
				viewController: ReplicaContentController(autosaveName: autosaveName, store: store),
			),
			inspector,
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

	/// The task commands, as the menu bar's Task menu and a row's context menu list them.
	public static func taskCommandMenuItems() -> [NSMenuItem] {
		ReplicaFeature.TaskCommand.all.map { command in
			NSMenuItem(title: command.title, action: command.action, keyEquivalent: command.keyEquivalent)
		}
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
	public func grantAccess(_: Any?) {
		store.send(.grantAccessButtonTapped)
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

	/// Re-applies the Undo point the window last undid. `ReplicaWindow` passes ⌘⇧Z on here only while
	/// no field is being edited.
	@objc
	public func redo(_: Any?) {
		store.send(.redoButtonTapped)
	}

	@objc
	public func selectNextTask(_: Any?) {
		selectAdjacentTask(.nextTaskButtonTapped)
	}

	@objc
	public func selectPreviousTask(_: Any?) {
		selectAdjacentTask(.previousTaskButtonTapped)
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

	/// Undoes the window's newest Undo point. `ReplicaWindow` passes ⌘Z on here only while no field
	/// is being edited.
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
		case #selector(grantAccess(_:)):
			store.canGrantAccess

		case #selector(newTask(_:)):
			store.canCreateTask

		case #selector(redo(_:)):
			validateRedo(menuItem)

		case #selector(selectNextTask(_:)):
			store.state.adjacentTask(1) != nil

		case #selector(selectPreviousTask(_:)):
			store.state.adjacentTask(-1) != nil

		case #selector(undo(_:)):
			validateUndo(menuItem)

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

	/// Whether Redo is enabled, titling it for the Undo point it re-applies.
	private func validateRedo(_ menuItem: NSMenuItem) -> Bool {
		menuItem.title = store.redoName.map { String(localized: "Redo \($0)") }
			?? String(localized: "Can’t Redo")
		return store.canRedo
	}

	/// Whether Undo is enabled, titling it for the Undo point it reverts.
	private func validateUndo(_ menuItem: NSMenuItem) -> Bool {
		menuItem.title = store.undoName.map { String(localized: "Undo \($0)") }
			?? String(localized: "Can’t Undo")
		return store.canUndo
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

/// Leaves ⌘Z and ⌘⇧Z to the window's own undo manager only while a field is being edited, where
/// they undo typing. Otherwise the window disowns them, so they reach the controller, which undoes
/// the Replica's changes: `NSWindow` handles `undo:` and `redo:` itself, ahead of its controller.
private final class ReplicaWindow: NSWindow {
	override func responds(to selector: Selector!) -> Bool {
		guard selector == undoSelector || selector == redoSelector else {
			return super.responds(to: selector)
		}
		// Only AppKit's search for an action's target asks about these, on the main thread.
		return MainActor.assumeIsolated { firstResponder is NSText }
	}
}

extension ReplicaFeature.FileImporter {
	/// Where the panel opens: at the path an include resolved to, or in the home folder, where the
	/// CLI looks for `.taskrc`.
	fileprivate var directory: URL? {
		switch self {
		case let .grant(_, file):
			file.deletingLastPathComponent()

		case .taskrc:
			Taskrc.Environment.live.variables["HOME"].map { URL(filePath: $0, directoryHint: .isDirectory) }
		}
	}

	fileprivate var message: String {
		switch self {
		case let .grant(_, file):
			String(localized: "Grant access to \(file.lastPathComponent), which the Taskrc includes.")

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

	/// Start/Stop's title until validation says which it is.
	fileprivate var title: String {
		switch self {
		case .delete: String(localized: "Delete")
		case .done: String(localized: "Done")
		case .markPending: String(localized: "Mark Pending")
		case .startStop: startStopTitle(isStopping: false)
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

private let redoSelector = #selector(ReplicaWindowController.redo(_:))

private let undoSelector = #selector(ReplicaWindowController.undo(_:))

private let newTaskIdentifier = NSToolbarItem.Identifier("newTask")

/// New Task's toolbar label, and the new-task row's placeholder.
let newTaskTitle = String(localized: "New Task")

private let searchIdentifier = NSToolbarItem.Identifier("search")

private let windowSize = NSSize(width: 1_000, height: 600)
