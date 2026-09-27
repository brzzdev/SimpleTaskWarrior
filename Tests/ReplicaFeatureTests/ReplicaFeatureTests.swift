import BookmarkClient
import ComposableArchitecture
import Foundation
import Models
import ReplicaClient
@testable import ReplicaFeature
import Taskrc
import TaskrcClient
import Testing
import TestSupport

@MainActor
struct ReplicaFeatureTests {
	@Test
	func bookmarkChangesFromAnotherWindowReloadTheTaskrc() async {
		let (changes, continuation) = AsyncStream<Void>.makeStream()
		let pairedTaskrc = LockIsolated<URL?>(nil)
		let store = TestStore(initialState: ReplicaFeature.State(bookmark: Data())) {
			ReplicaFeature()
		} withDependencies: {
			$0.bookmarkClient.changes = { changes }
			$0.bookmarkClient.grants = { [:] }
			$0.bookmarkClient.taskrc = { _ in pairedTaskrc.value }
			$0.date.now = now
			$0.taskrcClient.load = { taskrc, _, _ in
				.finished(yielding: TaskrcClient.Loaded(taskrc: .defaults, url: taskrc()))
			}
			$0.timeZone = .gmt
		}
		await store.send(.directoryResolved(replicaDirectory)) {
			$0.directory = replicaDirectory
		}
		await store.receive(\.taskrcLoaded) {
			$0.$hasShownTaskrcHint.withLock { $0 = true }
			$0.isTaskrcHintPresented = true
			$0.taskrc = TaskrcClient.Loaded(taskrc: .defaults, url: nil)
		}

		pairedTaskrc.setValue(taskrcFile)
		continuation.yield()
		await store.receive(\.pairingChanged)
		await store.receive(\.taskrcLoaded) {
			$0.isTaskrcHintPresented = false
			$0.taskrc?.url = taskrcFile
		}

		continuation.finish()
		await store.finish()
	}

	@Test
	func commandsAreEnabledOnlyWhenTheyApplyToEverySelectedTask() throws {
		let pending = storedTask(0, "Buy milk", workingSetID: 1)
		let active = storedTask(
			1,
			"Walk the dog",
			workingSetID: 2,
			["start": String(Int(now.timeIntervalSince1970))],
		)
		let completed = storedTask(2, "File taxes", status: "completed", workingSetID: nil)
		var state = try loadedState([pending, active, completed])

		#expect(state.enabledCommands.isEmpty)

		state.selection = [UUID(0), UUID(1)]
		#expect(state.enabledCommands == [.delete, .done, .startStop])
		#expect(!state.isStopping)

		state.selection = [UUID(1)]
		#expect(state.isStopping)

		state.selection = [UUID(2)]
		#expect(state.enabledCommands == [.delete, .markPending])

		state.selection = [UUID(0), UUID(2)]
		#expect(state.enabledCommands == [.delete])

		state.isNewTaskRowPresented = true
		#expect(state.enabledCommands.isEmpty)

		state.isNewTaskRowPresented = false
		state.writeProgress = .running
		#expect(state.enabledCommands.isEmpty)
	}

	@Test
	func doneCompletesTheSelectedTaskAndItLeavesTheList() async throws {
		let milk = storedTask(0, "Buy milk", workingSetID: 1)
		let dog = storedTask(1, "Walk the dog", workingSetID: 2)
		let milkDone = storedTask(0, "Buy milk", status: "completed", workingSetID: 1)
		let plans = LockIsolated<[WritePlan]>([])
		let initialState = try loadedState([milk, dog], selection: [UUID(0)])
		let store = TestStore(initialState: initialState) {
			ReplicaFeature()
		} withDependencies: {
			$0.continuousClock = TestClock()
			$0.date.now = now
			$0.replicaClient.apply = { plan, _ in
				plans.withValue { $0.append(plan) }
				return ApplyOutcome(isCommitted: true, snapshot: snapshot([milkDone, dog]))
			}
			$0.timeZone = .gmt
		}

		// It leaves before the write commits.
		await store.send(.doneButtonTapped) {
			$0.leavingTasks = [UUID(0)]
			$0.rows = try [row(dog)]
			$0.selection = []
			$0.writeProgress = .running
		}
		await store.receive(\.tasksLoaded) {
			$0.allRows = try [row(dog), row(milkDone, view: .completed)]
			$0.storedTasks = [milkDone, dog]
		}
		await store.receive(\.writeCommitted) {
			$0.leavingTasks = []
			$0.writeProgress = nil
		}
		#expect(
			try plans.value == [
				planner.plan(
					.complete([UUID(0)]),
					tasks: [UUID(0): milk.properties, UUID(1): dog.properties],
					at: now,
				),
			],
		)
		await store.finish()
	}

	@Test
	func inspectorEditKeepsATaskItMovesOutUntilTheSelectionChanges() async throws {
		let milk = storedTask(0, "Buy milk", workingSetID: 1, ["tag_home": "x"])
		let dog = storedTask(1, "Walk the dog", workingSetID: 2, ["tag_home": "x"])
		let milkUntagged = storedTask(0, "Buy milk", workingSetID: 1)
		let plans = LockIsolated<[WritePlan]>([])
		var initialState = try loadedState([milk, dog])
		initialState.sidebarSelection = [.tag("home")]
		let store = TestStore(initialState: initialState) {
			ReplicaFeature()
		} withDependencies: {
			$0.continuousClock = TestClock()
			$0.date.now = now
			$0.replicaClient.apply = { plan, _ in
				plans.withValue { $0.append(plan) }
				return ApplyOutcome(isCommitted: true, snapshot: snapshot([milkUntagged, dog]))
			}
			$0.timeZone = .gmt
		}

		await store.send(\.binding.selection, [UUID(0)]) {
			$0.inspectedTask = UUID(0)
			$0.selection = [UUID(0)]
		}
		await store.send(.tagRemoveButtonTapped(UUID(0), tag: "home")) {
			$0.keptTask = UUID(0)
			$0.writeProgress = .running
		}
		// Untagged, it's no longer in the sidebar's tag, yet it stays, selected.
		await store.receive(\.tasksLoaded) {
			$0.allRows = try [row(dog, urgency: 0.8), row(milkUntagged)]
			$0.highestUrgency = 0.8
			$0.rows = try [row(dog, urgency: 0.8), row(milkUntagged)]
			$0.storedTasks = [milkUntagged, dog]
		}
		await store.receive(\.writeCommitted) {
			$0.writeProgress = nil
		}
		#expect(
			try plans.value == [
				planner.plan(
					.edit([UUID(0)], .removeTag("home")),
					tasks: [UUID(0): milk.properties, UUID(1): dog.properties],
					at: now,
				),
			],
		)

		await store.send(\.binding.selection, [UUID(1)]) {
			$0.inspectedTask = UUID(1)
			$0.keptTask = nil
			$0.rows = try [row(dog, urgency: 0.8)]
			$0.selection = [UUID(1)]
		}
		await store.finish()
	}

	@Test
	func inspectorEditsWhileAWriteRunsAreWrittenInTurnOnceItEnds() async throws {
		let milk = storedTask(0, "Buy milk", workingSetID: 1)
		let milkHome = storedTask(0, "Buy milk", workingSetID: 1, ["project": "Home"])
		let (commits, commit) = AsyncStream<Void>.makeStream()
		let plans = LockIsolated<[WritePlan]>([])
		let initialState = try loadedState([milk], selection: [UUID(0)])
		let store = TestStore(initialState: initialState) {
			ReplicaFeature()
		} withDependencies: {
			$0.continuousClock = TestClock()
			$0.date.now = now
			$0.replicaClient.apply = { plan, _ in
				plans.withValue { $0.append(plan) }
				for await _ in commits {
					break
				}
				return ApplyOutcome(isCommitted: true, snapshot: snapshot([milkHome]))
			}
			$0.timeZone = .gmt
		}
		store.exhaustivity = .off(showSkippedAssertions: false)

		await store.send(.inspectorFieldSubmitted(UUID(0), .set("project", .string("Home")))) {
			$0.writeProgress = .running
		}
		await store.send(.annotationSubmitted(UUID(0), "Oat, not dairy")) {
			$0.queuedWrites = [.edit([UUID(0)], .addAnnotation("Oat, not dairy", entry: now))]
		}
		commit.yield()
		await store.receive(\.tasksLoaded)
		await store.receive(\.writeCommitted) {
			$0.queuedWrites = []
			$0.writeProgress = .running
		}
		commit.yield()
		await store.receive(\.tasksLoaded)
		await store.receive(\.writeCommitted) {
			$0.writeProgress = nil
		}
		// The queued edit plans against the tasks the first write read back.
		#expect(
			try plans.value == [
				planner.plan(
					.edit([UUID(0)], .set("project", .string("Home"))),
					tasks: [UUID(0): milk.properties],
					at: now,
				),
				planner.plan(
					.edit([UUID(0)], .addAnnotation("Oat, not dairy", entry: now)),
					tasks: [UUID(0): milkHome.properties],
					at: now,
				),
			],
		)
		commit.finish()
		await store.finish()
	}

	@Test
	func annotationsAddedWithinASecondEachKeepTheirOwnSecond() async throws {
		let second = Int(now.timeIntervalSince1970)
		// The CLI already annotated it this second.
		let milk = storedTask(0, "Buy milk", workingSetID: 1, ["annotation_\(second)": "Oat"])
		let (commits, commit) = AsyncStream<Void>.makeStream()
		let replica = LockIsolated([UUID(0): milk.properties])
		let initialState = try loadedState([milk], selection: [UUID(0)])
		let store = TestStore(initialState: initialState) {
			ReplicaFeature()
		} withDependencies: {
			$0.continuousClock = TestClock()
			$0.date.now = now
			$0.replicaClient.apply = { plan, _ in
				for await _ in commits {
					break
				}
				let tasks = replica.withValue { tasks in
					let isFirst = tasks[UUID(0)]?["annotation_\(second + 1)"] == nil
					tasks = plan.applied(to: tasks)
					// The CLI annotates it again just after the first add lands, in the second the next
					// add would have asked for when it was submitted.
					if isFirst {
						tasks[UUID(0)]?["annotation_\(second + 2)"] = "Oat"
					}
					return tasks
				}
				let stored = tasks.map { id, properties in
					StoredTask(properties: properties, uuid: id.uuidString.lowercased(), workingSetID: 1)
				}
				return ApplyOutcome(isCommitted: true, snapshot: snapshot(stored))
			}
			$0.timeZone = .gmt
		}
		store.exhaustivity = .off(showSkippedAssertions: false)

		// The same text each time, which the planner would take for a retry of a note in its second.
		for _ in 1 ... 3 {
			await store.send(.annotationSubmitted(UUID(0), "Oat"))
		}
		for _ in 1 ... 3 {
			commit.yield()
			await store.receive(\.writeCommitted)
		}
		let annotations = replica.value[UUID(0)]?.filter { $0.key.hasPrefix("annotation_") }
		#expect(
			annotations == Dictionary(
				uniqueKeysWithValues: (0 ... 4).map { ("annotation_\(second + $0)", "Oat") },
			),
		)
		commit.finish()
		await store.finish()
	}

	@Test
	func inspectorTakesTheTaskASelectionIsNarrowedTo() async throws {
		let milk = storedTask(0, "Buy milk", workingSetID: 1)
		let dog = storedTask(1, "Walk the dog", workingSetID: 2)
		let milkDone = storedTask(0, "Buy milk", status: "completed", workingSetID: nil)
		let initialState = try loadedState([milk, dog])
		let store = TestStore(initialState: initialState) {
			ReplicaFeature()
		} withDependencies: {
			$0.date.now = now
			$0.timeZone = .gmt
		}

		await store.send(\.binding.selection, [UUID(0), UUID(1)]) {
			$0.selection = [UUID(0), UUID(1)]
		}
		// The CLI completes one of the two, leaving the other selected alone.
		await store.send(.tasksLoaded(snapshot([milkDone, dog], readIndex: 1))) {
			$0.allRows = try [row(dog), row(milkDone, view: .completed)]
			$0.inspectedTask = UUID(1)
			$0.readIndex = 1
			$0.rows = try [row(dog)]
			$0.selection = [UUID(1)]
			$0.storedTasks = [milkDone, dog]
		}
	}

	@Test
	func inspectorStaysOnATaskTheCLIMovesOutOfTheView() async throws {
		let milk = storedTask(0, "Buy milk", workingSetID: 1)
		let dog = storedTask(1, "Walk the dog", workingSetID: 2)
		let milkDone = storedTask(0, "Buy milk", status: "completed", workingSetID: nil)
		let initialState = try loadedState([milk, dog])
		let store = TestStore(initialState: initialState) {
			ReplicaFeature()
		} withDependencies: {
			$0.date.now = now
			$0.timeZone = .gmt
		}

		await store.send(\.binding.selection, [UUID(0)]) {
			$0.inspectedTask = UUID(0)
			$0.selection = [UUID(0)]
		}
		await store.send(.tasksLoaded(snapshot([milkDone, dog], readIndex: 1))) {
			$0.allRows = try [row(dog), row(milkDone, view: .completed)]
			$0.readIndex = 1
			$0.rows = try [row(dog)]
			$0.selection = []
			$0.storedTasks = [milkDone, dog]
		}
		#expect(store.state.inspectedRow?.task.status == .completed)

		await store.send(\.binding.selection, [UUID(1)]) {
			$0.inspectedTask = UUID(1)
			$0.selection = [UUID(1)]
		}
	}

	@Test
	func nextAndPreviousTaskMoveFromTheInspectedTaskInTheTablesOrder() async throws {
		let milk = storedTask(0, "Buy milk", workingSetID: 1)
		let dog = storedTask(1, "Walk the dog", workingSetID: 2)
		let initialState = try loadedState([milk, dog])
		let store = TestStore(initialState: initialState) {
			ReplicaFeature()
		}

		// With nothing inspected, there's nothing to move from.
		await store.send(.nextTaskButtonTapped)
		await store.send(\.binding.selection, [UUID(0)]) {
			$0.inspectedTask = UUID(0)
			$0.selection = [UUID(0)]
		}
		await store.send(.previousTaskButtonTapped)
		await store.send(.nextTaskButtonTapped) {
			$0.inspectedTask = UUID(1)
			$0.selection = [UUID(1)]
		}
		await store.send(.nextTaskButtonTapped)
		await store.send(.previousTaskButtonTapped) {
			$0.inspectedTask = UUID(0)
			$0.selection = [UUID(0)]
		}
	}

	@Test
	func newTaskShowsInPendingAndIsSelectedOnceItsCreated() async throws {
		let taxes = storedTask(1, "File taxes", status: "completed", workingSetID: nil)
		let milk = storedTask(0, "Buy milk", workingSetID: 1)
		let plans = LockIsolated<[WritePlan]>([])
		var initialState = try loadedState([taxes])
		initialState.searchText = "taxes"
		initialState.sidebarSelection = [.view(.completed)]
		let store = TestStore(initialState: initialState) {
			ReplicaFeature()
		} withDependencies: {
			$0.continuousClock = TestClock()
			$0.date.now = now
			$0.replicaClient.apply = { plan, _ in
				plans.withValue { $0.append(plan) }
				return ApplyOutcome(isCommitted: true, snapshot: snapshot([taxes, milk]))
			}
			$0.timeZone = .gmt
			$0.uuid = .incrementing
		}

		await store.send(.newTaskButtonTapped) {
			$0.isNewTaskRowPresented = true
			$0.rows = []
			$0.sidebarSelection = [.view(.pending)]
		}
		await store.send(.newTaskDescriptionSubmitted("Buy milk")) {
			$0.creatingTask = UUID(0)
			$0.isNewTaskRowPresented = false
			$0.writeProgress = .running
		}
		await store.receive(\.tasksLoaded) {
			$0.allRows = try [row(milk), row(taxes, view: .completed)]
			$0.storedTasks = [taxes, milk]
		}
		// The search would hide it, so it's cleared.
		await store.receive(\.writeCommitted) {
			$0.creatingTask = nil
			$0.focusesDescription = true
			$0.inspectedTask = UUID(0)
			$0.rows = try [row(milk)]
			$0.searchText = ""
			$0.selection = [UUID(0)]
			$0.writeProgress = nil
		}
		#expect(plans.value.first?.operations.first == .create(UUID(0)))
		await store.finish()
	}

	@Test
	func newTaskChecksItsSidebarAgainWhenTheTaskrcChangesBeforeReturn() async throws {
		func taskrc(defaultProject: String) -> TaskrcClient.Loaded {
			let taskrc = Taskrc(path: taskrcFile.path(), environment: .fixture) { path, _ in
				Taskrc.File(contents: "default.project=\(defaultProject)", realPath: path)
			}
			return TaskrcClient.Loaded(taskrc: taskrc, url: taskrcFile)
		}
		var initialState = try loadedState([])
		initialState.sidebarSelection = [.project("Home")]
		initialState.taskrc = taskrc(defaultProject: "Home")
		let store = TestStore(initialState: initialState) {
			ReplicaFeature()
		} withDependencies: {
			$0.continuousClock = TestClock()
			$0.date.now = now
			$0.replicaClient.apply = { _, _ in ApplyOutcome(isCommitted: true, snapshot: snapshot([])) }
			$0.timeZone = .gmt
			$0.uuid = .incrementing
		}

		await store.send(.newTaskButtonTapped) {
			$0.isNewTaskRowPresented = true
		}
		await store.send(.taskrcLoaded(taskrc(defaultProject: "Work"))) {
			$0.taskrc = taskrc(defaultProject: "Work")
		}
		await store.send(.newTaskDescriptionSubmitted("Buy milk")) {
			$0.creatingTask = UUID(0)
			$0.isNewTaskRowPresented = false
			$0.sidebarSelection = [.view(.pending)]
			$0.writeProgress = .running
		}
		await store.receive(\.tasksLoaded)
		await store.receive(\.writeCommitted) {
			$0.creatingTask = nil
			$0.writeProgress = nil
		}
	}

	@Test
	func newTaskWaitsForTheReplicaAndTheTaskrc() async {
		var initialState = ReplicaFeature.State(bookmark: Data())
		initialState.directory = replicaDirectory
		let store = TestStore(initialState: initialState) {
			ReplicaFeature()
		} withDependencies: {
			$0.date.now = now
			$0.timeZone = .gmt
		}

		// Tasks with no Taskrc yet would create on TW's defaults.
		await store.send(.tasksLoaded(snapshot([]))) {
			$0.isReplicaOpen = true
		}
		await store.send(.newTaskButtonTapped)
		await store.send(.taskrcLoaded(TaskrcClient.Loaded(taskrc: .defaults, url: taskrcFile))) {
			$0.taskrc = TaskrcClient.Loaded(taskrc: .defaults, url: taskrcFile)
		}
		await store.send(.newTaskButtonTapped) {
			$0.isNewTaskRowPresented = true
		}
	}

	@Test
	func savingShowsAfterHalfASecondAndOtherWritesWaitUntilTheWriteEnds() async throws {
		let milk = storedTask(0, "Buy milk", workingSetID: 1)
		let milkDone = storedTask(0, "Buy milk", status: "completed", workingSetID: 1)
		let (commits, commit) = AsyncStream<Void>.makeStream()
		let clock = TestClock()
		let initialState = try loadedState([milk], selection: [UUID(0)])
		let store = TestStore(initialState: initialState) {
			ReplicaFeature()
		} withDependencies: {
			$0.continuousClock = clock
			$0.date.now = now
			$0.replicaClient.apply = { _, _ in
				for await _ in commits {
					break
				}
				return ApplyOutcome(isCommitted: true, snapshot: snapshot([milkDone]))
			}
			$0.timeZone = .gmt
		}

		await store.send(.doneButtonTapped) {
			$0.leavingTasks = [UUID(0)]
			$0.rows = []
			$0.selection = []
			$0.writeProgress = .running
		}
		await store.send(.deleteButtonTapped)
		await clock.advance(by: .milliseconds(499))
		await clock.advance(by: .milliseconds(1))
		await store.receive(\.savingDelayElapsed) {
			$0.writeProgress = .saving
		}

		commit.yield()
		await store.receive(\.tasksLoaded) {
			$0.allRows = try [row(milkDone, view: .completed)]
			$0.storedTasks = [milkDone]
		}
		await store.receive(\.writeCommitted) {
			$0.leavingTasks = []
			$0.writeProgress = nil
		}
		await store.finish()
	}

	@Test
	func stalePlanIsPlannedAgainAgainstTheTasksTheEngineRead() async throws {
		let milk = storedTask(0, "Buy milk", workingSetID: 1)
		let milkStarted = storedTask(
			0,
			"Buy milk",
			workingSetID: 1,
			["start": String(Int(now.timeIntervalSince1970))],
		)
		let milkDone = storedTask(0, "Buy milk", status: "completed", workingSetID: 1)
		let plans = LockIsolated<[WritePlan]>([])
		let initialState = try loadedState([milk], selection: [UUID(0)])
		let store = TestStore(initialState: initialState) {
			ReplicaFeature()
		} withDependencies: {
			$0.continuousClock = TestClock()
			$0.date.now = now
			$0.replicaClient.apply = { plan, _ in
				plans.withValue { $0.append(plan) }
				return plans.value.count == 1
					? ApplyOutcome(isCommitted: false, snapshot: snapshot([milkStarted]))
					: ApplyOutcome(isCommitted: true, snapshot: snapshot([milkDone]))
			}
			$0.timeZone = .gmt
		}

		await store.send(.doneButtonTapped) {
			$0.leavingTasks = [UUID(0)]
			$0.rows = []
			$0.selection = []
			$0.writeProgress = .running
		}
		// Active, so the CLI's start raised its Urgency.
		await store.receive(\.tasksLoaded) {
			$0.allRows = try [row(milkStarted, urgency: 4)]
			$0.storedTasks = [milkStarted]
		}
		await store.receive(\.tasksLoaded) {
			$0.allRows = try [row(milkDone, view: .completed)]
			$0.storedTasks = [milkDone]
		}
		await store.receive(\.writeCommitted) {
			$0.leavingTasks = []
			$0.writeProgress = nil
		}
		#expect(
			try plans.value.last
				== planner.plan(.complete([UUID(0)]), tasks: [UUID(0): milkStarted.properties], at: now),
		)
		await store.finish()
	}

	@Test
	func stalePlanFailsTheWriteAfterThreeAttempts() async throws {
		let milk = storedTask(0, "Buy milk", workingSetID: 1)
		let attempts = LockIsolated(0)
		let initialState = try loadedState([milk], selection: [UUID(0)])
		let store = TestStore(initialState: initialState) {
			ReplicaFeature()
		} withDependencies: {
			$0.continuousClock = TestClock()
			$0.date.now = now
			$0.replicaClient.apply = { _, _ in
				attempts.withValue { $0 += 1 }
				return ApplyOutcome(isCommitted: false, snapshot: snapshot([milk]))
			}
			$0.timeZone = .gmt
		}

		await store.send(.doneButtonTapped) {
			$0.leavingTasks = [UUID(0)]
			$0.rows = []
			$0.selection = []
			$0.writeProgress = .running
		}
		await store.receive(\.tasksLoaded)
		await store.receive(\.tasksLoaded)
		await store.receive(\.tasksLoaded)
		// The task it dropped comes back.
		await store.receive(\.writeFailed) {
			$0.leavingTasks = []
			$0.rows = try [row(milk)]
			$0.writeProgress = nil
		}
		#expect(attempts.value == 3)
		await store.finish()
	}

	@Test
	func snapshotReadBeforeTheLastIsDropped() async throws {
		let milk = storedTask(0, "Buy milk", workingSetID: 1)
		let initialState = try loadedState([])
		let store = TestStore(initialState: initialState) {
			ReplicaFeature()
		} withDependencies: {
			$0.date.now = now
			$0.timeZone = .gmt
		}

		await store.send(.tasksLoaded(snapshot([milk], readIndex: 2))) {
			$0.allRows = try [row(milk)]
			$0.readIndex = 2
			$0.rows = try [row(milk)]
			$0.storedTasks = [milk]
		}
		// A write's read, delivered after the stream's later one.
		await store.send(.tasksLoaded(snapshot([], readIndex: 1)))
	}

	@Test
	func failedSaveIsReportedAndTryAgainReopensThePanel() async {
		struct Gone: LocalizedError {
			var errorDescription: String? { "The file is gone." }
		}
		let store = TestStore(initialState: ReplicaFeature.State(bookmark: Data())) {
			ReplicaFeature()
		} withDependencies: {
			$0.bookmarkClient.changes = { .finished }
			$0.bookmarkClient.grants = { [:] }
			$0.bookmarkClient.saveTaskrc = { _, _ in throw Gone() }
			$0.taskrcClient.load = { _, _, _ in .finished }
		}
		await store.send(.directoryResolved(replicaDirectory)) {
			$0.directory = replicaDirectory
		}

		await store.send(.fileChosen(taskrcFile, for: .taskrc))
		await store.receive(\.taskrcSaveFailed) {
			$0.taskrcSaveFailure = ReplicaFeature.TaskrcSaveFailure(
				message: "The file is gone.",
				retry: .taskrc,
			)
		}

		await store.send(.tryAgainButtonTapped) {
			$0.fileImporter = .taskrc
		}
	}

	@Test
	func grantAccessAsksForTheIncludeAndReloadsKeepingTheRunningTaskrc() async {
		let include = Taskrc.Include(file: taskrcFile.path(), line: "include $DOTFILES/work.rc")
		let problem = Taskrc.Problem(
			.unreadable(path: "/work.rc", unsetVariables: ["DOTFILES"]),
			at: Taskrc.Location(file: taskrcFile.path(), line: 3),
			include: include,
		)
		let granted = URL(filePath: "/Users/paul/dotfiles/work.rc")
		let grants = LockIsolated<[Taskrc.Include: URL]>([:])
		let running = Taskrc(path: taskrcFile.path(), environment: .fixture) { path, _ in
			Taskrc.File(contents: "weekstart=monday", realPath: path)
		}
		let startingTaskrcs = LockIsolated<[Taskrc]>([])
		let store = TestStore(initialState: ReplicaFeature.State(bookmark: Data())) {
			ReplicaFeature()
		} withDependencies: {
			$0.bookmarkClient.changes = { .finished }
			$0.bookmarkClient.grants = { grants.value }
			$0.bookmarkClient.saveGrant = { file, include in
				grants.withValue { $0[include] = file }
			}
			$0.date.now = now
			$0.taskrcClient.load = { _, grants, lastGood in
				startingTaskrcs.withValue { $0.append(lastGood) }
				return .finished(
					yielding: TaskrcClient.Loaded(
						problem: grants()[include] == nil ? problem : nil,
						taskrc: running,
						url: taskrcFile,
					),
				)
			}
			$0.timeZone = .gmt
		}

		await store.send(.directoryResolved(replicaDirectory)) {
			$0.directory = replicaDirectory
		}
		await store.receive(\.taskrcLoaded) {
			$0.taskrc = TaskrcClient.Loaded(problem: problem, taskrc: running, url: taskrcFile)
		}

		await store.send(.grantAccessButtonTapped) {
			$0.fileImporter = .grant(include, file: URL(filePath: "/work.rc"))
		}
		await store.send(.fileChosen(granted, for: .grant(include, file: URL(filePath: "/work.rc")))) {
			$0.fileImporter = nil
		}
		await store.receive(\.taskrcLoaded) {
			$0.taskrc?.problem = nil
		}
		#expect(grants.value == [include: granted])
		#expect(startingTaskrcs.value == [.defaults, running])
	}

	@Test
	func grantAccessIsOfferedOnlyWhereAGrantCanReachTheFile() {
		let include = Taskrc.Include(file: taskrcFile.path(), line: "include $DOTFILES/work.rc")
		let at = Taskrc.Location(file: taskrcFile.path(), line: 3)
		var state = ReplicaFeature.State(bookmark: Data())
		let remedy = { (kind: Taskrc.Problem.Kind, include: Taskrc.Include?) in
			state.taskrc = TaskrcClient.Loaded(
				problem: Taskrc.Problem(kind, at: include == nil ? nil : at, include: include),
				taskrc: .defaults,
				url: taskrcFile,
			)
			return state.taskrcRemedy
		}
		let unset = Taskrc.Problem.Kind.notFound(path: "/work.rc", unsetVariables: ["DOTFILES"])

		#expect(remedy(unset, include) == .grant(include, file: URL(filePath: "/work.rc")))
		#expect(remedy(.notFound(path: "/work.rc", unsetVariables: []), include) == nil)
		#expect(remedy(.notFound(path: taskrcFile.path(), unsetVariables: []), nil) == .taskrc)
		#expect(remedy(.malformedLine("oops"), nil) == nil)
	}

	@Test
	func hintOffersATaskrcOnceAndTheMenuAttachesAndDetachesIt() async {
		let pairedTaskrc = LockIsolated<URL?>(nil)
		let store = TestStore(initialState: ReplicaFeature.State(bookmark: Data())) {
			ReplicaFeature()
		} withDependencies: {
			$0.bookmarkClient.changes = { .finished }
			$0.bookmarkClient.grants = { [:] }
			$0.bookmarkClient.saveTaskrc = { taskrc, replica in
				#expect(replica == replicaDirectory)
				pairedTaskrc.setValue(taskrc)
			}
			$0.bookmarkClient.taskrc = { _ in pairedTaskrc.value }
			$0.date.now = now
			$0.taskrcClient.load = { taskrc, _, _ in
				.finished(yielding: TaskrcClient.Loaded(taskrc: .defaults, url: taskrc()))
			}
			$0.timeZone = .gmt
		}

		await store.send(.directoryResolved(replicaDirectory)) {
			$0.directory = replicaDirectory
		}
		await store.receive(\.taskrcLoaded) {
			$0.$hasShownTaskrcHint.withLock { $0 = true }
			$0.isTaskrcHintPresented = true
			$0.taskrc = TaskrcClient.Loaded(taskrc: .defaults, url: nil)
		}

		await store.send(.chooseTaskrcButtonTapped) {
			$0.fileImporter = .taskrc
		}
		await store.send(.fileChosen(taskrcFile, for: .taskrc)) {
			$0.fileImporter = nil
			$0.isTaskrcHintPresented = false
		}
		await store.receive(\.taskrcLoaded) {
			$0.taskrc?.url = taskrcFile
		}

		// Back on TW's defaults, the hint has already been shown.
		await store.send(.useTaskwarriorDefaultsButtonTapped)
		await store.receive(\.taskrcLoaded) {
			$0.taskrc?.url = nil
		}
		#expect(pairedTaskrc.value == nil)
	}

	@Test
	func listsPendingTasksSortedAndDropsSelectedTasksThatLeave() async {
		let directory = URL(filePath: "/Users/paul/.task")
		let (tasks, continuation) = AsyncThrowingStream<TaskSnapshot, any Error>.makeStream()
		let store = TestStore(initialState: ReplicaFeature.State(bookmark: Data())) {
			ReplicaFeature()
		} withDependencies: {
			$0.bookmarkClient.changes = { .finished }
			$0.bookmarkClient.grants = { [:] }
			$0.bookmarkClient.resolve = { _ in directory }
			$0.continuousClock = TestClock()
			$0.date.now = now
			$0.replicaClient.tasks = { _ in tasks }
			$0.taskrcClient.load = { _, _, _ in .finished }
			$0.timeZone = .gmt
		}
		let milk = storedTask(0, "Buy milk", workingSetID: 1)
		let dog = storedTask(1, "Walk the dog", workingSetID: 2)
		let taxes = storedTask(2, "File taxes", status: "completed", workingSetID: nil)

		let task = await store.send(.fetchRequested)
		await store.receive(\.directoryResolved) {
			$0.directory = directory
		}

		// Tied on Urgency, so in ID order.
		continuation.yield(snapshot([dog, taxes, milk]))
		await store.receive(\.tasksLoaded) {
			$0.allRows = try [row(milk), row(dog), row(taxes, view: .completed)]
			$0.isReplicaOpen = true
			$0.storedTasks = [dog, taxes, milk]
			$0.rows = try [row(milk), row(dog)]
		}
		await store.send(.sortOrderChanged([TaskSort(.description, order: .reverse)])) {
			$0.allRows = try [row(dog), row(taxes, view: .completed), row(milk)]
			$0.rows = try [row(dog), row(milk)]
			$0.sortOrder = [TaskSort(.description, order: .reverse)]
		}
		await store.send(\.binding.selection, [UUID(0), UUID(1)]) {
			$0.selection = [UUID(0), UUID(1)]
		}

		let milkDone = storedTask(0, "Buy milk", status: "completed", workingSetID: 1)
		continuation.yield(snapshot([dog, taxes, milkDone]))
		// Down to one selected task, which the inspector takes.
		await store.receive(\.tasksLoaded) {
			$0.allRows = try [row(dog), row(taxes, view: .completed), row(milkDone, view: .completed)]
			$0.inspectedTask = UUID(1)
			$0.storedTasks = [dog, taxes, milkDone]
			$0.rows = try [row(dog)]
			$0.selection = [UUID(1)]
		}

		continuation.finish()
		await task.cancel()
	}

	@Test
	func recomputesUrgencyEveryMinute() async {
		let (tasks, continuation) = AsyncThrowingStream<TaskSnapshot, any Error>.makeStream()
		let clock = TestClock()
		let time = LockIsolated(now)
		let store = TestStore(initialState: ReplicaFeature.State(bookmark: Data())) {
			ReplicaFeature()
		} withDependencies: {
			$0.bookmarkClient.changes = { .finished }
			$0.bookmarkClient.grants = { [:] }
			$0.bookmarkClient.resolve = { _ in replicaDirectory }
			$0.continuousClock = clock
			$0.date = DateGenerator { time.value }
			$0.replicaClient.tasks = { _ in tasks }
			$0.taskrcClient.load = { _, _, _ in .finished }
			$0.timeZone = .gmt
		}
		let call = storedTask(
			0,
			"Call the bank",
			workingSetID: 2,
			["scheduled": String(Int(now.timeIntervalSince1970) + 30)],
		)
		let post = storedTask(1, "Post the letter", workingSetID: 1)

		let task = await store.send(.fetchRequested)
		await store.receive(\.directoryResolved) {
			$0.directory = replicaDirectory
		}
		// Tied on Urgency, so in ID order.
		continuation.yield(snapshot([call, post]))
		await store.receive(\.tasksLoaded) {
			$0.allRows = try [row(post), row(call)]
			$0.isReplicaOpen = true
			$0.rows = try [row(post), row(call)]
			$0.storedTasks = [call, post]
		}

		// Past `scheduled`, with nothing committed to the Replica.
		time.setValue(now.addingTimeInterval(60))
		await clock.advance(by: .seconds(60))
		await store.receive(\.timerTicked) {
			$0.allRows = try [row(call, urgency: 5), row(post)]
			$0.highestUrgency = 5
			$0.rows = try [row(call, urgency: 5), row(post)]
		}

		continuation.finish()
		await task.cancel()
	}

	@Test
	func ranksTasksAndRanksThemAgainWhenTheTaskrcReloads() async {
		let store = TestStore(initialState: ReplicaFeature.State(bookmark: Data())) {
			ReplicaFeature()
		} withDependencies: {
			$0.date.now = now
			$0.timeZone = .gmt
		}
		let estimated = storedTask(0, "Estimate the move", workingSetID: 1, ["estimate": "3"])
		let blocker = storedTask(1, "Book the van", workingSetID: 3)
		let blocked = storedTask(2, "Move", workingSetID: 2, ["dep_\(blocker.uuid)": "x"])
		let template = storedTask(3, "Water the plants", status: "recurring", workingSetID: nil)
		let storedTasks = [blocked, blocker, estimated, template]

		await store.send(.tasksLoaded(snapshot(storedTasks))) {
			$0.allRows = try [
				row(blocker, urgency: 8),
				row(estimated),
				row(blocked, isBlocked: true, urgency: -5),
			]
			$0.highestUrgency = 8
			$0.isReplicaOpen = true
			$0.storedTasks = storedTasks
			$0.rows = try [
				row(blocker, urgency: 8),
				row(estimated),
				row(blocked, isBlocked: true, urgency: -5),
			]
		}

		let taskrc = Taskrc(path: taskrcFile.path(), environment: .fixture) { path, _ in
			Taskrc.File(
				contents: "uda.estimate.type=numeric\nurgency.uda.estimate.coefficient=5",
				realPath: path,
			)
		}
		await store.send(.taskrcLoaded(TaskrcClient.Loaded(taskrc: taskrc, url: taskrcFile))) {
			$0.allRows[1].task.orphans = [:]
			$0.allRows[1].task.udas = ["estimate": .numeric(3)]
			$0.allRows[1].urgency = 5
			$0.rows[id: UUID(0)]?.task.orphans = [:]
			$0.rows[id: UUID(0)]?.task.udas = ["estimate": .numeric(3)]
			$0.rows[id: UUID(0)]?.urgency = 5
			$0.taskrc = TaskrcClient.Loaded(taskrc: taskrc, url: taskrcFile)
			$0.udaColumns = UDAColumn.all(in: taskrc)
		}
	}

	@Test
	func searchMatchesDescriptionsAndAnnotationsInAnyCaseAndWithoutDiacritics() async {
		let store = TestStore(initialState: ReplicaFeature.State(bookmark: Data())) {
			ReplicaFeature()
		} withDependencies: {
			$0.date.now = now
			$0.timeZone = .gmt
		}
		store.exhaustivity = .off
		let book = storedTask(0, "Book the Café", workingSetID: 1)
		let call = storedTask(
			1,
			"Call Bob",
			workingSetID: 2,
			["annotation_\(Int(now.timeIntervalSince1970))": "about the cafe"],
		)
		await store.send(.tasksLoaded(snapshot([book, call])))

		// TW's defaults set `search.case.sensitive`, which the search ignores.
		await store.send(\.binding.searchText, "CAFE")
		#expect(Set(store.state.rows.map(\.id)) == [UUID(0), UUID(1)])
		await store.send(\.binding.searchText, "bob")
		#expect(store.state.rows.map(\.id) == [UUID(1)])
	}

	@Test
	func sidebarListsProjectsAndTagsFromTheSelectedViewsAndKeepsSelectedOnes() throws {
		let rows = try [
			row(storedTask(0, "Dig", workingSetID: 1, ["project": "Home.Garden", "tag_phone": "x"])),
			row(storedTask(1, "Sweep", workingSetID: 2, ["project": "Home"])),
			row(
				storedTask(
					2,
					"Fix",
					status: "completed",
					workingSetID: nil,
					["project": "Work", "tag_bug": "x"],
				),
				view: .completed,
			),
		]

		let sidebar = Sidebar(rows: rows, selection: [.project("Errands"), .tag("bug")])

		#expect(sidebar.views.map(\.count) == [2, 0, 1, 0])
		#expect(
			sidebar.projects == [
				Sidebar.Project(children: [], count: 0, name: "Errands"),
				Sidebar.Project(
					children: [Sidebar.Project(children: [], count: 1, name: "Home.Garden")],
					count: 2,
					name: "Home",
				),
			],
		)
		#expect(
			sidebar.tags == [
				Sidebar.Count(count: 0, item: .tag("bug")),
				Sidebar.Count(count: 1, item: .tag("phone")),
			],
		)
	}

	@Test
	func sidebarNarrowsWithOrInASectionAndAndAcrossThem() async {
		let store = TestStore(initialState: ReplicaFeature.State(bookmark: Data())) {
			ReplicaFeature()
		} withDependencies: {
			$0.date.now = now
			$0.timeZone = .gmt
		}
		store.exhaustivity = .off
		let later = String(Int(now.timeIntervalSince1970) + 3_600)
		await store.send(
			.tasksLoaded(snapshot([
				storedTask(0, "Call the plumber", workingSetID: 1, ["project": "Home", "tag_phone": "x"]),
				storedTask(1, "Dig the beds", workingSetID: 2, ["project": "Home.Garden"]),
				storedTask(2, "Essay", workingSetID: 3, ["project": "Homework", "tag_phone": "x"]),
				storedTask(3, "Fix the build", workingSetID: 4, ["project": "Work", "tag_bug": "x"]),
				storedTask(
					4,
					"Ring the client",
					workingSetID: 5,
					["project": "Work", "tag_phone": "x", "wait": later],
				),
				storedTask(5, "Paint", status: "completed", workingSetID: nil, ["project": "Home"]),
			])),
		)
		let descriptions = { store.state.rows.map(\.task.description).sorted() }

		// No fixed view selected means Pending, and a project takes in its subprojects, by segment.
		await store.send(\.binding.sidebarSelection, [.project("Home")])
		#expect(descriptions() == ["Call the plumber", "Dig the beds"])

		await store.send(\.binding.sidebarSelection, [.project("Home"), .project("Work")])
		#expect(descriptions() == ["Call the plumber", "Dig the beds", "Fix the build"])

		await store.send(
			\.binding.sidebarSelection,
			[.project("Home"), .project("Work"), .tag("phone"), .view(.pending), .view(.waiting)],
		)
		#expect(descriptions() == ["Call the plumber", "Ring the client"])
	}

	@Test
	func sortDescriptorsRoundTripThroughTheTableColumnIdentifiers() {
		let sorts = [
			TaskSort(.description),
			TaskSort(.uda("estimate.hours"), order: .reverse),
			TaskSort(.urgency, order: .reverse),
		]
		let descriptors = sorts.map(\.descriptor)

		#expect(descriptors.map(\.key) == ["description", "uda.estimate.hours", "urgency"])
		#expect(descriptors.compactMap(TaskSort.init) == sorts)
		#expect(TaskSort(NSSortDescriptor(key: "gone", ascending: true)) == nil)
	}

	@Test
	func sortPutsEmptyValuesLastEitherWayAndAUDAInItsValuesOrder() throws {
		let rows = try ["L", "H", nil, "M"].enumerated().map { index, priority in
			try row(
				storedTask(
					index,
					priority ?? "None",
					workingSetID: index,
					priority.map { ["priority": $0] } ?? [:],
				),
			)
		}
		let descriptions = { (order: SortOrder) in
			rows.sorted(using: TaskSort(.uda("priority"), order: order)).map(\.task.description)
		}

		#expect(descriptions(.forward) == ["L", "M", "H", "None"])
		#expect(descriptions(.reverse) == ["H", "M", "L", "None"])
	}

	@Test
	func tiedTasksWithoutAnIDHoldTheirOrderAcrossSnapshots() async {
		let store = TestStore(initialState: ReplicaFeature.State(bookmark: Data())) {
			ReplicaFeature()
		} withDependencies: {
			$0.date.now = now
			$0.timeZone = .gmt
		}
		store.exhaustivity = .off
		let paint = storedTask(0, "Paint the fence", status: "completed", workingSetID: nil)
		let sweep = storedTask(1, "Sweep the yard", status: "completed", workingSetID: nil)
		await store.send(\.binding.sidebarSelection, [.view(.completed)])

		// Tied on Urgency and without IDs, so in UUID order whichever order the Replica reads them in.
		await store.send(.tasksLoaded(snapshot([sweep, paint])))
		#expect(store.state.rows.map(\.id) == [UUID(0), UUID(1)])
		await store.send(.tasksLoaded(snapshot([paint, sweep])))
		#expect(store.state.rows.map(\.id) == [UUID(0), UUID(1)])
	}

	@Test
	func waitingTaskMovesToPendingAsItsWaitPasses() async {
		let (tasks, continuation) = AsyncThrowingStream<TaskSnapshot, any Error>.makeStream()
		let clock = TestClock()
		let time = LockIsolated(now)
		let store = TestStore(initialState: ReplicaFeature.State(bookmark: Data())) {
			ReplicaFeature()
		} withDependencies: {
			$0.bookmarkClient.changes = { .finished }
			$0.bookmarkClient.grants = { [:] }
			$0.bookmarkClient.resolve = { _ in replicaDirectory }
			$0.continuousClock = clock
			$0.date = DateGenerator { time.value }
			$0.replicaClient.tasks = { _ in tasks }
			$0.taskrcClient.load = { _, _, _ in .finished }
			$0.timeZone = .gmt
		}
		store.exhaustivity = .off
		let call = storedTask(
			0,
			"Call the bank",
			workingSetID: 1,
			["wait": String(Int(now.timeIntervalSince1970) + 30)],
		)

		let task = await store.send(.fetchRequested)
		continuation.yield(snapshot([call]))
		await store.receive(\.tasksLoaded)
		#expect(store.state.rows.isEmpty)
		#expect(store.state.sidebar.views.map(\.count) == [0, 1, 0, 0])

		// Past `wait`, with nothing committed to the Replica.
		time.setValue(now.addingTimeInterval(60))
		await clock.advance(by: .seconds(60))
		await store.receive(\.timerTicked)
		#expect(store.state.rows.map(\.id) == [UUID(0)])

		continuation.finish()
		await task.cancel()
	}

	@Test
	func otherDataLocationIsReportedOnlyForAnAttachedTaskrc() {
		let taskrc = { (location: String) in
			Taskrc(path: taskrcFile.path(), environment: .fixture) { path, _ in
				Taskrc.File(contents: "data.location=\(location)", realPath: path)
			}
		}
		var state = ReplicaFeature.State(bookmark: Data())
		state.directory = replicaDirectory

		state.taskrc = TaskrcClient.Loaded(taskrc: taskrc("/Users/paul/.task/"), url: taskrcFile)
		#expect(state.otherDataLocation == nil)

		state.taskrc = TaskrcClient.Loaded(taskrc: taskrc("~/Sync/task"), url: taskrcFile)
		#expect(state.otherDataLocation == "/home/fixture/Sync/task")

		state.taskrc?.url = nil
		#expect(state.otherDataLocation == nil)
	}
}

/// When every test task was entered, so none has aged.
private let now = Date(timeIntervalSince1970: 1_790_000_000)

private let replicaDirectory = URL(filePath: "/Users/paul/.task", directoryHint: .isDirectory)

private let taskrcFile = URL(filePath: "/Users/paul/.taskrc")

extension AsyncStream where Element: Sendable {
	/// A stream of `element` alone.
	fileprivate static func finished(yielding element: Element) -> Self {
		Self { continuation in
			continuation.yield(element)
			continuation.finish()
		}
	}
}

/// A window on the Replica, showing `tasks` in the order given, as the table shows them on TW's
/// defaults.
private func loadedState(
	_ tasks: [StoredTask],
	selection: Set<UUID> = [],
) throws -> ReplicaFeature.State {
	var state = ReplicaFeature.State(bookmark: Data())
	state.allRows = try tasks.map { stored in
		let task = Models.Task(stored, udaTypes: Taskrc.defaults.udaTypes)
		return try row(stored, view: #require(task.flatMap { TaskView($0, at: now) }))
	}
	state.directory = replicaDirectory
	state.isReplicaOpen = true
	state.rows = IdentifiedArray(uniqueElements: state.allRows)
	state.selection = selection
	state.storedTasks = tasks
	state.taskrc = TaskrcClient.Loaded(taskrc: .defaults, url: nil)
	return state
}

/// `tasks` as the Replica's read number `readIndex`.
private func snapshot(_ tasks: [StoredTask], readIndex: Int = 0) -> TaskSnapshot {
	TaskSnapshot(readIndex: readIndex, tasks: tasks)
}

/// The planner a window on TW's defaults writes with.
private let planner = WritePlanner(taskrc: .defaults, timeZone: .gmt)

/// `stored` as the table shows it on TW's defaults.
private func row(
	_ stored: StoredTask,
	isBlocked: Bool = false,
	urgency: Double = 0,
	view: TaskView = .pending,
) throws -> TaskRow {
	let task = Models.Task(stored, udaTypes: Taskrc.defaults.udaTypes)
	return try TaskRow(
		isBlocked: isBlocked,
		task: #require(task),
		udaColumns: UDAColumn.all(in: .defaults),
		urgency: urgency,
		view: view,
	)
}

/// A task as the Replica stores it, entered at `now`.
private func storedTask(
	_ seed: Int,
	_ description: String,
	status: String = "pending",
	workingSetID: Int?,
	_ properties: [String: String] = [:],
) -> StoredTask {
	StoredTask(
		properties: properties.merging([
			"description": description,
			"entry": String(Int(now.timeIntervalSince1970)),
			"status": status,
		]) { $1 },
		uuid: UUID(seed).uuidString.lowercased(),
		workingSetID: workingSetID,
	)
}
