import AppKit
import ComposableArchitecture
import Foundation
@testable import ReplicaFeature
import Taskrc
import TaskrcClient
import Testing

@MainActor
struct TaskTableControllerTests {
	@Test
	func restoredLayoutDrawsColumnsInItsOrder() async throws {
		let autosaveName = "test:\(UUID())"
		defer {
			for prefix in ["NSTableView Columns v3", "NSTableView Sort Ordering v2"] {
				UserDefaults.standard.removeObject(forKey: "\(prefix) \(autosaveName)")
			}
		}
		let savingTable = try table(
			in: TaskTableController(autosaveName: autosaveName, store: store(taskrc: loaded)),
		)
		try #require(savingTable.tableColumn(withIdentifier: identifier(.tags))).isHidden = true
		savingTable.moveColumn(savingTable.column(withIdentifier: identifier(.due)), toColumn: 0)
		// Saved fitting the table, as a window saves it, so restoring it changes no column's width.
		savingTable.sizeToFit()

		// The table is laid out before its Taskrc loads, as a window opening on a Replica is.
		let restoringStore = store(taskrc: nil)
		let restoring = TaskTableController(autosaveName: autosaveName, store: restoringStore)
		let table = try table(in: restoring)
		restoringStore.send(.taskrcLoaded(loaded))
		// The table follows the store on a later turn of the run loop.
		for _ in 0 ..< 100 where table.autosaveName == nil {
			await Task.yield()
		}
		try #require(table.autosaveName != nil)

		#expect(table.tableColumns.first?.identifier == identifier(.due))
		// Where the header and cells draw: each shown column right after the one before it.
		var edge = table.rect(ofColumn: 0).minX
		for (index, column) in table.tableColumns.enumerated() {
			let rect = table.rect(ofColumn: index)
			guard !column.isHidden else {
				#expect(rect.width == 0, "\(column.identifier.rawValue)")
				continue
			}
			#expect(rect.minX == edge, "\(column.identifier.rawValue)")
			#expect(rect.width > 0, "\(column.identifier.rawValue)")
			edge = rect.maxX
		}
	}
}

/// A Taskrc with a file, so loading it doesn't offer the Taskrc hint.
private let loaded = TaskrcClient.Loaded(
	taskrc: .defaults,
	url: URL(filePath: "/Users/paul/.taskrc"),
)

private func identifier(_ column: TaskColumn) -> NSUserInterfaceItemIdentifier {
	NSUserInterfaceItemIdentifier(column.identifier)
}

@MainActor
private func store(taskrc: TaskrcClient.Loaded?) -> StoreOf<ReplicaFeature> {
	var state = ReplicaFeature.State(bookmark: Data())
	state.taskrc = taskrc
	return Store(initialState: state) {
		ReplicaFeature()
	} withDependencies: {
		$0.date.now = Date(timeIntervalSince1970: 1_790_000_000)
		$0.timeZone = .gmt
	}
}

/// `controller`'s table, laid out in a window.
@MainActor
private func table(in controller: TaskTableController) throws -> NSTableView {
	let window = NSWindow(
		contentRect: NSRect(x: 0, y: 0, width: 900, height: 400),
		styleMask: [.titled],
		backing: .buffered,
		defer: false,
	)
	window.contentViewController = controller
	window.layoutIfNeeded()
	let scrollView = try #require(controller.view as? NSScrollView)
	return try #require(scrollView.documentView as? NSTableView)
}
