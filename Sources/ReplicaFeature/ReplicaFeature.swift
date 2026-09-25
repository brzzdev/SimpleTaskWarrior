// The window over one Replica: sidebar, task table and inspector.
import BookmarkClient
public import ComposableArchitecture
public import Foundation
public import Models
import ReplicaClient
public import Sharing
public import SwiftUI
public import Taskrc
public import TaskrcClient
import UniformTypeIdentifiers

@Reducer
public struct ReplicaFeature {
	@ObservableState
	public struct State: Equatable {
		public let bookmark: Data

		var directory: URL?
		var failure: String?
		var fileImporter: FileImporter?
		/// Set once the hint that offers Choose Taskrc… has been shown, in any window.
		@Shared(.appStorage("hasShownTaskrcHint")) var hasShownTaskrcHint = false
		var isTaskrcHintPresented = false
		/// Kept by UUID, so it survives the CLI renumbering tasks.
		var selection: Set<Models.Task.ID> = []
		var taskrc: TaskrcClient.Loaded?
		/// Why the last Taskrc or grant the user chose couldn't be kept.
		var taskrcSaveFailure: TaskrcSaveFailure?
		var tasks: IdentifiedArrayOf<Models.Task> = []

		/// Whether Grant Access… can fix the Taskrc's problem.
		public var canGrantAccess: Bool {
			if case .grant = taskrcRemedy {
				return true
			}
			return false
		}

		/// Whether the window has a Taskrc, rather than running on TW's defaults.
		public var hasTaskrc: Bool {
			taskrc?.url != nil
		}

		/// The Taskrc's `data.location`, where it names a folder other than the window's Replica.
		var otherDataLocation: String? {
			guard hasTaskrc, let directory, let location = taskrc?.taskrc["data.location"] else {
				return nil
			}
			let folder = { (path: String) in
				URL(filePath: path, directoryHint: .isDirectory).standardizedFileURL
			}
			return folder(location) == folder(directory.path(percentEncoded: false)) ? nil : location
		}

		/// The file panel that fixes the Taskrc's problem: a grant for an include the app can't read,
		/// or another Taskrc in place of one it can't.
		var taskrcRemedy: FileImporter? {
			guard let problem = taskrc?.problem else {
				return nil
			}
			switch problem.kind {
			case let .notFound(path, variables), let .unreadable(path, variables):
				guard let include = problem.include else {
					return .taskrc
				}
				// A grant can't make a missing file exist, only reach one an unset variable moved.
				if case .notFound = problem.kind, variables.isEmpty {
					return nil
				}
				return .grant(include, file: URL(filePath: path))

			default:
				return nil
			}
		}

		public init(bookmark: Data) {
			self.bookmark = bookmark
		}
	}

	public struct TaskrcSaveFailure: Equatable, Sendable {
		public var message: String
		/// The panel that chose the file, which Try Again… opens again.
		public var retry: FileImporter?
	}

	/// What a file panel on screen is choosing.
	public enum FileImporter: Equatable, Sendable {
		/// The file an `include` line names, which the app couldn't read at `file`.
		case grant(Taskrc.Include, file: URL)
		case taskrc
	}

	public enum Action: BindableAction, Sendable {
		case binding(BindingAction<State>)
		case bookmarksChanged
		case chooseTaskrcButtonTapped
		case directoryResolved(URL)
		case fetchRequested
		case fileChosen(URL, for: FileImporter)
		case grantAccessButtonTapped
		case openFailed(String)
		case taskrcHintCloseButtonTapped
		case taskrcLoaded(TaskrcClient.Loaded)
		case taskrcSaveFailed(TaskrcSaveFailure)
		case tasksLoaded([Models.Task])
		case tryAgainButtonTapped
		case useTaskwarriorDefaultsButtonTapped
	}

	private enum CancelID {
		case bookmarkChanges
		case taskrc
	}

	@Dependency(\.bookmarkClient) var bookmarkClient
	@Dependency(\.replicaClient) var replicaClient
	@Dependency(\.taskrcClient) var taskrcClient

	public var body: some ReducerOf<Self> {
		BindingReducer()
		Reduce { state, action in
			switch action {
			case .binding:
				return .none

			case .bookmarksChanged:
				return loadTaskrc(for: state)

			case .chooseTaskrcButtonTapped:
				state.fileImporter = .taskrc
				return .none

			case let .directoryResolved(directory):
				state.directory = directory
				return .merge(
					loadTaskrc(for: state),
					// Another window pairing, detaching or granting changes this window's Taskrc too.
					.run { [bookmarkClient] send in
						for await _ in bookmarkClient.changes() {
							await send(.bookmarksChanged)
						}
					}
					.cancellable(id: CancelID.bookmarkChanges, cancelInFlight: true),
				)

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

			case let .fileChosen(file, .grant(include, resolved)):
				state.fileImporter = nil
				state.taskrcSaveFailure = nil
				return reloadTaskrc(
					for: state,
					retrying: .grant(include, file: resolved),
				) { [bookmarkClient] _ in
					try bookmarkClient.saveGrant(file, include)
				}

			case let .fileChosen(file, .taskrc):
				state.fileImporter = nil
				state.isTaskrcHintPresented = false
				state.taskrcSaveFailure = nil
				return reloadTaskrc(
					for: state,
					retrying: .taskrc,
				) { [bookmarkClient] directory in
					try bookmarkClient.saveTaskrc(file, directory)
				}

			case .grantAccessButtonTapped:
				state.fileImporter = state.taskrcRemedy
				return .none

			case let .openFailed(failure):
				state.failure = failure
				return .none

			case .taskrcHintCloseButtonTapped:
				state.isTaskrcHintPresented = false
				return .none

			case let .taskrcLoaded(taskrc):
				state.taskrc = taskrc
				if taskrc.url == nil, !state.hasShownTaskrcHint {
					state.isTaskrcHintPresented = true
					state.$hasShownTaskrcHint.withLock { $0 = true }
				}
				return .none

			case let .taskrcSaveFailed(failure):
				state.taskrcSaveFailure = failure
				return .none

			case let .tasksLoaded(tasks):
				state.tasks = IdentifiedArray(
					uniqueElements: tasks
						.filter { $0.status == .pending && !$0.isTemplate }
						.sorted { ($0.workingSetID ?? .max) < ($1.workingSetID ?? .max) },
				)
				state.selection.formIntersection(state.tasks.ids)
				return .none

			case .tryAgainButtonTapped:
				state.fileImporter = state.taskrcSaveFailure?.retry
				return .none

			case .useTaskwarriorDefaultsButtonTapped:
				state.isTaskrcHintPresented = false
				state.taskrcSaveFailure = nil
				// Detaching makes no bookmark, so it has nothing to retry.
				return reloadTaskrc(
					for: state,
					retrying: nil,
				) { [bookmarkClient] directory in
					try bookmarkClient.saveTaskrc(nil, directory)
				}
			}
		}
	}

	public init() {}

	/// Loads the Taskrc paired with the window's Replica, and keeps it current, replacing any load
	/// already running. Until the Taskrc parses, the window keeps the Taskrc it runs on now.
	private func loadTaskrc(for state: State) -> Effect<Action> {
		guard let directory = state.directory else {
			return .none
		}
		return .run { [bookmarkClient, lastGood = state.taskrc?.taskrc ?? .defaults, taskrcClient] send in
			// So an include in the Replica folder reads without a grant of its own.
			let isAccessing = directory.startAccessingSecurityScopedResource()
			defer {
				if isAccessing {
					directory.stopAccessingSecurityScopedResource()
				}
			}
			let taskrcs = taskrcClient.load(
				{ bookmarkClient.taskrc(directory) },
				{ bookmarkClient.grants() },
				lastGood,
			)
			for await taskrc in taskrcs {
				await send(.taskrcLoaded(taskrc))
			}
		}
		.cancellable(id: CancelID.taskrc, cancelInFlight: true)
	}

	/// Runs `save` with the Replica's folder, then loads its Taskrc again. A failed save is
	/// reported with the panel that would choose the file again.
	private func reloadTaskrc(
		for state: State,
		retrying retry: FileImporter?,
		after save: @escaping @Sendable (_ directory: URL) throws -> Void,
	) -> Effect<Action> {
		guard let directory = state.directory else {
			return .none
		}
		return .concatenate(
			.run { _ in
				try save(directory)
			} catch: { error, send in
				await send(
					.taskrcSaveFailed(TaskrcSaveFailure(message: error.localizedDescription, retry: retry)),
				)
			},
			loadTaskrc(for: state),
		)
	}
}

public struct ReplicaView: View {
	@Bindable var store: StoreOf<ReplicaFeature>

	/// Where the file panel opens: at the path an include resolved to, or in the home folder, where
	/// the CLI looks for `.taskrc`.
	private var fileDialogDirectory: URL? {
		switch store.fileImporter {
		case let .grant(_, file):
			file.deletingLastPathComponent()

		case .taskrc:
			Taskrc.Environment.live.variables["HOME"].map { URL(filePath: $0, directoryHint: .isDirectory) }

		case nil:
			nil
		}
	}

	private var fileDialogMessage: Text {
		switch store.fileImporter {
		case let .grant(_, file):
			Text("Grant access to \(file.lastPathComponent), which the Taskrc includes.")

		case nil, .taskrc:
			Text("Choose the Taskrc to use with this Replica.")
		}
	}

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
				.safeAreaInset(edge: .top, spacing: 0) {
					banners
				}
			}
		}
		.navigationTitle(store.directory?.lastPathComponent ?? "")
		.navigationSubtitle(store.directory?.path(percentEncoded: false) ?? "")
		.fileImporter(
			isPresented: Binding($store.fileImporter),
			// Regular files only: folders and packages aren't `.data`, and the Taskrc and its includes are
			// files.
			allowedContentTypes: [.data],
		) { [fileImporter = store.fileImporter] result in
			guard let fileImporter, let file = try? result.get() else {
				return
			}
			store.send(.fileChosen(file, for: fileImporter))
		}
		.fileDialogBrowserOptions(.includeHiddenFiles)
		.fileDialogDefaultDirectory(fileDialogDirectory)
		.fileDialogMessage(fileDialogMessage)
		.task { await store.send(.fetchRequested).finish() }
	}

	private var banners: some View {
		VStack(spacing: 0) {
			if store.isTaskrcHintPresented {
				Banner(systemImage: "gearshape") {
					Text("Choose your Taskrc to use its UDAs, Urgency coefficients and Context.")
				} actions: {
					Button("Choose Taskrc…") { store.send(.chooseTaskrcButtonTapped) }
					Button("Close", systemImage: "xmark") { store.send(.taskrcHintCloseButtonTapped) }
						.labelStyle(.iconOnly)
						.buttonStyle(.borderless)
				}
			}
			if let problem = store.taskrc?.problem {
				Banner(systemImage: "exclamationmark.triangle.fill") {
					Text(description(of: problem))
				} actions: {
					switch store.taskrcRemedy {
					case .grant:
						Button("Grant Access…") { store.send(.grantAccessButtonTapped) }

					case .taskrc:
						Button("Choose Taskrc…") { store.send(.chooseTaskrcButtonTapped) }

					case nil:
						EmptyView()
					}
				}
			}
			if let failure = store.taskrcSaveFailure {
				Banner(systemImage: "exclamationmark.triangle.fill") {
					Text("SimpleTaskWarrior couldn't keep access to the file: \(failure.message)")
				} actions: {
					if failure.retry != nil {
						Button("Try Again…") { store.send(.tryAgainButtonTapped) }
					}
				}
			}
			if let location = store.otherDataLocation {
				Banner(systemImage: "info.circle") {
					Text("The Taskrc's data.location is \(location), not this Replica.")
				} actions: {}
			}
		}
	}
}

/// A strip across the top of the task list.
private struct Banner<Message: View, Actions: View>: View {
	let systemImage: String
	@ViewBuilder let message: Message
	@ViewBuilder let actions: Actions

	var body: some View {
		HStack {
			Image(systemName: systemImage)
				.foregroundStyle(.secondary)
			message
				.frame(maxWidth: .infinity, alignment: .leading)
			actions
		}
		.padding(.horizontal, 12)
		.padding(.vertical, 8)
		.background(.bar)
		.overlay(alignment: .bottom) {
			Divider()
		}
	}
}

/// The banner's text for `problem`: where it is, what's wrong, and, when the window keeps running
/// on an earlier parse, what that risks.
private func description(of problem: Taskrc.Problem) -> String {
	let error =
		switch problem.kind {
		case let .includeNestedTooDeeply(path):
			"\(path) is included more than \(Taskrc.maximumIncludeDepth) levels deep."

		case let .invalidUDAType(uda, type):
			"UDA \(uda) has type \(type), which Taskwarrior doesn't know."

		case let .invalidWeekstart(day):
			"weekstart is \(day), which isn't Sunday or Monday."

		case let .malformedLine(line):
			"“\(line)” isn't a key=value line or an include."

		case let .notFound(path, variables):
			"\(path) doesn't exist." + unsetVariablesNote(variables)

		case let .unreadable(path, variables):
			"SimpleTaskWarrior needs access to \(path)." + unsetVariablesNote(variables)

		case let .unsetVariables(variables, key):
			"\(key) is missing variables." + unsetVariablesNote(variables)
		}
	let location = problem.location.map { "\($0.file), line \($0.line): " } ?? ""
	let stale =
		problem.kind.isFatal
			? " Running on the last Taskrc that loaded, or Taskwarrior's defaults, so the Context's"
				+ " defaults for new tasks may be out of date."
			: ""
	return location + error + stale
}

/// Names `variables`, which expanded to nothing.
private func unsetVariablesNote(_ variables: [String]) -> String {
	guard !variables.isEmpty else {
		return ""
	}
	let names = ListFormatter.localizedString(byJoining: variables.map { "$\($0)" })
	return " \(names) \(variables.count == 1 ? "isn't" : "aren't") set for SimpleTaskWarrior."
}
