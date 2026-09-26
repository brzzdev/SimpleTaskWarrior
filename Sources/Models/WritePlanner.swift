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
		case let .complete(ids):
			return try plan(ids, tasks: tasks, at: epoch) { $0.complete(at: epoch) }

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

		case let .delete(ids):
			return try plan(ids, tasks: tasks, at: epoch) { $0.delete(at: epoch) }

		case let .edit(ids, edit):
			let edit = edit.trimmed
			if case let .addAnnotation(text, _) = edit, text.isEmpty {
				throw .blankAnnotation
			}
			if let tag = edit.tag, reservedTags.contains(tag) {
				throw .reservedTag(tag)
			}
			guard case let .addDependency(dependency) = edit else {
				return try plan(ids, tasks: tasks, at: epoch) { $0.apply(edit) }
			}
			let searched = try refuseCycle(dependingOn: dependency, from: ids, tasks: tasks)
			var plan = try plan(ids, tasks: tasks, at: epoch) { $0.apply(edit) }
			guard !plan.operations.isEmpty else {
				return plan
			}
			for expectation in searched where !plan.expectations.contains(expectation) {
				plan.expectations.append(expectation)
			}
			return plan

		case let .markPending(ids):
			return try plan(ids, tasks: tasks, at: epoch) { $0.markPending() }

		case let .start(ids):
			return try plan(ids, tasks: tasks, at: epoch) { $0.start(at: epoch) }

		case let .stop(ids):
			return try plan(ids, tasks: tasks, at: epoch) { $0.stop() }
		}
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
			let references = { reference($0, in: properties) }
			let value: UDAValue? =
				switch taskrc.udaTypes[name] {
				case .date:
					(try? dateInput.date(text, at: now, references: references)).map(UDAValue.date)

				case .duration:
					(try? dateInput.duration(text, at: now, references: references))
						.map(UDAValue.duration)

				case nil, .numeric, .string, .uuid:
					.string(text)
				}
			guard let value else {
				continue
			}
			draft.set(name, value.stored)
		}
	}

	/// The tasks `properties` depend on, from its `dep_*` keys.
	private func dependencies(_ properties: [String: String]) -> [Task.ID] {
		properties.keys.compactMap { $0.dropPrefix("dep_").flatMap(UUID.init(uuidString:)) }
	}

	private func nonEmpty(_ key: String) -> String? {
		taskrc[key].flatMap { $0.isEmpty ? nil : $0 }
	}

	/// Plans `change` on each task in `ids`, once each, in order.
	private func plan(
		_ ids: [Task.ID],
		tasks: [Task.ID: [String: String]],
		at epoch: String,
		change: (inout Draft) -> Void,
	) throws(WritePlanError) -> WritePlan {
		var drafts: [Draft] = []
		var seen: Set<Task.ID> = []
		for id in ids where seen.insert(id).inserted {
			guard let properties = tasks[id] else {
				throw .noSuchTask(id)
			}
			var draft = Draft(id: id, properties: properties, isNew: false)
			change(&draft)
			draft.rewriteLegacyWaiting()
			drafts.append(draft)
		}
		return WritePlan(drafts, epoch: epoch)
	}

	/// What an expression reads for `name`: a date attribute or UDA as its value, dates and durations
	/// typed, or an empty string where the task has none, as TW reads one. Any other name is nil,
	/// which reads as its own text.
	private func reference(_ name: String, in properties: [String: String]) -> DateInput.Reference? {
		guard let type = dateAttributes.contains(name) ? .date : taskrc.udaTypes[name] else {
			return nil
		}
		guard let value = properties[name] else {
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
}

/// What the user did, over the tasks it names, which a re-plan reuses: a created task's UUID and an
/// annotation's entry are chosen once, when the user acts.
public enum WriteAction: Equatable, Sendable {
	/// `task done`, which leaves a task that isn't pending as it is.
	case complete([Task.ID])
	case create(Task.ID, description: String)
	/// `task delete`, which keeps `start`.
	case delete([Task.ID])
	case edit([Task.ID], TaskEdit)
	/// `task modify status:pending` on a completed or deleted task.
	case markPending([Task.ID])
	/// `task start`, which reopens a completed or deleted task.
	case start([Task.ID])
	case stop([Task.ID])
}

/// One change to each task an edit names. `wait` is an attribute like any other: setting it touches
/// `status` only to rewrite a legacy stored `waiting`, since TW 3 derives waiting from `wait`.
public enum TaskEdit: Equatable, Sendable {
	/// An annotation at `entry`, or the first free second after it, as `task annotate` does.
	case addAnnotation(String, entry: Date)
	case addDependency(Task.ID)
	case addTag(String)
	case removeAnnotation(entry: Date)
	case removeDependency(Task.ID)
	case removeTag(String)
	/// Sets an attribute, or removes it when `value` is nil or an empty string. Tags, dependencies,
	/// annotations and `status` have their own edits and actions.
	case set(String, UDAValue?)
}

extension TaskEdit {
	/// The tag an edit adds or removes.
	fileprivate var tag: String? {
		switch self {
		case let .addTag(tag), let .removeTag(tag): tag
		default: nil
		}
	}

	/// The edit with its text trimmed as `task annotate` and `task modify description:` trim it.
	fileprivate var trimmed: TaskEdit {
		switch self {
		case let .addAnnotation(text, entry):
			.addAnnotation(text.trimmingSpaces, entry: entry)

		case let .set("description", .string(description)):
			.set("description", .string(description.droppingTrailingSpaces))

		default:
			self
		}
	}
}

extension String {
	/// Without trailing spaces, as `task modify description:` stores its value, keeping leading ones.
	/// Other whitespace, such as a tab or a no-break space, stays.
	fileprivate var droppingTrailingSpaces: String {
		guard let last = lastIndex(where: { $0 != " " }) else {
			return ""
		}
		return String(self[...last])
	}

	/// Without leading or trailing spaces, as `task add` and `task annotate` store their text.
	fileprivate var trimmingSpaces: String {
		String(droppingTrailingSpaces.trimmingPrefix { $0 == " " })
	}
}

/// The attributes TW stores as dates, besides date UDAs.
private let dateAttributes: Set = [
	"due", "end", "entry", "modified", "scheduled", "start", "until", "wait",
]

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

public enum WritePlanError: Error, Equatable, Sendable {
	/// An annotation with no text, or only spaces, which `task annotate` refuses.
	case blankAnnotation
	/// A New Task with no description, or only spaces, which `task add` refuses. `task modify`
	/// accepts removing one, so an edit may remove it.
	case blankDescription
	/// The task would depend, through others, on a task that depends on it.
	case circularDependency(Task.ID)
	/// The task isn't in the snapshot, as after a `task undo` of its creation, or a purge.
	case noSuchTask(Task.ID)
	/// A virtual tag such as `PENDING`, which TW computes and refuses to add or remove.
	case reservedTag(String)
	/// The task would depend on itself.
	case selfDependency(Task.ID)
	/// A `default.due` or `default.scheduled` the app can't resolve: `task add` refuses invalid input
	/// and resolves a holiday, so a New Task without the date would differ either way.
	case unresolvedDefault(key: String, DateInputError)
}

public struct WritePlan: Equatable, Sendable {
	/// Every property the plan read, with the value it read, which must still hold for it to commit.
	public var expectations: [Expectation] = []
	/// Each task's changes, with `status` last, as `TDB2` writes it.
	public var operations: [Operation] = []
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
}

/// One task's properties as a plan changes them, recording what it reads before changing it.
private struct Draft {
	let id: Task.ID
	let isNew: Bool
	private(set) var properties: [String: String]
	/// Each property's value in the snapshot, for every property read before the plan changed it.
	private(set) var reads: [String: String?] = [:]

	private let original: [String: String]

	init(id: Task.ID, properties: [String: String], isNew: Bool) {
		self.id = id
		self.isNew = isNew
		self.properties = properties
		original = properties
	}

	mutating func apply(_ edit: TaskEdit) {
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

		case let .addTag(tag):
			setTag(tag, isPresent: true)

		case let .removeAnnotation(entry):
			set("annotation_\(entry.epoch)", nil)

		case let .removeDependency(dependency):
			setDependency(dependency, isPresent: false)

		case let .removeTag(tag):
			setTag(tag, isPresent: false)

		case let .set(property, value):
			set(property, value?.stored)
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

	/// A legacy stored `waiting` becomes `pending` on any write that changes the task, as TW 3 writes
	/// it back, while a write that changes nothing leaves it. Runs after the change it follows, and
	/// looks at `status` without reading it, so only a rewrite expects it.
	mutating func rewriteLegacyWaiting() {
		guard properties != original, properties["status"] == legacyWaiting else {
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

	private mutating func setDependency(_ dependency: Task.ID, isPresent: Bool) {
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
