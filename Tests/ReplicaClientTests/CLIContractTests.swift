import Foundation
import Models
import ReplicaClient
import Taskrc
import Testing

/// The app's writes against the real `task` CLI, which `just contract` names in `CONTRACT_TASK`.
/// Without it the suite is skipped, as it is in CI: it runs by hand when TaskChampion or TW is
/// bumped.
@Suite(
	.enabled(if: contractTask != nil, "`just contract` names the `task` to run"),
	.timeLimit(.minutes(1)),
)
final class CLIContractTests {
	let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
	let replicaClient = ReplicaClient.liveValue

	/// The Replica `task` creates on its first command.
	private var replica: URL {
		directory.appending(path: "replica")
	}

	init() throws {
		try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
		// Empty, so `task` runs on its defaults, as the planner does on `Taskrc.defaults`.
		try Data().write(to: directory.appending(path: "taskrc"))
	}

	deinit {
		try? FileManager.default.removeItem(at: directory)
	}

	@Test
	func taskReadsAndChangesAnAppWrite() async throws {
		// The app opens a Replica but never creates one.
		_ = try addTask("Seed")
		var tasks = replicaClient.tasks(replica).makeAsyncIterator()
		_ = try await tasks.next()
		let uuid = UUID()
		let planner = WritePlanner(taskrc: .defaults, timeZone: .current)
		let created = try await apply(
			planner.plan(.create(uuid, description: "Buy milk"), tasks: [:], at: .now),
			as: "New Task",
		)
		try await apply(
			planner.plan(
				.edit([uuid], .set("project", .string("Home"))),
				tasks: properties(created),
				at: .now,
			),
			as: "Set Project",
		)

		let exported = try export(uuid)

		#expect(exported.description == "Buy milk")
		#expect(exported.project == "Home")
		#expect(exported.status == "pending")
		#expect(exported.id == 2)

		_ = try task(uuid.uuidString.lowercased(), "done")

		let completed = try #require(try await tasks.next()?.get())
		#expect(completed.tasks
			.first { $0.uuid == uuid.uuidString.lowercased() }?
			.properties["status"] == "completed")
	}

	@Test
	func taskUndoRevertsTheAppsWriteAsOneUndoPoint() async throws {
		let uuid = try addTask("Buy milk")
		var tasks = replicaClient.tasks(replica).makeAsyncIterator()
		let read = try #require(try await tasks.next()?.get())
		let completed = try await apply(
			WritePlanner(taskrc: .defaults, timeZone: .current)
				.plan(.complete([uuid], chains: .repair), tasks: properties(read), at: .now),
			as: "Complete Task",
		)
		#expect(completed.undoName == "Complete Task")

		_ = try task("undo")

		#expect(try export(uuid).status == "pending")
		let undone = try #require(try await tasks.next()?.get())
		#expect(undone.undoName == nil)
		#expect(try await replicaClient.undo(replica).isApplied == false)
		// One undo took the whole write: the next reverts the CLI's add.
		_ = try task("undo")
		#expect(try task("export") == "[\n]")
	}

	@Test
	func aConcurrentEditRefusesTheAppsStaleWrite() async throws {
		let uuid = try addTask("Buy milk")
		var tasks = replicaClient.tasks(replica).makeAsyncIterator()
		let read = try #require(try await tasks.next()?.get())
		let planner = WritePlanner(taskrc: .defaults, timeZone: .current)
		let stale = try planner.plan(
			.complete([uuid], chains: .repair),
			tasks: properties(read),
			at: .now,
		)

		_ = try task(uuid.uuidString.lowercased(), "start")
		let refused = try await replicaClient.apply(stale, "Complete Task", replica)

		#expect(!refused.isCommitted)
		#expect(try export(uuid).start != nil)
		#expect(try export(uuid).status == "pending")

		try await apply(
			planner.plan(.complete([uuid], chains: .repair), tasks: properties(refused.snapshot), at: .now),
			as: "Complete Task",
		)
		#expect(try export(uuid).status == "completed")
	}

	/// Adds a pending task through `task`, which creates the Replica if it's the first command.
	private func addTask(_ description: String) throws -> UUID {
		_ = try task("add", description)
		let uuids = try task("_uuids")
		return try #require(UUID(uuidString: uuids))
	}

	/// Commits `plan` through the window, as the Undo point `name`.
	@discardableResult
	private func apply(_ plan: WritePlan, as name: String) async throws -> TaskSnapshot {
		let outcome = try await replicaClient.apply(plan, name, replica)
		try #require(outcome.isCommitted)
		return outcome.snapshot
	}

	/// The task `uuid`, as `task export` reports it.
	private func export(_ uuid: UUID) throws -> ExportedTask {
		let json = try task(uuid.uuidString.lowercased(), "export")
		let exported = try JSONDecoder().decode([ExportedTask].self, from: Data(json.utf8))
		return try #require(exported.first)
	}

	private func properties(_ snapshot: TaskSnapshot) -> [Models.Task.ID: [String: String]] {
		Dictionary(
			uniqueKeysWithValues: snapshot.tasks.compactMap { task in
				UUID(uuidString: task.uuid).map { ($0, task.properties) }
			},
		)
	}

	/// Runs `task` on the Replica with `arguments`, in an environment of its own so neither the
	/// user's Taskrc nor their hooks take part, and returns what it printed, trimmed.
	private func task(_ arguments: String...) throws -> String {
		let process = Process()
		process.executableURL = try URL(filePath: #require(contractTask))
		process.arguments = ["rc.confirmation=0", "rc.hooks=0", "rc.verbose=nothing"] + arguments
		process.environment = [
			"HOME": directory.path(percentEncoded: false),
			"TASKDATA": replica.path(percentEncoded: false),
			"TASKRC": directory.appending(path: "taskrc").path(percentEncoded: false),
		]
		let output = Pipe()
		process.standardOutput = output
		try process.run()
		let data = output.fileHandleForReading.readDataToEndOfFile()
		process.waitUntilExit()
		try #require(
			process.terminationStatus == 0,
			"`task \(arguments.joined(separator: " "))` exited \(process.terminationStatus)",
		)
		return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
	}
}

/// The fields of `task export` the contract checks.
private struct ExportedTask: Decodable {
	var description: String
	var id: Int
	var project: String?
	var start: String?
	var status: String
}

/// The `task` executable `just contract` runs against, forwarded by `xcodebuild` from
/// `TEST_RUNNER_CONTRACT_TASK`.
private let contractTask = ProcessInfo.processInfo.environment["CONTRACT_TASK"]
