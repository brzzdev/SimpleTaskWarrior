import Foundation
import Models
import Taskrc
import Testing
import TestSupport

/// Checked against what `task` 3.5 writes for each case `just fixtures` records.
struct WritePlannerTests {
	/// The app's action for each recorded write, by fixture and case.
	static let actions: [String: @Sendable (Recording) throws -> WriteAction] = [
		"context/add": { try .create($0.created(), description: "Alpha") },
		"defaults/add": { try .create($0.created(), description: "Alpha") },
		"edits/add": { try .create($0.created(), description: "Alpha") },
		"edits/add_annotation": { try .edit([$0.id("Alpha")], .addAnnotation("Note", entry: $0.now)) },
		"edits/add_annotation_in_a_taken_second": {
			try .edit([$0.id("Alpha")], .addAnnotation("Second", entry: $0.now))
		},
		"edits/add_annotation_nbsp_only": {
			try .edit([$0.id("Alpha")], .addAnnotation("\u{A0}", entry: $0.now))
		},
		"edits/add_annotation_padded": {
			try .edit([$0.id("Alpha")], .addAnnotation(" Note ", entry: $0.now))
		},
		"edits/add_dependency": { try .edit([$0.id("Alpha")], .addDependency($0.id("Beta"))) },
		"edits/add_padded": { try .create($0.created(), description: " Alpha ") },
		"edits/add_tab_only": { try .create($0.created(), description: "\t") },
		"edits/add_tag": { try .edit([$0.id("Alpha")], .addTag("Work")) },
		"edits/complete": { try .complete([$0.id("Alpha")]) },
		"edits/complete_several": { try .complete([$0.id("Alpha"), $0.id("Beta")]) },
		"edits/complete_started": { try .complete([$0.id("Alpha")]) },
		"edits/delete_started": { try .delete([$0.id("Alpha")]) },
		"edits/mark_completed_pending": { try .markPending([$0.id("Alpha")]) },
		"edits/mark_deleted_pending": { try .markPending([$0.id("Alpha")]) },
		"edits/remove_annotation": { try .edit([$0.id("Alpha")], .removeAnnotation(entry: $0.now)) },
		"edits/remove_dependency": { try .edit([$0.id("Alpha")], .removeDependency($0.id("Beta"))) },
		"edits/remove_last_tag": { try .edit([$0.id("Alpha")], .removeTag("home")) },
		"edits/remove_project": { try .edit([$0.id("Alpha")], .set("project", nil)) },
		"edits/remove_tag": { try .edit([$0.id("Alpha")], .removeTag("home")) },
		"edits/remove_wait": { try .edit([$0.id("Alpha")], .set("wait", .string(""))) },
		"edits/set_description": { try .edit([$0.id("Alpha")], .set("description", .string("Beta"))) },
		"edits/set_description_padded": {
			try .edit([$0.id("Alpha")], .set("description", .string(" Beta ")))
		},
		"edits/set_description_to_spaces": {
			try .edit([$0.id("Alpha")], .set("description", .string("   ")))
		},
		"edits/set_duration": {
			try .edit([$0.id("Alpha")], .set("estimate", .duration(TaskDuration(seconds: 5_400))))
		},
		"edits/set_integer": { try .edit([$0.id("Alpha")], .set("size", .numeric(1_234_567))) },
		"edits/set_project": { try .edit([$0.id("Alpha")], .set("project", .string("Home.garden"))) },
		"edits/set_real": { try .edit([$0.id("Alpha")], .set("size", .numeric(4.5))) },
		"edits/set_real_past_six_digits": {
			try .edit([$0.id("Alpha")], .set("size", .numeric(3.14159265)))
		},
		"edits/set_uda_date": { try .edit([$0.id("Alpha")], .set("review", .date(newYear2030))) },
		"edits/set_wait": { try .edit([$0.id("Alpha")], .set("wait", .date(newYear2030))) },
		"edits/start": { try .start([$0.id("Alpha")]) },
		"edits/start_completed": { try .start([$0.id("Alpha")]) },
		"edits/start_deleted": { try .start([$0.id("Alpha")]) },
		// `task start` refuses a task that kept its `start` when deleted: it's already started.
		"edits/start_deleted_while_started": { try .start([$0.id("Alpha")]) },
		"edits/stop": { try .stop([$0.id("Alpha")]) },
	]

	/// Where the app writes something other than `task` on purpose, as the value the app stores, or
	/// nil where it stores nothing.
	static let departures: [String: @Sendable (Recording) -> [String: String?]] = [
		// The Context's `priority:H` is neither `project:` nor `+tag`, so it's skipped and reported.
		"context/add": { _ in ["priority": nil] },
		// Date and duration UDA defaults resolve, where the CLI stores the text.
		"defaults/add": { recording in
			var calendar = Calendar(identifier: .gregorian)
			calendar.timeZone = .gmt
			let midnight = calendar.startOfDay(for: recording.now.addingTimeInterval(86_400))
			return ["estimate": "PT1H30M", "review": String(Int(midnight.timeIntervalSince1970))]
		},
	]

	@Test
	func everyRecordingHasAnAction() throws {
		let recordings = try FileManager.default
			.subpathsOfDirectory(atPath: Recording.directory().path(percentEncoded: false))
			.filter { $0.hasSuffix(".json") }
			.map { String($0.dropLast(".json".count)) }

		#expect(Set(recordings) == Set(Self.actions.keys))
	}

	@Test(arguments: actions.keys.sorted())
	func planMatchesTask(case name: String) throws {
		let recording = try Recording(name)
		let makeAction = try #require(Self.actions[name])
		let action = try makeAction(recording)
		let planner = WritePlanner(taskrc: recording.taskrc, timeZone: .gmt)
		var after = recording.after
		var changes = recording.changes()
		if let departures = Self.departures[name]?(recording) {
			let id = try recording.created()
			for (property, value) in departures {
				#expect(after[id]?[property] != value, "\(property) no longer departs from task")
				after[id]?[property] = value
				changes.values[id]?[property] = value.map(Optional.some)
			}
		}

		let plan = try planner.plan(action, tasks: recording.before, at: recording.now)

		#expect(plan.changes(from: recording.before) == changes)
		#expect(plan.applied(to: recording.before) == after)
		for id in Set(plan.operations.map(\.id)) {
			let operations = plan.operations.filter { $0.id == id }
			#expect(operations.dropLast().allSatisfy { !$0.isStatus }, "status isn't written last")
		}
		for expectation in plan.expectations {
			#expect(recording.before[expectation.uuid]?[expectation.property] == expectation.value)
		}
		let expected = Set(plan.expectations.map { "\($0.uuid) \($0.property)" })
		for case let .setValue(id, property, _) in plan.operations
			where recording.before[id] != nil && property != "modified"
		{
			#expect(expected.contains("\(id) \(property)"), "\(property) changes unread")
		}
		let replanned = try planner.plan(action, tasks: after, at: recording.now)
		#expect(replanned == WritePlan())
	}

	@Test
	func completingALegacyWaitingTaskCompletesIt() throws {
		let planner = WritePlanner(taskrc: .defaults, timeZone: .gmt)
		let id = UUID()
		let now = Date(timeIntervalSince1970: 1_790_000_000)

		// TW 2 stored `waiting`, which `task done` reads as pending.
		let plan = try planner.plan(.complete([id]), tasks: [id: ["status": "waiting"]], at: now)

		#expect(plan.operations.contains(.setValue(id, property: "end", value: "1790000000")))
		#expect(plan.operations.last == .setStatus(id, .completed))
	}

	@Test
	func writingALegacyWaitingTaskMakesItPending() throws {
		let planner = WritePlanner(taskrc: .defaults, timeZone: .gmt)
		let id = UUID()
		let now = Date(timeIntervalSince1970: 1_790_000_000)

		// `task modify` rewrites a stored `waiting` only when it writes anything.
		let edited = try planner.plan(
			.edit([id], .addTag("home")),
			tasks: [id: ["status": "waiting"]],
			at: now,
		)
		let retried = try planner.plan(
			.edit([id], .addTag("home")),
			tasks: [id: ["status": "waiting", "tag_home": "x", "tags": "home"]],
			at: now,
		)
		let markedPending = try planner.plan(
			.markPending([id]),
			tasks: [id: ["status": "waiting"]],
			at: now,
		)

		#expect(edited.operations.last == .setStatus(id, .pending))
		let status = WritePlan.Expectation(property: "status", uuid: id, value: "waiting")
		#expect(edited.expectations.contains(status))
		#expect(retried == WritePlan())
		#expect(markedPending.operations.last == .setStatus(id, .pending))
	}

	@Test
	func contextWriteReportsWhatItSkips() throws {
		let recording = try Recording("context/add")
		let planner = WritePlanner(taskrc: recording.taskrc, timeZone: .gmt)

		let plan = try planner.plan(
			.create(recording.created(), description: "Alpha"),
			tasks: [:],
			at: recording.now,
		)

		#expect(plan.skippedContextWrite == ["priority:H"])
	}

	/// `task add` refuses both with "Additional text must be provided", writing nothing.
	@Test(arguments: ["", " "])
	func creatingATaskWithABlankDescriptionThrows(description: String) {
		let planner = WritePlanner(taskrc: .defaults, timeZone: .gmt)

		#expect(throws: WritePlanError.blankDescription) {
			try planner.plan(.create(UUID(), description: description), tasks: [:], at: .now)
		}
	}

	/// `task annotate` refuses both with "Additional text must be provided", writing nothing.
	@Test(arguments: ["", " "])
	func annotatingATaskWithBlankTextThrows(text: String) {
		let planner = WritePlanner(taskrc: .defaults, timeZone: .gmt)
		let id = UUID()

		#expect(throws: WritePlanError.blankAnnotation) {
			try planner.plan(
				.edit([id], .addAnnotation(text, entry: .now)),
				tasks: [id: ["status": "pending"]],
				at: .now,
			)
		}
	}

	@Test
	func editingAMissingTaskThrows() {
		let planner = WritePlanner(taskrc: .defaults, timeZone: .gmt)
		let id = UUID()

		#expect(throws: WritePlanError.noSuchTask(id)) {
			try planner.plan(.stop([id]), tasks: [:], at: .now)
		}
	}

	/// A cycle already in the snapshot, which only another client could have written. TW returns
	/// before its search when the dependency is already there, so a re-plan plans nothing.
	@Test
	func addingADependencyAlreadyInACyclePlansNothing() throws {
		let planner = WritePlanner(taskrc: .defaults, timeZone: .gmt)
		let (alpha, beta) = (UUID(), UUID())
		let tasks = [
			alpha: ["dep_\(beta.uuidString.lowercased())": "x", "status": "pending"],
			beta: ["dep_\(alpha.uuidString.lowercased())": "x", "status": "pending"],
		]

		let plan = try planner.plan(.edit([alpha], .addDependency(beta)), tasks: tasks, at: .now)

		#expect(plan == WritePlan())
	}

	/// So a dependency another writer adds to the chain meanwhile, closing a cycle, fails the plan:
	/// every writer rewrites `depends` with the `dep_*` keys it mirrors.
	@Test
	func addingADependencyExpectsTheChainItSearched() throws {
		let planner = WritePlanner(taskrc: .defaults, timeZone: .gmt)
		let (alpha, beta, gamma) = (UUID(), UUID(), UUID())
		let gammaKey = "dep_\(gamma.uuidString.lowercased())"
		let tasks = [
			alpha: ["status": "pending"],
			beta: [gammaKey: "x", "depends": gamma.uuidString.lowercased(), "status": "pending"],
			gamma: ["status": "pending"],
		]

		let plan = try planner.plan(.edit([alpha], .addDependency(beta)), tasks: tasks, at: .now)

		let expected = [
			WritePlan.Expectation(property: "depends", uuid: beta, value: gamma.uuidString.lowercased()),
			WritePlan.Expectation(property: gammaKey, uuid: beta, value: "x"),
			WritePlan.Expectation(property: "depends", uuid: gamma, value: nil),
		]
		#expect(Set(expected).isSubset(of: plan.expectations))
	}

	/// `task modify depends:` refuses both, writing nothing.
	@Test
	func addingADependencyOnItselfThrows() {
		let planner = WritePlanner(taskrc: .defaults, timeZone: .gmt)
		let id = UUID()

		#expect(throws: WritePlanError.selfDependency(id)) {
			try planner.plan(.edit([id], .addDependency(id)), tasks: [id: [:]], at: .now)
		}
	}

	/// Alpha depends on Beta, which depends on Gamma. TW follows a chain through tasks of any status,
	/// so Beta being completed doesn't break it.
	@Test(arguments: ["Beta", "Gamma"])
	func addingADependencyThatClosesACycleThrows(dependent: String) {
		let planner = WritePlanner(taskrc: .defaults, timeZone: .gmt)
		let (alpha, beta, gamma) = (UUID(), UUID(), UUID())
		let tasks = [
			alpha: ["dep_\(beta.uuidString.lowercased())": "x", "status": "pending"],
			beta: ["dep_\(gamma.uuidString.lowercased())": "x", "status": "completed"],
			gamma: ["status": "pending"],
		]
		let id = dependent == "Beta" ? beta : gamma

		#expect(throws: WritePlanError.circularDependency(id)) {
			try planner.plan(.edit([id], .addDependency(alpha)), tasks: tasks, at: .now)
		}
	}

	/// `task` refuses adding or removing a virtual tag, whose names are uppercase, writing nothing.
	@Test(arguments: [(TaskEdit.addTag("PENDING"), "PENDING"), (.removeTag("BLOCKED"), "BLOCKED")])
	func addingOrRemovingAReservedTagThrows(edit: TaskEdit, tag: String) {
		let planner = WritePlanner(taskrc: .defaults, timeZone: .gmt)
		let id = UUID()

		#expect(throws: WritePlanError.reservedTag(tag)) {
			try planner.plan(.edit([id], edit), tasks: [id: ["status": "pending"]], at: .now)
		}
	}

	/// Only the uppercase name is reserved.
	@Test
	func addingALowercaseVirtualTagNameWritesIt() throws {
		let planner = WritePlanner(taskrc: .defaults, timeZone: .gmt)
		let id = UUID()

		let plan = try planner.plan(
			.edit([id], .addTag("pending")),
			tasks: [id: ["status": "pending"]],
			at: .now,
		)

		#expect(plan.operations.contains(.setValue(id, property: "tag_pending", value: "x")))
	}

	/// A default resolves against the attributes the create has already set, as `wait:due-1wk`
	/// resolves against the task's `due`.
	@Test
	func creatingATaskResolvesADefaultThatRefersToAnotherAttribute() throws {
		let taskrc = Taskrc(path: "/taskrc", environment: .fixture) { path, _ throws(Taskrc.ReadError) in
			Taskrc.File(
				contents: """
					default.due=2030-01-02
					uda.review.default=due-1d
					uda.review.type=date
					""",
				realPath: path,
			)
		}
		let planner = WritePlanner(taskrc: taskrc, timeZone: .gmt)
		let id = UUID()

		let plan = try planner.plan(.create(id, description: "Alpha"), tasks: [:], at: .now)

		#expect(plan.operations.contains(.setValue(id, property: "review", value: "1893456000")))
	}

	/// `modified`, which the create stamps, is set before the defaults that refer to it. `modified+1d`
	/// would resolve without it, since TW reads an unset attribute plus a duration from now.
	@Test
	func creatingATaskResolvesADefaultThatRefersToItsModifiedStamp() throws {
		let taskrc = Taskrc(path: "/taskrc", environment: .fixture) { path, _ throws(Taskrc.ReadError) in
			Taskrc.File(
				contents: """
					uda.review.default=modified-1d
					uda.review.type=date
					""",
				realPath: path,
			)
		}
		let planner = WritePlanner(taskrc: taskrc, timeZone: .gmt)
		let id = UUID()
		let now = Date(timeIntervalSince1970: 1_790_000_000)

		let plan = try planner.plan(.create(id, description: "Alpha"), tasks: [:], at: now)

		#expect(plan.operations.contains(.setValue(id, property: "review", value: "1789913600")))
	}

	/// `task add` refuses a `default.due` or `default.scheduled` it can't parse, and resolves a
	/// holiday the app doesn't, so neither may create a task without its date.
	@Test(arguments: [
		("default.due", "bogus", DateInputError.invalid),
		("default.scheduled", "easter", DateInputError.holiday("easter")),
	])
	func creatingATaskWithAnUnresolvedDefaultThrows(key: String, text: String, error: DateInputError) {
		let taskrc = Taskrc(path: "/taskrc", environment: .fixture) { path, _ throws(Taskrc.ReadError) in
			Taskrc.File(contents: "\(key)=\(text)", realPath: path)
		}
		let planner = WritePlanner(taskrc: taskrc, timeZone: .gmt)

		#expect(throws: WritePlanError.unresolvedDefault(key: key, error)) {
			try planner.plan(.create(UUID(), description: "Alpha"), tasks: [:], at: .now)
		}
	}

	@Test
	func creatingATaskInAContextThatWritesAReservedTagThrows() {
		let planner = WritePlanner(taskrc: pendingContext, timeZone: .gmt)

		#expect(throws: WritePlanError.reservedTag("PENDING")) {
			try planner.plan(.create(UUID(), description: "Alpha"), tasks: [:], at: .now)
		}
	}

	/// A retry of a create that landed before the Context changed still plans nothing.
	@Test
	func recreatingATaskInAContextThatWritesAReservedTagPlansNothing() throws {
		let planner = WritePlanner(taskrc: pendingContext, timeZone: .gmt)
		let id = UUID()

		let plan = try planner.plan(
			.create(id, description: "Alpha"),
			tasks: [id: ["description": "Alpha", "status": "pending"]],
			at: .now,
		)

		#expect(plan == WritePlan())
	}

	@Test
	func addingATagExpectsTheOtherTags() throws {
		let planner = WritePlanner(taskrc: .defaults, timeZone: .gmt)
		let id = UUID()
		let properties = ["status": "pending", "tag_home": "x", "tags": "home"]

		let plan = try planner.plan(.edit([id], .addTag("work")), tasks: [id: properties], at: .now)

		// So a tag the CLI adds meanwhile fails the plan, rather than dropping out of the mirror.
		#expect(plan.expectations.contains(WritePlan.Expectation(
			property: "tags",
			uuid: id,
			value: "home",
		)))
		#expect(plan.expectations.contains(WritePlan.Expectation(
			property: "tag_home",
			uuid: id,
			value: "x",
		)))
	}
}

/// 2030-01-01 in UTC, which the fixtures write as `2030-01-01`.
private let newYear2030 = Date(timeIntervalSince1970: 1_893_456_000)

/// A Taskrc whose active Context writes the reserved `+PENDING` to new tasks.
private let pendingContext = Taskrc(path: "/taskrc", environment: .fixture) {
	path, _ throws(Taskrc.ReadError) in
	Taskrc.File(contents: "context=work\ncontext.work.write=+PENDING\n", realPath: path)
}

/// One write `just fixtures` recorded.
struct Recording {
	private struct File: Decodable {
		var after: [String: [String: String]]
		var before: [String: [String: String]]
		var now: TimeInterval
		var operations: [RecordedOperation]
	}

	let after: [Task.ID: [String: String]]
	let before: [Task.ID: [String: String]]
	let now: Date
	let taskrc: Taskrc

	private let operations: [RecordedOperation]

	/// Reads `<fixture>/<case>`.
	init(_ name: String) throws {
		let directory = try Self.directory()
		let file = try JSONDecoder().decode(
			File.self,
			from: Data(contentsOf: directory.appending(path: "\(name).json")),
		)
		after = try file.after.byID()
		before = try file.before.byID()
		now = Date(timeIntervalSince1970: file.now)
		operations = file.operations
		let fixture = try #require(name.split(separator: "/").first)
		taskrc = Taskrc(fixture: directory.appending(path: "\(fixture)/taskrc"))
	}

	/// Where `just fixtures` records the writes.
	static func directory() throws -> URL {
		try #require(Bundle.module.url(forResource: "WriteFixtures", withExtension: nil))
	}

	/// The task the write created.
	func created() throws -> Task.ID {
		try #require(after.keys.first { before[$0] == nil })
	}

	/// The task described as `description` before the write.
	func id(_ description: String) throws -> Task.ID {
		try #require(before.first { $0.value["description"] == description }?.key)
	}

	/// What the write left different, by task and property.
	fileprivate func changes() -> Changes {
		var changes = Changes()
		for operation in operations {
			switch operation {
			case let .create(id):
				changes.created.insert(id)

			case let .update(id, property, value):
				changes.values[id, default: [:]][property] = .some(value)

			case .undoPoint:
				continue
			}
		}
		return changes.dropping(before)
	}
}

/// An operation from the `operations` table, as TaskChampion serialises it.
private enum RecordedOperation: Decodable {
	case create(Task.ID)
	case undoPoint
	case update(Task.ID, property: String, value: String?)

	private struct Create: Decodable {
		var uuid: Task.ID
	}

	private struct Update: Decodable {
		var property: String
		var uuid: Task.ID
		var value: String?
	}

	private enum CodingKeys: String, CodingKey {
		case create = "Create"
		case update = "Update"
	}

	init(from decoder: any Decoder) throws {
		if (try? decoder.singleValueContainer().decode(String.self)) == "UndoPoint" {
			self = .undoPoint
			return
		}
		let container = try decoder.container(keyedBy: CodingKeys.self)
		if let create = try container.decodeIfPresent(Create.self, forKey: .create) {
			self = .create(create.uuid)
		} else {
			let update = try container.decode(Update.self, forKey: .update)
			self = .update(update.uuid, property: update.property, value: update.value)
		}
	}
}

/// The tasks a write creates, and each property's final value where it differs from before.
private struct Changes: Equatable {
	var created: Set<Task.ID> = []
	var values: [Task.ID: [String: String?]] = [:]

	/// Without the updates that leave a property as it was, such as TW's second `modified`.
	func dropping(_ before: [Task.ID: [String: String]]) -> Self {
		var changes = self
		for (id, values) in values {
			changes.values[id] = values.filter { $0.value != before[id]?[$0.key] }
			if changes.values[id]?.isEmpty == true {
				changes.values[id] = nil
			}
		}
		return changes
	}
}

extension WritePlan {
	/// `tasks` with the plan applied.
	fileprivate func applied(to tasks: [Task.ID: [String: String]]) -> [Task.ID: [String: String]] {
		var tasks = tasks
		for operation in operations {
			switch operation {
			case let .create(id):
				tasks[id] = [:]

			case let .setStatus(id, status):
				tasks[id]?["status"] = status.rawValue

			case let .setValue(id, property, value):
				tasks[id]?[property] = value
			}
		}
		return tasks
	}

	fileprivate func changes(from before: [Task.ID: [String: String]]) -> Changes {
		var changes = Changes()
		for operation in operations {
			switch operation {
			case let .create(id):
				changes.created.insert(id)

			case let .setStatus(id, status):
				changes.values[id, default: [:]]["status"] = .some(status.rawValue)

			case let .setValue(id, property, value):
				changes.values[id, default: [:]][property] = .some(value)
			}
		}
		return changes.dropping(before)
	}
}

extension WritePlan.Operation {
	fileprivate var id: Task.ID {
		switch self {
		case let .create(id), let .setStatus(id, _), let .setValue(id, _, _): id
		}
	}

	fileprivate var isStatus: Bool {
		if case .setStatus = self {
			return true
		}
		return false
	}
}

extension [String: [String: String]] {
	fileprivate func byID() throws -> [Task.ID: [String: String]] {
		try [Task.ID: [String: String]](uniqueKeysWithValues: map { uuid, properties in
			try (#require(UUID(uuidString: uuid)), properties)
		})
	}
}
