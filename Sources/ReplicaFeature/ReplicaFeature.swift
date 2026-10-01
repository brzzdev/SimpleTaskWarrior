// One Replica as its window shows it: the tasks, the Taskrc it runs on and their order.
import AppKit
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
		/// Locates the Replica, and is re-saved, which the window's restorable state keeps, where it's
		/// stale or the window is pointed at another folder.
		var bookmark: Data
		/// The Done or Delete asking whether to repair the dependency chains it breaks.
		var chainRepairPrompt: ChainRepairPrompt?
		/// The task a New Task is creating, which is selected once it commits.
		var creatingTask: Models.Task.ID?
		/// The Replica's folder, or where it last was while the window can't open it.
		var directory: URL?
		/// Set as New Task selects the task it created, for the inspector to put the cursor in its
		/// description, until the selection changes.
		var focusesDescription = false
		/// Set once the hint that offers Choose Taskrc… has been shown, in any window.
		@Shared(.appStorage("hasShownTaskrcHint")) var hasShownTaskrcHint = false
		/// The task the inspector shows: the one selected task, kept by UUID until the selection changes,
		/// even once it leaves the table.
		var inspectedTask: Models.Task.ID?
		var isNewTaskRowPresented = false
		/// Set once reads of the Replica have failed for `readFailureDelay`, until one succeeds.
		var isReadFailureBannerPresented = false
		/// Set once the Replica's tasks first arrive, by which point `apply` can reach it.
		var isReplicaOpen = false
		var isTaskrcHintPresented = false
		var isTaskrcPanelPresented = false
		/// The tasks an inspector edit, of one task or several, may move out of the table, which the
		/// table keeps
		/// until the selection changes.
		var keptTasks: Set<Models.Task.ID> = []
		/// The tasks a Done or Delete in progress is writing, which the table drops as the write
		/// starts rather than once it commits, since that can wait seconds on the Replica's lock.
		var leavingTasks: Set<Models.Task.ID> = []
		/// Writes asked for while another was in progress or a write asked a question, written in order
		/// once that ends. Only edits get here: every other write is disabled then.
		var queuedWrites: [WriteAction] = []
		/// Why reading the Replica fails, while it does. The window keeps the last tasks it read.
		var readFailure: String?
		/// The read `storedTasks` came from. A snapshot read before it is dropped, since a write's read
		/// and the stream's are delivered separately and can arrive out of order.
		var readIndex = 0
		/// The Undo point Redo would re-apply, as of the last read.
		var redoName: String?
		/// The tasks the sidebar and search leave, in `sortOrder`.
		var rows: IdentifiedArrayOf<TaskRow> = []
		/// Narrows the table after the sidebar.
		var searchText = ""
		/// Kept by UUID, so it survives the CLI renumbering tasks.
		var selection: Set<Models.Task.ID> = []
		/// The Delete or edit asking whether to take the Series of each Recurrence instance it writes.
		var seriesPrompt: SeriesPrompt?
		var sidebarSelection: Set<SidebarItem> = []
		/// The table's sort, which the table autosaves per Replica and reports once it restores.
		var sortOrder = [TaskSort(.urgency, order: .reverse)]
		/// Every task in the Replica as last read, which the blocked rule and Urgency read.
		var storedTasks: [StoredTask] = []
		var taskrc: TaskrcClient.Loaded?
		/// Why the last Taskrc the user chose couldn't be kept.
		var taskrcSaveFailure: TaskrcSaveFailure?
		/// The running Taskrc's UDAs, which the table offers as columns.
		var udaColumns = UDAColumn.all(in: .defaults)
		/// Why the window shows no Replica, in place of its tasks.
		var unavailable: Unavailable?
		/// The window's Undo point Undo would revert, as of the last read. Nil where the Replica's
		/// newest isn't the window's own.
		var undoName: String?
		/// The write in progress, which disables every other.
		var writeProgress: WriteProgress?

		/// The active Context's name, where there is one.
		var activeContext: String? {
			runningTaskrc["context"].flatMap { $0.isEmpty ? nil : $0 }
		}

		/// Whether New Task applies: once `apply` can reach the Replica and the Taskrc, whose defaults
		/// and Context a new task takes, has loaded, and while nothing holds writes back.
		var canCreateTask: Bool {
			isReplicaOpen && unavailable == nil && taskrc != nil && canWrite
		}

		/// Whether Locate Replica… (the window's Locate… button) applies: while the window shows no
		/// Replica, unless another window has it. The menu item and the button both read this.
		var canLocateReplica: Bool {
			switch unavailable {
			case .cantOpen, .notFound, .replaced: true
			case .none, .openElsewhere: false
			}
		}

		/// Whether Open Replacement applies: once a different Replica is where the window's was. The
		/// menu item and the window's button both read this.
		var canOpenReplacement: Bool {
			unavailable == .replaced
		}

		/// Whether Redo applies: while nothing has written since the undo, and nothing holds writes back.
		var canRedo: Bool {
			redoName != nil && canWrite
		}

		/// Whether Add Dependency…, Remove Dependency and Remove Annotation apply: to the one task
		/// the inspector shows, even once a search hides it from the table and so from the
		/// selection. Not while the new-task row is open, whose editing moving the cursor would end.
		var canEditInspectedTask: Bool {
			isReplicaOpen && inspectedRow != nil && !isNewTaskRowPresented
		}

		/// Whether Set Project…, Add Tag… and Remove Tag apply: to any selection, but not while the
		/// new-task row is open, whose editing moving the cursor would end. Their edits queue behind a
		/// write in progress, as the inspector's do.
		var canEditSelection: Bool {
			isReplicaOpen && !selection.isEmpty && !isNewTaskRowPresented
		}

		/// Whether Undo applies: while the window's newest Undo point is the Replica's newest, and
		/// nothing holds writes back.
		var canUndo: Bool {
			undoName != nil && canWrite
		}

		/// The folder the window claims as its Replica's, which no other window opens: none once another
		/// window has the Replica.
		var claimedDirectory: URL? {
			unavailable == .openElsewhere ? nil : directory
		}

		/// The commands that apply to every selected task. None applies while a write would queue, or
		/// while the new-task row is open, whose Return would find the write in the way. Read once for
		/// all of them, since the selection is looked up for each read.
		var enabledCommands: Set<TaskCommand> {
			guard canWrite, !isNewTaskRowPresented else {
				return []
			}
			let tasks = selectedTasks()
			guard !tasks.isEmpty else {
				return []
			}
			var commands: Set<TaskCommand> = []
			if tasks.allSatisfy({ $0.status != .deleted }) {
				commands.insert(.delete)
			}
			let isPending = tasks.allSatisfy { $0.status == .pending }
			if isPending {
				commands.insert(.done)
			}
			if tasks.allSatisfy({ $0.status == .completed || $0.status == .deleted }) {
				commands.insert(.markPending)
			}
			if isPending || isStopping(tasks) {
				commands.insert(.startStop)
			}
			return commands
		}

		/// Whether the window has a Taskrc, rather than running on TW's defaults.
		var hasTaskrc: Bool {
			taskrc?.url != nil
		}

		/// Whether the Taskrc's problem is a file it names that's missing or can't be read, the Taskrc
		/// itself or an include. Choosing another Taskrc is the one remedy the app offers.
		var hasUnreachableFile: Bool {
			taskrc?.problem?.kind.isUnreachableFile ?? false
		}

		/// The row the inspector shows, whether or not the table does.
		var inspectedRow: TaskRow? {
			inspectedTask.flatMap { id in allRows.first { $0.id == id } }
		}

		/// Whether Start/Stop stops, which it does when every selected task is active.
		var isStopping: Bool {
			isStopping(selectedTasks())
		}

		/// Whether the window's Taskrc is paired with its Replica, which Use Taskwarrior Defaults
		/// detaches.
		var isTaskrcPaired: Bool {
			taskrc?.isPaired ?? false
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

		/// The selected tasks' IDs, in the table's order.
		var selectedIDs: [Models.Task.ID] {
			rows.ids.filter(selection.contains)
		}

		/// The projects the selected tasks have, nil for one without.
		var selectedProjects: Set<String?> {
			Set(selectedTasks().map(\.project))
		}

		/// Every tag any selected task has, sorted, as Remove Tag lists them.
		var selectedTags: [String] {
			Set(selectedTasks().flatMap(\.tags)).sorted()
		}

		var sidebar: Sidebar {
			Sidebar(rows: allRows, selection: sidebarSelection)
		}

		/// Whether a write can start now, rather than queue: not while one is in progress, nor while a
		/// write asks a question, whose answer writes against the tasks it asked about.
		var canWrite: Bool {
			isReplicaOpen && writeProgress == nil && chainRepairPrompt == nil && seriesPrompt == nil
		}

		/// A window on the Replica `bookmark` locates, which was last in `directory`, where known.
		init(bookmark: Data, directory: URL? = nil) {
			self.bookmark = bookmark
			self.directory = directory
		}

		/// The task `offset` rows from the inspected one, where the table shows both.
		func adjacentTask(_ offset: Int) -> Models.Task.ID? {
			guard let inspectedTask, let index = rows.index(id: inspectedTask) else {
				return nil
			}
			let adjacent = index + offset
			return rows.indices.contains(adjacent) ? rows[adjacent].id : nil
		}

		/// The tasks `task` depends on, in UUID order, as the inspector and Remove Dependency list
		/// them.
		func dependencies(of task: Models.Task) -> [InspectedDependency] {
			task.dependencies.sorted { $0.uuidString < $1.uuidString }.map { dependency in
				InspectedDependency(
					title: allRows.first { $0.id == dependency }?.inspectorTitle,
					uuid: dependency,
				)
			}
		}

		/// Whether the toolbar and a row's context menu list `command`. Mark Pending takes the place of
		/// the others where every selected fixed view is Completed or Deleted.
		func isOffered(_ command: TaskCommand) -> Bool {
			let offersMarkPending = SidebarFilter(sidebarSelection)
				.views
				.isSubset(of: [.completed, .deleted])
			return (command == .markPending) == offersMarkPending
		}

		private func isStopping(_ tasks: [Models.Task]) -> Bool {
			!tasks.isEmpty && tasks.allSatisfy { $0.start != nil }
		}

		/// The selected tasks, in no particular order.
		private func selectedTasks() -> [Models.Task] {
			selection.compactMap { rows[id: $0]?.task }
		}
	}

	/// A command on the selected tasks, from the toolbar, the menu bar or a row's context menu.
	enum TaskCommand {
		case delete
		case done
		case markPending
		case startStop
	}

	/// A Done or Delete that would break dependency chains, as `dependency.confirmation` asks about.
	struct ChainRepairPrompt: Equatable {
		/// Done or Delete.
		var command: TaskCommand
		var ids: [Models.Task.ID]
		/// What repairing would do, as planned when the command was chosen: a line for each dependent.
		var message: String
		/// The templates whose Series a Delete takes with it.
		var series: Set<Models.Task.ID>
		var title: String

		init(
			command: TaskCommand,
			ids: [Models.Task.ID],
			message: String,
			series: Set<Models.Task.ID> = [],
			title: String,
		) {
			self.command = command
			self.ids = ids
			self.message = message
			self.series = series
			self.title = title
		}

		/// Asks about `chains`, naming each task by its description in `tasks`.
		init(
			chains: [WritePlan.RepairedChain],
			command: TaskCommand,
			ids: [Models.Task.ID],
			series: Set<Models.Task.ID>,
			tasks: [Models.Task.ID: [String: String]],
		) {
			self.init(
				command: command,
				ids: ids,
				message: Self.message(for: chains, tasks: tasks),
				series: series,
				title: chains.count == 1
					? String(localized: "Repair the Dependency Chain?")
					: String(localized: "Repair \(chains.count) Dependency Chains?"),
			)
		}

		/// A line for each dependent `chains` move, naming each task by its description in `tasks`.
		static func message(
			for chains: [WritePlan.RepairedChain],
			tasks: [Models.Task.ID: [String: String]],
		) -> String {
			let quoted = { (id: Models.Task.ID) in "“\(tasks[id]?["description"] ?? "")”" }
			let lines = chains.flatMap { chain in
				let blocking = ListFormatter.localizedString(byJoining: chain.blocking.map(quoted))
				return chain.blocked.map { blocked in
					String(
						localized: "\(quoted(blocked)) would depend on \(blocking) instead of \(quoted(chain.task)).",
					)
				}
			}
			return lines.joined(separator: "\n")
		}
	}

	/// A Delete or edit of Recurrence instances, asking for each Series whether to take it whole, as
	/// `recurrence.confirmation=prompt` asks. A Delete asks about the chains the answer breaks too,
	/// so the whole Delete is one Undo point.
	struct SeriesPrompt: Equatable {
		/// One Series the write touches, by its template.
		struct Choice: Equatable, Identifiable {
			var description: String
			var id: Models.Task.ID
			/// Whether the write takes every pending task in the Series and the template.
			var includesSeries = false
		}

		enum Command: Equatable {
			case delete
			case edit(TaskEdit)
		}

		/// What repairing would do under a Delete's choices: a line for each dependent, nil where
		/// nothing needs asking.
		var chainRepairMessage: String?
		var choices: IdentifiedArrayOf<Choice>
		var command: Command
		var ids: [Models.Task.ID]
		var repairsChains = true

		/// The templates whose Series the write takes with it.
		var series: Set<Models.Task.ID> {
			Set(choices.filter(\.includesSeries).map(\.id))
		}
	}

	/// Why the window shows no Replica, which Locate… points it at another folder for.
	enum Unavailable: Equatable {
		/// The Replica couldn't be opened, for the reason given.
		case cantOpen(String)
		/// The bookmark no longer resolves, or nothing's where it does.
		case notFound
		/// Another window has the Replica open, as when it moved to a folder one had just opened.
		case openElsewhere
		/// A Replica other than the one the window had open is where its bookmark resolves, now its
		/// `directory`, which Open Replacement opens.
		case replaced
	}

	struct TaskrcSaveFailure: Equatable {
		var message: String
		/// Whether Try Again… can open the panel that chose the file: not after a detach, which chose
		/// none.
		var canRetry: Bool
	}

	/// A write, undo or redo that failed. It changed nothing, unless it was an undo the engine
	/// couldn't confirm.
	struct WriteFailure: Equatable {
		/// What Try Again does.
		enum Retry: Equatable {
			/// Undoes the window's newest Undo point, which is checked afresh.
			case undo
			/// Plans the action again against the tasks as last read, at the time it was first planned,
			/// so a relative date such as `tomorrow` resolves as it did, and a change that landed before
			/// its read failed isn't made twice.
			case write(WriteAction, at: Date)
		}

		var reason: String
		/// What Try Again does, nil where trying again can't help, so the alert offers only OK.
		var retry: Retry?
		/// As in "Couldn't Complete 3 Tasks".
		var title: String
	}

	enum WriteProgress: Equatable {
		/// Failed, and in progress still until its alert is dismissed.
		case failed(WriteFailure)
		case running
		/// Running long enough for the subtitle to say so.
		case saving
	}

	enum Action: BindableAction {
		case annotationDeleteButtonTapped(Models.Task.ID, entry: Date)
		/// Return in the inspector's new-annotation field, or clicking away from it.
		case annotationSubmitted(Models.Task.ID, String)
		case binding(BindingAction<State>)
		/// The window's bookmark was stale, and one made afresh replaces it.
		case bookmarkRefreshed(Data)
		/// Cancel in the sheet asking whether to repair dependency chains.
		case chainRepairDismissed
		case chooseTaskrcButtonTapped
		case deleteButtonTapped
		case dependencyChosen(Models.Task.ID, dependency: Models.Task.ID)
		case dependencyRemoveButtonTapped(Models.Task.ID, dependency: Models.Task.ID)
		case directoryResolved(URL)
		case doneButtonTapped
		case dontRepairChainButtonTapped
		case fetchRequested
		/// Return, Tab or clicking away from an inspector field, or choosing from its menu, for the tasks
		/// it showed as you began typing.
		case inspectorFieldSubmitted([Models.Task.ID], TaskEdit)
		case markPendingButtonTapped
		case newTaskButtonTapped
		/// Return in the new-task row, or clicking away from it.
		case newTaskDescriptionSubmitted(String)
		/// Escape in the new-task row.
		case newTaskEditingCancelled
		case nextTaskButtonTapped
		case openFailed(String)
		case openReplacementButtonTapped
		case pairingChanged
		case previousTaskButtonTapped
		case readFailed(String)
		case readFailureDelayElapsed
		case readSucceeded(TaskSnapshot)
		case redoButtonTapped
		/// A folder chosen in the panel Locate… opened, which is a Replica no other window shows.
		case replicaFolderChosen(URL)
		/// The Replica's database is no longer the one opened as `identity`.
		case replicaLost(ReplicaIdentity)
		/// Where the window's bookmark resolves, there's no Replica.
		case replicaNotFound
		/// Another window has the Replica open.
		case replicaOpenElsewhere
		/// Another Replica is where the lost one's bookmark resolves, in the folder given.
		case replicaReplaced(URL)
		case repairChainButtonTapped
		case repairChainsCheckboxChanged(repairsChains: Bool)
		case savingDelayElapsed
		case seriesChangeButtonTapped
		/// A Series' pop-up in the sheet asking whether a write takes each Series.
		case seriesChoiceChanged(Models.Task.ID, includesSeries: Bool)
		case seriesDeleteButtonTapped
		/// Cancel in the sheet asking whether a write takes each Series.
		case seriesPromptDismissed
		/// A column header was clicked, or the table restored the Replica's sort.
		case sortOrderChanged([TaskSort])
		case startStopButtonTapped
		/// A tag's remove button in the inspector, or the tag chosen from Remove Tag.
		case tagRemoveButtonTapped([Models.Task.ID], tag: String)
		/// A Taskrc chosen in the panel Choose Taskrc… or Try Again… opened.
		case taskrcChosen(URL)
		case taskrcHintCloseButtonTapped
		case taskrcLoaded(TaskrcClient.Loaded)
		case taskrcSaveFailed(TaskrcSaveFailure)
		/// A write, undo or redo read the tasks.
		case tasksLoaded(TaskSnapshot)
		case timerTicked
		case tryAgainButtonTapped
		case undoButtonTapped
		case undoOrRedoFinished(UndoOutcome)
		case useTaskwarriorDefaultsButtonTapped
		case writeCommitted
		case writeFailed(WriteFailure)
		/// Cancel, or OK where the alert offers only that.
		case writeFailureDismissed
		case writeFailureTryAgainButtonTapped
	}

	private enum CancelID {
		case bookmarkChanges
		case readFailure
		/// Opening, reading and finding the Replica, one at a time.
		case replica
		case taskrc
		case write
	}

	private enum UndoDirection {
		case redo
		case undo
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
			case let .annotationDeleteButtonTapped(id, entry):
				return edit([id], .removeAnnotation(entry: entry), &state)

			case let .annotationSubmitted(id, text):
				// Should it queue, `finishWrite` gives it its entry again as it starts.
				return edit([id], .addAnnotation(text, entry: annotationEntry(for: id, state)), &state)

			case .binding(\.searchText), .binding(\.sidebarSelection):
				state.keptTasks = []
				filterRows(&state)
				return .none

			case .binding(\.selection):
				inspectSelection(&state)
				return .none

			case .binding:
				return .none

			case let .bookmarkRefreshed(bookmark):
				state.bookmark = bookmark
				return .none

			case .chainRepairDismissed:
				state.chainRepairPrompt = nil
				// Starts any edit that queued behind the question.
				return finishWrite(&state)

			case .chooseTaskrcButtonTapped:
				state.isTaskrcPanelPresented = true
				return .none

			case .deleteButtonTapped:
				return perform(.delete, &state)

			case let .dependencyChosen(id, dependency):
				return edit([id], .addDependency(dependency), &state)

			case let .dependencyRemoveButtonTapped(id, dependency):
				return edit([id], .removeDependency(dependency), &state)

			case let .directoryResolved(directory):
				state.directory = directory
				// Another window pairing or detaching changes this window's Taskrc too. Subscribed
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
				return perform(.done, &state)

			case .dontRepairChainButtonTapped:
				return closePromptedTasks(chains: .leave, &state)

			case .fetchRequested:
				return .merge(
					openReplica(state),
					// Urgency moves with the clock too, as due dates near and `scheduled` and `wait` pass,
					// while the Replica may not change for hours.
					.run { [clock] send in
						for await _ in clock.timer(interval: urgencyInterval) {
							await send(.timerTicked)
						}
					},
				)

			case let .inspectorFieldSubmitted(ids, taskEdit):
				return edit(ids, taskEdit, &state)

			case .markPendingButtonTapped:
				return perform(.markPending, &state)

			case .newTaskButtonTapped:
				guard state.canCreateTask else {
					return .none
				}
				state.isNewTaskRowPresented = true
				showNewTaskSidebar(&state)
				return .none

			case let .newTaskDescriptionSubmitted(description):
				state.isNewTaskRowPresented = false
				// Spaces alone are what the planner refuses as blank, so they cancel instead.
				guard !description.allSatisfy({ $0 == " " }) else {
					return .none
				}
				// Again, since the Taskrc or its Context may have changed while the row was open.
				showNewTaskSidebar(&state)
				let id = uuid()
				state.creatingTask = id
				return write(.create(id, description: description), &state)

			case .newTaskEditingCancelled:
				state.isNewTaskRowPresented = false
				return .none

			case .nextTaskButtonTapped:
				selectAdjacentTask(1, &state)
				return .none

			case let .openFailed(reason):
				showUnavailable(.cantOpen(reason), &state)
				return .none

			case .openReplacementButtonTapped:
				guard state.canOpenReplacement, let directory = state.directory else {
					return .none
				}
				// The folder is the same, but the Replica in it isn't the one the bookmark was made for.
				return rebind(to: directory, &state)

			case .pairingChanged:
				return loadTaskrc(for: state)

			case .previousTaskButtonTapped:
				selectAdjacentTask(-1, &state)
				return .none

			case let .readFailed(reason):
				let isFirst = state.readFailure == nil
				state.readFailure = reason
				guard isFirst else {
					return .none
				}
				return .run { send in
					try await clock.sleep(for: readFailureDelay)
					await send(.readFailureDelayElapsed)
				}
				.cancellable(id: CancelID.readFailure, cancelInFlight: true)

			case .readFailureDelayElapsed:
				// The wait can end just as a read succeeds, queued behind it.
				state.isReadFailureBannerPresented = state.readFailure != nil
				return .none

			case let .readSucceeded(snapshot):
				// Only the stream's reads clear a failure: they run in turn, so this one came after it,
				// where a write's read can have come before.
				state.isReadFailureBannerPresented = false
				state.readFailure = nil
				loadTasks(snapshot, &state)
				return .cancel(id: CancelID.readFailure)

			case .redoButtonTapped:
				guard state.canRedo, let name = state.redoName else {
					return .none
				}
				return undoOrRedo(.redo, failureTitle: String(localized: "Couldn't Redo \(name)"), &state)

			case .repairChainButtonTapped:
				return closePromptedTasks(chains: .repair, &state)

			case let .replicaFolderChosen(directory):
				return rebind(to: directory, &state)

			case let .replicaLost(identity):
				// A write and the stream can each find it lost, and finding it again is harmless.
				state.chainRepairPrompt = nil
				state.isReadFailureBannerPresented = false
				state.isReplicaOpen = false
				state.queuedWrites = []
				// Whatever reads failed, they were of the Replica lost.
				state.readFailure = nil
				// A Replica opened again counts its reads from 0.
				state.readIndex = 0
				state.redoName = nil
				state.seriesPrompt = nil
				state.undoName = nil
				return .merge(
					// With nothing queued, this starts nothing.
					finishWrite(&state),
					.cancel(id: CancelID.readFailure),
					.cancel(id: CancelID.write),
					// Replaces the stream, closing the Replica.
					openReplica(state, lost: identity),
				)

			case .replicaNotFound:
				showUnavailable(.notFound, &state)
				return .none

			case .replicaOpenElsewhere:
				showUnavailable(.openElsewhere, &state)
				return .none

			case let .replicaReplaced(directory):
				state.directory = directory
				showUnavailable(.replaced, &state)
				return .none

			case let .repairChainsCheckboxChanged(repairsChains):
				state.seriesPrompt?.repairsChains = repairsChains
				return .none

			case .savingDelayElapsed:
				// The delay can elapse just as the write ends, or fails.
				if state.writeProgress == .running {
					state.writeProgress = .saving
				}
				return .none

			case .seriesChangeButtonTapped, .seriesDeleteButtonTapped:
				return writePromptedSeries(&state)

			case let .seriesChoiceChanged(template, includesSeries):
				guard var prompt = state.seriesPrompt else {
					return .none
				}
				prompt.choices[id: template]?.includesSeries = includesSeries
				if prompt.command == .delete {
					prompt.chainRepairMessage = chainRepairMessage(
						prompt.ids,
						series: prompt.series,
						tasks: properties(of: state.storedTasks),
						state,
					)
				}
				state.seriesPrompt = prompt
				return .none

			case .seriesPromptDismissed:
				state.seriesPrompt = nil
				// Starts any edit that queued behind the question.
				return finishWrite(&state)

			case let .sortOrderChanged(sortOrder):
				state.sortOrder = sortOrder
				sortRows(&state)
				return .none

			case .startStopButtonTapped:
				return perform(.startStop, &state)

			case let .tagRemoveButtonTapped(ids, tag):
				// Every task asked for, even one without the tag now: a write queued ahead may add it.
				return edit(ids, .removeTag(tag), &state)

			case let .taskrcChosen(file):
				state.isTaskrcPanelPresented = false
				state.isTaskrcHintPresented = false
				state.taskrcSaveFailure = nil
				return reloadTaskrc(
					for: state,
					canRetry: true,
				) { [bookmarkClient] directory in
					try bookmarkClient.saveTaskrc(file, directory)
				}

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

			case let .tasksLoaded(snapshot):
				loadTasks(snapshot, &state)
				return .none

			case .timerTicked:
				updateRows(&state)
				return .none

			case .tryAgainButtonTapped:
				state.isTaskrcPanelPresented = state.taskrcSaveFailure?.canRetry ?? false
				return .none

			case .undoButtonTapped:
				guard state.canUndo, let name = state.undoName else {
					return .none
				}
				return undoOrRedo(.undo, failureTitle: String(localized: "Couldn't Undo \(name)"), &state)

			case let .undoOrRedoFinished(outcome):
				// The tasks it changed that the view shows, tracked by UUID, since an undo can give a
				// pending task a new ID.
				let changed = state.rows.ids.filter(outcome.tasks.contains)
				if !changed.isEmpty {
					state.selection = Set(changed)
					inspectSelection(&state)
				}
				let finish = finishWrite(&state)
				guard !outcome.isApplied else {
					return finish
				}
				return .merge(.run { _ in NSSound.beep() }, finish)

			case .useTaskwarriorDefaultsButtonTapped:
				state.isTaskrcHintPresented = false
				state.taskrcSaveFailure = nil
				// Detaching makes no bookmark, so it has nothing to retry.
				return reloadTaskrc(
					for: state,
					canRetry: false,
				) { [bookmarkClient] directory in
					try bookmarkClient.saveTaskrc(nil, directory)
				}

			case .writeCommitted:
				// A closed task can't stay kept, or the table brings it back. An edit queued behind the
				// chain repair prompt keeps the tasks it edits; a close that fails leaves them open, so kept.
				state.keptTasks.subtract(state.leavingTasks)
				selectCreatedTask(&state)
				return finishWrite(&state)

			case let .writeFailed(failure):
				state.writeProgress = .failed(failure)
				return .none

			case .writeFailureDismissed:
				return finishWrite(&state)

			case .writeFailureTryAgainButtonTapped:
				guard case let .failed(failure) = state.writeProgress, let retry = failure.retry else {
					return .none
				}
				switch retry {
				case .undo:
					return undoOrRedo(.undo, failureTitle: failure.title, &state)

				case let .write(action, date):
					return startWrite(action, at: date, &state)
				}
			}
		}
	}

	init() {}

	/// Loads the Taskrc paired with the window's Replica, or else the CLI's default, and keeps it
	/// current, replacing any load already running. Until the Taskrc parses, the window keeps the
	/// Taskrc it runs on now.
	private func loadTaskrc(for state: State) -> Effect<Action> {
		guard let directory = state.directory else {
			return .none
		}
		return .run { [bookmarkClient, lastGood = state.runningTaskrc, taskrcClient] send in
			let taskrcs = taskrcClient.load({ bookmarkClient.taskrc(directory) }, lastGood)
			for await taskrc in taskrcs {
				await send(.taskrcLoaded(taskrc))
			}
		}
		.cancellable(id: CancelID.taskrc, cancelInFlight: true)
	}

	/// Resolves the window's bookmark, re-saving it where it's stale, then opens the Replica it
	/// resolves to and reads it until the window closes or loses it. After the window lost the
	/// Replica opened as `lost`, it opens only that one, moved, and otherwise says what's there.
	private func openReplica(_ state: State, lost: ReplicaIdentity? = nil) -> Effect<Action> {
		.run { [bookmark = state.bookmark, bookmarkClient, replicaClient] send in
			guard let (directory, refreshed) = try? bookmarkClient.resolve(bookmark) else {
				await send(.replicaNotFound)
				return
			}
			if let lost {
				guard let found = replicaClient.identity(directory) else {
					await send(.replicaNotFound)
					return
				}
				guard found == lost else {
					await send(.replicaReplaced(directory))
					return
				}
			}
			if let refreshed {
				await send(.bookmarkRefreshed(refreshed))
			}
			await send(.directoryResolved(directory))
			// The Replica lost only, should another replace it before it opens.
			for try await read in replicaClient.tasks(directory, lost) {
				switch read {
				case let .failure(error):
					await send(.readFailed(error.localizedDescription))

				case let .success(snapshot):
					await send(.readSucceeded(snapshot))
				}
			}
		} catch: { error, send in
			switch error as? ReplicaError {
			case let .lost(identity):
				await send(.replicaLost(identity))

			case .openElsewhere:
				await send(.replicaOpenElsewhere)

			default:
				await send(.openFailed(error.localizedDescription))
			}
		}
		.cancellable(id: CancelID.replica, cancelInFlight: true)
	}

	/// Points the window at the Replica in `directory`, moving its Taskrc pairing along, then opens
	/// it. Done at once, so the window claims the folder only once its bookmark exists, and before
	/// another window can open it.
	private func rebind(to directory: URL, _ state: inout State) -> Effect<Action> {
		let bookmark: Data
		do {
			bookmark = try bookmarkClient.create(directory)
		} catch {
			showUnavailable(.cantOpen(error.localizedDescription), &state)
			return .none
		}
		if let lastDirectory = state.directory {
			bookmarkClient.movePairing(lastDirectory, directory, bookmark)
		}
		state.bookmark = bookmark
		state.directory = directory
		state.unavailable = nil
		// Replaces anything still finding the Replica lost.
		return openReplica(state)
	}

	/// Shows why the window has no Replica in place of its tasks, which it drops.
	private func showUnavailable(_ unavailable: Unavailable, _ state: inout State) {
		state.unavailable = unavailable
		state.storedTasks = []
		updateRows(&state)
	}

	/// The one path every write takes. Every other write queues until it finishes.
	private func write(_ action: WriteAction, _ state: inout State) -> Effect<Action> {
		// Dropped while the window has no Replica to write to, such as once it's lost, rather than
		// queued for one opened later.
		guard state.isReplicaOpen else {
			return .none
		}
		guard state.canWrite else {
			state.queuedWrites.append(action)
			return .none
		}
		// An edit asks about Series as it starts, so it asks against what every write before it left,
		// and the answer writes it without coming back here.
		guard case let .edit(ids, edit, _) = action else {
			return startWrite(action, at: now, &state)
		}
		return editAskingAboutSeries(ids, edit, &state)
	}

	/// Plans `action` against the tasks as last read, and while the engine refuses the plan as
	/// stale, plans it again against the tasks it read instead, up to `planAttempts` times. A write
	/// that fails is reported, keeping `action`, and so its UUIDs, and `date` for Try Again.
	private func startWrite(
		_ action: WriteAction,
		at date: Date,
		_ state: inout State,
	) -> Effect<Action> {
		guard let directory = state.directory else {
			return .none
		}
		state.writeProgress = .running
		// A Remove Tag is named for the tasks that have the tag as it starts, after any write queued
		// ahead of it, while it still writes every task it was asked to. Where none has it, the name
		// counts them all rather than none.
		var named = action
		if case let .edit(ids, .removeTag(tag), series) = action {
			let tagged = Set(state.allRows.lazy.filter { $0.task.tags.contains(tag) }.map(\.id))
			let changed = ids.filter(tagged.contains)
			if !changed.isEmpty {
				named = .edit(changed, .removeTag(tag), series: series)
			}
		}
		let name = undoName(for: named, udaColumns: state.udaColumns)
		// "Couldn't New Task" wouldn't read, so a failure names what New Task does.
		let failureTitle =
			if case .create = action {
				String(localized: "Couldn't Create Task")
			} else {
				String(localized: "Couldn't \(name)")
			}
		let planner = WritePlanner(taskrc: state.runningTaskrc, timeZone: timeZone)
		return .run { [clock, replicaClient, storedTasks = state.storedTasks] send in
			// A child of the write, so it's cancelled as the write ends, however it ends.
			async let _: Void = {
				try await clock.sleep(for: savingDelay)
				await send(.savingDelayElapsed)
			}()
			var tasks = storedTasks
			for _ in 1 ... planAttempts {
				let plan = try planner.plan(action, tasks: properties(of: tasks), at: date)
				let outcome = try await replicaClient.apply(plan, name, directory)
				// The stream won't yield these, having been read already.
				await send(.tasksLoaded(outcome.snapshot))
				guard !outcome.isCommitted else {
					await send(.writeCommitted)
					return
				}
				tasks = outcome.snapshot.tasks
			}
			throw ReplicaError.failed(
				String(localized: "The Replica kept changing while it was written to."),
			)
		} catch: { error, send in
			if let identity = lostReplica(error) {
				await send(.replicaLost(identity))
				return
			}
			await send(.writeFailed(WriteFailure(
				error,
				retry: .write(action, at: date),
				title: failureTitle,
			)))
		}
		.cancellable(id: CancelID.write)
	}

	/// Undoes or redoes, holding every write back until it ends as a write would. A change that
	/// didn't apply cleanly beeps, and its read has checked Undo and Redo afresh. One that fails is
	/// reported as `failureTitle`.
	private func undoOrRedo(
		_ direction: UndoDirection,
		failureTitle: String,
		_ state: inout State,
	) -> Effect<Action> {
		guard let directory = state.directory else {
			return .none
		}
		state.writeProgress = .running
		return .run { [replicaClient] send in
			let outcome =
				switch direction {
				case .redo: try await replicaClient.redo(directory)
				case .undo: try await replicaClient.undo(directory)
				}
			// The stream won't yield these, having been read already.
			if let snapshot = outcome.snapshot {
				await send(.tasksLoaded(snapshot))
			}
			await send(.undoOrRedoFinished(outcome))
		} catch: { error, send in
			if let identity = lostReplica(error) {
				await send(.replicaLost(identity))
				return
			}
			// The engine lets go of a redo that fails, so there's nothing to try again. Nor for an undo
			// that may have landed, where trying again could revert the Undo point before it: the next
			// read shows what happened, and Undo stays available if it didn't land.
			let unconfirmed = error as? ReplicaError == .undoUnconfirmed
			let retry: WriteFailure.Retry? = direction == .undo && !unconfirmed ? .undo : nil
			let title = unconfirmed ? String(localized: "Couldn't Confirm Undo") : failureTitle
			await send(.writeFailed(WriteFailure(error, retry: retry, title: title)))
		}
		.cancellable(id: CancelID.write)
	}

	/// The entry an annotation added to the task `id` now asks for: the second after the latest of
	/// the task's annotations, where that's this second or later, else now. Read from the tasks as
	/// last read, so it's only sound as the write starts, with every earlier write read back.
	///
	/// A taken second would make the planner read a note with the same text there as a retry of it,
	/// and drop it. Only entries less than `annotationWindow` ahead count, so a clock set back
	/// doesn't carry every later note ahead with it.
	private func annotationEntry(for id: Models.Task.ID, _ state: State) -> Date {
		let second = Date(timeIntervalSince1970: now.timeIntervalSince1970.rounded(.down))
		let annotations = state.allRows.first { $0.id == id }?.task.annotations.map(\.entry) ?? []
		let taken = annotations.filter {
			$0 >= second && $0.timeIntervalSince(now) < annotationWindow
		}
		return taken.max().map { $0.addingTimeInterval(annotationSpacing) } ?? now
	}

	/// The templates of the Series `applied` changes from `tasks`, by the templates themselves or
	/// their
	/// instances, leaving out `mask`, which records an instance's status, and `modified`.
	private func changedSeries(
		_ applied: [Models.Task.ID: [String: String]],
		tasks: [Models.Task.ID: [String: String]],
	) -> Set<Models.Task.ID> {
		let fields = { (properties: [String: String]) in
			properties.filter { $0.key != "mask" && $0.key != "modified" }
		}
		var changed: Set<Models.Task.ID> = []
		for (id, properties) in applied where fields(properties) != fields(tasks[id] ?? [:]) {
			changed.insert(properties["parent"].flatMap(UUID.init(uuidString:)) ?? id)
		}
		return changed
	}

	/// What repairing would do to the chains a Delete of `ids` and `series` breaks, nil where
	/// `dependency.confirmation` doesn't ask or it breaks none.
	private func chainRepairMessage(
		_ ids: [Models.Task.ID],
		series: Set<Models.Task.ID>,
		tasks: [Models.Task.ID: [String: String]],
		_ state: State,
	) -> String? {
		guard state.runningTaskrc.boolean(dependencyConfirmation) else {
			return nil
		}
		let chains = repairedChains(.delete(ids, chains: .repair, series: series), tasks: tasks, state)
		return chains.isEmpty ? nil : ChainRepairPrompt.message(for: chains, tasks: tasks)
	}

	/// Completes or deletes the tasks `ids`, and a Delete the rest of each Series in `series`, as
	/// `command` says, which the table drops while it writes.
	private func close(
		_ ids: [Models.Task.ID],
		_ command: TaskCommand,
		chains: ChainRepair,
		series: Set<Models.Task.ID>,
		_ state: inout State,
	) -> Effect<Action> {
		let effect = write(closeAction(ids, command, chains: chains, series: series), &state)
		// Only once the write has started, since only its end brings them back.
		if state.writeProgress != nil {
			let tasks = series.isEmpty ? [:] : properties(of: state.storedTasks)
			state.leavingTasks = Set(WritePlanner.withSeries(ids, series: series, tasks: tasks))
			filterRows(&state)
		}
		return effect
	}

	/// The Done or Delete `command` over `ids`, a Delete taking the rest of each Series in `series`.
	private func closeAction(
		_ ids: [Models.Task.ID],
		_ command: TaskCommand,
		chains: ChainRepair,
		series: Set<Models.Task.ID>,
	) -> WriteAction {
		command == .delete
			? .delete(ids, chains: chains, series: series)
			: .complete(ids, chains: chains)
	}

	/// Closes `ids` as `command` says, first asking about the chains it breaks where
	/// `dependency.confirmation` says to.
	private func closeAskingAboutChains(
		_ ids: [Models.Task.ID],
		_ command: TaskCommand,
		series: Set<Models.Task.ID>,
		tasks: [Models.Task.ID: [String: String]],
		_ state: inout State,
	) -> Effect<Action> {
		guard state.runningTaskrc.boolean(dependencyConfirmation) else {
			return close(ids, command, chains: .repair, series: series, &state)
		}
		let action = closeAction(ids, command, chains: .repair, series: series)
		let chains = repairedChains(action, tasks: tasks, state)
		guard !chains.isEmpty else {
			return close(ids, command, chains: .leave, series: series, &state)
		}
		state.chainRepairPrompt = ChainRepairPrompt(
			chains: chains,
			command: command,
			ids: ids,
			series: series,
			tasks: tasks,
		)
		return .none
	}

	/// Writes the Done or Delete that asked about chains, with the user's answer.
	private func closePromptedTasks(chains: ChainRepair, _ state: inout State) -> Effect<Action> {
		guard let prompt = state.chainRepairPrompt else {
			return .none
		}
		state.chainRepairPrompt = nil
		return close(prompt.ids, prompt.command, chains: chains, series: prompt.series, &state)
	}

	/// Writes an inspector edit, of one task or several, to the tasks `ids`, keeping them in the table
	/// should the edit move them out.
	private func edit(
		_ ids: [Models.Task.ID],
		_ edit: TaskEdit,
		_ state: inout State,
	) -> Effect<Action> {
		state.keptTasks.formUnion(ids.filter { state.rows[id: $0] != nil })
		return write(.edit(ids, edit), &state)
	}

	/// Starts `edit` of the tasks `ids`, taking the Series of each Recurrence instance among them as
	/// `recurrence.confirmation` says, or first asking. A Series the edit would leave as it is asks
	/// nothing, since the inspector sends a value a task already shows, unless one can't be planned.
	private func editAskingAboutSeries(
		_ ids: [Models.Task.ID],
		_ edit: TaskEdit,
		_ state: inout State,
	) -> Effect<Action> {
		let planner = WritePlanner(taskrc: state.runningTaskrc, timeZone: timeZone)
		let tasks = properties(of: state.storedTasks)
		let every = seriesChoices(ids, tasks: tasks)
		// Planned only where it might ask.
		guard planner.cascadesToSeries(edit), !every.isEmpty else {
			return startWrite(.edit(ids, edit), at: now, &state)
		}
		let choices: IdentifiedArrayOf<SeriesPrompt.Choice>
		do {
			let plan = try planner.plan(.edit(ids, edit, series: Set(every.ids)), tasks: tasks, at: now)
			let changed = changedSeries(plan.applied(to: tasks), tasks: tasks)
			choices = every.filter { changed.contains($0.id) }
		} catch {
			// Where the tasks can take the edit but a Series can't, as when a sibling would depend on
			// itself, every Series is offered, and taking one reports why. Where the tasks can't, the
			// write reports why without asking.
			let plansAlone = (try? planner.plan(.edit(ids, edit), tasks: tasks, at: now)) != nil
			choices = plansAlone ? every : []
		}
		guard !choices.isEmpty else {
			return startWrite(.edit(ids, edit), at: now, &state)
		}
		guard state.runningTaskrc[recurrenceConfirmation] == askingConfirmation else {
			let series = seriesByTaskrc(choices, taskrc: state.runningTaskrc)
			return startWrite(.edit(ids, edit, series: series), at: now, &state)
		}
		state.seriesPrompt = SeriesPrompt(choices: choices, command: .edit(edit), ids: ids)
		return .none
	}

	/// Ends the write in progress, whatever became of it, and starts the next queued one.
	private func finishWrite(_ state: inout State) -> Effect<Action> {
		state.creatingTask = nil
		state.leavingTasks = []
		state.writeProgress = nil
		// A failed Done or Delete puts its tasks back.
		filterRows(&state)
		guard !state.queuedWrites.isEmpty else {
			return .none
		}
		var next = state.queuedWrites.removeFirst()
		// An annotation queued behind the write just ended takes its entry now, past every note that
		// write, or the CLI meanwhile, left in the second it asked for. The inspector adds one to a
		// single task.
		if case let .edit(ids, .addAnnotation(text, _), _) = next, let id = ids.first {
			next = .edit(ids, .addAnnotation(text, entry: annotationEntry(for: id, state)))
		}
		return write(next, &state)
	}

	/// Inspects the one selected task, and lets go of the tasks the table kept for an edit.
	private func inspectSelection(_ state: inout State) {
		state.focusesDescription = false
		state.inspectedTask = state.selection.count == 1 ? state.selection.first : nil
		guard !state.keptTasks.isEmpty else {
			return
		}
		state.keptTasks = []
		filterRows(&state)
	}

	/// Writes `command` over the selected tasks, where it applies to every one.
	private func perform(_ command: TaskCommand, _ state: inout State) -> Effect<Action> {
		guard state.enabledCommands.contains(command) else {
			return .none
		}
		let ids = state.selectedIDs
		switch command {
		case .delete, .done:
			// In ID order, as `task` closes them, since closing one can rewire the next.
			let rows = state.rows
			let ids = ids.sorted { lhs, rhs in
				let rank = { (id: Models.Task.ID) in rows[id: id]?.task.workingSetID ?? .max }
				return (rank(lhs), lhs) < (rank(rhs), rhs)
			}
			let tasks = properties(of: state.storedTasks)
			let choices = command == .delete ? seriesChoices(ids, tasks: tasks) : []
			guard !choices.isEmpty else {
				return closeAskingAboutChains(ids, command, series: [], tasks: tasks, &state)
			}
			// As `task delete` reads it: `prompt` asks, else it's a boolean.
			guard state.runningTaskrc[recurrenceConfirmation] == askingConfirmation else {
				let series = seriesByTaskrc(choices, taskrc: state.runningTaskrc)
				return closeAskingAboutChains(ids, command, series: series, tasks: tasks, &state)
			}
			state.seriesPrompt = SeriesPrompt(
				chainRepairMessage: chainRepairMessage(ids, series: [], tasks: tasks, state),
				choices: choices,
				command: .delete,
				ids: ids,
			)
			return .none

		case .markPending:
			return write(.markPending(ids), &state)

		case .startStop:
			return write(state.isStopping ? .stop(ids) : .start(ids), &state)
		}
	}

	/// The chains `action` repairs, planned against `tasks`. A plan that can't be made repairs none,
	/// so asks nothing, and its write reports why.
	private func repairedChains(
		_ action: WriteAction,
		tasks: [Models.Task.ID: [String: String]],
		_ state: State,
	) -> [WritePlan.RepairedChain] {
		let planner = WritePlanner(taskrc: state.runningTaskrc, timeZone: timeZone)
		return (try? planner.plan(action, tasks: tasks, at: now).repairedChains) ?? []
	}

	/// Selects the task `offset` rows from the inspected one, as ⌘⌥↑ and ⌘⌥↓ do.
	private func selectAdjacentTask(_ offset: Int, _ state: inout State) {
		guard let adjacent = state.adjacentTask(offset) else {
			return
		}
		state.selection = [adjacent]
		inspectSelection(&state)
	}

	/// Selects the task New Task created, clearing a search that hides it, and puts the cursor in its
	/// description. New Task already showed the sidebar it lands in.
	private func selectCreatedTask(_ state: inout State) {
		guard let created = state.creatingTask else {
			return
		}
		if state.rows[id: created] == nil, !state.searchText.isEmpty {
			state.searchText = ""
			filterRows(&state)
		}
		guard state.rows[id: created] != nil else {
			return
		}
		state.selection = [created]
		inspectSelection(&state)
		state.focusesDescription = true
	}

	/// The templates in `choices` whose Series a write takes where `recurrence.confirmation` doesn't
	/// ask, which `task` then reads as a boolean: every one or none.
	private func seriesByTaskrc(
		_ choices: IdentifiedArrayOf<SeriesPrompt.Choice>,
		taskrc: Taskrc,
	) -> Set<Models.Task.ID> {
		taskrc.boolean(recurrenceConfirmation) ? Set(choices.ids) : []
	}

	/// A choice for each Series the tasks `ids` are Recurrence instances of, in the order of the first
	/// of each, named by its template's description, or the instance's where the template is gone,
	/// since `task delete` still takes the siblings then.
	private func seriesChoices(
		_ ids: [Models.Task.ID],
		tasks: [Models.Task.ID: [String: String]],
	) -> IdentifiedArrayOf<SeriesPrompt.Choice> {
		var choices: IdentifiedArrayOf<SeriesPrompt.Choice> = []
		for id in ids {
			guard let template = tasks[id]?["parent"].flatMap(UUID.init(uuidString:)) else {
				continue
			}
			let description = (tasks[template] ?? tasks[id])?["description"] ?? ""
			choices.append(SeriesPrompt.Choice(description: description, id: template))
		}
		return choices
	}

	/// Resets the sidebar to Pending where it wouldn't show a task New Task would create now.
	private func showNewTaskSidebar(_ state: inout State) {
		guard !sidebarShowsNewTask(state) else {
			return
		}
		state.sidebarSelection = [.view(.pending)]
		filterRows(&state)
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
		guard
			let properties = plan.applied(to: [:])[id],
			let task = Models.Task(
				properties: properties,
				udaTypes: taskrc.udaTypes,
				uuid: id.uuidString,
				workingSetID: nil,
			),
			let view = TaskView(task, at: now)
		else {
			return true
		}
		let row = TaskRow(isBlocked: false, task: task, udaColumns: [], urgency: 0, view: view)
		return SidebarFilter(state.sidebarSelection).includes(row)
	}

	/// Writes the Delete or edit that asked about Series, with the user's choices.
	private func writePromptedSeries(_ state: inout State) -> Effect<Action> {
		guard let prompt = state.seriesPrompt else {
			return .none
		}
		state.seriesPrompt = nil
		switch prompt.command {
		case .delete:
			// Repaired unasked where the Taskrc says not to ask, and left where there was nothing to ask.
			let repairs = !state.runningTaskrc.boolean(dependencyConfirmation)
				|| prompt.chainRepairMessage != nil && prompt.repairsChains
			return close(
				prompt.ids,
				.delete,
				chains: repairs ? .repair : .leave,
				series: prompt.series,
				&state,
			)

		case let .edit(edit):
			return startWrite(.edit(prompt.ids, edit, series: prompt.series), at: now, &state)
		}
	}

	/// Ranks the Replica's tasks with the Taskrc the window runs on, decoding their UDAs, computing
	/// their Urgency and sorting them into fixed views again, then sorts and narrows them.
	/// Shows `snapshot`, unless it was read before the tasks shown.
	private func loadTasks(_ snapshot: TaskSnapshot, _ state: inout State) {
		state.isReplicaOpen = true
		guard snapshot.readIndex >= state.readIndex else {
			return
		}
		state.readIndex = snapshot.readIndex
		state.redoName = snapshot.redoName
		state.storedTasks = snapshot.tasks
		state.undoName = snapshot.undoName
		updateRows(&state)
	}

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

	/// Narrows the ranked rows by the sidebar, then the search, keeping the tasks an edit may have
	/// moved out. Drops selected tasks that left the table, and inspects the one task a
	/// selection is narrowed to.
	private func filterRows(_ state: inout State) {
		// Filtering keeps `allRows`' order, so the table needs no sort of its own.
		state.rows = IdentifiedArray(
			uniqueElements: state.allRows.filter { [
				filter = SidebarFilter(state.sidebarSelection),
				kept = state.keptTasks,
				search = state.searchText,
			] in
				guard !state.leavingTasks.contains($0.id) else {
					return false
				}
				return kept.contains($0.id) || filter.includes($0) && $0.matches(search: search)
			},
		)
		let selectedCount = state.selection.count
		state.selection.formIntersection(state.rows.ids)
		// A selection narrowed to one task inspects it, as selecting it would. A task already
		// inspected is kept by UUID, even once it leaves.
		if state.inspectedTask == nil, selectedCount > 1, state.selection.count == 1 {
			state.inspectedTask = state.selection.first
		}
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
	/// reported, offering Try Again… where `canRetry`.
	private func reloadTaskrc(
		for state: State,
		canRetry: Bool,
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
					.taskrcSaveFailed(TaskrcSaveFailure(message: error.localizedDescription, canRetry: canRetry)),
				)
			},
			loadTaskrc(for: state),
		)
	}
}

/// How far apart TW stores annotations: one to a second, keyed by it.
private let annotationSpacing: TimeInterval = 1

/// How far ahead of now an annotation's entry still moves a new one past it: far beyond any burst
/// of notes a person can add, and short enough that a clock set back soon stops mattering.
private let annotationWindow: TimeInterval = 60

/// The `recurrence.confirmation` value that asks, where any other reads as a boolean.
private let askingConfirmation = "prompt"

/// Whether a Done or Delete asks before repairing the dependency chains it breaks.
private let dependencyConfirmation = "dependency.confirmation"

/// How many times a write is planned before a plan the engine keeps refusing as stale fails it.
private let planAttempts = 3

/// How long reads of the Replica fail before the window says so, which rides out a `task` command
/// holding the lock for its 5 s.
private let readFailureDelay = Duration.seconds(30)

/// Whether a Delete or edit of a Recurrence instance takes its Series, or asks.
private let recurrenceConfirmation = "recurrence.confirmation"

/// How long a write runs before the subtitle says it's saving.
private let savingDelay = Duration.milliseconds(500)

/// How often an open window computes its tasks' Urgency again.
private let urgencyInterval = Duration.seconds(60)

/// How an Undo point's name refers to `attribute`: a UDA by its label.
private func attributeName(_ attribute: String, udaColumns: [UDAColumn]) -> String {
	switch attribute {
	case "description": String(localized: "Description")
	case "due": String(localized: "Due Date")
	case "project": String(localized: "Project")
	case "scheduled": String(localized: "Scheduled Date")
	case "until": String(localized: "Until Date")
	case "wait": String(localized: "Wait Date")
	default: udaColumns.first { $0.name == attribute }?.label ?? attribute
	}
}

/// `single` where `ids` is one task, else `multiple`, which counts them.
private func counted(_ ids: [Models.Task.ID], _ single: String, _ multiple: String) -> String {
	ids.count == 1 ? single : multiple
}

/// The Replica `error` says the window lost, as it was opened, where that's what it says.
private func lostReplica(_ error: any Error) -> ReplicaIdentity? {
	guard case let .lost(identity)? = error as? ReplicaError else {
		return nil
	}
	return identity
}

/// The name the Edit menu gives `action`'s Undo point, as in "Undo Change Due Date".
private func undoName(for action: WriteAction, udaColumns: [UDAColumn]) -> String {
	switch action {
	case let .complete(ids, _):
		counted(ids, String(localized: "Complete Task"), String(localized: "Complete \(ids.count) Tasks"))

	case .create:
		newTaskTitle

	case let .delete(_, _, series) where !series.isEmpty:
		counted(
			Array(series),
			String(localized: "Delete Series"),
			String(localized: "Delete \(series.count) Series"),
		)

	case let .delete(ids, _, _):
		counted(ids, String(localized: "Delete Task"), String(localized: "Delete \(ids.count) Tasks"))

	case .edit(_, .addAnnotation, _):
		String(localized: "Add Annotation")

	case .edit(_, .addDependency, _):
		String(localized: "Add Dependency")

	case let .edit(ids, .addTags(tags), _) where tags.count == 1:
		counted(ids, String(localized: "Add Tag"), String(localized: "Add Tag to \(ids.count) Tasks"))

	case let .edit(ids, .addTags, _):
		counted(ids, String(localized: "Add Tags"), String(localized: "Add Tags to \(ids.count) Tasks"))

	case .edit(_, .removeAnnotation, _):
		String(localized: "Remove Annotation")

	case .edit(_, .removeDependency, _):
		String(localized: "Remove Dependency")

	case let .edit(ids, .removeTag, _):
		counted(
			ids,
			String(localized: "Remove Tag"),
			String(localized: "Remove Tag from \(ids.count) Tasks"),
		)

	case let .edit(ids, .set(attribute, _), _), let .edit(ids, .setInput(attribute, _), _):
		counted(
			ids,
			String(localized: "Change \(attributeName(attribute, udaColumns: udaColumns))"),
			String(
				localized: "Change \(attributeName(attribute, udaColumns: udaColumns)) of \(ids.count) Tasks",
			),
		)

	case let .markPending(ids):
		counted(
			ids,
			String(localized: "Mark Task Pending"),
			String(localized: "Mark \(ids.count) Tasks Pending"),
		)

	case let .start(ids):
		counted(ids, String(localized: "Start Task"), String(localized: "Start \(ids.count) Tasks"))

	case let .stop(ids):
		counted(ids, String(localized: "Stop Task"), String(localized: "Stop \(ids.count) Tasks"))
	}
}

extension ReplicaFeature.WriteFailure {
	/// `error` failing the change `title` names, which `retry` tries again, unless the planner
	/// refused the change, which it would again.
	init(_ error: any Error, retry: Retry?, title: String) {
		reason = error.localizedDescription
		self.retry = error is WritePlanError ? nil : retry
		self.title = title
	}
}

/// A task the inspected task depends on.
struct InspectedDependency: Equatable {
	/// The task's `inspectorTitle`, where the Replica still has it.
	var title: String?
	var uuid: UUID

	/// The title, or the UUID where the Replica no longer has the task.
	var displayTitle: String {
		title ?? uuid.uuidString.lowercased()
	}
}

extension TaskRow {
	/// The task as the inspector and Remove Dependency name it: its ID, where it has one, before its
	/// description.
	var inspectorTitle: String {
		task.workingSetID.map { "\($0) \(task.description)" } ?? task.description
	}
}
