// What the task table shows: its rows, columns and sort order.
public import Foundation
public import Models
import Taskrc

/// A pending task as the table shows it, ranked with the window's Taskrc.
struct TaskRow: Equatable, Identifiable {
	var isBlocked: Bool
	var task: Models.Task
	/// Where the task's value of each UDA with `values` falls in that list.
	var udaRanks: [String: Int]
	var urgency: Double

	var id: Models.Task.ID {
		task.id
	}

	var tags: String {
		task.tags.sorted().joined(separator: " ")
	}

	init(isBlocked: Bool, task: Models.Task, udaColumns: [UDAColumn], urgency: Double) {
		self.isBlocked = isBlocked
		self.task = task
		// A value the list doesn't name ranks after every value it does.
		udaRanks = udaColumns.reduce(into: [:]) { ranks, uda in
			guard !uda.values.isEmpty, case let .string(value)? = task.udas[uda.name] else {
				return
			}
			ranks[uda.name] = uda.values.firstIndex(of: value) ?? uda.values.count
		}
		self.urgency = urgency
	}

	fileprivate func sortKey(for column: TaskColumn) -> SortKey? {
		switch column {
		case .age:
			// Negated, so the youngest sort first, as ascending ages read.
			task.entry.map { .number(-$0.timeIntervalSinceReferenceDate) }

		case .description:
			.text(task.description)

		case .due:
			task.due.map(SortKey.date)

		case .id:
			task.workingSetID.map { .number(Double($0)) }

		case .project:
			task.project.map(SortKey.text)

		case .scheduled:
			task.scheduled.map(SortKey.date)

		case .tags:
			task.tags.isEmpty ? nil : .text(tags)

		case let .uda(name):
			udaSortKey(name)

		case .until:
			task.until.map(SortKey.date)

		case .urgency:
			.number(urgency)

		case .wait:
			task.wait.map(SortKey.date)
		}
	}

	private func udaSortKey(_ name: String) -> SortKey? {
		// The list runs highest first, as the CLI's `<name>-` sorts it.
		if let rank = udaRanks[name] {
			return .number(Double(-rank))
		}
		switch task.udas[name] {
		case nil:
			return nil

		case let .date(date):
			return .date(date)

		case let .duration(duration):
			return .number(Double(duration.seconds))

		case let .numeric(number):
			return .number(number)

		case let .string(string):
			return .text(string)

		case let .uuid(uuid):
			return .text(uuid.uuidString.lowercased())
		}
	}
}

/// A UDA the Taskrc defines, as a column.
struct UDAColumn: Equatable, Identifiable {
	var label: String
	var name: String
	var type: UDAType
	/// `uda.<name>.values`, which lists the values highest first.
	var values: [String]

	var id: String {
		name
	}

	/// Every UDA `taskrc` defines, by name.
	static func all(in taskrc: Taskrc) -> [Self] {
		taskrc.udaTypes.sorted { $0.key < $1.key }.map { name, type in
			Self(
				label: taskrc["uda.\(name).label"] ?? name,
				name: name,
				type: type,
				values: (taskrc["uda.\(name).values"] ?? "").split(separator: ",").map(String.init),
			)
		}
	}
}

enum TaskColumn: Hashable {
	case age
	case description
	case due
	case id
	case project
	case scheduled
	case tags
	case uda(String)
	case until
	case urgency
	case wait

	/// The table column's identifier, which its autosaved layout and sort descriptors key on.
	var identifier: String {
		switch self {
		case .age: "age"
		case .description: "description"
		case .due: "due"
		case .id: "id"
		case .project: "project"
		case .scheduled: "scheduled"
		case .tags: "tags"
		case let .uda(name): udaIdentifierPrefix + name
		case .until: "until"
		case .urgency: "urgency"
		case .wait: "wait"
		}
	}

	init?(identifier: String) {
		if identifier.hasPrefix(udaIdentifierPrefix) {
			self = .uda(String(identifier.dropFirst(udaIdentifierPrefix.count)))
			return
		}
		let builtIn: [Self] = [
			.age, .description, .due, .id, .project, .scheduled, .tags, .until, .urgency, .wait,
		]
		guard let column = builtIn.first(where: { $0.identifier == identifier }) else {
			return nil
		}
		self = column
	}
}

private let udaIdentifierPrefix = "uda."

/// Sorts the table by one column. Empty values sort last in either direction.
struct TaskSort: Hashable, SortComparator {
	var column: TaskColumn
	var order: SortOrder

	/// The descriptor the table's header shows this sort as.
	var descriptor: NSSortDescriptor {
		NSSortDescriptor(key: column.identifier, ascending: order == .forward)
	}

	init(_ column: TaskColumn, order: SortOrder = .forward) {
		self.column = column
		self.order = order
	}

	/// The sort a table header's `descriptor` stands for, or nil for a column the table doesn't
	/// know.
	init?(_ descriptor: NSSortDescriptor) {
		guard let key = descriptor.key, let column = TaskColumn(identifier: key) else {
			return nil
		}
		self.init(column, order: descriptor.ascending ? .forward : .reverse)
	}

	func compare(_ lhs: TaskRow, _ rhs: TaskRow) -> ComparisonResult {
		switch (lhs.sortKey(for: column), rhs.sortKey(for: column)) {
		case (nil, nil):
			.orderedSame

		case (nil, _?):
			.orderedDescending

		case (_?, nil):
			.orderedAscending

		case let (lhs?, rhs?):
			switch order {
			case .forward: lhs.compare(rhs)
			case .reverse: rhs.compare(lhs)
			}
		}
	}
}

private enum SortKey {
	case number(Double)
	case text(String)

	static func date(_ date: Date) -> Self {
		.number(date.timeIntervalSinceReferenceDate)
	}

	func compare(_ other: Self) -> ComparisonResult {
		switch (self, other) {
		case let (.number(lhs), .number(rhs)):
			lhs == rhs ? .orderedSame : lhs < rhs ? .orderedAscending : .orderedDescending

		// Only a UDA value that doesn't read as its type is text among dates or numbers.
		case (.number, .text):
			.orderedAscending

		case (.text, .number):
			.orderedDescending

		case let (.text(lhs), .text(rhs)):
			lhs.localizedStandardCompare(rhs)
		}
	}
}
