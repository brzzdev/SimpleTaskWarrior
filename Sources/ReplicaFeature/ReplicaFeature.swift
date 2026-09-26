// One Replica as its window shows it: the tasks, the Taskrc it runs on and their order.
import BookmarkClient
import ComposableArchitecture
import Foundation
import Models
import ReplicaClient
import Sharing
import Taskrc
import TaskrcClient

@Reducer
struct ReplicaFeature {
	@ObservableState
	struct State: Equatable {
		let bookmark: Data

		var directory: URL?
		var failure: String?
		var fileImporter: FileImporter?
		/// Set once the hint that offers Choose Taskrc… has been shown, in any window.
		@Shared(.appStorage("hasShownTaskrcHint")) var hasShownTaskrcHint = false
		/// The highest Urgency in the table, which scales every row's bar.
		var highestUrgency = 0.0
		var isTaskrcHintPresented = false
		/// Every task in the Replica as last read, which the blocked rule and Urgency read.
		var storedTasks: [StoredTask] = []
		/// Pending tasks, in `sortOrder`.
		var rows: IdentifiedArrayOf<TaskRow> = []
		/// Kept by UUID, so it survives the CLI renumbering tasks.
		var selection: Set<Models.Task.ID> = []
		/// The table's sort, which the table autosaves per Replica and reports once it restores.
		var sortOrder = [TaskSort(.urgency, order: .reverse)]
		var taskrc: TaskrcClient.Loaded?
		/// Why the last Taskrc or grant the user chose couldn't be kept.
		var taskrcSaveFailure: TaskrcSaveFailure?
		/// The running Taskrc's UDAs, which the table offers as columns.
		var udaColumns = UDAColumn.all(in: .defaults)

		/// Whether Grant Access… can fix the Taskrc's problem.
		var canGrantAccess: Bool {
			if case .grant = taskrcRemedy {
				return true
			}
			return false
		}

		/// Whether the window has a Taskrc, rather than running on TW's defaults.
		var hasTaskrc: Bool {
			taskrc?.url != nil
		}

		/// The Taskrc's `data.location`, where it names a folder other than the window's Replica.
		var otherDataLocation: String? {
			guard hasTaskrc, let directory, let location = taskrc?.taskrc["data.location"] else {
				return nil
			}
			return standardizedFolder(URL(filePath: location)) == standardizedFolder(directory)
				? nil
				: location
		}

		/// The Taskrc the window runs on: the last one that loaded, or TW's defaults.
		var runningTaskrc: Taskrc {
			taskrc?.taskrc ?? .defaults
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

		init(bookmark: Data) {
			self.bookmark = bookmark
		}
	}

	struct TaskrcSaveFailure: Equatable {
		var message: String
		/// The panel that chose the file, which Try Again… opens again.
		var retry: FileImporter?
	}

	/// What a file panel on screen is choosing.
	enum FileImporter: Equatable {
		/// The file an `include` line names, which the app couldn't read at `file`.
		case grant(Taskrc.Include, file: URL)
		case taskrc
	}

	enum Action: BindableAction {
		case binding(BindingAction<State>)
		case chooseTaskrcButtonTapped
		case directoryResolved(URL)
		case fetchRequested
		case fileChosen(URL, for: FileImporter)
		case grantAccessButtonTapped
		case openFailed(String)
		case pairingChanged
		/// A column header was clicked, or the table restored the Replica's sort.
		case sortOrderChanged([TaskSort])
		case taskrcHintCloseButtonTapped
		case taskrcLoaded(TaskrcClient.Loaded)
		case taskrcSaveFailed(TaskrcSaveFailure)
		case tasksLoaded([StoredTask])
		case timerTicked
		case tryAgainButtonTapped
		case useTaskwarriorDefaultsButtonTapped
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

	var body: some ReducerOf<Self> {
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

			case let .sortOrderChanged(sortOrder):
				state.sortOrder = sortOrder
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

	init() {}

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

/// How often an open window computes its tasks' Urgency again.
private let urgencyInterval = Duration.seconds(60)
