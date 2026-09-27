import AppKit
import ComposableArchitecture
import Foundation
@testable import ReplicaFeature
import Taskrc
import TaskrcClient
import Testing
import TestSupport

@MainActor
struct TaskTableControllerTests {
	@Test
	func restoredLayoutDrawsColumnsInItsOrder() async throws {
		let autosaveName = "test:\(UUID())"
		defer {
			for prefix in autosaveKeyPrefixes {
				UserDefaults.standard.removeObject(forKey: "\(prefix) \(autosaveName)")
			}
		}
		let savingTable = try await tableLoadingTaskrc(autosaveName: autosaveName)
		try #require(savingTable.tableColumn(withIdentifier: identifier(.tags))).isHidden = true
		try #require(savingTable.tableColumn(withIdentifier: identifier(.uda("size")))).isHidden = false
		savingTable.moveColumn(savingTable.column(withIdentifier: identifier(.due)), toColumn: 0)
		// Saved fitting the table, as a window saves it, so restoring it changes no column's width.
		savingTable.sizeToFit()

		let restoredTable = try await tableLoadingTaskrc(autosaveName: autosaveName)

		#expect(restoredTable.tableColumns.first?.identifier == identifier(.due))
		#expect(restoredTable.tableColumn(withIdentifier: identifier(.uda("size")))?.isHidden == false)
		// Where the header and cells draw: each shown column right after the one before it.
		var edge = restoredTable.rect(ofColumn: 0).minX
		for (index, column) in restoredTable.tableColumns.enumerated() {
			let rect = restoredTable.rect(ofColumn: index)
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

/// The keys AppKit saves a table's columns and sort under, each followed by its autosave name.
private let autosaveKeyPrefixes = ["NSTableView Columns v3", "NSTableView Sort Ordering v2"]

private let now = Date(timeIntervalSince1970: 1_790_000_000)

/// A Taskrc defining a UDA, attached from a file so loading it doesn't offer the Taskrc hint.
private let sizedTaskrc: TaskrcClient.Loaded = {
	let taskrc = Taskrc(path: taskrcFile.path(), environment: .fixture) { path, _ in
		Taskrc.File(contents: "uda.size.type=string\nuda.size.values=S,M,L", realPath: path)
	}
	return TaskrcClient.Loaded(taskrc: taskrc, url: taskrcFile)
}()

private let taskrcFile = URL(filePath: "/Users/paul/.taskrc")

private func identifier(_ column: TaskColumn) -> NSUserInterfaceItemIdentifier {
	NSUserInterfaceItemIdentifier(column.identifier)
}

/// A table laid out in a window before its Taskrc loads, as a window opening on a Replica is, once
/// the Taskrc has loaded and the table has restored its layout.
@MainActor
private func tableLoadingTaskrc(autosaveName: String) async throws -> NSTableView {
	let store = Store(initialState: ReplicaFeature.State(bookmark: Data())) {
		ReplicaFeature()
	} withDependencies: {
		$0.date.now = now
		$0.timeZone = .gmt
	}
	let controller = TaskTableController(autosaveName: autosaveName, store: store)
	let window = NSWindow(
		contentRect: NSRect(x: 0, y: 0, width: 900, height: 400),
		styleMask: [.titled],
		backing: .buffered,
		defer: false,
	)
	window.contentViewController = controller
	window.layoutIfNeeded()
	let scrollView = try #require(controller.view as? NSScrollView)
	let table = try #require(scrollView.documentView as? NSTableView)
	store.send(.taskrcLoaded(sizedTaskrc))
	// The table follows the store on a later turn of the run loop.
	for _ in 0 ..< 100 where table.autosaveName == nil {
		await Task.yield()
	}
	try #require(table.autosaveName != nil)
	return table
}
