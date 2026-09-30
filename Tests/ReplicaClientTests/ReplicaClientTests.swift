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
		var tasks = replicaClient.tasks(directory, nil).makeAsyncIterator()
		_ = try await tasks.next()
		let uuid = UUID()
		let plan = try WritePlanner(taskrc: .defaults, timeZone: .gmt)
			.plan(.create(uuid, description: "Buy milk"), tasks: [:], at: .now)

		let outcome = try await replicaClient.apply(plan, "New Task", directory)

		#expect(outcome.isCommitted)
		#expect(outcome.snapshot.tasks.map(\.uuid) == [uuid.uuidString.lowercased()])
		let undoOperations = try cli.getUndoOperations()
		#expect(undoOperations.first == .undoPoint)
		#expect(undoOperations.count { $0 == .undoPoint } == 1)
		#expect(undoOperations.count == plan.operations.count + 1)
	}

	@Test
	func applyFailsAsBusyWhileAnotherConnectionHoldsTheLock() async throws {
		_ = try createReplica()
		var tasks = replicaClient.tasks(directory, nil).makeAsyncIterator()
		_ = try await tasks.next()
		let plan = try WritePlanner(taskrc: .defaults, timeZone: .gmt)
			.plan(.create(UUID(), description: "Buy milk"), tasks: [:], at: .now)
		var database: OpaquePointer?
		defer { sqlite3_close(database) }
		try #require(sqlite3_open(databasePath, &database) == SQLITE_OK)
		// TaskChampion reads under `BEGIN IMMEDIATE` and rolls each read back asynchronously, so the
		// Replica can still hold the lock just after yielding its first read.
		try #require(sqlite3_busy_timeout(database, 1_000) == SQLITE_OK)
		try #require(sqlite3_exec(database, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK)

		await #expect(throws: ReplicaError.busy) {
			try await self.replicaClient.apply(plan, "New Task", self.directory)
		}
	}

	@Test
	func applyRefusesAStalePlanAndCommitsNothing() async throws {
		let cli = try createReplica()
		let uuid = try addPendingTask("Buy milk", with: cli)
		var tasks = replicaClient.tasks(directory, nil).makeAsyncIterator()
		let stored = try #require(try await tasks.next()?.get().tasks.first)
		let plan = try WritePlanner(taskrc: .defaults, timeZone: .gmt)
			.plan(.complete([uuid], chains: .repair), tasks: [uuid: stored.properties], at: .now)
		commit([.setValue(uuid: uuid.uuidString, property: "start", value: "1790000000")], with: cli)
		let before = try cli.getUndoOperations()

		let outcome = try await replicaClient.apply(plan, "Complete Task", directory)

		#expect(!outcome.isCommitted)
		#expect(outcome.snapshot.tasks.first?.properties["start"] == "1790000000")
		#expect(outcome.snapshot.tasks.first?.properties["status"] == "pending")
		#expect(try cli.getUndoOperations() == before)
	}

	@Test
	func replacedDatabaseEndsTheStreamAndRefusesWrites() async throws {
		_ = try createReplica()
		var tasks = replicaClient.tasks(directory, nil).makeAsyncIterator()
		_ = try await tasks.next()
		let identity = try #require(replicaClient.identity(directory))
		let plan = try WritePlanner(taskrc: .defaults, timeZone: .gmt)
			.plan(.create(UUID(), description: "Buy milk"), tasks: [:], at: .now)
		// As a restore from backup would: a copy in its place, under a new inode.
		let copy = directory.appending(path: "copy.sqlite3")
		try FileManager.default.copyItem(atPath: databasePath, toPath: copy.path(percentEncoded: false))
		_ = try FileManager.default.replaceItemAt(URL(filePath: databasePath), withItemAt: copy)

		await #expect(throws: ReplicaError.lost(identity)) {
			try await self.replicaClient.apply(plan, "New Task", self.directory)
		}
		await #expect(throws: ReplicaError.lost(identity)) {
			_ = try await tasks.next()
		}
	}

	@Test
	func redoReappliesTheUndoneChangeUntilAnythingWrites() async throws {
		let cli = try createReplica()
		let uuid = try addPendingTask("Buy milk", with: cli)
		var tasks = replicaClient.tasks(directory, nil).makeAsyncIterator()
		let stored = try #require(try await tasks.next()?.get().tasks.first)
		try await complete(uuid, stored, as: "Complete Task")
		_ = try await replicaClient.undo(directory)

		let redone = try await replicaClient.redo(directory)

		#expect(redone.isApplied)
		#expect(redone.snapshot?.tasks.first?.properties["status"] == "completed")
		#expect(redone.snapshot?.undoName == "Complete Task")
		#expect(redone.snapshot?.redoName == nil)

		let undone = try await replicaClient.undo(directory)
		#expect(undone.snapshot?.redoName == "Complete Task")
		commit([.setValue(uuid: uuid.uuidString, property: "project", value: "Home")], with: cli)
		#expect(try await tasks.next()?.get().redoName == nil)
		#expect(try await replicaClient.redo(directory).isApplied == false)
	}

	@Test
	func tasksLeavesAReplicaToTheWindowAlreadyOnIt() async throws {
		_ = try createReplica()
		var recovered = replicaClient.tasks(directory, nil).makeAsyncIterator()
		_ = try await recovered.next()
		// As ⌘O would, finishing its open after a moved window recovered the Replica.
		var opened = replicaClient.tasks(directory, nil).makeAsyncIterator()

		await #expect(throws: ReplicaError.openElsewhere) {
			_ = try await opened.next()
		}
	}

	@Test
	func tasksReopensAReplicaWhoseWindowJustClosed() async throws {
		_ = try createReplica()
		var closing = Optional(replicaClient.tasks(directory, nil).makeAsyncIterator())
		_ = try await closing?.next()
		// Its stream ends at once, though it lets go of the Replica only as its poll returns.
		closing = nil
		var reopened = replicaClient.tasks(directory, nil).makeAsyncIterator()

		#expect(try await reopened.next()?.get().tasks.isEmpty == true)
	}

	@Test
	func tasksOpensOnlyTheDatabaseExpected() async throws {
		_ = try createReplica()
		let other = ReplicaIdentity(device: 0, inode: 0)
		var tasks = replicaClient.tasks(directory, other).makeAsyncIterator()

		await #expect(throws: ReplicaError.lost(other)) {
			_ = try await tasks.next()
		}
	}

	@Test
	func tasksReadsAgainWhenTheCLICommits() async throws {
		let cli = try createReplica()
		var tasks = replicaClient.tasks(directory, nil).makeAsyncIterator()
		#expect(try await tasks.next()?.get().tasks.isEmpty == true)

		let uuid = try addPendingTask("Buy milk", with: cli)

		#expect(
			try await tasks.next()?.get().tasks == [
				pendingTask("Buy milk", id: uuid),
			],
		)
	}

	@Test
	func tasksReadsTheReplica() async throws {
		let cli = try createReplica()
		let uuid = try addPendingTask("Buy milk", with: cli)

		var tasks = replicaClient.tasks(directory, nil).makeAsyncIterator()

		#expect(
			try await tasks.next()?.get().tasks == [
				pendingTask("Buy milk", id: uuid),
			],
		)
	}

	@Test
	func undoRefusesWhenACLIChangeIsNewest() async throws {
		let cli = try createReplica()
		let uuid = try addPendingTask("Buy milk", with: cli)
		var tasks = replicaClient.tasks(directory, nil).makeAsyncIterator()
		let stored = try #require(try await tasks.next()?.get().tasks.first)
		let completed = try await complete(uuid, stored, as: "Complete Task")
		#expect(completed.undoName == "Complete Task")

		commit([.setValue(uuid: uuid.uuidString, property: "project", value: "Home")], with: cli)

		#expect(try await tasks.next()?.get().undoName == nil)
		let outcome = try await replicaClient.undo(directory)
		#expect(!outcome.isApplied)
		#expect(outcome.snapshot?.tasks.first?.properties["project"] == "Home")
		#expect(outcome.snapshot?.tasks.first?.properties["status"] == "completed")
	}

	@Test
	func undoRevertsTheWindowsNewestChange() async throws {
		let cli = try createReplica()
		let uuid = try addPendingTask("Buy milk", with: cli)
		var tasks = replicaClient.tasks(directory, nil).makeAsyncIterator()
		let stored = try #require(try await tasks.next()?.get().tasks.first)
		try await complete(uuid, stored, as: "Complete Task")

		let outcome = try await replicaClient.undo(directory)

		#expect(outcome.isApplied)
		#expect(outcome.tasks == [uuid])
		#expect(outcome.snapshot?.tasks == [pendingTask("Buy milk", id: uuid)])
		#expect(outcome.snapshot?.undoName == nil)
		// The CLI's change is next in the log, and the window's to leave alone.
		#expect(try cli.getUndoOperations().count { $0 == .undoPoint } == 1)
	}

	@Test
	func validateRefusesAFolderWithoutAReplica() async {
		await #expect(throws: ReplicaError.notAReplica) {
			try await self.replicaClient.validate(self.directory)
		}
	}

	@Test
	func validateRefusesAFileThatIsntADatabase() async throws {
		try #require(FileManager.default.createFile(
			atPath: databasePath,
			contents: Data(repeating: 1, count: 4_096),
		))

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
		commit(
			[
				.create(uuid: uuid.uuidString),
				.setValue(uuid: uuid.uuidString, property: "description", value: description),
				.setStatus(uuid: uuid.uuidString, status: Engine.Status.pending),
			],
			with: cli,
		)
		return uuid
	}

	/// Commits `operations` through `cli`, as the CLI would.
	private func commit(_ operations: [PlannedOperation], with cli: EngineHandle) {
		do {
			if case let .conflict(uuids) = try cli.apply(operations: operations, expectations: []) {
				Issue.record("The CLI's write conflicted on \(uuids)")
			}
		} catch {
			Issue.record(error)
		}
	}

	/// Completes the task `uuid`, read as `stored`, through the window, as the Undo point `name`.
	@discardableResult
	private func complete(
		_ uuid: UUID,
		_ stored: StoredTask,
		as name: String,
	) async throws -> TaskSnapshot {
		let plan = try WritePlanner(taskrc: .defaults, timeZone: .gmt)
			.plan(.complete([uuid], chains: .repair), tasks: [uuid: stored.properties], at: .now)
		let outcome = try await replicaClient.apply(plan, name, directory)
		try #require(outcome.isCommitted)
		return outcome.snapshot
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
