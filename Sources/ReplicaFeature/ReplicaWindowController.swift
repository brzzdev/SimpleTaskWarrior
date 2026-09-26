// The window over one Replica: a sidebar, the task table and an inspector, under a toolbar.
public import AppKit
import ComposableArchitecture
public import Foundation
import SwiftNavigation
import SwiftUI

/// Shows one Replica, and handles the menu bar's Taskrc commands while its window is in front.
public final class ReplicaWindowController: NSWindowController, NSMenuItemValidation,
	NSToolbarDelegate, NSWindowDelegate
{
	private var fetch: _Concurrency.Task<Void, Never>?
	private var inspectorCollapseObservation: NSKeyValueObservation?
	private let onClose: @MainActor () -> Void
	private let store: StoreOf<ReplicaFeature>

	/// A controller for the Replica `bookmark` locates. It calls `onClose` as its window closes.
	public init(bookmark: Data, onClose: @escaping @MainActor () -> Void) {
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
			inspectorWithViewController: hostingController(InspectorView(store: store)),
		)
		// An inspector's maximum defaults to its minimum, which leaves its divider nothing to drag. The
		// cap leaves the table room at the default window size.
		inspector.maximumThickness = 400
		let split = NSSplitViewController()
		split.splitViewItems = [
			NSSplitViewItem(sidebarWithViewController: sidebarController),
			NSSplitViewItem(viewController: hostingController(ReplicaContentView(store: store))),
			inspector,
		]
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
		observe { [weak self, weak inspector] in
			guard let self, let inspector else {
				return
			}
			let isCollapsed = !store.layout.isInspectorPresented
			if inspector.isCollapsed != isCollapsed {
				inspector.isCollapsed = isCollapsed
			}
		}
		// The toolbar button, the View menu and dragging the divider all collapse the inspector.
		inspectorCollapseObservation = inspector.observe(\.isCollapsed) { [weak self] inspector, _ in
			guard let self else {
				return
			}
			let isPresented = !inspector.isCollapsed
			MainActor.assumeIsolated {
				guard self.store.layout.isInspectorPresented != isPresented else {
					return
				}
				self.store.$layout.withLock { $0.isInspectorPresented = isPresented }
			}
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
}

private let bookmarkKey = "bookmark"

/// Hosts `rootView`, leaving its size to the split view rather than to SwiftUI.
@MainActor
private func hostingController(_ rootView: some View) -> NSViewController {
	let controller = NSHostingController(rootView: rootView)
	controller.sizingOptions = []
	return controller
}

private let windowSize = NSSize(width: 1_000, height: 600)
