public import Foundation
public import Taskrc

/// Turns a user action into the property operations `task` 3.5 would have written for it, plus the
/// expectations the engine checks before committing them as one Undo point.
///
/// A plan changes only what differs from the snapshot, so re-planning an action that already
/// landed, such as a retried New Task whose commit succeeded, plans nothing.
public struct WritePlanner: Sendable {
	private let dateInput: DateInput
	private let taskrc: Taskrc

	public init(taskrc: Taskrc, timeZone: TimeZone) {
		dateInput = DateInput(taskrc: taskrc, timeZone: timeZone)
		self.taskrc = taskrc
	}

	/// Plans `action` against `tasks`, every task's properties as the snapshot holds them.
	public func plan(
		_ action: WriteAction,
		tasks: [Task.ID: [String: String]],
		at now: Date,
	) throws(WritePlanError) -> WritePlan {
		let epoch = String(now.epoch)
		switch action {
		case let .complete(ids, chains):
			return try plan(ids, tasks: tasks, at: now, chains: chains) { $0.complete(at: epoch) }

		case let .create(id, description):
			let description = description.trimmingSpaces
			guard !description.isEmpty else {
				throw .blankDescription
			}
			guard tasks[id] == nil else {
				return WritePlan()
			}
			// After the retry check: a create that landed plans nothing, whatever the Context is now.
			if let tag = taskrc.contextWrite.tags.first(where: reservedTags.contains) {
				throw .reservedTag(tag)
			}
			var draft = Draft(id: id, properties: [:], isNew: true)
			try create(&draft, description: description, at: now, epoch: epoch)
			var plan = WritePlan([draft], epoch: epoch)
			if !plan.operations.isEmpty {
				plan.skippedContextWrite = taskrc.contextWrite.skipped
			}
			return plan

		case let .delete(ids, chains):
			return try plan(ids, tasks: tasks, at: now, chains: chains) { $0.delete(at: epoch) }

		case let .edit(ids, edit):
			let edit = edit.trimmed
			if case let .addAnnotation(text, _) = edit, text.isEmpty {
				throw .blankAnnotation
			}
			if let tag = edit.tags.first(where: reservedTags.contains) {
				throw .reservedTag(tag)
			}
			let apply = { (draft: inout Draft) throws(WritePlanError) in
				try draft.apply(edit, at: now, resolving: self)
			}
			guard case let .addDependency(dependency) = edit else {
				return try plan(ids, tasks: tasks, at: now, change: apply)
			}
			let searched = try refuseCycle(dependingOn: dependency, from: ids, tasks: tasks)
			var plan = try plan(ids, tasks: tasks, at: now, change: apply)
			guard !plan.operations.isEmpty else {
				return plan
			}
			for expectation in searched where !plan.expectations.contains(expectation) {
				plan.expectations.append(expectation)
			}
			return plan

		case let .markPending(ids):
			return try plan(ids, tasks: tasks, at: now) { $0.markPending() }

		case let .start(ids):
			return try plan(ids, tasks: tasks, at: now) { $0.start(at: epoch) }

		case let .stop(ids):
			return try plan(ids, tasks: tasks, at: now) { $0.stop() }
		}
	}

	/// What a `setInput` edit of `property` stores for `text` on a task with `properties`, or nil
	/// where it removes the attribute, so input can be checked and previewed as it's typed.
	public func resolve(
		_ text: String,
		for property: String,
		of properties: [String: String],
		at now: Date,
	) throws(DateInputError) -> String? {
		try resolve(text, for: property, at: now) { properties[$0] }
	}

	/// The value `text` stores for `property`, a date or duration, resolved at `now` against the
	/// attributes it refers to, each of which it `read`s. Empty text removes the attribute.
	fileprivate func resolve(
		_ text: String,
		for property: String,
		at now: Date,
		reading read: (String) -> String?,
	) throws(DateInputError) -> String? {
		guard !text.isEmpty else {
			return nil
		}
		let references = { reference($0, reading: read) }
		switch attributeType(property) {
		case .date:
			return try UDAValue.date(dateInput.date(text, at: now, references: references)).stored

		case .duration:
			return try UDAValue.duration(dateInput.duration(text, at: now, references: references)).stored

		case nil, .numeric, .string, .uuid:
			throw .invalid
		}
	}

	/// The type TW stores `attribute` as: a date for the built-in date attributes, else its UDA type.
	private func attributeType(_ attribute: String) -> UDAType? {
		dateAttributes.contains(attribute) ? .date : taskrc.udaTypes[attribute]
	}

	/// What `task add <description>` writes: `Task::validate`'s stamps and defaults, after the
	/// active Context's `project:` and `+tag` modifications, which the CLI applies as if typed.
	/// Throws where `default.due` or `default.scheduled` doesn't resolve.
	private func create(
		_ draft: inout Draft,
		description: String,
		at now: Date,
		epoch: String,
	) throws(WritePlanError) {
		draft.set("description", description)
		draft.set("entry", epoch)
		// Stamped here, not only by `operations(modified:)`, so defaults can refer to it.
		draft.set("modified", epoch)
		draft.set("status", Status.pending.rawValue)
		for tag in taskrc.contextWrite.tags {
			draft.setTag(tag, isPresent: true)
		}
		if let project = taskrc.contextWrite.project ?? nonEmpty("default.project") {
			draft.set("project", project)
		}
		for attribute in ["due", "scheduled"] {
			let key = "default.\(attribute)"
			guard let text = nonEmpty(key) else {
				continue
			}
			do {
				try draft.set(attribute, UDAValue.date(dateInput.date(text, at: now)).stored)
			} catch {
				throw .unresolvedDefault(key: key, error)
			}
		}
		// Every `uda.<name>…default…` key, as `Task::validate` finds them. A date or duration default
		// is resolved against the attributes set so far (`due`, `scheduled`, then UDAs by name), where
		// the CLI stores the text, which `task export` then drops.
		for key in taskrc.values.keys.sorted() where key.hasPrefix("uda.") && key.contains(".default") {
			guard
				let name = key.dropPrefix("uda.")?.split(separator: ".").first.map(String.init),
				draft.properties[name] == nil,
				let text = nonEmpty("uda.\(name).default")
			else {
				continue
			}
			let properties = draft.properties
			let value: String? =
				switch taskrc.udaTypes[name] {
				case .date, .duration: try? resolve(text, for: name, at: now) { properties[$0] }
				case nil, .numeric, .string, .uuid: text
				}
			guard let value else {
				continue
			}
			draft.set(name, value)
		}
	}

	/// The tasks `properties` depend on, from its `dep_*` keys.
	private func dependencies(_ properties: [String: String]) -> [Task.ID] {
		properties.keys.compactMap { $0.dropPrefix("dep_").flatMap(UUID.init(uuidString:)) }
	}

	private func nonEmpty(_ key: String) -> String? {
		taskrc[key].flatMap { $0.isEmpty ? nil : $0 }
	}

	/// Plans `change` on each task in `ids`, once each, in order, repairing each chain it breaks
	/// where `chains` says to, as `dependencyChainOnComplete` does after each task in turn. Closing
	/// one task can rewire the next, so the order matters: `task` goes in ID order, and so must the
	/// caller.
	private func plan(
		_ ids: [Task.ID],
		tasks: [Task.ID: [String: String]],
		at now: Date,
		chains: ChainRepair = .leave,
		change: (inout Draft) throws(WritePlanError) -> Void,
	) throws(WritePlanError) -> WritePlan {
		var drafts = Drafts(tasks: tasks)
		var repairedChains: [WritePlan.RepairedChain] = []
		var seen: Set<Task.ID> = []
		for id in ids where seen.insert(id).inserted {
			guard let index = drafts.index(id) else {
				throw .noSuchTask(id)
			}
			let status = drafts[index].properties["status"]
			try change(&drafts[index])
			// Only closing a task breaks a chain: a closed one stopped blocking when it closed.
			guard chains == .repair, isOpen(status), !isOpen(drafts[index].properties["status"]) else {
				continue
			}
			if let chain = repairChain(of: index, in: &drafts) {
				repairedChains.append(chain)
			}
		}
		// The indices are taken before the mask update drafts any template, which needs no pass of its
		// own: it has no `parent`.
		for index in drafts.all.indices {
			try drafts[index].refuseRemovingSeriesDue()
			drafts[index].rewriteLegacyWaiting()
			updateRecurrenceMask(of: index, in: &drafts, at: now)
		}
		var plan = WritePlan(drafts.all, epoch: String(now.epoch))
		plan.repairedChains = repairedChains
		return plan
	}

	/// Moves the open tasks that depend on the task the draft at `closing` just closed onto the open
	/// tasks it depends on, where there are both, and reports the chain.
	private func repairChain(
		of closing: Int,
		in drafts: inout Drafts,
	) -> WritePlan.RepairedChain? {
		let id = drafts[closing].id
		// Read only to expect them, so a dependency added or removed before the plan commits changes
		// the repair: `depends` catches an added one, which TW rewrites with the keys, and each
		// `dep_*` key its own removal, as `refuseCycle` expects both.
		_ = drafts[closing].read("depends")
		// Only the tasks it still blocks on, as `getDependencyTasks` reads them.
		var blocking: [Task.ID] = []
		for dependency in dependencies(drafts[closing].properties).sorted() {
			_ = drafts[closing].read("dep_\(dependency.uuidString.lowercased())")
			guard let index = drafts.index(dependency), isOpen(drafts[index].read("status")) else {
				continue
			}
			blocking.append(dependency)
		}
		guard !blocking.isEmpty else {
			return nil
		}
		// Found by scanning, so a dependent the CLI adds before the plan commits is left unrepaired,
		// as one added just after `task done` would be.
		let member = "dep_\(id.uuidString.lowercased())"
		var blocked: [Task.ID] = []
		for candidate in drafts.ids.filter({ drafts.properties($0)[member] != nil }).sorted() {
			guard let index = drafts.index(candidate), isOpen(drafts[index].read("status")) else {
				continue
			}
			drafts[index].setDependency(id, isPresent: false)
			for dependency in blocking where dependency != candidate {
				drafts[index].setDependency(dependency, isPresent: true)
			}
			blocked.append(candidate)
		}
		guard !blocked.isEmpty else {
			return nil
		}
		return WritePlan.RepairedChain(blocked: blocked, blocking: blocking, task: id)
	}

	/// What an expression reads for `name`: a date attribute or UDA as its value, dates and durations
	/// typed, or an empty string where the task has none, as TW reads one. Any other name is nil,
	/// which reads as its own text, and is never passed to `read`.
	private func reference(
		_ name: String,
		reading read: (String) -> String?,
	) -> DateInput.Reference? {
		guard let type = attributeType(name) else {
			return nil
		}
		guard let value = read(name) else {
			return .text("")
		}
		switch type {
		case .date:
			return Date(epoch: value).map(DateInput.Reference.date) ?? .text(value)

		case .duration:
			return TaskDuration(stored: value).map(DateInput.Reference.duration) ?? .text(value)

		case .numeric, .string, .uuid:
			return .text(value)
		}
	}

	/// Refuses a dependency `task modify depends:` refuses, as `Task::addDependency` does: on the
	/// task itself, or one that makes the task reachable from itself through `dep_*` keys, which
	/// `dependencyIsCircular` follows through tasks of any status. A dependency the task already has
	/// is left for the plan, since TW returns before searching. A task missing from the snapshot is
	/// left for the plan to report.
	///
	/// Returns what the search read of each task it passed through: its `dep_*` keys and the
	/// `depends` mirror every writer rewrites alongside them, so a dependency added to the chain
	/// before the plan commits fails it.
	private func refuseCycle(
		dependingOn dependency: Task.ID,
		from ids: [Task.ID],
		tasks: [Task.ID: [String: String]],
	) throws(WritePlanError) -> [WritePlan.Expectation] {
		var searched: [WritePlan.Expectation] = []
		for id in ids {
			guard let properties = tasks[id] else {
				continue
			}
			if id == dependency {
				throw .selfDependency(id)
			}
			guard properties["dep_\(dependency.uuidString.lowercased())"] == nil else {
				continue
			}
			var visited: Set<Task.ID> = []
			var unvisited = [dependency] + dependencies(properties)
			while let next = unvisited.popLast() {
				if next == id {
					throw .circularDependency(id)
				}
				guard visited.insert(next).inserted else {
					continue
				}
				let properties = tasks[next] ?? [:]
				for property in properties.keys.sorted() where property.hasPrefix("dep_") {
					let value = properties[property]
					searched.append(WritePlan.Expectation(property: property, uuid: next, value: value))
				}
				searched.append(
					WritePlan.Expectation(property: "depends", uuid: next, value: properties["depends"]),
				)
				unvisited += dependencies(properties)
			}
		}
		return searched
	}

	/// Records the status of the Recurrence instance the draft at `index` changed in its template's
	/// `mask`, as TW's `updateRecurrenceMask` does: `-` pending, `W` waiting at `now`, `+` completed,
	/// `X` deleted. Only the instance's character changes, so the mask never shortens, and a missing,
	/// invalid or out-of-range `imask` leaves it alone, where TW reads a missing or invalid one as 0.
	private func updateRecurrenceMask(of index: Int, in drafts: inout Drafts, at now: Date) {
		guard drafts[index].isChanged, drafts[index].properties["parent"] != nil else {
			return
		}
		// Read, so a CLI write that moves the instance to another template or index fails the plan.
		guard
			let templateID = drafts[index].read("parent").flatMap(UUID.init(uuidString:)),
			let imask = drafts[index].read("imask").flatMap(Int.init),
			let template = drafts.index(templateID),
			var mask = drafts[template].read("mask").map(Array.init),
			mask.indices.contains(imask),
			let status = drafts[index].read("status").flatMap(Status.init(rawValue:))
		else {
			return
		}
		let symbol: Character =
			switch status {
			case .completed:
				"+"

			case .deleted:
				"X"

			// `Task.isWaiting`, over the stored `wait`.
			case .pending:
				drafts[index].read("wait").flatMap { Date(epoch: $0) }.map { $0 > now } == true ? "W" : "-"

			// Only a template has this status; TW writes `?` for an instance that has it anyway.
			case .recurring:
				"?"
			}
		mask[imask] = symbol
		drafts[template].set("mask", String(mask))
	}
}

/// What the user did, over the tasks it names, which a re-plan reuses: a created task's UUID and an
/// annotation's entry are chosen once, when the user acts.
public enum WriteAction: Equatable, Sendable {
	/// `task done`, which leaves a task that isn't pending as it is.
	case complete([Task.ID], chains: ChainRepair)
	case create(Task.ID, description: String)
	/// `task delete`, which keeps `start`.
	case delete([Task.ID], chains: ChainRepair)
	case edit([Task.ID], TaskEdit)
	/// `task modify status:pending` on a completed or deleted task.
	case markPending([Task.ID])
	/// `task start`, which reopens a completed or deleted task.
	case start([Task.ID])
	case stop([Task.ID])
}

/// What a Done or Delete does to a dependency chain it breaks: a task it closes that both blocks
/// and is blocked, as `task` asks under `dependency.confirmation`.
public enum ChainRepair: Equatable, Sendable {
	/// Leaves each dependent depending on the closed task, as answering no does.
	case leave
	/// Moves each open dependent of the closed task onto the open tasks it depended on.
	case repair
}

/// One change to each task an edit names. `wait` is an attribute like any other: setting it touches
/// `status` only to rewrite a legacy stored `waiting`, since TW 3 derives waiting from `wait`.
public enum TaskEdit: Equatable, Sendable {
	/// An annotation at `entry`, or the first free second after it, as `task annotate` does.
	case addAnnotation(String, entry: Date)
	case addDependency(Task.ID)
	/// Adds each tag, as `task modify +a +b` does in one command.
	case addTags([String])
	case removeAnnotation(entry: Date)
	case removeDependency(Task.ID)
	case removeTag(String)
	/// Sets an attribute, or removes it when `value` is nil or an empty string. A description loses
	/// its trailing spaces first, so one of only spaces removes it. Tags, dependencies, annotations
	/// and `status` have their own edits and actions.
	case set(String, UDAValue?)
	/// Sets a date or duration attribute from text in Taskwarrior's syntax, as `DateInput` reads it,
	/// resolved as the plan is made, so a relative date means the moment it's written. The attributes
	/// it refers to, as in `wait:due-1wk`, must still hold for the plan to commit. Empty text removes
	/// the attribute.
	case setInput(String, text: String)
}

extension TaskEdit {
	/// The tags an edit adds or removes.
	fileprivate var tags: [String] {
		switch self {
		case let .addTags(tags): tags
		case let .removeTag(tag): [tag]
		default: []
		}
	}

	/// The edit with its text trimmed as `task annotate` and `task modify description:` trim it.
	fileprivate var trimmed: TaskEdit {
		switch self {
		case let .addAnnotation(text, entry):
			.addAnnotation(text.trimmingSpaces, entry: entry)

		case let .set("description", .string(description)):
			.set("description", .string(description.trimmingTrailingSpaces))

		default:
			self
		}
	}
}

// Spaces are trimmed as scalars, as `task` trims bytes: a space followed by a combining mark shares
// a `Character` with it, yet `task` still drops it.
extension String {
	/// Without trailing spaces, as `task modify description:` stores its value, keeping leading ones.
	/// Other whitespace, such as a tab or a no-break space, stays.
	fileprivate var trimmingTrailingSpaces: String {
		var scalars = unicodeScalars[...]
		while scalars.last == " " {
			scalars.removeLast()
		}
		return String(scalars)
	}

	/// Without leading or trailing spaces, as `task add` and `task annotate` store their text.
	fileprivate var trimmingSpaces: String {
		String(trimmingTrailingSpaces.unicodeScalars.drop { $0 == " " })
	}
}

/// The attributes TW stores as dates, besides date UDAs.
private let dateAttributes: Set = [
	"due", "end", "entry", "modified", "scheduled", "start", "until", "wait",
]

/// Whether a task with `status` blocks or is blocked: any status but completed or deleted, as
/// `Status.isOpen` reads it, a Recurrence template and a legacy `waiting` included.
private func isOpen(_ status: String?) -> Bool {
	status.flatMap(Status.init(rawValue:))?.isOpen ?? true
}

/// The status TW 2 stored for a waiting task, which `Status` doesn't decode. TW 3 reads it as
/// pending and writes it back as `pending`.
private let legacyWaiting = "waiting"

/// TW's virtual tags, which `task` refuses to add or remove, as `feedback_reserved_tags` lists
/// them. Only these uppercase names are reserved: `pending` is an ordinary tag.
private let reservedTags: Set = [
	"ACTIVE", "ANNOTATED", "BLOCKED", "BLOCKING", "CHILD", "COMPLETED", "DELETED", "DUE", "DUETODAY",
	"INSTANCE", "LATEST", "MONTH", "ORPHAN", "OVERDUE", "PARENT", "PENDING", "PRIORITY", "PROJECT",
	"QUARTER", "READY", "SCHEDULED", "TAGGED", "TEMPLATE", "TODAY", "TOMORROW", "UDA", "UNBLOCKED",
	"UNTIL", "WAITING", "WEEK", "YEAR", "YESTERDAY",
]

public enum WritePlanError: Equatable, LocalizedError, Sendable {
	/// An annotation with no text, or only spaces, which `task annotate` refuses.
	case blankAnnotation
	/// A New Task with no description, or only spaces, which `task add` refuses. `task modify`
	/// accepts removing one, so an edit may remove it.
	case blankDescription
	/// The task would depend, through others, on a task that depends on it.
	case circularDependency(Task.ID)
	/// Text a `setInput` edit can't resolve for its attribute.
	case invalidInput(property: String, DateInputError)
	/// The task isn't in the snapshot, as after a `task undo` of its creation, or a purge.
	case noSuchTask(Task.ID)
	/// An edit removing `due` from a task in a Series, which repeats from it.
	case removedSeriesDue
	/// A virtual tag such as `PENDING`, which TW computes and refuses to add or remove.
	case reservedTag(String)
	/// The task would depend on itself.
	case selfDependency(Task.ID)
	/// A `default.due` or `default.scheduled` the app can't resolve: `task add` refuses invalid input
	/// and resolves a holiday, so a New Task without the date would differ either way.
	case unresolvedDefault(key: String, DateInputError)

	public var errorDescription: String? {
		switch self {
		case .blankAnnotation:
			String(localized: "An annotation needs text.")

		case .blankDescription:
			String(localized: "A task needs a description.")

		case .circularDependency:
			String(localized: "The task would come to depend on itself through other tasks.")

		case let .invalidInput(property, error):
			String(localized: "\(property): \(error.localizedDescription)")

		case .noSuchTask:
			String(localized: "The task no longer exists.")

		case .removedSeriesDue:
			String(
				localized: "A repeating task needs a due date, which its series repeats from. Change the series with the task command.",
			)

		case let .reservedTag(tag):
			String(localized: "\(tag) is a virtual tag, which Taskwarrior sets itself.")

		case .selfDependency:
			String(localized: "A task can't depend on itself.")

		case let .unresolvedDefault(key, error):
			String(localized: "The Taskrc's \(key) can't be resolved: \(error.localizedDescription)")
		}
	}
}

public struct WritePlan: Equatable, Sendable {
	/// Every property the plan read, with the value it read, which must still hold for it to commit.
	public var expectations: [Expectation] = []
	/// Each task's changes, with `status` last, as `TDB2` writes it.
	public var operations: [Operation] = []
	/// The chains the plan repairs, in the order it closes their tasks.
	public var repairedChains: [RepairedChain] = []
	/// The active Context's write modifications a New Task left out, being neither `project:` nor
	/// `+tag`.
	public var skippedContextWrite: [String] = []

	public init() {}

	/// Empty when no draft changed, since a plan that writes nothing needs nothing to hold.
	fileprivate init(_ drafts: [Draft], epoch: String) {
		operations = drafts.flatMap { $0.operations(modified: epoch) }
		guard !operations.isEmpty else {
			return
		}
		// The engine refuses to create a task that exists, so a new one needs no expectations.
		expectations = drafts.filter { !$0.isNew }.flatMap { draft in
			draft.reads.sorted { $0.key < $1.key }.map { property, value in
				Expectation(property: property, uuid: draft.id, value: value)
			}
		}
	}
}

extension WritePlan {
	public struct Expectation: Hashable, Sendable {
		public var property: String
		public var uuid: Task.ID
		/// Nil for a property the task doesn't have.
		public var value: String?

		public init(property: String, uuid: Task.ID, value: String?) {
			self.property = property
			self.uuid = uuid
			self.value = value
		}
	}

	/// The engine's primitives, which write exactly what they name.
	public enum Operation: Hashable, Sendable {
		case create(Task.ID)
		case setStatus(Task.ID, Status)
		/// Removes the property when `value` is nil.
		case setValue(Task.ID, property: String, value: String?)
	}

	/// A closed task's open dependents, moved onto the open tasks it depended on.
	public struct RepairedChain: Equatable, Sendable {
		/// The dependents, which depend on `blocking` instead.
		public var blocked: [Task.ID]
		public var blocking: [Task.ID]
		/// The task closed.
		public var task: Task.ID

		public init(blocked: [Task.ID], blocking: [Task.ID], task: Task.ID) {
			self.blocked = blocked
			self.blocking = blocking
			self.task = task
		}
	}

	/// `tasks` with the plan applied, as the engine would commit it.
	public func applied(to tasks: [Task.ID: [String: String]]) -> [Task.ID: [String: String]] {
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
}

/// One task's properties as a plan changes them, recording what it reads before changing it.
private struct Draft {
	let id: Task.ID
	let isNew: Bool
	private(set) var properties: [String: String]
	/// Each property's value in the snapshot, for every property read before the plan changed it.
	private(set) var reads: [String: String?] = [:]

	private let original: [String: String]

	var isChanged: Bool {
		properties != original
	}

	init(id: Task.ID, properties: [String: String], isNew: Bool) {
		self.id = id
		self.isNew = isNew
		self.properties = properties
		original = properties
	}

	/// Applies `edit`, resolving input with `planner` at `now`.
	mutating func apply(
		_ edit: TaskEdit,
		at now: Date,
		resolving planner: WritePlanner,
	) throws(WritePlanError) {
		switch edit {
		case let .addAnnotation(description, entry):
			var second = entry.epoch
			while let existing = read("annotation_\(second)") {
				// Already added, by an earlier attempt at this action.
				if existing == description {
					return
				}
				second += 1
			}
			set("annotation_\(second)", description)

		case let .addDependency(dependency):
			setDependency(dependency, isPresent: true)

		case let .addTags(tags):
			for tag in tags {
				setTag(tag, isPresent: true)
			}

		case let .removeAnnotation(entry):
			set("annotation_\(entry.epoch)", nil)

		case let .removeDependency(dependency):
			setDependency(dependency, isPresent: false)

		case let .removeTag(tag):
			setTag(tag, isPresent: false)

		case let .set(property, value):
			set(property, value?.stored)

		case let .setInput(property, text):
			do throws(DateInputError) {
				let value = try planner.resolve(text, for: property, at: now) { read($0) }
				set(property, value)
			} catch {
				throw .invalidInput(property: property, error)
			}
		}
	}

	/// `task done`: only from pending, removing `start`. A legacy stored `waiting` is pending too.
	mutating func complete(at epoch: String) {
		let status = read("status")
		guard status == Status.pending.rawValue || status == legacyWaiting else {
			return
		}
		stampEnd(at: epoch)
		set("start", nil)
		set("status", Status.completed.rawValue)
	}

	/// `task delete`: from anything but deleted, keeping `start`.
	mutating func delete(at epoch: String) {
		guard read("status") != Status.deleted.rawValue else {
			return
		}
		stampEnd(at: epoch)
		set("status", Status.deleted.rawValue)
	}

	/// `modify status:pending`, where `Task::validate` removes `end` from a pending task. A legacy
	/// stored `waiting` changes to `pending` too.
	mutating func markPending() {
		let status = read("status")
		let from = [Status.completed.rawValue, Status.deleted.rawValue, legacyWaiting]
		guard let status, from.contains(status) else {
			return
		}
		set("end", nil)
		set("status", Status.pending.rawValue)
	}

	/// The changes, stamped with `modified` when there are any.
	func operations(modified epoch: String) -> [WritePlan.Operation] {
		let changed = Set(properties.keys).union(original.keys).filter { properties[$0] != original[$0] }
		guard !changed.isEmpty else {
			return []
		}
		var operations: [WritePlan.Operation] = isNew ? [.create(id)] : []
		for property in changed.union(["modified"]).sorted() where property != "status" {
			let value = property == "modified" ? epoch : properties[property]
			operations.append(.setValue(id, property: property, value: value))
		}
		if changed.contains("status"), let status = properties["status"].flatMap(Status.init(rawValue:)) {
			operations.append(.setStatus(id, status))
		}
		return operations
	}

	mutating func read(_ property: String) -> String? {
		if reads[property] == nil, properties[property] == original[property] {
			reads[property] = .some(original[property])
		}
		return properties[property]
	}

	/// Refuses removing `due` from a task with `recur`, as `task modify due:` does, whichever change
	/// removed it. A removal reads `recur` either way, so a CLI write that adds one fails the plan.
	mutating func refuseRemovingSeriesDue() throws(WritePlanError) {
		guard original["due"] != nil, properties["due"] == nil, read("recur") != nil else {
			return
		}
		throw .removedSeriesDue
	}

	/// A legacy stored `waiting` becomes `pending` on any write that changes the task, as TW 3 writes
	/// it back, while a write that changes nothing leaves it. Runs after the change it follows, and
	/// looks at `status` without reading it, so only a rewrite expects it.
	mutating func rewriteLegacyWaiting() {
		guard isChanged, properties["status"] == legacyWaiting else {
			return
		}
		set("status", Status.pending.rawValue)
	}

	/// Sets `property`, or removes it when `value` is nil, having read it: a plan changes a property
	/// only on the strength of its current value.
	mutating func set(_ property: String, _ value: String?) {
		_ = read(property)
		properties[property] = value
	}

	mutating func setTag(_ tag: String, isPresent: Bool) {
		setMember(tag, isPresent: isPresent, prefix: "tag_", mirror: "tags")
	}

	/// `task start`: only when not started, reopening a completed or deleted task.
	mutating func start(at epoch: String) {
		guard read("start") == nil else {
			return
		}
		set("start", epoch)
		markPending()
	}

	/// `task stop`.
	mutating func stop() {
		set("start", nil)
	}

	mutating func setDependency(_ dependency: Task.ID, isPresent: Bool) {
		let member = dependency.uuidString.lowercased()
		setMember(member, isPresent: isPresent, prefix: "dep_", mirror: "depends")
	}

	/// Adds or removes a `tag_*` or `dep_*` key, stored as `"x"` as TW writes them, and rewrites the
	/// legacy mirror that lists them, in byte order, which TW writes but never reads back.
	private mutating func setMember(
		_ member: String,
		isPresent: Bool,
		prefix: String,
		mirror: String,
	) {
		let property = prefix + member
		guard (read(property) != nil) != isPresent else {
			return
		}
		set(property, isPresent ? "x" : nil)
		for key in original.keys where key.hasPrefix(prefix) {
			_ = read(key)
		}
		let members = properties.keys
			.compactMap { $0.dropPrefix(prefix) }
			.sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
		set(mirror, members.isEmpty ? nil : members.joined(separator: ","))
	}

	private mutating func stampEnd(at epoch: String) {
		if read("end") == nil {
			set("end", epoch)
		}
	}
}

/// The drafts a plan makes, in the order it first reads each task. A repair drafts the other tasks
/// it reads, which a later task the action names may be.
private struct Drafts {
	private(set) var all: [Draft] = []

	private var indices: [Task.ID: Int] = [:]
	private let tasks: [Task.ID: [String: String]]

	/// Every task in the snapshot.
	var ids: Dictionary<Task.ID, [String: String]>.Keys {
		tasks.keys
	}

	init(tasks: [Task.ID: [String: String]]) {
		self.tasks = tasks
	}

	subscript(index: Int) -> Draft {
		get { all[index] }
		set { all[index] = newValue }
	}

	/// The index of the draft of `id`, drafted from the snapshot first where it isn't yet, or nil
	/// where the snapshot has no such task.
	mutating func index(_ id: Task.ID) -> Int? {
		if let index = indices[id] {
			return index
		}
		guard let properties = tasks[id] else {
			return nil
		}
		indices[id] = all.count
		all.append(Draft(id: id, properties: properties, isNew: false))
		return all.count - 1
	}

	/// The properties of `id` as the plan has them so far, without reading them: none where the
	/// snapshot has no such task.
	func properties(_ id: Task.ID) -> [String: String] {
		indices[id].map { all[$0].properties } ?? tasks[id] ?? [:]
	}
}
