import Foundation
import Models
import Taskrc
import Testing
import TestSupport

/// Checked against what `task` 3.5 writes for each case `just fixtures` records.
struct WritePlannerTests {
	/// The app's action for each recorded write, by fixture and case.
	static let actions: [String: @Sendable (Recording) throws -> WriteAction] = [
		"chains/complete_already_depending": { try .complete([$0.id("Beta")], chains: .repair) },
		"chains/complete_declined": { try .complete([$0.id("Beta")], chains: .leave) },
		"chains/complete_fanned": { try .complete([$0.id("Beta")], chains: .repair) },
		"chains/complete_middle": { try .complete([$0.id("Beta")], chains: .repair) },
		"chains/complete_several": {
			try .complete([$0.id("Beta"), $0.id("Gamma")], chains: .repair)
		},
		"chains/complete_with_closed_ends": { try .complete([$0.id("Beta")], chains: .repair) },
		"chains/complete_with_template_dependent": {
			try .complete([$0.id("Beta")], chains: .repair)
		},
		"chains/delete_completed": { try .delete([$0.id("Beta")], chains: .repair) },
		"chains/delete_middle": { try .delete([$0.id("Beta")], chains: .repair) },
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
		"edits/add_annotation_space_before_combining_mark": {
			try .edit([$0.id("Alpha")], .addAnnotation(" \u{301}Note ", entry: $0.now))
		},
		"edits/add_dependency": { try .edit([$0.id("Alpha")], .addDependency($0.id("Beta"))) },
		"edits/add_padded": { try .create($0.created(), description: " Alpha ") },
		"edits/add_tab_only": { try .create($0.created(), description: "\t") },
		"edits/add_tag": { try .edit([$0.id("Alpha")], .addTags(["Work"])) },
		"edits/complete": { try .complete([$0.id("Alpha")], chains: .repair) },
		"edits/complete_several": {
			try .complete([$0.id("Alpha"), $0.id("Beta")], chains: .repair)
		},
		"edits/complete_started": { try .complete([$0.id("Alpha")], chains: .repair) },
		"edits/delete_started": { try .delete([$0.id("Alpha")], chains: .repair) },
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
		"recurrence/complete_instance": { try .complete([$0.instance()], chains: .repair) },
		"recurrence/complete_two_instances": { recording in
			// The two of the Series' four the CLI completed.
			.complete(
				recording.after.filter { $0.value["status"] == "completed" }.keys.sorted(),
				chains: .repair,
			)
		},
		"recurrence/delete_instance": { try .delete([$0.instance()], chains: .repair) },
		"recurrence/mark_completed_instance_pending": { try .markPending([$0.instance()]) },
		"recurrence/remove_wait_from_instance": { try .edit([$0.instance()], .set("wait", nil)) },
		"recurrence/set_description_of_instance": {
			try .edit([$0.instance()], .set("description", .string("Beta")))
		},
		"recurrence/set_wait_on_instance": {
			try .edit([$0.instance()], .set("wait", .date(december2029)))
		},
		"recurrence/start_instance": { try .start([$0.instance()]) },
		"series/add_tag_to_series": { try .editSeries(.addTags(["work"]), in: $0) },
		"series/annotate_series": { try .editSeries(.addAnnotation("Note", entry: $0.now), in: $0) },
		"series/delete_series": { try .deleteSeries(of: $0.deleted(), in: $0) },
		"series/delete_series_with_completed_and_waiting": { try .deleteSeries(of: $0.deleted(), in: $0)
		},
		"series/set_description_of_series_with_completed_and_waiting": {
			try .editSeries(.set("description", .string("Beta")), in: $0)
		},
		"series/set_until_of_series": { try .editSeries(.set("until", .date(newYear2030)), in: $0) },
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

	/// A dependency the CLI adds to the closed task before the plan commits rewrites `depends`, which
	/// the plan must expect to fail and be made again.
	@Test
	func repairExpectsTheClosedTasksDependencies() throws {
		let recording = try Recording("chains/complete_middle")
		let planner = WritePlanner(taskrc: recording.taskrc, timeZone: .gmt)
		let beta = try recording.id("Beta")

		let plan = try planner.plan(
			.complete([beta], chains: .repair),
			tasks: recording.before,
			at: recording.now,
		)

		let depends = WritePlan.Expectation(
			property: "depends",
			uuid: beta,
			value: recording.before[beta]?["depends"],
		)
		#expect(plan.expectations.contains(depends))
	}

	@Test
	func repairReportsEachChainItRepairs() throws {
		let recording = try Recording("chains/complete_fanned")
		let planner = WritePlanner(taskrc: recording.taskrc, timeZone: .gmt)
		let beta = try recording.id("Beta")

		let plan = try planner.plan(
			.complete([beta], chains: .repair),
			tasks: recording.before,
			at: recording.now,
		)

		#expect(plan.repairedChains.count == 1)
		let chain = try #require(plan.repairedChains.first)
		#expect(chain.task == beta)
		#expect(try Set(chain.blocked) == [recording.id("Alpha"), recording.id("Delta")])
		#expect(try Set(chain.blocking) == [recording.id("Epsilon"), recording.id("Gamma")])
	}

	@Test
	func completingALegacyWaitingTaskCompletesIt() throws {
		let planner = WritePlanner(taskrc: .defaults, timeZone: .gmt)
		let id = UUID()
		let now = Date(timeIntervalSince1970: 1_790_000_000)

		// TW 2 stored `waiting`, which `task done` reads as pending.
		let plan = try planner.plan(
			.complete([id], chains: .repair),
			tasks: [id: ["status": "waiting"]],
			at: now,
		)

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
			.edit([id], .addTags(["home"])),
			tasks: [id: ["status": "waiting"]],
			at: now,
		)
		let retried = try planner.plan(
			.edit([id], .addTags(["home"])),
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
	@Test(arguments: ["", " ", "   "])
	func creatingATaskWithABlankDescriptionThrows(description: String) {
		let planner = WritePlanner(taskrc: .defaults, timeZone: .gmt)

		#expect(throws: WritePlanError.blankDescription) {
			try planner.plan(.create(UUID(), description: description), tasks: [:], at: .now)
		}
	}

	/// `task annotate` refuses both with "Additional text must be provided", writing nothing.
	@Test(arguments: ["", " ", "   "])
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
	@Test(arguments: [(TaskEdit.addTags(["PENDING"]), "PENDING"), (.removeTag("BLOCKED"), "BLOCKED")])
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
			.edit([id], .addTags(["pending"])),
			tasks: [id: ["status": "pending"]],
			at: .now,
		)

		#expect(plan.operations.contains(.setValue(id, property: "tag_pending", value: "x")))
	}

	/// A default resolves against the attributes the create has already set, as `wait:due-1wk`
	/// resolves against the task's `due`.
	@Test
	func creatingATaskResolvesADefaultThatRefersToAnotherAttribute() throws {
		let taskrc = Taskrc(path: "/taskrc", environment: .fixture) { path throws(Taskrc.ReadError) in
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
		let taskrc = Taskrc(path: "/taskrc", environment: .fixture) { path throws(Taskrc.ReadError) in
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
		let taskrc = Taskrc(path: "/taskrc", environment: .fixture) { path throws(Taskrc.ReadError) in
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

	/// Relative input means the moment the plan is made, not when it was typed.
	@Test
	func settingInputResolvesItAsPlanned() throws {
		let planner = WritePlanner(taskrc: .defaults, timeZone: .gmt)
		let id = UUID()

		let plan = try planner.plan(
			.edit([id], .setInput("wait", text: "tomorrow")),
			tasks: [id: ["status": "pending"]],
			at: newYear2030,
		)

		#expect(plan.operations.contains(.setValue(id, property: "wait", value: "1893542400")))
	}

	/// So a `due` the CLI changes before the plan commits fails it, rather than leaving `wait` a week
	/// before the old one.
	@Test
	func settingInputThatRefersToAnAttributeExpectsIt() throws {
		let planner = WritePlanner(taskrc: .defaults, timeZone: .gmt)
		let id = UUID()

		let plan = try planner.plan(
			.edit([id], .setInput("wait", text: "due-1wk")),
			tasks: [id: ["due": "1893456000", "status": "pending"]],
			at: .now,
		)

		#expect(plan.operations.contains(.setValue(id, property: "wait", value: "1892851200")))
		#expect(plan.expectations.contains(WritePlan.Expectation(
			property: "due",
			uuid: id,
			value: "1893456000",
		)))
	}

	@Test
	func settingDurationInputStoresItNormalised() throws {
		let taskrc = Taskrc(path: "/taskrc", environment: .fixture) { path throws(Taskrc.ReadError) in
			Taskrc.File(contents: "uda.estimate.type=duration", realPath: path)
		}
		let planner = WritePlanner(taskrc: taskrc, timeZone: .gmt)
		let id = UUID()

		let plan = try planner.plan(
			.edit([id], .setInput("estimate", text: "1mo")),
			tasks: [id: ["status": "pending"]],
			at: .now,
		)

		#expect(plan.operations.contains(.setValue(id, property: "estimate", value: "P30D")))
	}

	@Test
	func settingEmptyInputRemovesTheAttribute() throws {
		let planner = WritePlanner(taskrc: .defaults, timeZone: .gmt)
		let id = UUID()

		let plan = try planner.plan(
			.edit([id], .setInput("due", text: "")),
			tasks: [id: ["due": "1893456000", "status": "pending"]],
			at: .now,
		)

		#expect(plan.operations.contains(.setValue(id, property: "due", value: nil)))
	}

	@Test(arguments: [("due", "bogus", DateInputError.invalid), ("project", "tomorrow", .invalid)])
	func settingInputThatDoesNotResolveThrows(property: String, text: String, error: DateInputError) {
		let planner = WritePlanner(taskrc: .defaults, timeZone: .gmt)
		let id = UUID()

		#expect(throws: WritePlanError.invalidInput(property: property, error)) {
			try planner.plan(
				.edit([id], .setInput(property, text: text)),
				tasks: [id: ["status": "pending"]],
				at: .now,
			)
		}
	}

	/// The CLI reads a missing or invalid `imask` as 0, overwriting another instance's status.
	@Test(arguments: ["1", "-1", "first", nil])
	func completingAnInstanceWithAnUnusableImaskLeavesTheMask(imask: String?) throws {
		let recording = try Recording("recurrence/complete_instance")
		let planner = WritePlanner(taskrc: recording.taskrc, timeZone: .gmt)
		let instance = try recording.instance()
		var tasks = recording.before
		tasks[instance]?["imask"] = imask

		let plan = try planner.plan(
			.complete([instance], chains: .repair),
			tasks: tasks,
			at: recording.now,
		)

		#expect(plan.operations.allSatisfy { $0.id == instance })
	}

	/// `task modify due:` refuses it with "You cannot remove the due date from a recurring task."
	@Test(arguments: [TaskEdit.set("due", nil), .setInput("due", text: "")])
	func removingDueFromAnInstanceThrows(edit: TaskEdit) throws {
		let recording = try Recording("recurrence/set_description_of_instance")
		let planner = WritePlanner(taskrc: recording.taskrc, timeZone: .gmt)
		let instance = try recording.instance()

		#expect(throws: WritePlanError.removedSeriesDue) {
			try planner.plan(.edit([instance], edit), tasks: recording.before, at: recording.now)
		}
	}

	/// So a `task modify recur:` that lands first fails the plan, rather than leaving a Series without
	/// its `due`.
	@Test
	func removingDueExpectsNoRecur() throws {
		let planner = WritePlanner(taskrc: .defaults, timeZone: .gmt)
		let id = UUID()
		let properties = ["due": "1893456000", "status": "pending"]

		let plan = try planner.plan(.edit([id], .set("due", nil)), tasks: [id: properties], at: .now)

		#expect(plan.expectations.contains(WritePlan.Expectation(
			property: "recur",
			uuid: id,
			value: nil,
		)))
	}

	/// The CLI repairs only the chain of the instance it was asked to delete.
	@Test
	func deletingASeriesRepairsTheChainOfEachTaskItDeletes() throws {
		let recording = try Recording("series/delete_series")
		let planner = WritePlanner(taskrc: recording.taskrc, timeZone: .gmt)
		let (deleted, sibling) = try (recording.deleted(), #require(recording.siblings().first))
		let (blocked, blocking) = (UUID(), UUID())
		var tasks = recording.before
		tasks[blocking] = ["status": "pending"]
		tasks[sibling]?["dep_\(blocking.uuidString.lowercased())"] = "x"
		tasks[blocked] = ["dep_\(sibling.uuidString.lowercased())": "x", "status": "pending"]

		let plan = try planner.plan(
			.deleteSeries(of: deleted, in: recording),
			tasks: tasks,
			at: recording.now,
		)

		#expect(plan.repairedChains == [
			WritePlan.RepairedChain(blocked: [blocked], blocking: [blocking], task: sibling),
		])
	}

	/// As a bulk Delete of two instances writes it, once for each.
	@Test
	func deletingTwoInstancesOfASeriesDeletesItOnce() throws {
		let recording = try Recording("series/delete_series")
		let planner = WritePlanner(taskrc: recording.taskrc, timeZone: .gmt)
		let deleted = try recording.deleted()
		let template = try #require(recording.before[deleted]?["parent"].flatMap(UUID.init(uuidString:)))
		let both = try WriteAction.delete(
			[deleted, recording.siblings()[0]],
			chains: .repair,
			series: [template],
		)

		let plan = try planner.plan(both, tasks: recording.before, at: recording.now)

		#expect(plan.applied(to: recording.before) == recording.after)
	}

	/// `task delete` finds siblings by `parent` alone, so they go even once the template is gone.
	@Test
	func deletingASeriesWhoseTemplateIsGoneDeletesItsSiblings() throws {
		let recording = try Recording("series/delete_series")
		let planner = WritePlanner(taskrc: recording.taskrc, timeZone: .gmt)
		let deleted = try recording.deleted()
		let template = try #require(recording.before[deleted]?["parent"].flatMap(UUID.init(uuidString:)))
		var tasks = recording.before
		tasks[template] = nil

		let plan = try planner.plan(
			.delete([deleted], chains: .repair, series: [template]),
			tasks: tasks,
			at: recording.now,
		)

		let applied = plan.applied(to: tasks)
		#expect(try recording.siblings().allSatisfy { applied[$0]?["status"] == "deleted" })
	}

	/// As a bulk edit of two instances writes it, once for each.
	@Test
	func editingTwoInstancesOfASeriesEditsItOnce() throws {
		let recording = try Recording("series/set_until_of_series")
		let planner = WritePlanner(taskrc: recording.taskrc, timeZone: .gmt)
		let instances = recording.pendingInstances()
		let template = try #require(recording.before[instances[0]]?["parent"]
			.flatMap(UUID.init(uuidString:)))
		let both = WriteAction.edit(
			Array(instances.prefix(2)),
			.set("until", .date(newYear2030)),
			series: [template],
		)

		let plan = try planner.plan(both, tasks: recording.before, at: recording.now)

		#expect(plan.applied(to: recording.before) == recording.after)
	}

	/// The CLI sets the date on every task in the Series, collapsing it onto one date.
	@Test(arguments: ["due", "scheduled", "wait"])
	func editingADateOfAnInstanceLeavesItsSeries(property: String) throws {
		let recording = try Recording("series/set_until_of_series")
		let planner = WritePlanner(taskrc: recording.taskrc, timeZone: .gmt)
		let instances = recording.pendingInstances()
		let instance = try #require(instances.first)
		let template = try #require(recording.before[instance]?["parent"].flatMap(UUID.init(uuidString:)))

		let plan = try planner.plan(
			.edit([instance], .setInput(property, text: "2030-01-01"), series: [template]),
			tasks: recording.before,
			at: recording.now,
		)

		let applied = plan.applied(to: recording.before)
		#expect(applied[instance]?[property] == "1893456000")
		#expect(instances.dropFirst().allSatisfy { applied[$0] == recording.before[$0] })
		#expect(applied[template]?[property] == recording.before[template]?[property])
	}

	@Test(arguments: [
		(TaskEdit.addAnnotation("Note", entry: .now), true),
		(.addDependency(UUID()), true),
		(.addTags(["work"]), true),
		(.removeAnnotation(entry: .now), false),
		(.removeDependency(UUID()), true),
		(.removeTag("work"), true),
		(.set("description", .string("Beta")), true),
		(.set("due", nil), false),
		(.set("review", .date(newYear2030)), false),
		(.set("scheduled", nil), false),
		(.set("until", nil), true),
		(.setInput("estimate", text: "1h"), true),
		(.setInput("until", text: "eom"), true),
		(.setInput("wait", text: "tomorrow"), false),
	])
	func cascadesToSeries(edit: TaskEdit, cascades: Bool) {
		let taskrc = Taskrc(path: "/taskrc", environment: .fixture) { path throws(Taskrc.ReadError) in
			Taskrc.File(
				contents: "uda.estimate.type=duration\nuda.review.type=date\n",
				realPath: path,
			)
		}

		#expect(WritePlanner(taskrc: taskrc, timeZone: .gmt).cascadesToSeries(edit) == cascades)
	}

	@Test
	func addingATagExpectsTheOtherTags() throws {
		let planner = WritePlanner(taskrc: .defaults, timeZone: .gmt)
		let id = UUID()
		let properties = ["status": "pending", "tag_home": "x", "tags": "home"]

		let plan = try planner.plan(.edit([id], .addTags(["work"])), tasks: [id: properties], at: .now)

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

/// 2029-12-01 in UTC, which the fixtures write as `2029-12-01`.
private let december2029 = Date(timeIntervalSince1970: 1_890_777_600)

/// 2030-01-01 in UTC, which the fixtures write as `2030-01-01`.
private let newYear2030 = Date(timeIntervalSince1970: 1_893_456_000)

/// A Taskrc whose active Context writes the reserved `+PENDING` to new tasks.
private let pendingContext = Taskrc(path: "/taskrc", environment: .fixture) {
	path throws(Taskrc.ReadError) in
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

	/// The one Recurrence instance before the write, which shares its template's description.
	func instance() throws -> Task.ID {
		try #require(before.first { $0.value["parent"] != nil }?.key)
	}

	/// The instance `task delete` was run on: the one whose `end` is the first operation on an
	/// instance, since the CLI deletes it before its siblings.
	func deleted() throws -> Task.ID {
		let ended = operations.compactMap { operation -> Task.ID? in
			guard case let .update(id, "end", _) = operation else {
				return nil
			}
			return id
		}
		return try #require(ended.first { before[$0]?["parent"] != nil })
	}

	/// The pending instances, in `imask` order.
	func pendingInstances() -> [Task.ID] {
		before
			.filter { $0.value["parent"] != nil && $0.value["status"] == "pending" }
			.sorted { Int($0.value["imask"] ?? "") ?? .max < Int($1.value["imask"] ?? "") ?? .max }
			.map(\.key)
	}

	/// The instances other than `deleted()`, in `imask` order.
	func siblings() throws -> [Task.ID] {
		let deleted = try deleted()
		return before
			.filter { $0.key != deleted && $0.value["parent"] != nil }
			.sorted { Int($0.value["imask"] ?? "") ?? .max < Int($1.value["imask"] ?? "") ?? .max }
			.map(\.key)
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

extension WriteAction {
	/// Deletes `instance` with the rest of its Series, as `recurrence.confirmation=yes` does.
	fileprivate static func deleteSeries(
		of instance: Task.ID,
		in recording: Recording,
	) throws -> Self {
		let template = try #require(recording.before[instance]?["parent"].flatMap(UUID.init(uuidString:)))
		return .delete([instance], chains: .repair, series: [template])
	}

	/// `edit` of the first pending instance with the rest of its Series, as
	/// `recurrence.confirmation=yes` makes it. The patch is the same on every pending instance, so any
	/// stands for the one `task` was run on.
	fileprivate static func editSeries(_ edit: TaskEdit, in recording: Recording) throws -> Self {
		let instance = try #require(recording.pendingInstances().first)
		let template = try #require(recording.before[instance]?["parent"].flatMap(UUID.init(uuidString:)))
		return .edit([instance], edit, series: [template])
	}
}
