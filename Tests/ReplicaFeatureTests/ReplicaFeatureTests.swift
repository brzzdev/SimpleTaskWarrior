import BookmarkClient
import ComposableArchitecture
import Foundation
import Models
import ReplicaClient
@testable import ReplicaFeature
import Testing

@MainActor
struct ReplicaFeatureTests {
	@Test
	func listsPendingTasksAndDropsSelectedTasksThatLeave() async {
		let directory = URL(filePath: "/Users/paul/.task")
		let (tasks, continuation) = AsyncThrowingStream<[Models.Task], any Error>.makeStream()
		let store = TestStore(initialState: ReplicaFeature.State(bookmark: Data())) {
			ReplicaFeature()
		} withDependencies: {
			$0.bookmarkClient.resolve = { _ in directory }
			$0.replicaClient.tasks = { _ in tasks }
		}
		var milk = Models.Task(description: "Buy milk", id: UUID(0), status: .pending, workingSetID: 1)
		let dog = Models.Task(description: "Walk the dog", id: UUID(1), status: .pending, workingSetID: 2)
		let taxes = Models.Task(
			description: "File taxes",
			id: UUID(2),
			status: .completed,
			workingSetID: nil,
		)

		let task = await store.send(.task)
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
}
