import Engine
import Foundation
import Models
import ReplicaClient
import SQLite3
import Taskrc
import Testing

/// End to end across the Swift/Rust seam, on a Replica in a temporary folder. A second engine
/// handle stands in for the CLI.
@Suite(.timeLimit(.minutes(1)))
final class ReplicaClientTests {
	let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
	let replicaClient = ReplicaClient.liveValue

	private var databasePath: String {
		directory.appending(path: "taskchampion.sqlite3").path(percentEncoded: false)
	}

	init() throws {
		try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
	}

	deinit {
		try? FileManager.default.removeItem(at: directory)
	}

	@Test
	func applyCommitsOneActionAsOneUndoPoint() async throws {
		let cli = try createReplica()
		var tasks = replicaClient.tasks(directory).makeAsyncIterator()
		_ = try await tasks.next()
		let uuid = UUID()
		let plan = try WritePlanner(taskrc: .defaults, timeZone: .gmt)
			.plan(.create(uuid, description: "Buy milk"), tasks: [:], at: .now)

		let outcome = try await replicaClient.apply(plan, directory)

		#expect(outcome.isCommitted)
		#expect(outcome.snapshot.tasks.map(\.uuid) == [uuid.uuidString.lowercased()])
		let undoOperations = try cli.getUndoOperations()
		#expect(undoOperations.first == .undoPoint)
		#expect(undoOperations.count { $0 == .undoPoint } == 1)
		#expect(undoOperations.count == plan.operations.count + 1)
	}

	@Test
	func applyRefusesAStalePlanAndCommitsNothing() async throws {
		let cli = try createReplica()
		let uuid = try addPendingTask("Buy milk", with: cli)
		var tasks = replicaClient.tasks(directory).makeAsyncIterator()
		let stored = try #require(try await tasks.next()?.tasks.first)
		let plan = try WritePlanner(taskrc: .defaults, timeZone: .gmt)
			.plan(.complete([uuid]), tasks: [uuid: stored.properties], at: .now)
		let cliChange = try cli.apply(
			operations: [.setValue(uuid: uuid.uuidString, property: "start", value: "1790000000")],
			expectations: [],
		)
		try #require(cliChange == .committed)
		let before = try cli.getUndoOperations()

		let outcome = try await replicaClient.apply(plan, directory)

		#expect(!outcome.isCommitted)
		#expect(outcome.snapshot.tasks.first?.properties["start"] == "1790000000")
		#expect(outcome.snapshot.tasks.first?.properties["status"] == "pending")
		#expect(try cli.getUndoOperations() == before)
	}

	@Test
	func tasksReadsAgainWhenTheCLICommits() async throws {
		let cli = try createReplica()
		var tasks = replicaClient.tasks(directory).makeAsyncIterator()
		#expect(try await tasks.next()?.tasks.isEmpty == true)

		let uuid = try addPendingTask("Buy milk", with: cli)

		#expect(
			try await tasks.next()?.tasks == [
				pendingTask("Buy milk", id: uuid),
			],
		)
	}

	@Test
	func tasksReadsTheReplica() async throws {
		let cli = try createReplica()
		let uuid = try addPendingTask("Buy milk", with: cli)

		var tasks = replicaClient.tasks(directory).makeAsyncIterator()

		#expect(
			try await tasks.next()?.tasks == [
				pendingTask("Buy milk", id: uuid),
			],
		)
	}

	@Test
	func validateRefusesAFolderWithoutAReplica() async {
		await #expect(throws: ReplicaError.notAReplica) {
			try await self.replicaClient.validate(self.directory)
		}
	}

	@Test
	func validateRefusesANewerSchemaMajor() async throws {
		var database: OpaquePointer?
		defer { sqlite3_close(database) }
		try #require(sqlite3_open(databasePath, &database) == SQLITE_OK)
		try #require(
			sqlite3_exec(
				database,
				"""
				CREATE TABLE version (major INTEGER, minor INTEGER);
				INSERT INTO version VALUES (1, 0);
				""",
				nil,
				nil,
				nil,
			) == SQLITE_OK,
		)

		await #expect(throws: ReplicaError.unsupportedSchema) {
			try await self.replicaClient.validate(self.directory)
		}
	}

	private func addPendingTask(_ description: String, with cli: EngineHandle) throws -> UUID {
		let uuid = UUID()
		let outcome = try cli.apply(
			operations: [
				.create(uuid: uuid.uuidString),
				.setValue(uuid: uuid.uuidString, property: "description", value: description),
				.setStatus(uuid: uuid.uuidString, status: Engine.Status.pending),
			],
			expectations: [],
		)
		try #require(outcome == .committed)
		return uuid
	}

	/// A task `addPendingTask` adds, as the Replica reads it back.
	private func pendingTask(_ description: String, id: UUID) -> StoredTask {
		StoredTask(
			properties: ["description": description, "status": "pending"],
			uuid: id.uuidString.lowercased(),
			workingSetID: 1,
		)
	}

	/// The engine opens a Replica but never creates one, so this starts from an empty database
	/// file, which TaskChampion gives its schema.
	private func createReplica() throws -> EngineHandle {
		try #require(FileManager.default.createFile(atPath: databasePath, contents: nil))
		return try EngineHandle.open(directory: directory.path(percentEncoded: false))
	}
}
