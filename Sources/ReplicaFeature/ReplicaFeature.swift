// The window over one Replica: sidebar, task table and inspector.
import BookmarkClient
public import ComposableArchitecture
public import Foundation
public import Models
import ReplicaClient
public import SwiftUI

@Reducer
public struct ReplicaFeature {
	@ObservableState
	public struct State: Equatable {
		public let bookmark: Data

		var directory: URL?
		var failure: String?
		/// Kept by UUID, so it survives the CLI renumbering tasks.
		var selection: Set<Models.Task.ID> = []
		var tasks: IdentifiedArrayOf<Models.Task> = []

		public init(bookmark: Data) {
			self.bookmark = bookmark
		}
	}

	public enum Action: BindableAction, Sendable {
		case binding(BindingAction<State>)
		case directoryResolved(URL)
		case fetchRequested
		case openFailed(String)
		case tasksLoaded([Models.Task])
	}

	@Dependency(\.bookmarkClient) var bookmarkClient
	@Dependency(\.replicaClient) var replicaClient

	public var body: some ReducerOf<Self> {
		BindingReducer()
		Reduce { state, action in
			switch action {
			case .binding:
				return .none

			case let .directoryResolved(directory):
				state.directory = directory
				return .none

			case .fetchRequested:
				return .run { [bookmark = state.bookmark, bookmarkClient, replicaClient] send in
					let directory = try bookmarkClient.resolve(bookmark)
					await send(.directoryResolved(directory))
					for try await tasks in replicaClient.tasks(directory) {
						await send(.tasksLoaded(tasks))
					}
				} catch: { error, send in
					await send(.openFailed(error.localizedDescription))
				}

			case let .openFailed(failure):
				state.failure = failure
				return .none

			case let .tasksLoaded(tasks):
				state.tasks = IdentifiedArray(
					uniqueElements: tasks
						.filter { $0.status == .pending }
						.sorted { ($0.workingSetID ?? .max) < ($1.workingSetID ?? .max) },
				)
				state.selection.formIntersection(state.tasks.ids)
				return .none
			}
		}
	}

	public init() {}
}

public struct ReplicaView: View {
	@Bindable var store: StoreOf<ReplicaFeature>

	public init(store: StoreOf<ReplicaFeature>) {
		self.store = store
	}

	public var body: some View {
		NavigationSplitView {
			List {}
		} detail: {
			if let failure = store.failure {
				ContentUnavailableView(
					"Can't Open Replica",
					systemImage: "exclamationmark.triangle",
					description: Text(failure),
				)
			} else {
				Table(store.tasks, selection: $store.selection) {
					TableColumn("ID") { task in
						Text(task.workingSetID.map(String.init) ?? "")
							.monospacedDigit()
					}
					.width(min: 32, ideal: 40, max: 64)
					TableColumn("Description", value: \.description)
				}
			}
		}
		.navigationTitle(store.directory?.lastPathComponent ?? "")
		.navigationSubtitle(store.directory?.path(percentEncoded: false) ?? "")
		.task { await store.send(.fetchRequested).finish() }
	}
}
