// What the sidebar lists, and how its selection and the search narrow the task table.
import Foundation
import Models

/// One of the fixed views at the top of the sidebar, which splits tasks by status.
enum TaskView: Hashable {
	case completed
	case deleted
	case pending
	case waiting

	/// In sidebar order.
	static let all: [Self] = [.pending, .waiting, .completed, .deleted]

	/// The view `task` shows in at `now`, or nil for a Recurrence template, which none shows.
	init?(_ task: Models.Task, at now: Date) {
		guard !task.isTemplate else {
			return nil
		}
		switch task.status {
		case .completed: self = .completed
		case .deleted: self = .deleted
		case .pending: self = task.isWaiting(at: now) ? .waiting : .pending
		case .recurring: return nil
		}
	}
}

/// A row in the sidebar that narrows the table.
enum SidebarItem: Hashable {
	/// A dotted project name, which takes in its subprojects.
	case project(String)
	case tag(String)
	case view(TaskView)
}

/// The sidebar's three sections, counted from the ranked rows.
struct Sidebar: Equatable {
	struct Count: Equatable {
		var count: Int
		var item: SidebarItem
	}

	/// A node of the dotted project tree. Its count takes in its subprojects.
	struct Project: Equatable {
		var children: [Self]
		var count: Int
		/// The whole dotted name.
		var name: String
	}

	// Both named and counted from the selected views' tasks.
	var projects: [Project]
	var tags: [Count]
	var views: [Count]

	/// The sidebar over `rows`, keeping every selected project and tag listed, at a count of 0 where
	/// no task has it.
	init(rows: [TaskRow], selection: Set<SidebarItem>) {
		views = TaskView.all.map { view in
			Count(count: rows.count { $0.view == view }, item: .view(view))
		}
		let filter = SidebarFilter(selection)
		let listed = rows.filter { filter.views.contains($0.view) }

		var projectCounts = zeroCounts(filter.projects.flatMap(\.ancestry))
		for name in listed.compactMap(\.task.project).flatMap(\.ancestry) {
			projectCounts[name, default: 0] += 1
		}
		projects = Project.children(of: nil, in: projectCounts)

		var tagCounts = zeroCounts(filter.tags)
		for tag in listed.flatMap(\.task.tags) {
			tagCounts[tag, default: 0] += 1
		}
		tags = sorted(tagCounts).map { Count(count: $0.value, item: .tag($0.key)) }
	}
}

extension Sidebar.Project {
	/// The projects in `counts` one segment below `parent`, or the top-level ones for nil, with
	/// theirs below them.
	fileprivate static func children(of parent: String?, in counts: [String: Int]) -> [Self] {
		sorted(counts.filter { $0.key.parentProject == parent }).map { name, count in
			Self(children: children(of: name, in: counts), count: count, name: name)
		}
	}
}

/// The sidebar's selection, split by section once rather than for every row it narrows.
struct SidebarFilter {
	var projects: [String] = []
	var tags: [String] = []
	/// The selected fixed views, or Pending when none is selected.
	var views: Set<TaskView> = []

	init(_ selection: Set<SidebarItem>) {
		for item in selection {
			switch item {
			case let .project(project): projects.append(project)
			case let .tag(tag): tags.append(tag)
			case let .view(view): views.insert(view)
			}
		}
		if views.isEmpty {
			views = [.pending]
		}
	}

	/// Whether `row` shows: in any selected view, and in any selected project and with any selected
	/// tag where those sections have some selected.
	func includes(_ row: TaskRow) -> Bool {
		views.contains(row.view)
			&& (projects.isEmpty || projects.contains(where: row.task.isIn(project:)))
			&& (tags.isEmpty || tags.contains(where: row.task.tags.contains))
	}
}

extension TaskRow {
	/// Whether the description or an annotation contains `search`, in any case and with or without
	/// diacritics, whatever `search.case.sensitive` says. An empty search matches every task.
	func matches(search: String) -> Bool {
		guard !search.isEmpty else {
			return true
		}
		let texts = [task.description] + task.annotations.map(\.description)
		return texts
			.contains { $0.range(of: search, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
	}
}

extension String {
	/// The project and each project above it, as `A`, `A.B` and `A.B.C` for `A.B.C`.
	var ancestry: [String] {
		let segments = split(separator: ".", omittingEmptySubsequences: false)
		return segments.indices.map { segments[...$0].joined(separator: ".") }
	}

	/// The project one segment up, or nil for a top-level one.
	fileprivate var parentProject: String? {
		lastIndex(of: ".").map { String(self[..<$0]) }
	}
}

/// A count of 0 for each of `names`.
private func zeroCounts(_ names: [String]) -> [String: Int] {
	Dictionary(names.map { ($0, 0) }, uniquingKeysWith: { first, _ in first })
}

/// `counts` in the order Finder sorts names.
private func sorted(_ counts: [String: Int]) -> [(key: String, value: Int)] {
	counts.sorted { $0.key.localizedStandardCompare($1.key) == .orderedAscending }
}
