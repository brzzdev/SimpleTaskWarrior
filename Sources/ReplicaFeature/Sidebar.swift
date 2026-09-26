// What the sidebar lists, and how its selection and the search narrow the task table.
import Foundation
import Models

/// One of the fixed views at the top of the sidebar, which splits tasks by status.
enum TaskView: Hashable {
	case completed
	case deleted
	case pending
	case waiting

	/// In sidebar order, which ⌘1 to ⌘4 follow.
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

	/// Named and counted from the selected views' tasks, or Pending's when none is selected.
	var projects: [Project]
	/// Named and counted from the selected views' tasks, or Pending's when none is selected.
	var tags: [Count]
	var views: [Count]

	/// The sidebar over `rows`, keeping every selected project and tag listed, at a count of 0 where
	/// no task has it.
	init(rows: [TaskRow], selection: Set<SidebarItem>) {
		views = TaskView.all.map { view in
			Count(count: rows.count { $0.view == view }, item: .view(view))
		}
		let listed = rows.filter { selection.views.contains($0.view) }

		var projectCounts: [String: Int] = [:]
		for project in selection.projects {
			for name in project.ancestry {
				projectCounts[name, default: 0] += 0
			}
		}
		for project in listed.compactMap(\.task.project) {
			for name in project.ancestry {
				projectCounts[name, default: 0] += 1
			}
		}
		projects = Project.children(of: nil, in: projectCounts)

		var tagCounts = Dictionary(uniqueKeysWithValues: selection.tags.map { ($0, 0) })
		for tag in listed.flatMap(\.task.tags) {
			tagCounts[tag, default: 0] += 1
		}
		tags = tagCounts.keys
			.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
			.map { Count(count: tagCounts[$0] ?? 0, item: .tag($0)) }
	}
}

extension Sidebar.Project {
	/// The projects in `counts` one segment below `parent`, or the top-level ones for nil, with
	/// theirs below them.
	fileprivate static func children(of parent: String?, in counts: [String: Int]) -> [Self] {
		counts.keys
			.filter { $0.parentProject == parent }
			.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
			.map { name in
				Self(children: children(of: name, in: counts), count: counts[name] ?? 0, name: name)
			}
	}
}

extension Set<SidebarItem> {
	/// The selected fixed views, or Pending when none is selected.
	var views: Set<TaskView> {
		let views = Set<TaskView>(compactMap {
			guard case let .view(view) = $0 else {
				return nil
			}
			return view
		})
		return views.isEmpty ? [.pending] : views
	}

	fileprivate var projects: [String] {
		compactMap {
			guard case let .project(project) = $0 else {
				return nil
			}
			return project
		}
	}

	fileprivate var tags: [String] {
		compactMap {
			guard case let .tag(tag) = $0 else {
				return nil
			}
			return tag
		}
	}

	/// Whether `row` shows under this selection: in any selected view, and in any selected project
	/// and with any selected tag where the sections have some selected.
	func includes(_ row: TaskRow) -> Bool {
		guard views.contains(row.view) else {
			return false
		}
		let projects = projects
		if !projects.isEmpty {
			guard let project = row.task.project, projects.contains(where: project.isWithin) else {
				return false
			}
		}
		let tags = tags
		return tags.isEmpty || tags.contains(where: row.task.tags.contains)
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

	/// Whether this project is `project` or one of its subprojects, matching whole segments, so
	/// `Homework` isn't within `Home`.
	fileprivate func isWithin(_ project: String) -> Bool {
		self == project || hasPrefix(project + ".")
	}
}
