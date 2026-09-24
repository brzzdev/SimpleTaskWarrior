// Task decoding, Urgency, the blocked rule and the write planner: every Taskwarrior rule, in Swift.
public import Foundation
public import Taskrc

/// A task decoded from the properties TaskChampion stores, as `task` 3.5 reads them.
public struct Task: Equatable, Identifiable, Sendable {
	public var annotations: [Annotation] = []
	/// The tasks this one depends on, from its `dep_<uuid>` keys.
	public var dependencies: Set<UUID> = []
	public var description: String
	public var due: Date?
	public var end: Date?
	public var entry: Date?
	/// The task's UUID, which holds still while the CLI renumbers `workingSetID`.
	public var id: UUID
	/// A Recurrence instance's index into its template's `mask`, as stored.
	public var imask: String?
	/// A Recurrence template's last generated index, as stored.
	public var last: String?
	/// A Recurrence template's record of each instance's status, as stored.
	public var mask: String?
	public var modified: Date?
	/// Keys that are neither Taskwarrior's nor a UDA the Taskrc defines, kept as stored.
	public var orphans: [String: String] = [:]
	/// A Recurrence instance's template UUID, as stored.
	public var parent: String?
	public var project: String?
	public var recur: String?
	public var rtype: String?
	public var scheduled: Date?
	public var start: Date?
	public var status: Status
	public var tags: Set<String> = []
	/// The template UUID of an instance from a TW version that stored it under this name, as stored.
	public var template: String?
	/// The UDAs the Taskrc defines, keyed by name.
	public var udas: [String: UDAValue] = [:]
	public var until: Date?
	public var wait: Date?
	/// The ID `task` shows, absent when the task has left the working set.
	public var workingSetID: Int?

	public init(description: String = "", id: UUID, status: Status, workingSetID: Int?) {
		self.description = description
		self.id = id
		self.status = status
		self.workingSetID = workingSetID
	}
}

extension Task {
	public struct Annotation: Equatable, Sendable {
		public var description: String
		public var entry: Date

		public init(description: String, entry: Date) {
			self.description = description
			self.entry = entry
		}
	}

	/// Whether this is a Recurrence template, which every view and count leaves out, deleted ones
	/// included.
	public var isTemplate: Bool {
		status == .recurring || hasTemplateTag
	}

	/// TW's `+TEMPLATE`, which looks only for the keys a template carries.
	var hasTemplateTag: Bool {
		mask != nil || last != nil
	}

	/// Decodes a task from the properties TaskChampion stores, reading the UDAs in `udaTypes`, or nil
	/// when its UUID or status is one this app doesn't read.
	public init?(
		properties: [String: String],
		udaTypes: [String: UDAType],
		uuid: String,
		workingSetID: Int?,
	) {
		guard
			let id = UUID(uuidString: uuid),
			let status = properties["status"].flatMap(Status.init(rawValue:))
		else {
			return nil
		}
		self.init(id: id, status: status, workingSetID: workingSetID)
		for (key, value) in properties {
			if let tag = key.dropPrefix("tag_") {
				tags.insert(tag)
				continue
			}
			if let dependency = key.dropPrefix("dep_") {
				if let uuid = UUID(uuidString: dependency) {
					dependencies.insert(uuid)
				}
				continue
			}
			if let entry = key.dropPrefix("annotation_") {
				if let entry = Date(epoch: entry) {
					annotations.append(Annotation(description: value, entry: entry))
				}
				continue
			}
			switch key {
			case "description": description = value

			case "due": due = Date(epoch: value)

			case "end": end = Date(epoch: value)

			case "entry": entry = Date(epoch: value)

			case "imask": imask = value

			case "last": last = value

			case "mask": mask = value

			case "modified": modified = Date(epoch: value)

			case "parent": parent = value

			case "project": project = value

			case "recur": recur = value

			case "rtype": rtype = value

			case "scheduled": scheduled = Date(epoch: value)

			case "start": start = Date(epoch: value)

			case "template": template = value

			case "until": until = Date(epoch: value)

			case "wait": wait = Date(epoch: value)

			// Mirrors of `dep_*` and `tag_*` that TW writes but never reads back, and names TW reserves.
			case "depends", "id", "status", "tags", "urgency", "uuid": continue

			default:
				if let type = udaTypes[key] {
					udas[key] = UDAValue(value, as: type)
				} else {
					orphans[key] = value
				}
			}
		}
		annotations.sort { $0.entry < $1.entry }
	}
}

public enum Status: String, Sendable {
	case completed
	case deleted
	case pending
	case recurring
}

public enum UDAValue: Equatable, Sendable {
	case date(Date)
	/// ISO 8601, as TW stores it.
	case duration(String)
	case numeric(Double)
	/// A string UDA, or any value that doesn't read as its UDA's type, as stored.
	case string(String)
	case uuid(UUID)

	/// The type this value reads as, where one that didn't read as its UDA's type is a string.
	var type: UDAType {
		switch self {
		case .date: .date
		case .duration: .duration
		case .numeric: .numeric
		case .string: .string
		case .uuid: .uuid
		}
	}

	init(_ value: String, as type: UDAType) {
		switch type {
		case .date:
			self = Date(epoch: value).map(Self.date) ?? .string(value)

		case .duration:
			self = .duration(value)

		case .numeric:
			self = Double(value).map(Self.numeric) ?? .string(value)

		case .string:
			self = .string(value)

		case .uuid:
			self = UUID(uuidString: value).map(Self.uuid) ?? .string(value)
		}
	}
}

extension Date {
	/// A date as TW stores it: whole seconds since 1970.
	init?(epoch: some StringProtocol) {
		guard let seconds = Int(epoch) else {
			return nil
		}
		self.init(timeIntervalSince1970: TimeInterval(seconds))
	}
}

extension String {
	fileprivate func dropPrefix(_ prefix: String) -> String? {
		hasPrefix(prefix) ? String(dropFirst(prefix.count)) : nil
	}
}
