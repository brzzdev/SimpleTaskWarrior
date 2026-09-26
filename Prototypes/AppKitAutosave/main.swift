// PROTOTYPE — throwaway, never shipped. Answers #65's question: can AppKit autosave, keyed per
// Replica, own everything `ReplicaFeature.Layout` keeps today — column width, order and hidden
// state, the sort order, and whether the inspector is collapsed?
//
// Opens two Replica windows, A and B, over the same shape as `ReplicaWindowController`: a sidebar,
// a table and an inspector in an NSSplitViewController. Each run replays the app's timeline:
//   1. the window shows, with the built-in columns only
//   2. `directoryResolved`: the table and split view get their per-Replica autosave names
//   3. `taskrcLoaded`: the UDA columns arrive
//
// Phases, each a separate launch so restoring really crosses a relaunch:
//   --phase write   wipe the saved state, then change every piece of layout differently per Replica
//   --phase read    change nothing; log what came back and compare it with what `write` set
// Options:
//   --early         set the autosave names before the window shows (control: no late naming)
//   --reapply       in `read`, set the table's autosave name again once the UDA columns exist
//   --name-after-columns  name the autosave only once the UDA columns exist, as if the window
//                   waited for `taskrcLoaded` rather than `directoryResolved`
//   --readd         in `read`, drop the estimate column and add it back, as switching to a
//                   Taskrc without that UDA and back again would
//
// Run: `just prototype-autosave` (interactive) or `just prototype-autosave --check`, which runs
// every scenario and prints the verdicts.

import AppKit

let arguments = CommandLine.arguments
let phase = arguments.firstIndex(of: "--phase").map { arguments[$0 + 1] }
let early = arguments.contains("--early")
let reapply = arguments.contains("--reapply")
let nameAfterColumns = arguments.contains("--name-after-columns")
let readd = arguments.contains("--readd")

let builtInColumns = ["id", "description", "urgency"]
let udaColumns = ["client", "estimate"]

/// What `write` sets on one Replica, and what `read` expects back.
struct Expected {
	var hidden: Set<String>
	var inspectorCollapsed: Bool
	/// The inspector's width, where it stays shown.
	var inspectorWidth: Int?
	var order: [String]
	var sort: [(key: String, ascending: Bool)]
	var widths: [String: Int]
}

let expected: [String: Expected] = [
	"A": Expected(
		hidden: ["id"],
		inspectorCollapsed: true,
		inspectorWidth: nil,
		order: ["client", "id", "description", "urgency", "estimate"],
		sort: [("estimate", true), ("urgency", false)],
		widths: ["description": 260, "estimate": 180],
	),
	"B": Expected(
		hidden: ["client"],
		inspectorCollapsed: false,
		inspectorWidth: 340,
		order: ["urgency", "id", "description", "client", "estimate"],
		sort: [("description", true)],
		widths: ["estimate": 90, "urgency": 150],
	),
]

func autosaveName(_ replica: String) -> String { "Replica \(replica)" }

func column(_ identifier: String) -> NSTableColumn {
	let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(identifier))
	column.title = identifier
	column.width = 100
	column.sortDescriptorPrototype = NSSortDescriptor(key: identifier, ascending: true)
	return column
}

final class Controller: NSWindowController, NSTableViewDataSource {
	let replica: String
	let split = NSSplitViewController()
	let table = NSTableView()
	let inspector: NSSplitViewItem

	var inspectorWidth: Int { Int(inspector.viewController.view.frame.width) }

	init(replica: String, origin: NSPoint) {
		self.replica = replica
		let window = NSWindow(
			contentRect: NSRect(origin: origin, size: NSSize(width: 1_000, height: 400)),
			styleMask: [.closable, .fullSizeContentView, .miniaturizable, .resizable, .titled],
			backing: .buffered,
			defer: false,
		)
		window.isReleasedWhenClosed = false
		window.title = "Replica \(replica)"
		window.toolbarStyle = .unified

		let sidebar = NSViewController()
		sidebar.view = NSView()
		let content = NSViewController()
		let scroll = NSScrollView()
		scroll.documentView = table
		scroll.hasVerticalScroller = true
		content.view = scroll
		let inspectorController = NSViewController()
		inspectorController.view = NSView()
		inspector = NSSplitViewItem(inspectorWithViewController: inspectorController)
		// An inspector item defaults to 270 pt both ways, which leaves nothing to drag.
		inspector.maximumThickness = 500
		super.init(window: window)

		for identifier in builtInColumns {
			table.addTableColumn(column(identifier))
		}
		// Otherwise the last column absorbs the slack, and no width reads back as it was set.
		table.columnAutoresizingStyle = .noColumnAutoresizing
		table.dataSource = self
		split.splitViewItems = [
			NSSplitViewItem(sidebarWithViewController: sidebar),
			NSSplitViewItem(viewController: content),
			inspector,
		]
		window.contentViewController = split
		window.setContentSize(NSSize(width: 1_000, height: 400))
		window.setFrameOrigin(origin)
		if early {
			nameAutosave()
		}
	}

	@available(*, unavailable)
	required init?(coder: NSCoder) { fatalError() }

	func numberOfRows(in tableView: NSTableView) -> Int { 3 }

	func tableView(
		_ tableView: NSTableView,
		objectValueFor tableColumn: NSTableColumn?,
		row: Int,
	) -> Any? {
		"\(tableColumn?.identifier.rawValue ?? "") \(row)"
	}

	/// What `directoryResolved` would do once the Replica's folder is known.
	func nameAutosave() {
		table.autosaveName = autosaveName(replica)
		table.autosaveTableColumns = true
		split.splitView.autosaveName = "\(autosaveName(replica)) split"
	}

	/// What `taskrcLoaded` would do: offer the Taskrc's UDAs as columns.
	func addUDAColumns() {
		for identifier in udaColumns {
			table.addTableColumn(column(identifier))
		}
	}

	func readdEstimate() {
		let estimate = tableColumn("estimate")
		table.removeTableColumn(estimate)
		table.addTableColumn(column("estimate"))
	}

	func reapplyAutosave() {
		table.autosaveName = nil
		table.autosaveName = autosaveName(replica)
	}

	func applyExpected() {
		let target = expected[replica]!
		for (index, identifier) in target.order.enumerated() {
			let from = table.column(withIdentifier: NSUserInterfaceItemIdentifier(identifier))
			if from != index {
				table.moveColumn(from, toColumn: index)
			}
		}
		for (identifier, width) in target.widths {
			tableColumn(identifier).width = CGFloat(width)
		}
		for identifier in target.hidden {
			tableColumn(identifier).isHidden = true
		}
		table.sortDescriptors = target.sort.map {
			NSSortDescriptor(key: $0.key, ascending: $0.ascending)
		}
		if target.inspectorCollapsed {
			inspector.isCollapsed = true
		} else if let width = target.inspectorWidth {
			let splitView = split.splitView
			splitView.setPosition(splitView.bounds.width - CGFloat(width), ofDividerAt: 1)
		}
	}

	func tableColumn(_ identifier: String) -> NSTableColumn {
		table.tableColumns.first { $0.identifier.rawValue == identifier }!
	}

	func describe() -> String {
		let columns = table.tableColumns.map { column in
			"\(column.identifier.rawValue)(\(Int(column.width))\(column.isHidden ? ",hidden" : ""))"
		}
		let sort = table.sortDescriptors.map { "\($0.key ?? "?")\($0.ascending ? "↑" : "↓")" }
		let inspectorState = inspector.isCollapsed ? "collapsed" : "shown w=\(inspectorWidth)"
		return "columns=\(columns.joined(separator: " ")) sort=\(sort) inspector=\(inspectorState)"
	}

	/// One line per question: whether `read` got back what `write` set.
	func verdicts() -> [String] {
		let target = expected[replica]!
		let order = table.tableColumns.map(\.identifier.rawValue)
		let widths = target.widths.allSatisfy { Int(tableColumn($0.key).width) == $0.value }
		let hidden = Set(table.tableColumns.filter(\.isHidden).map(\.identifier.rawValue))
		let sort = table.sortDescriptors.map { ($0.key ?? "", $0.ascending) }
		let sortMatches = sort.count == target.sort.count
			&& zip(sort, target.sort).allSatisfy { $0.0 == $1.key && $0.1 == $1.ascending }
		var inspectorMatches = inspector.isCollapsed == target.inspectorCollapsed
		if let width = target.inspectorWidth, !inspector.isCollapsed {
			inspectorMatches = inspectorMatches && abs(inspectorWidth - width) <= 1
		}
		func mark(_ passed: Bool) -> String { passed ? "PASS" : "FAIL" }
		return [
			"order     \(mark(order == target.order)) got \(order) want \(target.order)",
			"widths    \(mark(widths)) want \(target.widths)",
			"hidden    \(mark(hidden == target.hidden)) got \(hidden.sorted()) want \(target.hidden.sorted())",
			"sort      \(mark(sortMatches)) got \(sort) want \(target.sort)",
			"inspector \(mark(inspectorMatches)) got \(inspector.isCollapsed ? "collapsed" : "shown w=\(inspectorWidth)") want \(target.inspectorCollapsed ? "collapsed" : "shown w=\(target.inspectorWidth ?? 0)")",
		]
	}
}

/// Every key autosave wrote for the prototype's Replicas.
func savedKeys() -> [String: Any] {
	UserDefaults.standard.dictionaryRepresentation().filter { $0.key.contains("Replica ") }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
	var controllers: [Controller] = []

	func applicationDidFinishLaunching(_ notification: Notification) {
		let label = "[\(phase ?? "interactive")\(early ? " early" : "")\(nameAfterColumns ? " after-columns" : "")\(readd ? " readd" : "")\(reapply ? " reapply" : "")]"
		if phase == "write" {
			for key in savedKeys().keys {
				UserDefaults.standard.removeObject(forKey: key)
			}
		}
		controllers = ["A", "B"].enumerated().map { index, replica in
			let controller = Controller(
				replica: replica,
				origin: NSPoint(x: 40 + index * 60, y: 80 + index * 460),
			)
			controller.showWindow(nil)
			return controller
		}
		NSApp.activate()

		Task { @MainActor in
			@MainActor
			func step(_ name: String, _ body: (Controller) -> Void) async {
				try? await Task.sleep(for: .milliseconds(300))
				for controller in controllers {
					body(controller)
					print("\(label) \(controller.replica) after \(name): \(controller.describe())")
				}
			}
			await step("launch") { _ in }
			if !early, !nameAfterColumns {
				await step("directoryResolved") { $0.nameAutosave() }
			}
			await step("taskrcLoaded") { $0.addUDAColumns() }
			if nameAfterColumns {
				await step("nameAfterColumns") { $0.nameAutosave() }
			}
			if readd {
				await step("readd") { $0.readdEstimate() }
			}
			if reapply {
				await step("reapply") { $0.reapplyAutosave() }
			}
			switch phase {
			case "write":
				await step("write") { $0.applyExpected() }
				try? await Task.sleep(for: .milliseconds(500))
				for (key, value) in savedKeys().sorted(by: { $0.key < $1.key }) {
					print("\(label) saved \(key) = \(value)")
				}
				NSApp.terminate(nil)

			case "read":
				try? await Task.sleep(for: .milliseconds(500))
				for controller in controllers {
					for verdict in controller.verdicts() {
						print("\(label) \(controller.replica) \(verdict)")
					}
				}
				NSApp.terminate(nil)

			default:
				break
			}
		}
	}

	func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
