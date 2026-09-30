// The app: its menu bar, and a window per open Replica.
public import AppKit
import BookmarkClient
import ComposableArchitecture
import ReplicaClient
import ReplicaFeature
import Sparkle

/// Opens each Replica in one window, and restores the windows after a relaunch.
@MainActor
public final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate,
	NSWindowRestoration
{
	/// Where the next new window goes, just below and right of the last.
	private var cascadePoint = NSPoint.zero
	/// Each window's controller, kept until the window closes.
	private var controllers: [ReplicaWindowController] = []
	#if DEBUG
	/// None, so a Debug build never checks the production feed or installs the Release product over
	/// itself.
	private let updater: SPUStandardUpdaterController? = nil
	#else
	/// Checks the feed on Sparkle's schedule, for as long as the app runs.
	private let updater: SPUStandardUpdaterController? = SPUStandardUpdaterController(
		startingUpdater: true,
		updaterDelegate: nil,
		userDriverDelegate: nil,
	)
	#endif

	public static func restoreWindow(
		withIdentifier _: NSUserInterfaceItemIdentifier,
		state: NSCoder,
		// Escaping in `NSWindowRestoration`'s requirement, though this calls it at once.
		// swiftlint:disable:next unneeded_escaping
		completionHandler: @escaping (NSWindow?, (any Error)?) -> Void,
	) {
		// A Replica already restored gets no second window, since AppKit expects a window per request.
		// One that's gone still gets its window, which says so, at the path it was last at.
		guard
			let delegate = NSApp.delegate as? AppDelegate,
			let bookmark = ReplicaWindowController.bookmark(restoredFrom: state),
			let folder = (try? folder(of: bookmark)) ?? bookmarkPath(bookmark).map(standardizedFolder),
			delegate.controller(on: folder) == nil
		else {
			completionHandler(nil, CocoaError(.userCancelled))
			return
		}
		completionHandler(delegate.makeController(bookmark: bookmark, folder: folder).window, nil)
	}

	public func application(_: NSApplication, openFile filename: String) -> Bool {
		// The Dock's recent Replicas arrive here.
		open(URL(filePath: filename, directoryHint: .isDirectory))
		return true
	}

	/// Asks for a Replica when the app launches or is reopened with no window: AppKit skips it when
	/// it restored windows, and when the launch was to open a Replica.
	public func applicationOpenUntitledFile(_: NSApplication) -> Bool {
		openReplica(nil)
		return true
	}

	public func applicationSupportsSecureRestorableState(_: NSApplication) -> Bool {
		true
	}

	public func applicationWillFinishLaunching(_: Notification) {
		NSApp.mainMenu = mainMenu(openRecent: self, updater: updater)
	}

	/// None, so a key equivalent search doesn't fill Open Recent: its entries have no shortcuts.
	public func menuHasKeyEquivalent(
		_: NSMenu,
		for _: NSEvent,
		target _: AutoreleasingUnsafeMutablePointer<AnyObject?>,
		action _: UnsafeMutablePointer<Selector?>,
	) -> Bool {
		false
	}

	/// Fills Open Recent with the Replicas opened last.
	public func menuNeedsUpdate(_ menu: NSMenu) {
		let replicas = NSDocumentController.shared.recentDocumentURLs.map { url in
			let path = url.path(percentEncoded: false)
			let replica = menuItem(FileManager.default.displayName(atPath: path), #selector(openRecent(_:)))
			replica.image = NSWorkspace.shared.icon(forFile: path)
			replica.image?.size = NSSize(width: 16, height: 16)
			replica.representedObject = url
			return replica
		}
		let clear = menuItem("Clear Menu", #selector(NSDocumentController.clearRecentDocuments(_:)))
		// With no NSDocument, the document controller isn't in the responder chain.
		clear.target = NSDocumentController.shared
		menu.items = (replicas.isEmpty ? [] : replicas + [.separator()]) + [clear]
	}

	@objc
	func openReplica(_: Any?) {
		_Concurrency.Task {
			let panel = NSOpenPanel()
			panel.canChooseDirectories = true
			panel.canChooseFiles = false
			panel.message = "Choose a Taskwarrior 3 Replica: the folder TASKDATA points at."
			panel.prompt = "Open"
			guard await panel.begin() == .OK, let directory = panel.url else {
				return
			}
			open(directory)
		}
	}

	/// The window on the Replica in `folder`, standardized, if any.
	private func controller(on folder: URL) -> ReplicaWindowController? {
		controllers.first { $0.folder == folder }
	}

	private func makeController(bookmark: Data, folder: URL) -> ReplicaWindowController {
		// Unique per window, as restoration requires, and the same for a Replica each time, so its
		// window reopens where it last was, laid out as it was.
		let name = "replica:" + folder.path(percentEncoded: false)
		let controller = ReplicaWindowController(
			autosaveName: name,
			bookmark: bookmark,
			folder: folder,
		) { [weak self] closed in
			self?.controllers.removeAll { $0 === closed }
		}
		controller.window?.identifier = NSUserInterfaceItemIdentifier(name)
		controller.window?.restorationClass = Self.self
		controller.window?.setFrameAutosaveName(name)
		controllers.append(controller)
		return controller
	}

	/// Brings forward the window on the Replica in `directory`, opening one if it has none, or
	/// explains why the Replica can't be opened.
	private func open(_ directory: URL) {
		@Dependency(\.bookmarkClient) var bookmarkClient
		@Dependency(\.replicaClient) var replicaClient

		_Concurrency.Task {
			do {
				try await replicaClient.validate(directory)
				let bookmark = try bookmarkClient.create(directory)
				let folder = try folder(of: bookmark)
				NSDocumentController.shared.noteNewRecentDocumentURL(folder)
				if let controller = controller(on: folder) {
					controller.showWindow(nil)
					return
				}
				let controller = makeController(bookmark: bookmark, folder: folder)
				// A Replica opened before keeps the frame it autosaved.
				if let window = controller.window, !window.setFrameUsingName(window.frameAutosaveName) {
					if cascadePoint == .zero {
						window.center()
					}
					cascadePoint = window.cascadeTopLeft(from: cascadePoint)
				}
				controller.showWindow(nil)
			} catch {
				let alert = NSAlert()
				alert.messageText = error.localizedDescription
				alert.runModal()
			}
		}
	}

	@objc
	private func openRecent(_ sender: NSMenuItem) {
		guard let url = sender.representedObject as? URL else {
			return
		}
		open(url)
	}
}

/// The Replica folder `bookmark` resolves to.
private func folder(of bookmark: Data) throws -> URL {
	@Dependency(\.bookmarkClient) var bookmarkClient
	return try standardizedFolder(bookmarkClient.resolve(bookmark).url)
}
