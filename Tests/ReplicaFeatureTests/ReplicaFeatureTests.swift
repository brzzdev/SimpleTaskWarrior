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
	func layoutIsKeptPerReplicaForTheNextWindowOnIt() async {
		let work = URL(filePath: "/Users/paul/work", directoryHint: .isDirectory)
		let home = URL(filePath: "/Users/paul/home", directoryHint: .isDirectory)
		let sortOrder = [TaskSort(.description)]
		func window() -> TestStoreOf<ReplicaFeature> {
			TestStore(initialState: ReplicaFeature.State(bookmark: Data())) {
				ReplicaFeature()
			} withDependencies: {
				$0.bookmarkClient.changes = { .finished }
				$0.taskrcClient.load = { _, _, _ in .finished }
			}
		}

		let closed = window()
		await closed.send(.directoryResolved(work)) {
			$0.directory = work
		}
		await closed.send(\.binding.sortOrder, sortOrder) {
			$0.$layout.withLock { $0.sortOrder = sortOrder }
			$0.sortOrder = sortOrder
		}

		let reopened = window()
		await reopened.send(.directoryResolved(work)) {
			$0.directory = work
			$0.$layout.withLock { $0.sortOrder = sortOrder }
			$0.sortOrder = sortOrder
		}

		let other = window()
		await other.send(.directoryResolved(home)) {
			$0.directory = home
		}
	}

	@Test
	func listsPendingTasksSortedAndDropsSelectedTasksThatLeave() async {
		let directory = URL(filePath: "/Users/paul/.task")
		let (tasks, continuation) = AsyncThrowingStream<[StoredTask], any Error>.makeStream()
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
		continuation.yield([dog, taxes, milk])
		await store.receive(\.tasksLoaded) {
			$0.storedTasks = [dog, taxes, milk]
			$0.rows = try [row(milk), row(dog)]
		}
		await store.send(\.binding.sortOrder, [TaskSort(.description, order: .reverse)]) {
			$0.$layout.withLock { $0.sortOrder = [TaskSort(.description, order: .reverse)] }
			$0.rows = try [row(dog), row(milk)]
			$0.sortOrder = [TaskSort(.description, order: .reverse)]
		}
		await store.send(\.binding.selection, [UUID(0), UUID(1)]) {
			$0.selection = [UUID(0), UUID(1)]
		}

		let milkDone = storedTask(0, "Buy milk", status: "completed", workingSetID: 1)
		continuation.yield([dog, taxes, milkDone])
		await store.receive(\.tasksLoaded) {
			$0.storedTasks = [dog, taxes, milkDone]
			$0.rows = try [row(dog)]
			$0.selection = [UUID(1)]
		}

		continuation.finish()
		await task.cancel()
	}

	@Test
	func recomputesUrgencyEveryMinute() async {
		let (tasks, continuation) = AsyncThrowingStream<[StoredTask], any Error>.makeStream()
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
		continuation.yield([call, post])
		await store.receive(\.tasksLoaded) {
			$0.rows = try [row(post), row(call)]
			$0.storedTasks = [call, post]
		}

		// Past `scheduled`, with nothing committed to the Replica.
		time.setValue(now.addingTimeInterval(60))
		await clock.advance(by: .seconds(60))
		await store.receive(\.timerTicked) {
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

		await store.send(.tasksLoaded(storedTasks)) {
			$0.highestUrgency = 8
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
			$0.rows[id: UUID(0)]?.task.orphans = [:]
			$0.rows[id: UUID(0)]?.task.udas = ["estimate": .numeric(3)]
			$0.rows[id: UUID(0)]?.urgency = 5
			$0.taskrc = TaskrcClient.Loaded(taskrc: taskrc, url: taskrcFile)
			$0.udaColumns = UDAColumn.all(in: taskrc)
		}
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

/// `stored` as the table shows it on TW's defaults.
private func row(
	_ stored: StoredTask,
	isBlocked: Bool = false,
	urgency: Double = 0,
) throws -> TaskRow {
	let task = Models.Task(stored, udaTypes: Taskrc.defaults.udaTypes)
	return try TaskRow(
		isBlocked: isBlocked,
		task: #require(task),
		udaColumns: UDAColumn.all(in: .defaults),
		urgency: urgency,
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
