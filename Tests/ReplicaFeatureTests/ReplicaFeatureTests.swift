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
			$0.bookmarkClient.taskrc = { _ in pairedTaskrc.value }
			$0.date.now = now
			$0.taskrcClient.load = { taskrc, _ in
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
	func bulkDoneAsksOnceListingEveryChainItRepairs() async throws {
		// Beta and Beta 2 each break a chain of their own.
		let tasks = chain() + chain(from: 3, suffix: " 2")
		let initialState = try loadedState(tasks, selection: [UUID(1), UUID(4)])
		let store = TestStore(initialState: initialState) {
			ReplicaFeature()
		} withDependencies: {
			$0.date.now = now
			$0.timeZone = .gmt
		}

		await store.send(.doneButtonTapped) {
			$0.chainRepairPrompt = ReplicaFeature.ChainRepairPrompt(
				command: .done,
				ids: [UUID(1), UUID(4)],
				message: """
					“Alpha” would depend on “Gamma” instead of “Beta”.
					“Alpha 2” would depend on “Gamma 2” instead of “Beta 2”.
					""",
				title: "Repair 2 Dependency Chains?",
			)
		}
	}

	@Test
	func bulkDeleteOfInstancesAsksOnceForEachSeries() async throws {
		let plants = series(0, "Water plants", instances: [1, 2])
		let bins = series(3, "Take out bins", instances: [4])
		var initialState = try loadedState(
			plants.instances + bins.instances,
			selection: [UUID(1), UUID(2), UUID(4)],
		)
		initialState.storedTasks += [plants.template, bins.template]
		let store = TestStore(initialState: initialState) {
			ReplicaFeature()
		} withDependencies: {
			$0.date.now = now
			$0.timeZone = .gmt
		}

		await store.send(.deleteButtonTapped) {
			$0.seriesPrompt = ReplicaFeature.SeriesPrompt(
				choices: [
					ReplicaFeature.SeriesPrompt.Choice(description: "Water plants", id: UUID(0)),
					ReplicaFeature.SeriesPrompt.Choice(description: "Take out bins", id: UUID(3)),
				],
				command: .delete,
				ids: [UUID(1), UUID(2), UUID(4)],
			)
		}
	}

	@Test
	func bulkEditsNameTheirUndoPointAfterTheTasksTheyChange() async throws {
		let milk = storedTask(0, "Buy milk", workingSetID: 1, ["tag_home": "x"])
		let dog = storedTask(1, "Walk the dog", workingSetID: 2)
		let plans = LockIsolated<[WritePlan]>([])
		let undoNames = LockIsolated<[String]>([])
		let initialState = try loadedState([milk, dog], selection: [UUID(0), UUID(1)])
		let store = TestStore(initialState: initialState) {
			ReplicaFeature()
		} withDependencies: {
			$0.continuousClock = TestClock()
			$0.date.now = now
			$0.replicaClient.apply = { plan, name, _ in
				plans.withValue { $0.append(plan) }
				undoNames.withValue { $0.append(name) }
				return ApplyOutcome(isCommitted: true, snapshot: snapshot([milk, dog]))
			}
			$0.timeZone = .gmt
		}
		// The table's reads are other tests' business: this one is about the plans.
		store.exhaustivity = .off(showSkippedAssertions: false)

		await store.send(.inspectorFieldSubmitted([UUID(0), UUID(1)], .set("project", .string("Home"))))
		await store.receive(\.writeCommitted)
		await store.send(.inspectorFieldSubmitted([UUID(0), UUID(1)], .addTags(["errand", "shop"])))
		await store.receive(\.writeCommitted)
		// Only Buy milk has it.
		await store.send(.tagRemoveButtonTapped([UUID(0), UUID(1)], tag: "home"))
		await store.receive(\.writeCommitted)

		#expect(
			undoNames.value == ["Change Project of 2 Tasks", "Add Tags to 2 Tasks", "Remove Tag"],
		)
		#expect(
			try plans.value.last == planner.plan(
				.edit([UUID(0), UUID(1)], .removeTag("home")),
				tasks: [UUID(0): milk.properties, UUID(1): dog.properties],
				at: now,
			),
		)
		await store.finish()
	}

	@Test
	func bulkTagRemovalQueuedBehindAnAddTakesTheTagFromEveryTaskTheAddTagged() async throws {
		let milk = storedTask(0, "Buy milk", workingSetID: 1, ["tag_home": "x"])
		let dog = storedTask(1, "Walk the dog", workingSetID: 2)
		let dogHome = storedTask(1, "Walk the dog", workingSetID: 2, ["tag_home": "x"])
		let (commits, commit) = AsyncStream<Void>.makeStream()
		let plans = LockIsolated<[WritePlan]>([])
		let undoNames = LockIsolated<[String]>([])
		let initialState = try loadedState([milk, dog], selection: [UUID(0), UUID(1)])
		let store = TestStore(initialState: initialState) {
			ReplicaFeature()
		} withDependencies: {
			$0.continuousClock = TestClock()
			$0.date.now = now
			$0.replicaClient.apply = { plan, name, _ in
				plans.withValue { $0.append(plan) }
				undoNames.withValue { $0.append(name) }
				for await _ in commits {
					break
				}
				return ApplyOutcome(isCommitted: true, snapshot: snapshot([milk, dogHome]))
			}
			$0.timeZone = .gmt
		}
		// The table's reads are other tests' business: this one is about the plans.
		store.exhaustivity = .off(showSkippedAssertions: false)

		await store.send(.inspectorFieldSubmitted([UUID(0), UUID(1)], .addTags(["home"])))
		// Walk the dog doesn't have it yet, but will once the add ahead of it commits.
		await store.send(.tagRemoveButtonTapped([UUID(0), UUID(1)], tag: "home")) {
			$0.queuedWrites = [.edit([UUID(0), UUID(1)], .removeTag("home"))]
		}
		commit.yield()
		await store.receive(\.writeCommitted)
		commit.yield()
		await store.receive(\.writeCommitted)

		#expect(undoNames.value == ["Add Tag to 2 Tasks", "Remove Tag from 2 Tasks"])
		#expect(
			try plans.value.last == planner.plan(
				.edit([UUID(0), UUID(1)], .removeTag("home")),
				tasks: [UUID(0): milk.properties, UUID(1): dogHome.properties],
				at: now,
			),
		)
		commit.finish()
		await store.finish()
	}

	@Test
	func bulkTagRemovalWritesEverySelectedTaskAtOnceAndKeepsThemUntilTheSelectionChanges(
	) async throws {
		let milk = storedTask(0, "Buy milk", workingSetID: 1, ["tag_home": "x"])
		let dog = storedTask(1, "Walk the dog", workingSetID: 2, ["tag_home": "x"])
		let cat = storedTask(2, "Feed the cat", workingSetID: 3, ["tag_home": "x"])
		let milkUntagged = storedTask(0, "Buy milk", workingSetID: 1)
		let dogUntagged = storedTask(1, "Walk the dog", workingSetID: 2)
		let plans = LockIsolated<[WritePlan]>([])
		var initialState = try loadedState([milk, dog, cat], selection: [UUID(0), UUID(1)])
		initialState.sidebarSelection = [.tag("home")]
		let store = TestStore(initialState: initialState) {
			ReplicaFeature()
		} withDependencies: {
			$0.continuousClock = TestClock()
			$0.date.now = now
			$0.replicaClient.apply = { plan, _, _ in
				plans.withValue { $0.append(plan) }
				return ApplyOutcome(isCommitted: true, snapshot: snapshot([milkUntagged, dogUntagged, cat]))
			}
			$0.timeZone = .gmt
		}

		await store.send(.tagRemoveButtonTapped([UUID(0), UUID(1)], tag: "home")) {
			$0.keptTasks = [UUID(0), UUID(1)]
			$0.writeProgress = .running
		}
		// Untagged, they're no longer in the sidebar's tag, yet they stay, selected.
		await store.receive(\.tasksLoaded) {
			$0.allRows = try [row(cat, urgency: 0.8), row(milkUntagged), row(dogUntagged)]
			$0.rows = try [row(cat, urgency: 0.8), row(milkUntagged), row(dogUntagged)]
			$0.storedTasks = [milkUntagged, dogUntagged, cat]
		}
		await store.receive(\.writeCommitted) {
			$0.writeProgress = nil
		}
		#expect(
			try plans.value == [
				planner.plan(
					.edit([UUID(0), UUID(1)], .removeTag("home")),
					tasks: [UUID(0): milk.properties, UUID(1): dog.properties, UUID(2): cat.properties],
					at: now,
				),
			],
		)

		await store.send(\.binding.selection, [UUID(2)]) {
			$0.inspectedTask = UUID(2)
			$0.keptTasks = []
			$0.rows = try [row(cat, urgency: 0.8)]
			$0.selection = [UUID(2)]
		}
		await store.finish()
	}

	@Test
	func chainRepairPromptHoldsBackEveryOtherWrite() throws {
		var state = try loadedState(chain(), selection: [UUID(1)])
		state.redoName = "Complete Task"
		state.undoName = "Complete Task"
		#expect(state.canCreateTask)
		#expect(state.canRedo)
		#expect(state.canUndo)

		state.chainRepairPrompt = ReplicaFeature.ChainRepairPrompt(
			command: .done,
			ids: [UUID(1)],
			message: "",
			title: "",
		)

		#expect(!state.canCreateTask)
		#expect(!state.canRedo)
		#expect(!state.canUndo)
		#expect(state.enabledCommands.isEmpty)
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
	func doneThatBreaksAChainAsksBeforeRepairingIt() async throws {
		let tasks = chain()
		let plans = LockIsolated<[WritePlan]>([])
		let initialState = try loadedState(tasks, selection: [UUID(1)])
		let store = TestStore(initialState: initialState) {
			ReplicaFeature()
		} withDependencies: {
			$0.continuousClock = TestClock()
			$0.date.now = now
			$0.replicaClient.apply = { plan, _, _ in
				plans.withValue { $0.append(plan) }
				return ApplyOutcome(isCommitted: true, snapshot: snapshot(tasks))
			}
			$0.timeZone = .gmt
		}
		let prompt = ReplicaFeature.ChainRepairPrompt(
			command: .done,
			ids: [UUID(1)],
			message: "“Alpha” would depend on “Gamma” instead of “Beta”.",
			title: "Repair the Dependency Chain?",
		)

		await store.send(.doneButtonTapped) {
			$0.chainRepairPrompt = prompt
		}
		await store.send(.chainRepairDismissed) {
			$0.chainRepairPrompt = nil
		}
		#expect(plans.value.isEmpty)

		await store.send(.doneButtonTapped) {
			$0.chainRepairPrompt = prompt
		}
		await store.send(.repairChainButtonTapped) {
			$0.chainRepairPrompt = nil
			$0.leavingTasks = [UUID(1)]
			$0.rows = try [row(tasks[0]), row(tasks[2])]
			$0.selection = []
			$0.writeProgress = .running
		}
		// The table's reads are other tests' business: this one is about the plan.
		store.exhaustivity = .off(showSkippedAssertions: false)
		await store.receive(\.writeCommitted)
		#expect(
			try plans.value == [
				planner.plan(
					.complete([UUID(1)], chains: .repair),
					tasks: [
						UUID(0): tasks[0].properties,
						UUID(1): tasks[1].properties,
						UUID(2): tasks[2].properties,
					],
					at: now,
				),
			],
		)
		await store.finish()
	}

	@Test
	func deleteOfAnInstanceAsksWhetherToTakeItsSeries() async throws {
		let plants = series(0, "Water plants", instances: [1, 2])
		let plans = LockIsolated<[WritePlan]>([])
		let undoNames = LockIsolated<[String]>([])
		var initialState = try loadedState(plants.instances, selection: [UUID(1)])
		initialState.storedTasks.append(plants.template)
		let stored = initialState.storedTasks
		let store = TestStore(initialState: initialState) {
			ReplicaFeature()
		} withDependencies: {
			$0.continuousClock = TestClock()
			$0.date.now = now
			$0.replicaClient.apply = { plan, name, _ in
				plans.withValue { $0.append(plan) }
				undoNames.withValue { $0.append(name) }
				return ApplyOutcome(isCommitted: true, snapshot: snapshot(stored))
			}
			$0.timeZone = .gmt
		}

		await store.send(.deleteButtonTapped) {
			$0.seriesPrompt = ReplicaFeature.SeriesPrompt(
				choices: [ReplicaFeature.SeriesPrompt.Choice(description: "Water plants", id: UUID(0))],
				command: .delete,
				ids: [UUID(1)],
			)
		}
		await store.send(.seriesChoiceChanged(UUID(0), includesSeries: true)) {
			$0.seriesPrompt?.choices[id: UUID(0)]?.includesSeries = true
		}
		await store.send(.seriesDeleteButtonTapped) {
			// Everything the Delete takes, the hidden template included.
			$0.leavingTasks = [UUID(0), UUID(1), UUID(2)]
			$0.rows = []
			$0.selection = []
			$0.seriesPrompt = nil
			$0.writeProgress = .running
		}
		// The table's reads are other tests' business: this one is about the plan.
		store.exhaustivity = .off(showSkippedAssertions: false)
		await store.receive(\.writeCommitted)
		#expect(
			try plans.value == [
				planner.plan(
					.delete([UUID(1)], chains: .leave, series: [UUID(0)]),
					tasks: properties(of: stored),
					at: now,
				),
			],
		)
		#expect(undoNames.value == ["Delete Series"])
		await store.finish()
	}

	/// `task delete` asks only under `prompt`, and reads anything else as a boolean.
	@Test(arguments: [("no", false), ("yes", true)])
	func deleteOfAnInstanceFollowsTheTaskrcWithoutAsking(
		confirmation: String,
		deletesSeries: Bool,
	) async throws {
		let plants = series(0, "Water plants", instances: [1, 2])
		let taskrc = Taskrc(path: taskrcFile.path(), environment: .fixture) { path in
			Taskrc.File(contents: "recurrence.confirmation=\(confirmation)", realPath: path)
		}
		let plans = LockIsolated<[WritePlan]>([])
		var initialState = try loadedState(plants.instances, selection: [UUID(1)])
		initialState.storedTasks.append(plants.template)
		let stored = initialState.storedTasks
		initialState.taskrc = TaskrcClient.Loaded(taskrc: taskrc, url: taskrcFile)
		let store = TestStore(initialState: initialState) {
			ReplicaFeature()
		} withDependencies: {
			$0.continuousClock = TestClock()
			$0.date.now = now
			$0.replicaClient.apply = { plan, _, _ in
				plans.withValue { $0.append(plan) }
				return ApplyOutcome(isCommitted: true, snapshot: snapshot(stored))
			}
			$0.timeZone = .gmt
		}
		// The table's reads are other tests' business: this one is about the plan.
		store.exhaustivity = .off(showSkippedAssertions: false)

		await store.send(.deleteButtonTapped)
		await store.receive(\.writeCommitted)

		#expect(
			try plans.value == [
				WritePlanner(taskrc: taskrc, timeZone: .gmt).plan(
					.delete([UUID(1)], chains: .leave, series: deletesSeries ? [UUID(0)] : []),
					tasks: properties(of: stored),
					at: now,
				),
			],
		)
		await store.finish()
	}

	@Test
	func deletingASeriesAsksAboutTheChainsItsSiblingsBreak() async throws {
		let plants = series(0, "Water plants", instances: [1, 2])
		let uuid = { (seed: Int) in UUID(seed).uuidString.lowercased() }
		// Alpha depends on the sibling, which depends on Gamma.
		var instances = plants.instances
		instances[1].properties.merge(["dep_\(uuid(4))": "x", "depends": uuid(4)]) { $1 }
		let alpha = storedTask(3, "Alpha", workingSetID: 4, ["dep_\(uuid(2))": "x", "depends": uuid(2)])
		let gamma = storedTask(4, "Gamma", workingSetID: 5)
		let plans = LockIsolated<[WritePlan]>([])
		var initialState = try loadedState(instances + [alpha, gamma], selection: [UUID(1)])
		initialState.storedTasks.append(plants.template)
		let stored = initialState.storedTasks
		let store = TestStore(initialState: initialState) {
			ReplicaFeature()
		} withDependencies: {
			$0.continuousClock = TestClock()
			$0.date.now = now
			$0.replicaClient.apply = { plan, _, _ in
				plans.withValue { $0.append(plan) }
				return ApplyOutcome(isCommitted: true, snapshot: snapshot(stored))
			}
			$0.timeZone = .gmt
		}

		// Deleting only the instance breaks no chain.
		await store.send(.deleteButtonTapped) {
			$0.seriesPrompt = ReplicaFeature.SeriesPrompt(
				choices: [ReplicaFeature.SeriesPrompt.Choice(description: "Water plants", id: UUID(0))],
				command: .delete,
				ids: [UUID(1)],
			)
		}
		await store.send(.seriesChoiceChanged(UUID(0), includesSeries: true)) {
			$0.seriesPrompt?.chainRepairMessage =
				"“Alpha” would depend on “Gamma” instead of “Water plants”."
			$0.seriesPrompt?.choices[id: UUID(0)]?.includesSeries = true
		}
		await store.send(.repairChainsCheckboxChanged(repairsChains: false)) {
			$0.seriesPrompt?.repairsChains = false
		}
		// The table's reads are other tests' business: this one is about the plan.
		store.exhaustivity = .off(showSkippedAssertions: false)
		await store.send(.seriesDeleteButtonTapped)
		await store.receive(\.writeCommitted)

		#expect(
			try plans.value == [
				planner.plan(
					.delete([UUID(1)], chains: .leave, series: [UUID(0)]),
					tasks: properties(of: stored),
					at: now,
				),
			],
		)
		await store.finish()
	}

	@Test
	func bulkEditOfInstancesAsksOnceForEachSeriesAndWritesTheChoices() async throws {
		let plants = series(0, "Water plants", instances: [1, 2])
		let bins = series(3, "Take out bins", instances: [4])
		let plans = LockIsolated<[WritePlan]>([])
		var initialState = try loadedState(
			plants.instances + bins.instances,
			selection: [UUID(1), UUID(2), UUID(4)],
		)
		initialState.storedTasks += [plants.template, bins.template]
		let stored = initialState.storedTasks
		let store = TestStore(initialState: initialState) {
			ReplicaFeature()
		} withDependencies: {
			$0.continuousClock = TestClock()
			$0.date.now = now
			$0.replicaClient.apply = { plan, _, _ in
				plans.withValue { $0.append(plan) }
				return ApplyOutcome(isCommitted: true, snapshot: snapshot(stored))
			}
			$0.timeZone = .gmt
		}
		let edit = TaskEdit.set("project", .string("Home"))
		let ids = [UUID(1), UUID(2), UUID(4)]

		await store.send(.inspectorFieldSubmitted(ids, edit)) {
			$0.keptTasks = Set(ids)
			$0.seriesPrompt = ReplicaFeature.SeriesPrompt(
				choices: [
					ReplicaFeature.SeriesPrompt.Choice(description: "Water plants", id: UUID(0)),
					ReplicaFeature.SeriesPrompt.Choice(description: "Take out bins", id: UUID(3)),
				],
				command: .edit(edit),
				ids: ids,
			)
		}
		await store.send(.seriesChoiceChanged(UUID(3), includesSeries: true)) {
			$0.seriesPrompt?.choices[id: UUID(3)]?.includesSeries = true
		}
		// The table's reads are other tests' business: this one is about the plan.
		store.exhaustivity = .off(showSkippedAssertions: false)
		await store.send(.seriesChangeButtonTapped)
		await store.receive(\.writeCommitted)

		#expect(
			try plans.value == [
				planner.plan(.edit(ids, edit, series: [UUID(3)]), tasks: properties(of: stored), at: now),
			],
		)
		await store.finish()
	}

	/// The inspector sends a value a task already shows, and a date never takes the Series.
	@Test(arguments: [
		TaskEdit.set("description", .string("Water plants")),
		.setInput("due", text: "2030-01-01"),
	])
	func editThatLeavesTheSeriesAloneAsksNothing(edit: TaskEdit) async throws {
		let plants = series(0, "Water plants", instances: [1, 2])
		let plans = LockIsolated<[WritePlan]>([])
		var initialState = try loadedState(plants.instances, selection: [UUID(1)])
		initialState.storedTasks.append(plants.template)
		let stored = initialState.storedTasks
		let store = TestStore(initialState: initialState) {
			ReplicaFeature()
		} withDependencies: {
			$0.continuousClock = TestClock()
			$0.date.now = now
			$0.replicaClient.apply = { plan, _, _ in
				plans.withValue { $0.append(plan) }
				return ApplyOutcome(isCommitted: true, snapshot: snapshot(stored))
			}
			$0.timeZone = .gmt
		}
		// The table's reads are other tests' business: this one is about the plan.
		store.exhaustivity = .off(showSkippedAssertions: false)

		await store.send(.inspectorFieldSubmitted([UUID(1)], edit))
		await store.receive(\.writeCommitted)

		#expect(
			try plans.value == [
				planner.plan(.edit([UUID(1)], edit), tasks: properties(of: stored), at: now),
			],
		)
		await store.finish()
	}

	/// As `task modify` reads it: only `prompt` asks.
	@Test(arguments: [("no", false), ("yes", true)])
	func editOfAnInstanceFollowsTheTaskrcWithoutAsking(
		confirmation: String,
		includesSeries: Bool,
	) async throws {
		let plants = series(0, "Water plants", instances: [1, 2])
		let taskrc = Taskrc(path: taskrcFile.path(), environment: .fixture) { path in
			Taskrc.File(contents: "recurrence.confirmation=\(confirmation)", realPath: path)
		}
		let plans = LockIsolated<[WritePlan]>([])
		var initialState = try loadedState(plants.instances, selection: [UUID(1)])
		initialState.storedTasks.append(plants.template)
		let stored = initialState.storedTasks
		initialState.taskrc = TaskrcClient.Loaded(taskrc: taskrc, url: taskrcFile)
		let store = TestStore(initialState: initialState) {
			ReplicaFeature()
		} withDependencies: {
			$0.continuousClock = TestClock()
			$0.date.now = now
			$0.replicaClient.apply = { plan, _, _ in
				plans.withValue { $0.append(plan) }
				return ApplyOutcome(isCommitted: true, snapshot: snapshot(stored))
			}
			$0.timeZone = .gmt
		}
		// The table's reads are other tests' business: this one is about the plan.
		store.exhaustivity = .off(showSkippedAssertions: false)
		let edit = TaskEdit.addTags(["garden"])

		await store.send(.inspectorFieldSubmitted([UUID(1)], edit))
		await store.receive(\.writeCommitted)

		#expect(
			try plans.value == [
				WritePlanner(taskrc: taskrc, timeZone: .gmt).plan(
					.edit([UUID(1)], edit, series: includesSeries ? [UUID(0)] : []),
					tasks: properties(of: stored),
					at: now,
				),
			],
		)
		await store.finish()
	}

	/// As `task modify` offers it: the selected instance may already have the value its Series lacks,
	/// and a sibling the view hides is still in the Series.
	@Test
	func editOfAnInstanceAsksWhereOnlyItsHiddenSiblingWouldChange() async throws {
		var plants = series(0, "Water plants", instances: [1, 2])
		plants.instances[0].properties.merge(["tag_garden": "x", "tags": "garden"]) { $1 }
		plants.template.properties.merge(["tag_garden": "x", "tags": "garden"]) { $1 }
		let plans = LockIsolated<[WritePlan]>([])
		var initialState = try loadedState([plants.instances[0]], selection: [UUID(1)])
		initialState.storedTasks += [plants.instances[1], plants.template]
		let stored = initialState.storedTasks
		let store = TestStore(initialState: initialState) {
			ReplicaFeature()
		} withDependencies: {
			$0.continuousClock = TestClock()
			$0.date.now = now
			$0.replicaClient.apply = { plan, _, _ in
				plans.withValue { $0.append(plan) }
				return ApplyOutcome(isCommitted: true, snapshot: snapshot(stored))
			}
			$0.timeZone = .gmt
		}
		let edit = TaskEdit.addTags(["garden"])

		await store.send(.inspectorFieldSubmitted([UUID(1)], edit)) {
			$0.keptTasks = [UUID(1)]
			$0.seriesPrompt = ReplicaFeature.SeriesPrompt(
				choices: [ReplicaFeature.SeriesPrompt.Choice(description: "Water plants", id: UUID(0))],
				command: .edit(edit),
				ids: [UUID(1)],
			)
		}
		await store.send(.seriesChoiceChanged(UUID(0), includesSeries: true)) {
			$0.seriesPrompt?.choices[id: UUID(0)]?.includesSeries = true
		}
		// The table's reads are other tests' business: this one is about the plan.
		store.exhaustivity = .off(showSkippedAssertions: false)
		await store.send(.seriesChangeButtonTapped)
		await store.receive(\.writeCommitted)

		let applied = try #require(plans.value.first).applied(to: properties(of: stored))
		#expect(applied[UUID(2)]?["tag_garden"] == "x")
		await store.finish()
	}

	/// A sibling can't depend on itself, so the Series can't take the edit, but it's still offered
	/// rather than quietly dropped.
	@Test
	func editOfAnInstanceTheSeriesCantTakeStillAsks() async throws {
		let plants = series(0, "Water plants", instances: [1, 2])
		var initialState = try loadedState(plants.instances, selection: [UUID(1)])
		initialState.storedTasks.append(plants.template)
		let store = TestStore(initialState: initialState) {
			ReplicaFeature()
		} withDependencies: {
			$0.date.now = now
			$0.timeZone = .gmt
		}
		let edit = TaskEdit.addDependency(UUID(2))

		await store.send(.inspectorFieldSubmitted([UUID(1)], edit)) {
			$0.keptTasks = [UUID(1)]
			$0.seriesPrompt = ReplicaFeature.SeriesPrompt(
				choices: [ReplicaFeature.SeriesPrompt.Choice(description: "Water plants", id: UUID(0))],
				command: .edit(edit),
				ids: [UUID(1)],
			)
		}
	}

	/// Taking the Series reports why it can't, where `task` would refuse the whole command.
	@Test
	func editOfAnInstanceTheSeriesCantTakeFailsWhereTheTaskrcTakesIt() async throws {
		let plants = series(0, "Water plants", instances: [1, 2])
		let taskrc = Taskrc(path: taskrcFile.path(), environment: .fixture) { path in
			Taskrc.File(contents: "recurrence.confirmation=yes", realPath: path)
		}
		var initialState = try loadedState(plants.instances, selection: [UUID(1)])
		initialState.storedTasks.append(plants.template)
		initialState.taskrc = TaskrcClient.Loaded(taskrc: taskrc, url: taskrcFile)
		let store = TestStore(initialState: initialState) {
			ReplicaFeature()
		} withDependencies: {
			$0.continuousClock = TestClock()
			$0.date.now = now
			$0.timeZone = .gmt
		}
		store.exhaustivity = .off(showSkippedAssertions: false)

		await store.send(.inspectorFieldSubmitted([UUID(1)], .addDependency(UUID(2))))
		await store.receive(\.writeFailed) {
			$0.writeProgress = .failed(ReplicaFeature.WriteFailure(
				reason: WritePlanError.selfDependency(UUID(2)).localizedDescription,
				retry: nil,
				title: "Couldn't Add Dependency",
			))
		}
	}

	/// Asked as it starts, so an edit queued behind a running write asks once that write ends, and
	/// the edits queued behind the question wait for the answer.
	@Test
	func editQueuedBehindAWriteAsksAboutItsSeriesOnceItStarts() async throws {
		let plants = series(0, "Water plants", instances: [1, 2])
		let plans = LockIsolated<[WritePlan]>([])
		var initialState = try loadedState(plants.instances, selection: [UUID(1)])
		initialState.storedTasks.append(plants.template)
		initialState.writeProgress = .running
		let stored = initialState.storedTasks
		let store = TestStore(initialState: initialState) {
			ReplicaFeature()
		} withDependencies: {
			$0.continuousClock = TestClock()
			$0.date.now = now
			$0.replicaClient.apply = { plan, _, _ in
				plans.withValue { $0.append(plan) }
				return ApplyOutcome(isCommitted: true, snapshot: snapshot(stored))
			}
			$0.timeZone = .gmt
		}
		let project = TaskEdit.set("project", .string("Home"))
		let tag = TaskEdit.addTags(["garden"])

		await store.send(.inspectorFieldSubmitted([UUID(1)], project)) {
			$0.keptTasks = [UUID(1)]
			$0.queuedWrites = [.edit([UUID(1)], project)]
		}
		await store.send(.writeCommitted) {
			$0.queuedWrites = []
			$0.seriesPrompt = ReplicaFeature.SeriesPrompt(
				choices: [ReplicaFeature.SeriesPrompt.Choice(description: "Water plants", id: UUID(0))],
				command: .edit(project),
				ids: [UUID(1)],
			)
			$0.writeProgress = nil
		}
		await store.send(.inspectorFieldSubmitted([UUID(1)], tag)) {
			$0.queuedWrites = [.edit([UUID(1)], tag)]
		}
		// The table's reads are other tests' business: this one is about the plans.
		store.exhaustivity = .off(showSkippedAssertions: false)
		await store.send(.seriesChangeButtonTapped)
		await store.receive(\.writeCommitted)
		await store.send(.seriesChoiceChanged(UUID(0), includesSeries: true))
		await store.send(.seriesChangeButtonTapped)
		await store.receive(\.writeCommitted)

		let tasks = properties(of: stored)
		#expect(
			try plans.value == [
				planner.plan(.edit([UUID(1)], project), tasks: tasks, at: now),
				planner.plan(.edit([UUID(1)], tag, series: [UUID(0)]), tasks: tasks, at: now),
			],
		)
		await store.finish()
	}

	@Test
	func doneClosesTasksInIDOrderWhateverTheTableOrder() async throws {
		let tasks = chain()
		// Gamma above Beta, as a sort by description descending would show them.
		let initialState = try loadedState(tasks.reversed(), selection: [UUID(1), UUID(2)])
		let store = TestStore(initialState: initialState) {
			ReplicaFeature()
		} withDependencies: {
			$0.date.now = now
			$0.timeZone = .gmt
		}

		// Beta first, while Gamma is open to take its dependent. Gamma first would leave Beta nothing
		// open to repair onto, so nothing to ask.
		await store.send(.doneButtonTapped) {
			$0.chainRepairPrompt = ReplicaFeature.ChainRepairPrompt(
				command: .done,
				ids: [UUID(1), UUID(2)],
				message: "“Alpha” would depend on “Gamma” instead of “Beta”.",
				title: "Repair the Dependency Chain?",
			)
		}
	}

	@Test
	func doneRepairsAChainWithoutAskingWhereTheTaskrcSaysNotTo() async throws {
		let tasks = chain()
		let taskrc = Taskrc(path: taskrcFile.path(), environment: .fixture) { path in
			Taskrc.File(contents: "dependency.confirmation=off", realPath: path)
		}
		let plans = LockIsolated<[WritePlan]>([])
		var initialState = try loadedState(tasks, selection: [UUID(1)])
		initialState.taskrc = TaskrcClient.Loaded(taskrc: taskrc, url: taskrcFile)
		let store = TestStore(initialState: initialState) {
			ReplicaFeature()
		} withDependencies: {
			$0.continuousClock = TestClock()
			$0.date.now = now
			$0.replicaClient.apply = { plan, _, _ in
				plans.withValue { $0.append(plan) }
				return ApplyOutcome(isCommitted: true, snapshot: snapshot(tasks))
			}
			$0.timeZone = .gmt
		}

		await store.send(.doneButtonTapped) {
			$0.leavingTasks = [UUID(1)]
			$0.rows = try [row(tasks[0]), row(tasks[2])]
			$0.selection = []
			$0.writeProgress = .running
		}
		// The table's reads are other tests' business: this one is about the plan.
		store.exhaustivity = .off(showSkippedAssertions: false)
		await store.receive(\.writeCommitted)
		#expect(plans.value.first?.repairedChains.map(\.blocked) == [[UUID(0)]])
		await store.finish()
	}

	@Test
	func doneCompletesTheSelectedTaskAndItLeavesTheList() async throws {
		let milk = storedTask(0, "Buy milk", workingSetID: 1)
		let dog = storedTask(1, "Walk the dog", workingSetID: 2)
		let milkDone = storedTask(0, "Buy milk", status: "completed", workingSetID: 1)
		let plans = LockIsolated<[WritePlan]>([])
		let undoNames = LockIsolated<[String]>([])
		let initialState = try loadedState([milk, dog], selection: [UUID(0)])
		let store = TestStore(initialState: initialState) {
			ReplicaFeature()
		} withDependencies: {
			$0.continuousClock = TestClock()
			$0.date.now = now
			$0.replicaClient.apply = { plan, name, _ in
				plans.withValue { $0.append(plan) }
				undoNames.withValue { $0.append(name) }
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
		#expect(undoNames.value == ["Complete Task"])
		#expect(
			try plans.value == [
				planner.plan(
					.complete([UUID(0)], chains: .leave),
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
			$0.replicaClient.apply = { plan, _, _ in
				plans.withValue { $0.append(plan) }
				return ApplyOutcome(isCommitted: true, snapshot: snapshot([milkUntagged, dog]))
			}
			$0.timeZone = .gmt
		}

		await store.send(\.binding.selection, [UUID(0)]) {
			$0.inspectedTask = UUID(0)
			$0.selection = [UUID(0)]
		}
		await store.send(.tagRemoveButtonTapped([UUID(0)], tag: "home")) {
			$0.keptTasks = [UUID(0)]
			$0.writeProgress = .running
		}
		// Untagged, it's no longer in the sidebar's tag, yet it stays, selected.
		await store.receive(\.tasksLoaded) {
			$0.allRows = try [row(dog, urgency: 0.8), row(milkUntagged)]
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
			$0.keptTasks = []
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
			$0.replicaClient.apply = { plan, _, _ in
				plans.withValue { $0.append(plan) }
				for await _ in commits {
					break
				}
				return ApplyOutcome(isCommitted: true, snapshot: snapshot([milkHome]))
			}
			$0.timeZone = .gmt
		}
		store.exhaustivity = .off(showSkippedAssertions: false)

		await store.send(.inspectorFieldSubmitted([UUID(0)], .set("project", .string("Home")))) {
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
	func editDuringAChainRepairPromptWaitsForTheAnswer() async throws {
		let tasks = chain()
		let plans = LockIsolated<[WritePlan]>([])
		var initialState = try loadedState(tasks, selection: [UUID(1)])
		initialState.chainRepairPrompt = ReplicaFeature.ChainRepairPrompt(
			command: .done,
			ids: [UUID(1)],
			message: "",
			title: "",
		)
		let store = TestStore(initialState: initialState) {
			ReplicaFeature()
		} withDependencies: {
			$0.continuousClock = TestClock()
			$0.date.now = now
			$0.replicaClient.apply = { plan, _, _ in
				plans.withValue { $0.append(plan) }
				return ApplyOutcome(isCommitted: true, snapshot: snapshot(tasks))
			}
			$0.timeZone = .gmt
		}
		let edit = TaskEdit.set("description", .string("Beta, renamed"))

		await store.send(.inspectorFieldSubmitted([UUID(1)], edit)) {
			$0.keptTasks = [UUID(1)]
			$0.queuedWrites = [.edit([UUID(1)], edit)]
		}
		#expect(plans.value.isEmpty)

		await store.send(.chainRepairDismissed) {
			$0.chainRepairPrompt = nil
			$0.queuedWrites = []
			$0.writeProgress = .running
		}
		store.exhaustivity = .off(showSkippedAssertions: false)
		await store.receive(\.writeCommitted)
		#expect(plans.value.count == 1)
	}

	@Test
	func editQueuedBehindAChainRepairPromptDoesNotKeepTheTaskItCloses() async throws {
		let tasks = chain()
		var closed = tasks
		closed[1].properties["status"] = "completed"
		var initialState = try loadedState(tasks, selection: [UUID(1)])
		initialState.chainRepairPrompt = ReplicaFeature.ChainRepairPrompt(
			command: .done,
			ids: [UUID(1)],
			message: "",
			title: "",
		)
		let store = TestStore(initialState: initialState) {
			ReplicaFeature()
		} withDependencies: {
			$0.continuousClock = TestClock()
			$0.date.now = now
			$0.replicaClient.apply = { [closed] _, _, _ in
				ApplyOutcome(isCommitted: true, snapshot: snapshot(closed))
			}
			$0.timeZone = .gmt
		}
		let edit = TaskEdit.set("description", .string("Beta, renamed"))

		await store.send(.inspectorFieldSubmitted([UUID(1)], edit)) {
			$0.keptTasks = [UUID(1)]
			$0.queuedWrites = [.edit([UUID(1)], edit)]
		}

		store.exhaustivity = .off(showSkippedAssertions: false)
		await store.send(.repairChainButtonTapped)
		await store.receive(\.writeCommitted)
		await store.receive(\.writeCommitted)

		#expect(store.state.keptTasks.isEmpty)
		#expect(Array(store.state.rows.ids) == [UUID(0), UUID(2)])
	}

	@Test
	func editQueuedBehindAChainRepairPromptKeepsTheTaskAFailedCloseLeavesOpen() async throws {
		var tasks = chain()
		tasks[1].properties["project"] = "Home"
		var edited = tasks
		edited[1].properties["project"] = nil
		let attempts = LockIsolated(0)
		var initialState = try loadedState(tasks, selection: [UUID(1)])
		initialState.chainRepairPrompt = ReplicaFeature.ChainRepairPrompt(
			command: .done,
			ids: [UUID(1)],
			message: "",
			title: "",
		)
		initialState.sidebarSelection = [.project("Home")]
		let store = TestStore(initialState: initialState) {
			ReplicaFeature()
		} withDependencies: {
			$0.continuousClock = TestClock()
			$0.date.now = now
			$0.replicaClient.apply = { [edited] _, _, _ in
				let attempt = attempts.withValue {
					$0 += 1
					return $0
				}
				guard attempt > 1 else {
					throw ReplicaError.failed("The disk is full.")
				}
				return ApplyOutcome(isCommitted: true, snapshot: snapshot(edited))
			}
			$0.timeZone = .gmt
		}
		// Moves the task out of the Home view, which only the keep holds it in.
		let edit = TaskEdit.set("project", nil)

		await store.send(.inspectorFieldSubmitted([UUID(1)], edit)) {
			$0.keptTasks = [UUID(1)]
			$0.queuedWrites = [.edit([UUID(1)], edit)]
		}

		store.exhaustivity = .off(showSkippedAssertions: false)
		await store.send(.repairChainButtonTapped)
		await store.receive(\.writeFailed)
		await store.send(.writeFailureDismissed)
		await store.receive(\.writeCommitted)

		// Still open, so still shown until the selection changes, as any edited task is.
		#expect(store.state.keptTasks == [UUID(1)])
		#expect(Array(store.state.rows.ids) == [UUID(1)])
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
			$0.replicaClient.apply = { plan, _, _ in
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
			$0.replicaClient.apply = { plan, _, _ in
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
			let taskrc = Taskrc(path: taskrcFile.path(), environment: .fixture) { path in
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
			$0.replicaClient.apply = { _, _, _ in ApplyOutcome(isCommitted: true, snapshot: snapshot([])) }
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
			$0.replicaClient.apply = { _, _, _ in
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
			$0.replicaClient.apply = { plan, _, _ in
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
				== planner.plan(
					.complete([UUID(0)], chains: .leave),
					tasks: [UUID(0): milkStarted.properties],
					at: now,
				),
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
			$0.replicaClient.apply = { _, _, _ in
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
		await store.receive(\.writeFailed) {
			$0.writeProgress = .failed(
				ReplicaFeature.WriteFailure(
					reason: "The Replica kept changing while it was written to.",
					retry: .write(.complete([UUID(0)], chains: .leave), at: now),
					title: "Couldn't Complete Task",
				),
			)
		}
		#expect(attempts.value == 3)
		// Cancel drops it, and the task it dropped comes back.
		await store.send(.writeFailureDismissed) {
			$0.leavingTasks = []
			$0.rows = try [row(milk)]
			$0.writeProgress = nil
		}
		await store.finish()
	}

	@Test
	func failedWriteIsReportedAndTryAgainPlansItAgainWithTheSameUUIDAndTime() async throws {
		let milk = storedTask(0, "Buy milk", workingSetID: 1)
		let plans = LockIsolated<[WritePlan]>([])
		var initialState = try loadedState([])
		initialState.sidebarSelection = [.view(.pending)]
		let store = TestStore(initialState: initialState) {
			ReplicaFeature()
		} withDependencies: {
			$0.continuousClock = TestClock()
			$0.date.now = now
			$0.replicaClient.apply = { plan, _, _ in
				let attempt = plans.withValue {
					$0.append(plan)
					return $0.count
				}
				guard attempt > 1 else {
					throw ReplicaError.busy
				}
				return ApplyOutcome(isCommitted: true, snapshot: snapshot([milk]))
			}
			$0.timeZone = .gmt
			$0.uuid = .incrementing
		}

		await store.send(.newTaskDescriptionSubmitted("Buy milk")) {
			$0.creatingTask = UUID(0)
			$0.writeProgress = .running
		}
		await store.receive(\.writeFailed) {
			$0.writeProgress = .failed(
				ReplicaFeature.WriteFailure(
					reason: "The Replica is busy. A `task` command may be holding it.",
					retry: .write(.create(UUID(0), description: "Buy milk"), at: now),
					title: "Couldn't Create Task",
				),
			)
		}
		store.dependencies.date.now = now.addingTimeInterval(3_600)
		await store.send(.writeFailureTryAgainButtonTapped) {
			$0.writeProgress = .running
		}
		await store.receive(\.tasksLoaded) {
			$0.allRows = try [row(milk)]
			$0.rows = try [row(milk)]
			$0.storedTasks = [milk]
		}
		await store.receive(\.writeCommitted) {
			$0.creatingTask = nil
			$0.focusesDescription = true
			$0.inspectedTask = UUID(0)
			$0.selection = [UUID(0)]
			$0.writeProgress = nil
		}
		// Stamped with the same `entry` and `modified`, an hour on.
		#expect(plans.value.count == 2)
		#expect(plans.value.first == plans.value.last)
		await store.finish()
	}

	@Test
	func failedUndoIsReportedAndTryAgainUndoesAgain() async throws {
		let milk = storedTask(0, "Buy milk", workingSetID: 1)
		let attempts = LockIsolated(0)
		var initialState = try loadedState([milk])
		initialState.undoName = "Complete Task"
		let store = TestStore(initialState: initialState) {
			ReplicaFeature()
		} withDependencies: {
			$0.date.now = now
			$0.replicaClient.undo = { _ in
				attempts.withValue { $0 += 1 }
				guard attempts.value > 1 else {
					throw ReplicaError.busy
				}
				return UndoOutcome(isApplied: true, snapshot: snapshot([milk], readIndex: 1), tasks: [UUID(0)])
			}
			$0.timeZone = .gmt
		}

		await store.send(.undoButtonTapped) {
			$0.writeProgress = .running
		}
		await store.receive(\.writeFailed) {
			$0.writeProgress = .failed(
				ReplicaFeature.WriteFailure(
					reason: "The Replica is busy. A `task` command may be holding it.",
					retry: .undo,
					title: "Couldn't Undo Complete Task",
				),
			)
		}
		await store.send(.writeFailureTryAgainButtonTapped) {
			$0.writeProgress = .running
		}
		await store.receive(\.tasksLoaded) {
			$0.readIndex = 1
			$0.undoName = nil
		}
		await store.receive(\.undoOrRedoFinished) {
			$0.inspectedTask = UUID(0)
			$0.selection = [UUID(0)]
			$0.writeProgress = nil
		}
		await store.finish()
	}

	@Test
	func undoTheEngineCantConfirmSaysItMayHaveLandedAndOffersNoRetry() async throws {
		var initialState = try loadedState([storedTask(0, "Buy milk", workingSetID: 1)])
		initialState.undoName = "Complete Task"
		let store = TestStore(initialState: initialState) {
			ReplicaFeature()
		} withDependencies: {
			$0.date.now = now
			$0.replicaClient.undo = { _ in throw ReplicaError.undoUnconfirmed }
			$0.timeZone = .gmt
		}

		await store.send(.undoButtonTapped) {
			$0.writeProgress = .running
		}
		await store.receive(\.writeFailed) {
			$0.writeProgress = .failed(
				ReplicaFeature.WriteFailure(
					reason: "The change may have been undone. A `task` command may be holding the Replica.",
					retry: nil,
					title: "Couldn't Confirm Undo",
				),
			)
		}
		await store.finish()
	}

	@Test
	func readFailureShowsABannerAfterThirtySecondsUntilAReadSucceeds() async throws {
		let clock = TestClock()
		var initialState = try loadedState([])
		initialState.readIndex = 1
		let store = TestStore(initialState: initialState) {
			ReplicaFeature()
		} withDependencies: {
			$0.continuousClock = clock
			$0.date.now = now
			$0.timeZone = .gmt
		}

		await store.send(.readFailed("disk I/O error")) {
			$0.readFailure = "disk I/O error"
		}
		await clock.advance(by: .seconds(29))
		// Neither a read failing again nor a write's read, perhaps from before the failure, restarts
		// the wait.
		await store.send(.readFailed("disk I/O error"))
		await store.send(.tasksLoaded(snapshot([], readIndex: 2))) {
			$0.readIndex = 2
		}
		await clock.advance(by: .seconds(1))
		await store.receive(\.readFailureDelayElapsed) {
			$0.isReadFailureBannerPresented = true
		}
		await store.send(.readSucceeded(snapshot([], readIndex: 3))) {
			$0.isReadFailureBannerPresented = false
			$0.readFailure = nil
			$0.readIndex = 3
		}
		// A wait that ended just before the read, handled after it.
		await store.send(.readFailureDelayElapsed)
	}

	@Test
	func writeToATaskThatNoLongerExistsOffersOnlyOK() async throws {
		let milk = storedTask(0, "Buy milk", workingSetID: 1)
		let initialState = try loadedState([milk], selection: [UUID(0)])
		let store = TestStore(initialState: initialState) {
			ReplicaFeature()
		} withDependencies: {
			$0.continuousClock = TestClock()
			$0.date.now = now
			// `task undo` of its creation, just before the write.
			$0.replicaClient.apply = { _, _, _ in
				ApplyOutcome(isCommitted: false, snapshot: snapshot([]))
			}
			$0.timeZone = .gmt
		}

		await store.send(.doneButtonTapped) {
			$0.leavingTasks = [UUID(0)]
			$0.rows = []
			$0.selection = []
			$0.writeProgress = .running
		}
		await store.receive(\.tasksLoaded) {
			$0.allRows = []
			$0.storedTasks = []
		}
		await store.receive(\.writeFailed) {
			$0.writeProgress = .failed(
				ReplicaFeature.WriteFailure(
					reason: "The task no longer exists.",
					retry: nil,
					title: "Couldn't Complete Task",
				),
			)
		}
		await store.send(.writeFailureDismissed) {
			$0.leavingTasks = []
			$0.writeProgress = nil
		}
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
	func undoRevertsTheWindowsChangeAndSelectsTheTasksItChanged() async throws {
		let milk = storedTask(0, "Buy milk", workingSetID: 1)
		let dog = storedTask(1, "Walk the dog", workingSetID: 2)
		var initialState = try loadedState([milk, dog])
		initialState.undoName = "Complete Task"
		let store = TestStore(initialState: initialState) {
			ReplicaFeature()
		} withDependencies: {
			$0.date.now = now
			$0.replicaClient.undo = { _ in
				UndoOutcome(
					isApplied: true,
					snapshot: snapshot([milk, dog], readIndex: 1, redoName: "Complete Task"),
					tasks: [UUID(0)],
				)
			}
			$0.timeZone = .gmt
		}

		await store.send(.undoButtonTapped) {
			$0.writeProgress = .running
		}
		await store.receive(\.tasksLoaded) {
			$0.readIndex = 1
			$0.redoName = "Complete Task"
			$0.storedTasks = [milk, dog]
			$0.undoName = nil
		}
		await store.receive(\.undoOrRedoFinished) {
			$0.inspectedTask = UUID(0)
			$0.selection = [UUID(0)]
			$0.writeProgress = nil
		}
		#expect(!store.state.canUndo)
		#expect(store.state.canRedo)
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
			$0.bookmarkClient.saveTaskrc = { _, _ in throw Gone() }
			$0.taskrcClient.load = { _, _ in .finished }
		}
		await store.send(.directoryResolved(replicaDirectory)) {
			$0.directory = replicaDirectory
		}

		await store.send(.taskrcChosen(taskrcFile))
		await store.receive(\.taskrcSaveFailed) {
			$0.taskrcSaveFailure = ReplicaFeature.TaskrcSaveFailure(
				message: "The file is gone.",
				canRetry: true,
			)
		}

		await store.send(.tryAgainButtonTapped) {
			$0.isTaskrcPanelPresented = true
		}
	}

	@Test
	func hintOffersATaskrcOnceAndTheMenuAttachesAndDetachesIt() async {
		let pairedTaskrc = LockIsolated<URL?>(nil)
		let store = TestStore(initialState: ReplicaFeature.State(bookmark: Data())) {
			ReplicaFeature()
		} withDependencies: {
			$0.bookmarkClient.changes = { .finished }
			$0.bookmarkClient.saveTaskrc = { taskrc, replica in
				#expect(replica == replicaDirectory)
				pairedTaskrc.setValue(taskrc)
			}
			$0.bookmarkClient.taskrc = { _ in pairedTaskrc.value }
			$0.date.now = now
			$0.taskrcClient.load = { taskrc, _ in
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
			$0.isTaskrcPanelPresented = true
		}
		await store.send(.taskrcChosen(taskrcFile)) {
			$0.isTaskrcPanelPresented = false
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
		let (tasks, continuation) = AsyncThrowingStream<Result<TaskSnapshot, ReplicaError>, any Error>
			.makeStream()
		let store = TestStore(initialState: ReplicaFeature.State(bookmark: Data())) {
			ReplicaFeature()
		} withDependencies: {
			$0.bookmarkClient.changes = { .finished }
			$0.bookmarkClient.resolve = { _ in directory }
			$0.continuousClock = TestClock()
			$0.date.now = now
			$0.replicaClient.tasks = { _ in tasks }
			$0.taskrcClient.load = { _, _ in .finished }
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
		continuation.yield(.success(snapshot([dog, taxes, milk])))
		await store.receive(\.readSucceeded) {
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
		continuation.yield(.success(snapshot([dog, taxes, milkDone])))
		// Down to one selected task, which the inspector takes.
		await store.receive(\.readSucceeded) {
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
		let (tasks, continuation) = AsyncThrowingStream<Result<TaskSnapshot, ReplicaError>, any Error>
			.makeStream()
		let clock = TestClock()
		let time = LockIsolated(now)
		let store = TestStore(initialState: ReplicaFeature.State(bookmark: Data())) {
			ReplicaFeature()
		} withDependencies: {
			$0.bookmarkClient.changes = { .finished }
			$0.bookmarkClient.resolve = { _ in replicaDirectory }
			$0.continuousClock = clock
			$0.date = DateGenerator { time.value }
			$0.replicaClient.tasks = { _ in tasks }
			$0.taskrcClient.load = { _, _ in .finished }
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
		continuation.yield(.success(snapshot([call, post])))
		await store.receive(\.readSucceeded) {
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
			$0.isReplicaOpen = true
			$0.storedTasks = storedTasks
			$0.rows = try [
				row(blocker, urgency: 8),
				row(estimated),
				row(blocked, isBlocked: true, urgency: -5),
			]
		}

		let taskrc = Taskrc(path: taskrcFile.path(), environment: .fixture) { path in
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
		let (tasks, continuation) = AsyncThrowingStream<Result<TaskSnapshot, ReplicaError>, any Error>
			.makeStream()
		let clock = TestClock()
		let time = LockIsolated(now)
		let store = TestStore(initialState: ReplicaFeature.State(bookmark: Data())) {
			ReplicaFeature()
		} withDependencies: {
			$0.bookmarkClient.changes = { .finished }
			$0.bookmarkClient.resolve = { _ in replicaDirectory }
			$0.continuousClock = clock
			$0.date = DateGenerator { time.value }
			$0.replicaClient.tasks = { _ in tasks }
			$0.taskrcClient.load = { _, _ in .finished }
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
		continuation.yield(.success(snapshot([call])))
		await store.receive(\.readSucceeded)
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
			Taskrc(path: taskrcFile.path(), environment: .fixture) { path in
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
private func snapshot(
	_ tasks: [StoredTask],
	readIndex: Int = 0,
	redoName: String? = nil,
) -> TaskSnapshot {
	TaskSnapshot(readIndex: readIndex, redoName: redoName, tasks: tasks)
}

/// Three pending tasks in a chain, each depending on the next: `first` on `first + 1`, and that on
/// `first + 2`, named Alpha, Beta and Gamma, then `suffix`.
private func chain(from first: Int = 0, suffix: String = "") -> [StoredTask] {
	func dependingOn(_ seed: Int) -> [String: String] {
		let uuid = UUID(seed).uuidString.lowercased()
		return ["dep_\(uuid)": "x", "depends": uuid]
	}
	return [
		storedTask(first, "Alpha" + suffix, workingSetID: first + 1, dependingOn(first + 1)),
		storedTask(first + 1, "Beta" + suffix, workingSetID: first + 2, dependingOn(first + 2)),
		storedTask(first + 2, "Gamma" + suffix, workingSetID: first + 3),
	]
}

/// A weekly Series named `description`: its template, seeded `template`, and a pending instance
/// seeded with each of `instances`, in `imask` order.
private func series(
	_ template: Int,
	_ description: String,
	instances: [Int],
) -> (instances: [StoredTask], template: StoredTask) {
	let recurrence = ["due": "1790600000", "recur": "weekly"]
	let parent = UUID(template).uuidString.lowercased()
	return (
		instances.enumerated().map { imask, seed in
			storedTask(
				seed,
				description,
				workingSetID: seed + 1,
				recurrence.merging(["imask": String(imask), "parent": parent]) { $1 },
			)
		},
		storedTask(
			template,
			description,
			status: "recurring",
			workingSetID: nil,
			recurrence.merging(["mask": String(repeating: "-", count: instances.count)]) { $1 },
		),
	)
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
