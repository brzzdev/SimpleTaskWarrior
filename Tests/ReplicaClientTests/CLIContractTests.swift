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
final class CLIContractTests: Sendable {
	let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
	let planner = WritePlanner(taskrc: .defaults, timeZone: .gmt)
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
	func aCLIEditSinceTheAppsReadRefusesItsWrite() async throws {
		let uuid = try addTask("Buy milk")
		var tasks = replicaClient.tasks(replica, nil).makeAsyncIterator()
		let read = try #require(await tasks.next()?.get())
		let stale = try planner.plan(
			.complete([uuid], chains: .repair),
			tasks: properties(of: read.tasks),
			at: .now,
		)

		try task(uuid.uuidString.lowercased(), "start")
		let refused = try await replicaClient.apply(stale, "Complete Task", replica)

		#expect(!refused.isCommitted)
		// Refused for the `start` the CLI wrote, which the refusal read back.
		#expect(refused.snapshot.tasks.first?.properties["start"] != nil)
		let started = try export(uuid)
		#expect(started.start != nil)
		#expect(started.status == "pending")

		try await apply(
			planner.plan(
				.complete([uuid], chains: .repair),
				tasks: properties(of: refused.snapshot.tasks),
				at: .now,
			),
			as: "Complete Task",
		)
		#expect(try export(uuid).status == "completed")
	}

	@Test
	func anAppWriteCommitsBetweenATaskImportsCommits() async throws {
		let uuid = try addTask("Seed")
		var tasks = replicaClient.tasks(replica, nil).makeAsyncIterator()
		_ = try await tasks.next()
		// `task` holds the lock only while it commits, never at a prompt or in a hook, so a long
		// import is how it holds it again and again. It commits each task on its own, and this many
		// keep it going for seconds, well past the up to 500 ms the app takes to see it start.
		// It can't hold the lock past the 5 s the app waits, so the app's busy failure is out of
		// the contract's reach.
		let imported = (1 ... 500).map { ["description": "Imported \($0)"] }
		// The seed and the import.
		let total = imported.count + 1
		let file = directory.appending(path: "import.json")
		try JSONEncoder().encode(imported).write(to: file)
		async let importing = task("import", file.path(percentEncoded: false))

		// The import's first commits.
		var read: TaskSnapshot
		repeat {
			read = try #require(await tasks.next()?.get())
		} while read.tasks.count == 1
		let written = try await apply(
			planner.plan(
				.edit([uuid], .set("project", .string("Home"))),
				tasks: properties(of: read.tasks),
				at: .now,
			),
			as: "Set Project",
		)

		// Committed between the import's commits, not after them.
		#expect(written.tasks.count < total)
		// Nor did the app's lock fail an import commit.
		_ = try await importing
		#expect(try task("count") == "\(total)")
		#expect(try export(uuid).project == "Home")
	}

	@Test
	func taskReadsAndChangesAnAppWrite() async throws {
		// The app opens a Replica but never creates one.
		try addTask("Seed")
		var tasks = replicaClient.tasks(replica, nil).makeAsyncIterator()
		_ = try await tasks.next()
		let uuid = UUID()
		let created = try await apply(
			planner.plan(.create(uuid, description: "Buy milk"), tasks: [:], at: .now),
			as: "New Task",
		)
		try await apply(
			planner.plan(
				.edit([uuid], .set("project", .string("Home"))),
				tasks: properties(of: created.tasks),
				at: .now,
			),
			as: "Set Project",
		)

		let exported = try export(uuid)

		#expect(exported.description == "Buy milk")
		#expect(exported.project == "Home")
		#expect(exported.status == "pending")
		// After the seed's 1: `task` gives an app write a working set ID of its own.
		#expect(exported.id == 2)

		try task(uuid.uuidString.lowercased(), "done")

		let completed = try #require(await tasks.next()?.get())
		#expect(completed.tasks
			.first { $0.uuid == uuid.uuidString.lowercased() }?
			.properties["status"] == "completed")
	}

	@Test
	func taskUndoRevertsTheAppsWriteAsOneUndoPoint() async throws {
		let uuid = try addTask("Buy milk")
		var tasks = replicaClient.tasks(replica, nil).makeAsyncIterator()
		let read = try #require(await tasks.next()?.get())
		let completed = try await apply(
			planner.plan(
				.complete([uuid], chains: .repair),
				tasks: properties(of: read.tasks),
				at: .now,
			),
			as: "Complete Task",
		)
		#expect(completed.undoName == "Complete Task")

		try task("undo")

		#expect(try export(uuid).status == "pending")
		let undone = try #require(await tasks.next()?.get())
		#expect(undone.undoName == nil)
		#expect(try await replicaClient.undo(replica).isApplied == false)
		// One undo took the whole write: the next reverts the CLI's add.
		try task("undo")
		#expect(try task("count") == "0")
	}

	/// Adds a pending task through `task`, which creates the Replica if it's the first command.
	@discardableResult
	private func addTask(_ description: String) throws -> UUID {
		try task("add", description)
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

	/// Runs `task` on the Replica with `arguments`, in an environment of its own so neither the
	/// user's Taskrc nor their hooks take part, and returns what it printed, trimmed.
	@discardableResult
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
