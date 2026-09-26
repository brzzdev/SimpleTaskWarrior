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
		if case let .create(id, description) = action {
			guard tasks[id] == nil else {
				return WritePlan()
			}
			var draft = Draft(id: id, properties: [:], isNew: true)
			create(&draft, description: description, at: now)
			return WritePlan([draft], now: epoch, skippedContextWrite: taskrc.contextWrite.skipped)
		}

		var drafts: [Draft] = []
		for id in action.ids where !drafts.contains(where: { $0.id == id }) {
			guard let properties = tasks[id] else {
				throw .noSuchTask(id)
			}
			var draft = Draft(id: id, properties: properties, isNew: false)
			switch action {
			case .complete: draft.complete(at: epoch)
			case .create: break
			case .delete: draft.delete(at: epoch)
			case let .edit(_, edit): draft.apply(edit)
			case .markPending: draft.markPending()
			case .start: draft.start(at: epoch)
			case .stop: draft.stop()
			}
			drafts.append(draft)
		}
		return WritePlan(drafts, now: epoch)
	}

	/// What `task add <description>` writes: `Task::validate`'s stamps and defaults, after the
	/// active Context's `project:` and `+tag` modifications, which the CLI applies as if typed.
	private func create(_ draft: inout Draft, description: String, at now: Date) {
		draft.set("description", description)
		draft.set("entry", String(now.epoch))
		draft.set("status", Status.pending.rawValue)
		for tag in taskrc.contextWrite.tags {
			draft.setTag(tag, isPresent: true)
		}
		if let project = taskrc.contextWrite.project ?? nonEmpty("default.project") {
			draft.set("project", project)
		}
		for attribute in ["due", "scheduled"] {
			guard
				let text = nonEmpty("default.\(attribute)"),
				let date = try? dateInput.date(text, at: now)
			else {
				continue
			}
			draft.set(attribute, UDAValue.date(date).stored)
		}
		// Every `uda.<name>…default…` key, as `Task::validate` finds them. A date or duration default
		// is resolved, where the CLI stores the text, which `task export` then drops.
		for key in taskrc.values.keys.sorted() where key.hasPrefix("uda.") && key.contains(".default") {
			guard
				let name = key.dropFirst("uda.".count).split(separator: ".").first.map(String.init),
				draft.properties[name] == nil,
				let text = nonEmpty("uda.\(name).default")
			else {
				continue
			}
			switch taskrc.udaTypes[name] {
			case .date:
				guard let date = try? dateInput.date(text, at: now) else {
					continue
				}
				draft.set(name, UDAValue.date(date).stored)

			case .duration:
				guard let duration = try? dateInput.duration(text, at: now) else {
					continue
				}
				draft.set(name, duration.iso)

			case nil, .numeric, .string, .uuid:
				draft.set(name, text)
			}
		}
	}

	private func nonEmpty(_ key: String) -> String? {
		taskrc[key].flatMap { $0.isEmpty ? nil : $0 }
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

	fileprivate var ids: [Task.ID] {
		switch self {
		case let .complete(ids), let .delete(ids), let .edit(ids, _), let .markPending(ids),
		     let .start(ids), let .stop(ids):
			ids

		case let .create(id, _):
			[id]
		}
	}
}

/// One change to each task an edit names. `wait` is an attribute like any other: setting it never
/// touches `status`, since TW 3 derives waiting from it.
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

public enum WritePlanError: Error, Equatable, Sendable {
	/// The task isn't in the snapshot, as after a `task undo` of its creation, or a purge.
	case noSuchTask(Task.ID)
}

public struct WritePlan: Equatable, Sendable {
	/// Every property the plan read, with the value it read, which must still hold for it to commit.
	public var expectations: [Expectation] = []
	/// Each task's changes, with `status` last, as `TDB2` writes it.
	public var operations: [Operation] = []
	/// The active Context's write modifications a New Task left out, being neither `project:` nor
	/// `+tag`.
	public var skippedContextWrite: [String] = []

	public init(
		expectations: [Expectation] = [],
		operations: [Operation] = [],
		skippedContextWrite: [String] = [],
	) {
		self.expectations = expectations
		self.operations = operations
		self.skippedContextWrite = skippedContextWrite
	}

	/// Empty when no draft changed, since a plan that writes nothing needs nothing to hold.
	fileprivate init(_ drafts: [Draft], now: String, skippedContextWrite: [String] = []) {
		operations = drafts.flatMap { $0.operations(modified: now) }
		guard !operations.isEmpty else {
			return
		}
		// The engine refuses to create a task that exists, so a new one needs no expectations.
		expectations = drafts.filter { !$0.isNew }.flatMap { draft in
			draft.reads.sorted { $0.key < $1.key }.map { property, value in
				Expectation(property: property, uuid: draft.id, value: value)
			}
		}
		self.skippedContextWrite = skippedContextWrite
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

extension UDAValue {
	/// The value as TW stores it, or nil for an empty string, which TW stores by removing the key.
	public var stored: String? {
		switch self {
		case let .date(date):
			String(date.epoch)

		case let .duration(duration):
			duration.iso

		// An integer as it is, and anything else as `std::ostream` writes a double: six significant
		// digits. The CLI keeps the integer form only for input typed without a point, which a
		// `Double` can't tell apart.
		case let .numeric(number):
			if number.rounded() == number, abs(number) < 1e15 {
				String(Int(number))
			} else {
				String(format: "%g", number)
			}

		case let .string(string):
			string.isEmpty ? nil : string

		case let .uuid(uuid):
			uuid.uuidString.lowercased()
		}
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

	/// The changes, stamped with `modified` when there are any.
	func operations(modified now: String) -> [WritePlan.Operation] {
		let changed = Set(properties.keys).union(original.keys).filter { properties[$0] != original[$0] }
		guard !changed.isEmpty else {
			return []
		}
		var operations: [WritePlan.Operation] = isNew ? [.create(id)] : []
		for property in changed.union(["modified"]).sorted() where property != "status" {
			let value = property == "modified" ? now : properties[property]
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

	/// Sets `property`, or removes it when `value` is nil.
	mutating func set(_ property: String, _ value: String?) {
		properties[property] = value
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
			let property = "annotation_\(entry.epoch)"
			_ = read(property)
			set(property, nil)

		case let .removeDependency(dependency):
			setDependency(dependency, isPresent: false)

		case let .removeTag(tag):
			setTag(tag, isPresent: false)

		case let .set(property, value):
			_ = read(property)
			set(property, value?.stored)
		}
	}

	/// `task done`: only from pending, removing `start`.
	mutating func complete(at now: String) {
		guard read("status") == Status.pending.rawValue else {
			return
		}
		stampEnd(at: now)
		_ = read("start")
		set("start", nil)
		set("status", Status.completed.rawValue)
	}

	/// `task delete`: from anything but deleted, keeping `start`.
	mutating func delete(at now: String) {
		guard read("status") != Status.deleted.rawValue else {
			return
		}
		stampEnd(at: now)
		set("status", Status.deleted.rawValue)
	}

	/// `modify status:pending`, where `Task::validate` removes `end` from a pending task.
	mutating func markPending() {
		let status = read("status")
		guard status == Status.completed.rawValue || status == Status.deleted.rawValue else {
			return
		}
		_ = read("end")
		set("end", nil)
		set("status", Status.pending.rawValue)
	}

	/// `task start`: only when not started, reopening a completed or deleted task.
	mutating func start(at now: String) {
		guard read("start") == nil else {
			return
		}
		set("start", now)
		markPending()
	}

	/// `task stop`.
	mutating func stop() {
		_ = read("start")
		set("start", nil)
	}

	mutating func setTag(_ tag: String, isPresent: Bool) {
		setMember("tag_\(tag)", isPresent: isPresent, mirror: "tags", prefix: "tag_")
	}

	private mutating func setDependency(_ dependency: Task.ID, isPresent: Bool) {
		let property = "dep_\(dependency.uuidString.lowercased())"
		setMember(property, isPresent: isPresent, mirror: "depends", prefix: "dep_")
	}

	/// Adds or removes a `tag_*` or `dep_*` key, stored as `"x"` as TW writes them, and rewrites the
	/// legacy mirror that lists them, in byte order, which TW writes but never reads back.
	private mutating func setMember(
		_ property: String,
		isPresent: Bool,
		mirror: String,
		prefix: String,
	) {
		guard (read(property) != nil) != isPresent else {
			return
		}
		set(property, isPresent ? "x" : nil)
		for key in original.keys where key.hasPrefix(prefix) {
			_ = read(key)
		}
		_ = read(mirror)
		let members = properties.keys
			.filter { $0.hasPrefix(prefix) }
			.map { String($0.dropFirst(prefix.count)) }
			.sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
		set(mirror, members.isEmpty ? nil : members.joined(separator: ","))
	}

	private mutating func stampEnd(at now: String) {
		if read("end") == nil {
			set("end", now)
		}
	}
}
