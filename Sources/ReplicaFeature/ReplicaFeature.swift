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
		/// Every task a fixed view shows, ranked and in `sortOrder`, which the sidebar and search narrow
		/// to `rows`.
		var allRows: [TaskRow] = []
		let bookmark: Data
		/// The task a New Task is creating, which is selected once it commits.
		var creatingTask: Models.Task.ID?
		var directory: URL?
		var failure: String?
		var fileImporter: FileImporter?
		/// Set once the hint that offers Choose Taskrc… has been shown, in any window.
		@Shared(.appStorage("hasShownTaskrcHint")) var hasShownTaskrcHint = false
		/// The highest Urgency in the table, which scales every row's bar.
		var highestUrgency = 0.0
		var isNewTaskRowPresented = false
		/// Set once a write has run long enough for the subtitle to say so.
		var isSaving = false
		var isTaskrcHintPresented = false
		/// Set while a write is in progress, which disables every other write.
		var isWriting = false
		/// The tasks the sidebar and search leave, in `sortOrder`.
		var rows: IdentifiedArrayOf<TaskRow> = []
		/// Narrows the table after the sidebar.
		var searchText = ""
		/// Kept by UUID, so it survives the CLI renumbering tasks.
		var selection: Set<Models.Task.ID> = []
		var sidebarSelection: Set<SidebarItem> = []
		/// The table's sort, which the table autosaves per Replica and reports once it restores.
		var sortOrder = [TaskSort(.urgency, order: .reverse)]
		/// Every task in the Replica as last read, which the blocked rule and Urgency read.
		var storedTasks: [StoredTask] = []
		var taskrc: TaskrcClient.Loaded?
		/// Why the last Taskrc or grant the user chose couldn't be kept.
		var taskrcSaveFailure: TaskrcSaveFailure?
		/// The running Taskrc's UDAs, which the table offers as columns.
		var udaColumns = UDAColumn.all(in: .defaults)

		/// The active Context's name, where there is one.
		var activeContext: String? {
			runningTaskrc["context"].flatMap { $0.isEmpty ? nil : $0 }
		}

		/// Whether Grant Access… can fix the Taskrc's problem.
		var canGrantAccess: Bool {
			if case .grant = taskrcRemedy {
				return true
			}
			return false
		}

		/// Whether Start/Stop stops, which it does when every selected task is active.
		var isStopping: Bool {
			let tasks = selectedTasks
			return !tasks.isEmpty && tasks.allSatisfy { $0.start != nil }
		}

		/// Whether the toolbar offers Mark Pending in place of Start/Stop, Done and Delete, which it
		/// does when every selected fixed view is Completed or Deleted.
		var offersMarkPending: Bool {
			SidebarFilter(sidebarSelection).views.isSubset(of: [.completed, .deleted])
		}

		/// The selected tasks, in the table's order.
		var selectedTasks: [Models.Task] {
			rows.filter { selection.contains($0.id) }.map(\.task)
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

		var sidebar: Sidebar {
			Sidebar(rows: allRows, selection: sidebarSelection)
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

		/// Whether `command` applies to every selected task, while no write is in progress.
		func isEnabled(_ command: TaskCommand) -> Bool {
			guard !isWriting else {
				return false
			}
			let tasks = selectedTasks
			guard command == .newTask || !tasks.isEmpty else {
				return false
			}
			switch command {
			case .delete:
				return tasks.allSatisfy { $0.status != .deleted }

			case .done:
				return tasks.allSatisfy { $0.status == .pending }

			case .markPending:
				return tasks.allSatisfy { $0.status == .completed || $0.status == .deleted }

			case .newTask:
				return true

			case .startStop:
				return isStopping || tasks.allSatisfy { $0.status == .pending }
			}
		}
	}

	/// A command on the selected tasks, from the toolbar, the menu bar or a row's context menu.
	enum TaskCommand {
		case delete
		case done
		case markPending
		case newTask
		case startStop
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
		case deleteButtonTapped
		case directoryResolved(URL)
		case doneButtonTapped
		case fetchRequested
		case fileChosen(URL, for: FileImporter)
		case grantAccessButtonTapped
		case markPendingButtonTapped
		case newTaskButtonTapped
		/// Return in the new-task row, or clicking away from it.
		case newTaskDescriptionSubmitted(String)
		/// Escape in the new-task row.
		case newTaskEditingCancelled
		case openFailed(String)
		case pairingChanged
		case savingDelayElapsed
		/// A column header was clicked, or the table restored the Replica's sort.
		case sortOrderChanged([TaskSort])
		case startStopButtonTapped
		case taskrcHintCloseButtonTapped
		case taskrcLoaded(TaskrcClient.Loaded)
		case taskrcSaveFailed(TaskrcSaveFailure)
		case tasksLoaded([StoredTask])
		case timerTicked
		case tryAgainButtonTapped
		case useTaskwarriorDefaultsButtonTapped
		case writeCommitted([StoredTask])
		case writeFailed
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
	@Dependency(\.uuid) var uuid

	var body: some ReducerOf<Self> {
		BindingReducer()
		Reduce { state, action in
			switch action {
			case .binding(\.searchText), .binding(\.sidebarSelection):
				filterRows(&state)
				return .none

			case .binding:
				return .none

			case .chooseTaskrcButtonTapped:
				state.fileImporter = .taskrc
				return .none

			case .deleteButtonTapped:
				guard state.isEnabled(.delete) else {
					return .none
				}
				return write(.delete(selectedIDs(state)), &state)

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

			case .doneButtonTapped:
				guard state.isEnabled(.done) else {
					return .none
				}
				return write(.complete(selectedIDs(state)), &state)

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

			case .markPendingButtonTapped:
				guard state.isEnabled(.markPending) else {
					return .none
				}
				return write(.markPending(selectedIDs(state)), &state)

			case .newTaskButtonTapped:
				guard state.isEnabled(.newTask) else {
					return .none
				}
				state.isNewTaskRowPresented = true
				if !sidebarShowsNewTask(state) {
					state.sidebarSelection = [.view(.pending)]
					filterRows(&state)
				}
				return .none

			case let .newTaskDescriptionSubmitted(description):
				state.isNewTaskRowPresented = false
				// Spaces alone are what the planner refuses as blank, so they cancel instead.
				guard !description.allSatisfy({ $0 == " " }) else {
					return .none
				}
				let id = uuid()
				state.creatingTask = id
				return write(.create(id, description: description), &state)

			case .newTaskEditingCancelled:
				state.isNewTaskRowPresented = false
				return .none

			case let .openFailed(failure):
				state.failure = failure
				return .none

			case .pairingChanged:
				return loadTaskrc(for: state)

			case .savingDelayElapsed:
				// The delay can elapse just as the write ends.
				state.isSaving = state.isWriting
				return .none

			case let .sortOrderChanged(sortOrder):
				state.sortOrder = sortOrder
				sortRows(&state)
				return .none

			case .startStopButtonTapped:
				guard state.isEnabled(.startStop) else {
					return .none
				}
				let ids = selectedIDs(state)
				return write(state.isStopping ? .stop(ids) : .start(ids), &state)

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

			case let .writeCommitted(tasks):
				state.storedTasks = tasks
				updateRows(&state)
				if let created = state.creatingTask {
					// Only a search can hide a new task: New Task already showed the sidebar it lands in.
					if state.rows[id: created] == nil, !state.searchText.isEmpty {
						state.searchText = ""
						filterRows(&state)
					}
					if state.rows[id: created] != nil {
						state.selection = [created]
					}
				}
				finishWrite(&state)
				return .none

			case .writeFailed:
				finishWrite(&state)
				return .none
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

	/// The one path every write takes. Plans `action` against the tasks as last read, and while the
	/// engine refuses the plan as stale, plans it again against the tasks it read instead, up to
	/// `planAttempts` times. Every other write waits until it finishes.
	private func write(_ action: WriteAction, _ state: inout State) -> Effect<Action> {
		guard !state.isWriting, let directory = state.directory else {
			return .none
		}
		state.isWriting = true
		let planner = WritePlanner(taskrc: state.runningTaskrc, timeZone: timeZone)
		return .run { [clock, now, replicaClient, storedTasks = state.storedTasks] send in
			// A child of the write, so it's cancelled as the write ends, however it ends.
			async let _: Void = {
				try await clock.sleep(for: savingDelay)
				await send(.savingDelayElapsed)
			}()
			var tasks = storedTasks
			for _ in 1 ... planAttempts {
				let plan = try planner.plan(action, tasks: properties(of: tasks), at: now)
				switch try await replicaClient.apply(plan, directory) {
				case let .committed(committed):
					await send(.writeCommitted(committed))
					return

				case let .conflict(fresh):
					// The stream won't yield these, having been read already.
					await send(.tasksLoaded(fresh))
					tasks = fresh
				}
			}
			await send(.writeFailed)
		} catch: { _, send in
			await send(.writeFailed)
		}
	}

	/// Ends the write in progress, whatever became of it.
	private func finishWrite(_ state: inout State) {
		state.creatingTask = nil
		state.isSaving = false
		state.isWriting = false
	}

	/// The selected tasks' IDs, in the table's order.
	private func selectedIDs(_ state: State) -> [Models.Task.ID] {
		state.selectedTasks.map(\.id)
	}

	/// Whether the sidebar shows a task New Task would create now, with only the Context's and the
	/// Taskrc's defaults, never the sidebar's project or tag. A New Task that can't be planned shows
	/// nowhere, so it changes nothing.
	private func sidebarShowsNewTask(_ state: State) -> Bool {
		let taskrc = state.runningTaskrc
		let id = UUID()
		guard
			let plan = try? WritePlanner(taskrc: taskrc, timeZone: timeZone)
				.plan(.create(id, description: "New Task"), tasks: [:], at: now)
		else {
			return true
		}
		// The plan writes `status` with its own operation.
		var properties = ["status": Status.pending.rawValue]
		for case let .setValue(_, property, value?) in plan.operations {
			properties[property] = value
		}
		let stored = StoredTask(properties: properties, uuid: id.uuidString, workingSetID: nil)
		guard
			let task = Models.Task(stored, udaTypes: taskrc.udaTypes),
			let view = TaskView(task, at: now)
		else {
			return true
		}
		let row = TaskRow(isBlocked: false, task: task, udaColumns: [], urgency: 0, view: view)
		return SidebarFilter(state.sidebarSelection).includes(row)
	}

	/// Ranks the Replica's tasks with the Taskrc the window runs on, decoding their UDAs, computing
	/// their Urgency and sorting them into fixed views again, then sorts and narrows them.
	private func updateRows(_ state: inout State) {
		let taskrc = state.runningTaskrc
		let tasks = state.storedTasks.compactMap { Models.Task($0, udaTypes: taskrc.udaTypes) }
		let blocked = DependencyScan(tasks).blocked
		let urgencies = UrgencyCoefficients(taskrc).urgencies(of: tasks, at: now, in: timeZone)
		state.udaColumns = UDAColumn.all(in: taskrc)
		state.allRows = tasks.compactMap { [now, udaColumns = state.udaColumns] task in
			TaskView(task, at: now).map { view in
				TaskRow(
					isBlocked: blocked.contains(task.id),
					task: task,
					udaColumns: udaColumns,
					urgency: urgencies[task.id] ?? 0,
					view: view,
				)
			}
		}
		sortRows(&state)
	}

	/// Narrows the ranked rows by the sidebar, then the search, and drops selected tasks that left
	/// the table.
	private func filterRows(_ state: inout State) {
		// Filtering keeps `allRows`' order, so the table needs no sort of its own.
		state.rows = IdentifiedArray(
			uniqueElements: state.allRows.filter { [
				filter = SidebarFilter(state.sidebarSelection),
				search = state.searchText,
			] in
				filter.includes($0) && $0.matches(search: search)
			},
		)
		state.highestUrgency = state.rows.map(\.urgency).max() ?? 0
		state.selection.formIntersection(state.rows.ids)
	}

	/// Sorts the ranked rows by `sortOrder`, then narrows them to the table. Ties break by ID, then
	/// by UUID for the completed and deleted tasks that have no ID, so the order holds still whatever
	/// order the Replica reads them in.
	private func sortRows(_ state: inout State) {
		let comparators = state.sortOrder + [TaskSort(.id)]
		state.allRows.sort { lhs, rhs in
			for comparator in comparators {
				let order = comparator.compare(lhs, rhs)
				if order != .orderedSame {
					return order == .orderedAscending
				}
			}
			return lhs.id < rhs.id
		}
		filterRows(&state)
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

/// How many times a write is planned before a plan the engine keeps refusing as stale fails it.
private let planAttempts = 3

/// How long a write runs before the subtitle says it's saving.
private let savingDelay = Duration.milliseconds(500)

/// How often an open window computes its tasks' Urgency again.
private let urgencyInterval = Duration.seconds(60)

/// Every task's properties, as the planner reads them.
private func properties(of tasks: [StoredTask]) -> [Models.Task.ID: [String: String]] {
	Dictionary(
		tasks.compactMap { task in UUID(uuidString: task.uuid).map { ($0, task.properties) } },
		uniquingKeysWith: { first, _ in first },
	)
}
