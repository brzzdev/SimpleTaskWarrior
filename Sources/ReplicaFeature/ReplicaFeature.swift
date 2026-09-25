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
		/// The highest Urgency in the table, which scales every row's bar.
		var highestUrgency = 0.0
		var isTaskrcHintPresented = false
		/// Kept per Replica once its folder resolves, so it outlives the window.
		@Shared(value: Layout()) var layout
		/// Every task in the Replica as last read, which the blocked rule and Urgency read.
		var storedTasks: [StoredTask] = []
		/// Pending tasks, in `sortOrder`.
		var rows: IdentifiedArrayOf<TaskRow> = []
		/// Kept by UUID, so it survives the CLI renumbering tasks.
		var selection: Set<Models.Task.ID> = []
		var taskrc: TaskrcClient.Loaded?
		/// Why the last Taskrc or grant the user chose couldn't be kept.
		var taskrcSaveFailure: TaskrcSaveFailure?
		/// The running Taskrc's UDAs, which the table offers as columns.
		var udaColumns = UDAColumn.all(in: .defaults)

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
			return folder(location) == folder(directory.path(percentEncoded: false)) ? nil : location
		}

		/// The Taskrc the window runs on: the last one that loaded, or TW's defaults.
		var runningTaskrc: Taskrc {
			taskrc?.taskrc ?? .defaults
		}

		/// The table's binding to `layout.sortOrder`, which any window on the Replica can change.
		var sortOrder: [TaskSort] {
			get { layout.sortOrder }
			set { $layout.withLock { $0.sortOrder = newValue } }
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
		case chooseTaskrcButtonTapped
		case directoryResolved(URL)
		case fetchRequested
		case fileChosen(URL, for: FileImporter)
		case grantAccessButtonTapped
		case openFailed(String)
		case pairingChanged
		/// The sort order changed, in this window or another on the Replica.
		case sortOrderChanged
		case taskrcHintCloseButtonTapped
		case taskrcLoaded(TaskrcClient.Loaded)
		case taskrcSaveFailed(TaskrcSaveFailure)
		case tasksLoaded([StoredTask])
		case timerTicked
		case tryAgainButtonTapped
		case useTaskwarriorDefaultsButtonTapped
	}

	/// How a window over the Replica arranges its table and inspector. The view binds `columns` and
	/// `isInspectorPresented` directly, since only a new sort order needs the reducer.
	struct Layout: Codable, Equatable {
		var columns = TableColumnCustomization<TaskRow>()
		var isInspectorPresented = true
		var sortOrder = [TaskSort(.urgency, order: .reverse)]
	}

	private enum CancelID {
		case bookmarkChanges
		case taskrc
	}

	@Dependency(\.bookmarkClient) var bookmarkClient
	@Dependency(\.continuousClock) var clock
	@Dependency(\.date.now) var now
	@Dependency(\.replicaClient) var replicaClient
	@Dependency(\.taskrcClient) var taskrcClient
	@Dependency(\.timeZone) var timeZone

	public var body: some ReducerOf<Self> {
		BindingReducer()
		Reduce { state, action in
			switch action {
			case .binding:
				return .none

			case .chooseTaskrcButtonTapped:
				state.fileImporter = .taskrc
				return .none

			case let .directoryResolved(directory):
				state.directory = directory
				state.$layout = Shared(wrappedValue: Layout(), .appStorage(layoutKey(for: directory)))
				// Another window pairing, detaching or granting changes this window's Taskrc too. Subscribed
				// here rather than in the effect, so the subscription exists before the first load reads the
				// pairing and a change between the two can't be missed.
				let changes = bookmarkClient.changes()
				return .merge(
					loadTaskrc(for: state),
					.run { send in
						for await _ in changes {
							await send(.pairingChanged)
						}
					}
					.cancellable(id: CancelID.bookmarkChanges, cancelInFlight: true),
				)

			case .fetchRequested:
				return .merge(
					.run { [bookmark = state.bookmark, bookmarkClient, replicaClient] send in
						let directory = try bookmarkClient.resolve(bookmark)
						await send(.directoryResolved(directory))
						for try await tasks in replicaClient.tasks(directory) {
							await send(.tasksLoaded(tasks))
						}
					} catch: { error, send in
						await send(.openFailed(error.localizedDescription))
					},
					// Urgency moves with the clock too, as due dates near and `scheduled` and `wait` pass,
					// while the Replica may not change for hours.
					.run { [clock] send in
						for await _ in clock.timer(interval: urgencyInterval) {
							await send(.timerTicked)
						}
					},
				)

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

			case .pairingChanged:
				return loadTaskrc(for: state)

			case .sortOrderChanged:
				sortRows(&state)
				return .none

			case .taskrcHintCloseButtonTapped:
				state.isTaskrcHintPresented = false
				return .none

			case let .taskrcLoaded(taskrc):
				state.taskrc = taskrc
				updateRows(&state)
				// Another window may have attached one while this window offered it.
				if taskrc.url != nil {
					state.isTaskrcHintPresented = false
				} else if !state.hasShownTaskrcHint {
					state.isTaskrcHintPresented = true
					state.$hasShownTaskrcHint.withLock { $0 = true }
				}
				return .none

			case let .taskrcSaveFailed(failure):
				state.taskrcSaveFailure = failure
				return .none

			case let .tasksLoaded(tasks):
				state.storedTasks = tasks
				updateRows(&state)
				return .none

			case .timerTicked:
				updateRows(&state)
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
		return .run { [bookmarkClient, lastGood = state.runningTaskrc, taskrcClient] send in
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

	/// Ranks the Replica's pending tasks with the Taskrc the window runs on, decoding their UDAs and
	/// computing their Urgency again, and drops selected tasks that left the table.
	private func updateRows(_ state: inout State) {
		let taskrc = state.runningTaskrc
		let tasks = state.storedTasks.compactMap { Models.Task($0, udaTypes: taskrc.udaTypes) }
		let blocked = DependencyScan(tasks).blocked
		let urgencies = UrgencyCoefficients(taskrc).urgencies(of: tasks, at: now, in: timeZone)
		state.udaColumns = UDAColumn.all(in: taskrc)
		state.rows = IdentifiedArray(
			uniqueElements: tasks
				.filter { $0.status == .pending && !$0.isTemplate }
				.map { [udaColumns = state.udaColumns] task in
					TaskRow(
						isBlocked: blocked.contains(task.id),
						task: task,
						udaColumns: udaColumns,
						urgency: urgencies[task.id] ?? 0,
					)
				},
		)
		sortRows(&state)
		state.highestUrgency = state.rows.map(\.urgency).max() ?? 0
		state.selection.formIntersection(state.rows.ids)
	}

	/// Sorts the table's rows by `sortOrder`, breaking ties by ID so the order holds still.
	private func sortRows(_ state: inout State) {
		state.rows = IdentifiedArray(
			uniqueElements: state.rows.sorted(using: state.sortOrder + [TaskSort(.id)]),
		)
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
		// The save also reaches this window through `bookmarkClient.changes`. Reloading here as well
		// keeps the reload when a save leaves the bookmarks as they were, and cancels the other.
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

/// The folder at `path`, standardized so two spellings of it compare equal.
private func folder(_ path: String) -> URL {
	URL(filePath: path, directoryHint: .isDirectory).standardizedFileURL
}

/// The user defaults key of the layout of the Replica in `directory`. Keyed on the folder rather
/// than the bookmark, since opening the folder again makes a new bookmark, so a moved Replica
/// starts over. Its dots are percent-encoded, since a key with one can't be observed through
/// key-value observing, and its percent signs first, so two folders never share a key.
func layoutKey(for directory: URL) -> String {
	let path = folder(directory.path(percentEncoded: false)).path(percentEncoded: false)
	return "layout:" + path.replacing("%", with: "%25").replacing(".", with: "%2E")
}

/// How often an open window computes its tasks' Urgency again.
private let urgencyInterval = Duration.seconds(60)

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
			} else if store.directory != nil {
				// Only once `layout` is the Replica's, so the table doesn't draw the default first.
				TaskTable(store: store)
					.safeAreaInset(edge: .top, spacing: 0) {
						banners
					}
					.inspector(isPresented: Binding(store.$layout.isInspectorPresented)) {
						if store.selection.isEmpty {
							ContentUnavailableView("No Selection", systemImage: "sidebar.trailing")
						}
					}
					.toolbar {
						Button("Inspector", systemImage: "sidebar.trailing") {
							store.$layout.withLock { $0.isInspectorPresented.toggle() }
						}
					}
			}
		}
		.navigationTitle(store.directory?.lastPathComponent ?? "")
		.navigationSubtitle(store.directory?.path(percentEncoded: false) ?? "")
		.fileImporter(
			isPresented: Binding($store.fileImporter),
			// Files, and the symlinks dotfile managers make of them. Folders and packages are neither.
			allowedContentTypes: [.data, .symbolicLink],
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
