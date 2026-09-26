// The window over one Replica: a sidebar, the task table and an inspector, under a toolbar.
public import AppKit
import ComposableArchitecture
public import Foundation
import SwiftNavigation
import Taskrc
import UniformTypeIdentifiers

/// Shows one Replica, and handles the menu bar's Taskrc commands while its window is in front.
public final class ReplicaWindowController: NSWindowController, NSMenuItemValidation,
	NSToolbarDelegate, NSWindowDelegate
{
	private var fetch: _Concurrency.Task<Void, Never>?
	private let onClose: @MainActor () -> Void
	/// The file panel on screen, so a store change while it's up doesn't open a second.
	private var openPanel: NSOpenPanel?
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

		let sidebarController = NSViewController()
		sidebarController.view = NSView()
		let inspector = NSSplitViewItem(
			inspectorWithViewController: InspectorController(store: store),
		)
		// An inspector's maximum defaults to its minimum, which leaves its divider nothing to drag. The
		// cap leaves the table room at the default window size.
		inspector.maximumThickness = 400
		let split = NSSplitViewController()
		split.splitViewItems = [
			NSSplitViewItem(sidebarWithViewController: sidebarController),
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

		let toolbar = NSToolbar(identifier: "replica")
		toolbar.allowsDisplayModeCustomization = false
		toolbar.delegate = self
		toolbar.displayMode = .iconOnly
		window.toolbar = toolbar

		observe { [weak self] in
			guard let self, let window = self.window else {
				return
			}
			window.subtitle = store.directory?.path(percentEncoded: false) ?? ""
			window.title = store.directory?.lastPathComponent ?? ""
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

	/// The bookmark a window encoded for restoration after a relaunch.
	public static func bookmark(restoredFrom state: NSCoder) -> Data? {
		state.decodeObject(of: NSData.self, forKey: bookmarkKey) as Data?
	}

	@objc
	public func chooseTaskrc(_: Any?) {
		store.send(.chooseTaskrcButtonTapped)
	}

	@objc
	public func grantAccess(_: Any?) {
		store.send(.grantAccessButtonTapped)
	}

	/// Unused, since every item is a system one, but AppKit drops a toolbar delegate without it.
	public func toolbar(
		_: NSToolbar,
		itemForItemIdentifier _: NSToolbarItem.Identifier,
		willBeInsertedIntoToolbar _: Bool,
	) -> NSToolbarItem? {
		nil
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
			.flexibleSpace,
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
		case #selector(grantAccess(_:)):
			store.canGrantAccess

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

private let bookmarkKey = "bookmark"

private let windowSize = NSSize(width: 1_000, height: 600)
