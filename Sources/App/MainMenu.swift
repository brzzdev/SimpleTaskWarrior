// The menu bar, built in code since the app has no nib or storyboard.
import AppKit
import ReplicaFeature

/// The app's menu bar. Commands go to the first responder that handles them: the Taskrc commands
/// to the Replica window in front, and Open Replica… to the app delegate.
@MainActor
func mainMenu(openRecent openRecentDelegate: any NSMenuDelegate) -> NSMenu {
	let name = ProcessInfo.processInfo.processName

	let services = NSMenu(title: "Services")
	NSApp.servicesMenu = services
	let app = NSMenu(title: name)
	app.items = [
		item("About \(name)", #selector(NSApplication.orderFrontStandardAboutPanel(_:))),
		.separator(),
		submenu(services),
		.separator(),
		item("Hide \(name)", #selector(NSApplication.hide(_:)), key: "h"),
		item(
			"Hide Others",
			#selector(NSApplication.hideOtherApplications(_:)),
			key: "h",
			modifiers: [.command, .option],
		),
		item("Show All", #selector(NSApplication.unhideAllApplications(_:))),
		.separator(),
		item("Quit \(name)", #selector(NSApplication.terminate(_:)), key: "q"),
	]

	// Filled by its delegate as it opens: NSDocumentController fills only an Open Recent menu loaded
	// from a nib.
	let openRecent = NSMenu(title: "Open Recent")
	openRecent.delegate = openRecentDelegate
	let file = NSMenu(title: "File")
	file.items = [
		item("Open Replica…", #selector(AppDelegate.openReplica(_:)), key: "o"),
		submenu(openRecent),
		.separator(),
		item(
			"Choose Taskrc…",
			#selector(ReplicaWindowController.chooseTaskrc(_:)),
			key: "o",
			modifiers: [.command, .option],
		),
		item("Grant Access…", #selector(ReplicaWindowController.grantAccess(_:))),
		item(
			"Use Taskwarrior Defaults",
			#selector(ReplicaWindowController.useTaskwarriorDefaults(_:)),
		),
		.separator(),
		item("Close", #selector(NSWindow.performClose(_:)), key: "w"),
	]

	let edit = NSMenu(title: "Edit")
	edit.items = [
		item("Undo", Selector(("undo:")), key: "z"),
		item("Redo", Selector(("redo:")), key: "z", modifiers: [.command, .shift]),
		.separator(),
		item("Cut", #selector(NSText.cut(_:)), key: "x"),
		item("Copy", #selector(NSText.copy(_:)), key: "c"),
		item("Paste", #selector(NSText.paste(_:)), key: "v"),
		item("Delete", #selector(NSText.delete(_:))),
		item("Select All", #selector(NSText.selectAll(_:)), key: "a"),
	]

	// The split view controller retitles these Show or Hide as the panes change.
	let view = NSMenu(title: "View")
	view.items = [
		item(
			"Show Sidebar",
			#selector(NSSplitViewController.toggleSidebar(_:)),
			key: "s",
			modifiers: [.command, .control],
		),
		item(
			"Show Inspector",
			#selector(NSSplitViewController.toggleInspector(_:)),
			key: "i",
			modifiers: [.command, .control],
		),
	]

	let window = NSMenu(title: "Window")
	NSApp.windowsMenu = window
	window.items = [
		item("Minimize", #selector(NSWindow.performMiniaturize(_:)), key: "m"),
		item("Zoom", #selector(NSWindow.performZoom(_:))),
		.separator(),
		item("Bring All to Front", #selector(NSApplication.arrangeInFront(_:))),
	]

	// AppKit adds the Help menu's search field.
	let help = NSMenu(title: "Help")
	NSApp.helpMenu = help

	let menu = NSMenu()
	menu.items = [app, file, edit, view, window, help].map(submenu)
	return menu
}

func item(
	_ title: String,
	_ action: Selector,
	key: String = "",
	modifiers: NSEvent.ModifierFlags = .command,
) -> NSMenuItem {
	let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
	item.keyEquivalentModifierMask = modifiers
	return item
}

private func submenu(_ menu: NSMenu) -> NSMenuItem {
	let item = NSMenuItem(title: menu.title, action: nil, keyEquivalent: "")
	item.submenu = menu
	return item
}
