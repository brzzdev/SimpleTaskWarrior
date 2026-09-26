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
	private let deleteItem = commandItem(
		deleteIdentifier,
		action: #selector(deleteTasks(_:)),
		label: String(localized: "Delete"),
		symbolName: "trash",
	)
	private let doneItem = commandItem(
		doneIdentifier,
		action: #selector(markDone(_:)),
		label: String(localized: "Done"),
		symbolName: "checkmark.circle",
	)
	private var fetch: _Concurrency.Task<Void, Never>?
	private let markPendingItem = commandItem(
		markPendingIdentifier,
		action: #selector(markPending(_:)),
		label: String(localized: "Mark Pending"),
		symbolName: "arrow.uturn.backward.circle",
	)
	private let newTaskItem = commandItem(
		newTaskIdentifier,
		action: #selector(newTask(_:)),
		label: String(localized: "New Task"),
		symbolName: "square.and.pencil",
	)
	private let onClose: @MainActor () -> Void
	/// The file panel on screen, so a store change while it's up doesn't open a second.
	private var openPanel: NSOpenPanel?
	private let searchItem = NSSearchToolbarItem(itemIdentifier: searchIdentifier)
	private let startStopItem = commandItem(
		startStopIdentifier,
		action: #selector(startOrStop(_:)),
		label: String(localized: "Start"),
		symbolName: "play",
	)
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
		let window = NSWindow(
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
				store.isSaving
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
		fetch = _Concurrency.Task { [store] in
			await store.send(.fetchRequested).finish()
		}
	}

	@available(*, unavailable)
	required init?(coder: NSCoder) {
		fatalError("init(coder:) has not been implemented")
	}

	/// The task commands, as the menu bar's Task menu and a row's context menu list them.
	public static func taskCommandMenuItems() -> [NSMenuItem] {
		[
			NSMenuItem(
				title: String(localized: "Start"),
				action: #selector(startOrStop(_:)),
				keyEquivalent: "s",
			),
			NSMenuItem(
				title: String(localized: "Done"),
				action: #selector(markDone(_:)),
				keyEquivalent: "\r",
			),
			NSMenuItem(
				title: String(localized: "Delete"),
				action: #selector(deleteTasks(_:)),
				keyEquivalent: backspace,
			),
			NSMenuItem(
				title: String(localized: "Mark Pending"),
				action: #selector(markPending(_:)),
				keyEquivalent: "P",
			),
		]
	}

	/// The bookmark a window encoded for restoration after a relaunch.
	public static func bookmark(restoredFrom state: NSCoder) -> Data? {
		state.decodeObject(of: NSData.self, forKey: bookmarkKey) as Data?
	}

	@objc
	public func chooseTaskrc(_: Any?) {
		store.send(.chooseTaskrcButtonTapped)
	}

	/// Puts the cursor in the search field.
	@objc
	public func find(_: Any?) {
		searchItem.beginSearchInteraction()
	}

	@objc
	public func deleteTasks(_: Any?) {
		store.send(.deleteButtonTapped)
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
		[
			deleteItem, doneItem, markPendingItem, newTaskItem, searchItem, startStopItem,
		].first { $0.itemIdentifier == identifier }
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
			startStopIdentifier,
			doneIdentifier,
			deleteIdentifier,
			markPendingIdentifier,
			searchIdentifier,
			.inspectorTrackingSeparator,
			.flexibleSpace,
			.toggleInspector,
		]
	}

	@objc
	public func useTaskwarriorDefaults(_: Any?) {
		store.send(.useTaskwarriorDefaultsButtonTapped)
	}

	public func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
		switch menuItem.action {
		case #selector(deleteTasks(_:)):
			// ⌘⌫ deletes text while a field is being edited, so it's left for the field.
			!(window?.firstResponder is NSText) && store.state.isEnabled(.delete)

		case #selector(grantAccess(_:)):
			store.canGrantAccess

		case #selector(markDone(_:)):
			store.state.isEnabled(.done)

		case #selector(markPending(_:)):
			store.state.isEnabled(.markPending)

		case #selector(newTask(_:)):
			store.state.isEnabled(.newTask)

		case #selector(startOrStop(_:)):
			startOrStopValidated(menuItem)

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

	/// Titles Start/Stop for what it will do, and reports whether it's enabled.
	private func startOrStopValidated(_ menuItem: NSMenuItem) -> Bool {
		menuItem.title = store.isStopping ? String(localized: "Stop") : String(localized: "Start")
		return store.state.isEnabled(.startStop)
	}

	/// Shows Mark Pending in place of Start/Stop, Done and Delete where the sidebar shows only closed
	/// tasks, and enables each item as the menu bar does.
	private func updateCommandItems() {
		let offersMarkPending = store.offersMarkPending
		for item in [deleteItem, doneItem, startStopItem] {
			item.isHidden = offersMarkPending
		}
		markPendingItem.isHidden = !offersMarkPending
		deleteItem.isEnabled = store.state.isEnabled(.delete)
		doneItem.isEnabled = store.state.isEnabled(.done)
		markPendingItem.isEnabled = store.state.isEnabled(.markPending)
		newTaskItem.isEnabled = store.state.isEnabled(.newTask)
		startStopItem.isEnabled = store.state.isEnabled(.startStop)
		let isStopping = store.isStopping
		startStopItem.image = NSImage(
			systemSymbolName: isStopping ? "stop" : "play",
			accessibilityDescription: nil,
		)
		startStopItem.label = isStopping ? String(localized: "Stop") : String(localized: "Start")
		startStopItem.toolTip = startStopItem.label
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

/// ⌘⌫'s key equivalent.
private let backspace = "\u{8}"

private let bookmarkKey = "bookmark"

private let deleteIdentifier = NSToolbarItem.Identifier("delete")

private let doneIdentifier = NSToolbarItem.Identifier("done")

private let markPendingIdentifier = NSToolbarItem.Identifier("markPending")

private let newTaskIdentifier = NSToolbarItem.Identifier("newTask")

private let searchIdentifier = NSToolbarItem.Identifier("search")

private let startStopIdentifier = NSToolbarItem.Identifier("startStop")

private let windowSize = NSSize(width: 1_000, height: 600)
