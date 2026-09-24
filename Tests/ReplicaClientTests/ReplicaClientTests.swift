import Engine
import Foundation
import Models
import ReplicaClient
import SQLite3
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
	func tasksReadsAgainWhenTheCLICommits() async throws {
		let cli = try createReplica()
		var tasks = replicaClient.tasks(directory).makeAsyncIterator()
		#expect(try await tasks.next()?.isEmpty == true)

		let uuid = try addPendingTask("Buy milk", with: cli)

		#expect(
			try await tasks.next() == [
				Models.Task(description: "Buy milk", id: uuid, status: .pending, workingSetID: 1),
			],
		)
	}

	@Test
	func tasksReadsTheReplica() async throws {
		let cli = try createReplica()
		let uuid = try addPendingTask("Buy milk", with: cli)

		var tasks = replicaClient.tasks(directory).makeAsyncIterator()

		#expect(
			try await tasks.next() == [
				Models.Task(description: "Buy milk", id: uuid, status: .pending, workingSetID: 1),
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

	/// The engine opens a Replica but never creates one, so this starts from an empty database
	/// file, which TaskChampion gives its schema.
	private func createReplica() throws -> EngineHandle {
		try #require(FileManager.default.createFile(atPath: databasePath, contents: nil))
		return try EngineHandle.open(directory: directory.path(percentEncoded: false))
	}
}
