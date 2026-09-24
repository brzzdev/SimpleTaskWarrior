import AppKit
import BookmarkClient
import ComposableArchitecture
import ReplicaClient
import ReplicaFeature
public import SwiftUI

public struct SimpleTaskWarriorApp: App {
	public var body: some Scene {
		// Keyed on the Replica's bookmark, so SwiftUI restores each window after a relaunch.
		WindowGroup(for: Data.self) { $bookmark in
			if let bookmark {
				ReplicaWindow(bookmark: bookmark)
			} else {
				ContentUnavailableView {
					Label("No Replica", systemImage: "checklist")
				} description: {
					Text("Open the folder `TASKDATA` points at.")
				} actions: {
					Button("Open Replica…") {
						_Concurrency.Task {
							bookmark = await chooseReplica()
						}
					}
				}
			}
		}
		.commands {
			CommandGroup(replacing: .newItem) {
				OpenReplicaButton()
			}
		}
	}

	public init() {}
}

private struct OpenReplicaButton: View {
	@Environment(\.openWindow) private var openWindow

	var body: some View {
		Button("Open Replica…") {
			_Concurrency.Task {
				guard let bookmark = await chooseReplica() else { return }
				openWindow(value: bookmark)
			}
		}
		.keyboardShortcut("o")
	}
}

private struct ReplicaWindow: View {
	@State private var store: StoreOf<ReplicaFeature>

	init(bookmark: Data) {
		_store = State(
			initialValue: Store(initialState: ReplicaFeature.State(bookmark: bookmark)) {
				ReplicaFeature()
			},
		)
	}

	var body: some View {
		ReplicaView(store: store)
	}
}

/// Asks for a Replica folder and bookmarks it, or explains why it can't be opened. Nil when
/// there's no window to open.
@MainActor
private func chooseReplica() async -> Data? {
	@Dependency(\.bookmarkClient) var bookmarkClient
	@Dependency(\.replicaClient) var replicaClient

	let panel = NSOpenPanel()
	panel.canChooseDirectories = true
	panel.canChooseFiles = false
	panel.message = "Choose a Taskwarrior 3 Replica: the folder TASKDATA points at."
	panel.prompt = "Open"
	guard await panel.begin() == .OK, let directory = panel.url else { return nil }

	do {
		try await replicaClient.validate(directory)
		return try bookmarkClient.create(directory)
	} catch {
		let alert = NSAlert()
		alert.messageText = error.localizedDescription
		alert.runModal()
		return nil
	}
}
