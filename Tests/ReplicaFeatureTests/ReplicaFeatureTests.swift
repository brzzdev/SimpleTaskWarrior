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
		let (changes, changed) = AsyncStream<Void>.makeStream()
		let pairedTaskrc = LockIsolated<URL?>(nil)
		let store = TestStore(initialState: ReplicaFeature.State(bookmark: Data())) {
			ReplicaFeature()
		} withDependencies: {
			$0.bookmarkClient.changes = { changes }
			$0.bookmarkClient.grants = { [:] }
			$0.bookmarkClient.taskrc = { _ in pairedTaskrc.value }
			$0.taskrcClient.load = { taskrc, _, _ in
				.finished(yielding: TaskrcClient.Loaded(taskrc: .defaults, url: taskrc()))
			}
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
		changed.yield()
		await store.receive(\.bookmarksChanged)
		await store.receive(\.taskrcLoaded) {
			$0.taskrc?.url = taskrcFile
		}

		changed.finish()
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
			$0.taskrcClient.load = { taskrc, _, _ in
				.finished(yielding: TaskrcClient.Loaded(taskrc: .defaults, url: taskrc()))
			}
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
	func listsPendingTasksAndDropsSelectedTasksThatLeave() async {
		let directory = URL(filePath: "/Users/paul/.task")
		let (tasks, continuation) = AsyncThrowingStream<[Models.Task], any Error>.makeStream()
		let store = TestStore(initialState: ReplicaFeature.State(bookmark: Data())) {
			ReplicaFeature()
		} withDependencies: {
			$0.bookmarkClient.changes = { .finished }
			$0.bookmarkClient.grants = { [:] }
			$0.bookmarkClient.resolve = { _ in directory }
			$0.replicaClient.tasks = { _ in tasks }
			$0.taskrcClient.load = { _, _, _ in .finished }
		}
		var milk = Models.Task(
			description: "Buy milk",
			id: UUID(0),
			status: .pending,
			workingSetID: 1,
		)
		let dog = Models.Task(
			description: "Walk the dog",
			id: UUID(1),
			status: .pending,
			workingSetID: 2,
		)
		let taxes = Models.Task(
			description: "File taxes",
			id: UUID(2),
			status: .completed,
			workingSetID: nil,
		)

		let task = await store.send(.fetchRequested)
		await store.receive(\.directoryResolved) {
			$0.directory = directory
		}

		continuation.yield([dog, taxes, milk])
		await store.receive(\.tasksLoaded) {
			$0.tasks = [milk, dog]
		}
		await store.send(\.binding.selection, [milk.id, dog.id]) {
			$0.selection = [milk.id, dog.id]
		}

		milk.status = .completed
		continuation.yield([dog, taxes, milk])
		await store.receive(\.tasksLoaded) {
			$0.selection = [dog.id]
			$0.tasks = [dog]
		}

		continuation.finish()
		await task.finish()
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
