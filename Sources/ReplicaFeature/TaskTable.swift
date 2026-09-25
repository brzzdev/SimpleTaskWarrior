// The task table: its rows, columns and sort order.
import ComposableArchitecture
public import Foundation
public import Models
import SwiftUI
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

enum TaskColumn: Codable, Hashable {
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
}

/// Sorts the table by one column. Empty values sort last in either direction.
struct TaskSort: Codable, Hashable, SortComparator {
	var column: TaskColumn
	var order: SortOrder

	init(_ column: TaskColumn, order: SortOrder = .forward) {
		self.column = column
		self.order = order
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

struct TaskTable: View {
	@Bindable var store: StoreOf<ReplicaFeature>

	/// Visible columns, their order and widths, as JSON. Remembered per window, like the sort order.
	@SceneStorage("columns") private var columns: Data?
	/// The store's sort order as JSON, which the window restores it from.
	@SceneStorage("sortOrder") private var sortOrder: Data?

	private var columnCustomization: Binding<TableColumnCustomization<TaskRow>> {
		Binding {
			columns.flatMap { try? JSONDecoder().decode(TableColumnCustomization.self, from: $0) }
				?? TableColumnCustomization()
		} set: {
			columns = try? JSONEncoder().encode($0)
		}
	}

	var body: some View {
		Table(
			store.rows,
			selection: $store.selection,
			sortOrder: $store.sortOrder,
			columnCustomization: columnCustomization,
		) {
			TableColumn("ID", sortUsing: TaskSort(.id)) { row in
				Text(row.task.workingSetID.map(String.init) ?? "")
					.monospacedDigit()
			}
			.width(min: 32, ideal: 40, max: 64)
			.customizationID("id")
			TableColumn("Urgency", sortUsing: TaskSort(.urgency, order: .reverse)) { row in
				UrgencyCell(highest: store.highestUrgency, urgency: row.urgency)
			}
			.width(min: 48, ideal: 64, max: 96)
			.customizationID("urgency")
			TableColumn("Description", sortUsing: TaskSort(.description)) { row in
				DescriptionCell(row: row)
			}
			.customizationID("description")
			.disabledCustomizationBehavior(.visibility)
			TableColumn("Project", sortUsing: TaskSort(.project)) { row in
				Text(verbatim: row.task.project ?? "")
			}
			.customizationID("project")
			TableColumn("Tags", sortUsing: TaskSort(.tags)) { row in
				Text(verbatim: row.tags)
			}
			.customizationID("tags")
			TableColumn("Due", sortUsing: TaskSort(.due)) { row in
				dateText(row.task.due)
			}
			.customizationID("due")
			// Grouped because a table takes at most ten columns at one level.
			Group {
				TableColumn("Age", sortUsing: TaskSort(.age)) { row in
					Text(
						row.task.entry?.formatted(.relative(presentation: .numeric, unitsStyle: .narrow))
							?? "",
					)
				}
				.customizationID("age")
				TableColumn("Scheduled", sortUsing: TaskSort(.scheduled)) { row in
					dateText(row.task.scheduled)
				}
				.customizationID("scheduled")
				TableColumn("Wait", sortUsing: TaskSort(.wait)) { row in
					dateText(row.task.wait)
				}
				.customizationID("wait")
				TableColumn("Until", sortUsing: TaskSort(.until)) { row in
					dateText(row.task.until)
				}
				.customizationID("until")
				TableColumnForEach(store.udaColumns) { uda in
					// Descending first where `values` lists the order, so the first click shows the list as
					// written, while each direction still sorts as the CLI's `<name>-` and `<name>+` do.
					TableColumn(
						Text(verbatim: uda.label),
						sortUsing: TaskSort(.uda(uda.name), order: uda.values.isEmpty ? .forward : .reverse),
					) { row in
						udaText(row.task.udas[uda.name])
					}
					.customizationID("uda.\(uda.name)")
				}
			}
			.defaultVisibility(.hidden)
		}
		.onAppear {
			guard
				let sortOrder,
				let restored = try? JSONDecoder().decode([TaskSort].self, from: sortOrder)
			else {
				return
			}
			store.sortOrder = restored
		}
		.onChange(of: store.sortOrder) { _, newValue in
			sortOrder = try? JSONEncoder().encode(newValue)
		}
	}
}

/// The description, with a dot before an active task and markers after it.
private struct DescriptionCell: View {
	let row: TaskRow

	var body: some View {
		HStack(spacing: 6) {
			if row.task.start != nil {
				Circle()
					.fill(.green)
					.frame(width: 7, height: 7)
					.accessibilityLabel("Active")
			}
			Text(verbatim: row.task.description)
				.lineLimit(1)
			if row.isBlocked {
				Text("Blocked")
					.font(.caption)
					.foregroundStyle(.red)
			}
			if !row.task.annotations.isEmpty {
				Label("\(row.task.annotations.count)", systemImage: "text.bubble")
					.font(.caption)
					.foregroundStyle(.secondary)
					.accessibilityLabel(Text("^[\(row.task.annotations.count) annotation](inflect: true)"))
			}
			if row.task.isInstance {
				Text(verbatim: "↻")
					.foregroundStyle(.secondary)
					.accessibilityLabel("Repeats")
			}
		}
	}
}

/// Urgency to one decimal, over a thin bar scaled to the list's highest. Urgency of 0 or less
/// draws no bar.
private struct UrgencyCell: View {
	let highest: Double
	let urgency: Double

	var body: some View {
		Text(urgency, format: .number.precision(.fractionLength(1)))
			.monospacedDigit()
			.frame(maxWidth: .infinity, alignment: .trailing)
			.background(alignment: .bottom) {
				if urgency > 0 {
					Capsule()
						.fill(.tint.opacity(0.4))
						.frame(height: 2)
						.scaleEffect(x: urgency / highest, anchor: .leading)
				}
			}
	}
}

private func dateText(_ date: Date?) -> Text {
	Text(date?.formatted(date: .numeric, time: .omitted) ?? "")
}

private func udaText(_ value: UDAValue?) -> Text {
	switch value {
	case nil:
		Text(verbatim: "")

	case let .date(date):
		dateText(date)

	case let .duration(duration):
		Text(verbatim: duration.description)

	case let .numeric(number):
		Text(number, format: .number)

	case let .string(string):
		Text(verbatim: string)

	case let .uuid(uuid):
		Text(verbatim: uuid.uuidString.lowercased())
	}
}
