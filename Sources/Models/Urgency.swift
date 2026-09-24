public import Foundation
public import Taskrc

/// How a Taskrc weighs Urgency, read through its active Context.
public struct UrgencyCoefficients: Equatable, Sendable {
	var active: Double
	var age: Double
	/// The age in days past which the age term stops growing, or 0 for no growth.
	var ageMax: Double
	var annotations: Double
	var blocked: Double
	var blocking: Double
	var due: Double
	/// TW's `due`: how many days ahead a due date counts as `+DUE`.
	var imminentDays: Int
	/// Whether a blocking task takes on the Urgency of the tasks it blocks.
	var inherits: Bool
	var project: Double
	var scheduled: Double
	var tags: Double
	/// The `urgency.user.*` and `urgency.uda.*` coefficients, each a flat amount for a match.
	var matchCoefficients: [UserCoefficient]
	var waiting: Double

	public init(_ taskrc: Taskrc) {
		active = taskrc.real("urgency.active.coefficient")
		age = taskrc.real("urgency.age.coefficient")
		ageMax = taskrc.real("urgency.age.max")
		annotations = taskrc.real("urgency.annotations.coefficient")
		blocked = taskrc.real("urgency.blocked.coefficient")
		blocking = taskrc.real("urgency.blocking.coefficient")
		due = taskrc.real("urgency.due.coefficient")
		imminentDays = taskrc.integer("due")
		inherits = taskrc.boolean("urgency.inherit")
		project = taskrc.real("urgency.project.coefficient")
		scheduled = taskrc.real("urgency.scheduled.coefficient")
		tags = taskrc.real("urgency.tags.coefficient")
		// TW finds these among the keys the Taskrc sets, not the ones only the Context does.
		matchCoefficients = taskrc.values.keys.sorted().compactMap { key in
			UserCoefficient(key: key, value: taskrc.real(key))
		}
		waiting = taskrc.real("urgency.waiting.coefficient")
	}

	/// Every task's Urgency at `now`, as `task export` reports it. The date terms and synthetic tags
	/// read days, weeks, months, quarters and years in `timeZone`, as the CLI reads them in the
	/// local one.
	public func urgencies(
		of tasks: [Task],
		at now: Date,
		in timeZone: TimeZone,
	) -> [Task.ID: Double] {
		let calculator = UrgencyCalculator(
			coefficients: self,
			// TW reads the clock in whole seconds.
			now: Date(timeIntervalSince1970: now.timeIntervalSince1970.rounded(.down)),
			scan: DependencyScan(tasks),
			timeZone: timeZone,
		)
		let tasksByID = Dictionary(tasks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

		var urgencies: [Task.ID: Double] = [:]
		var visiting: Set<Task.ID> = []
		func urgency(of task: Task) -> Double {
			if let urgency = urgencies[task.id] {
				return urgency
			}
			var urgency = calculator.urgency(of: task)
			// TW recurses without a guard and never finishes on a cycle, so here a task in one skips
			// the tasks that lead back to it.
			if inherits, calculator.scan.blocking.contains(task.id), visiting.insert(task.id).inserted {
				let inherited = (calculator.scan.dependents[task.id] ?? [])
					.filter { !visiting.contains($0) }
					.compactMap { tasksByID[$0].map(urgency(of:)) }
					.max()
				urgency = max(urgency, inherited ?? -.greatestFiniteMagnitude) + 0.01
				visiting.remove(task.id)
			}
			urgencies[task.id] = urgency
			return urgency
		}
		for task in tasks {
			_ = urgency(of: task)
		}
		return urgencies
	}
}

extension UrgencyCoefficients {
	/// An `urgency.user.*` or `urgency.uda.*` coefficient, named as TW parses it: up to the first
	/// `.coefficient`.
	struct UserCoefficient: Equatable {
		enum Match: Equatable {
			/// A substring of the description, case-sensitively.
			case keyword(String)
			/// The project or any of its subprojects.
			case project(String)
			/// A tag, synthetic tags included.
			case tag(String)
			/// Any value of the attribute.
			case uda(String)
			/// One value of the attribute, which may itself contain dots. An empty one matches a task
			/// without the attribute.
			case udaValue(String, String)
		}

		var match: Match
		var value: Double

		init?(key: String, value: Double) {
			guard abs(value) > epsilon else {
				return nil
			}
			self.value = value
			if let name = key.prefixMatch(of: /urgency\.user\.(keyword|project|tag)\.(.*?)\.coefficient/) {
				let argument = String(name.2)
				switch name.1 {
				case "keyword": match = .keyword(argument)
				case "project": match = .project(argument)
				default: match = .tag(argument)
				}
			} else if let name = key.prefixMatch(of: /urgency\.uda\.(.*?)\.coefficient/)?.1 {
				let parts = name.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
				match = parts.count == 2
					? .udaValue(String(parts[0]), String(parts[1]))
					: .uda(String(name))
			} else {
				return nil
			}
		}
	}
}

/// Urgency without inheritance, at one moment.
private struct UrgencyCalculator {
	/// Gregorian, in the time zone the dates are read in.
	let calendar: Calendar
	let coefficients: UrgencyCoefficients
	/// Where a date stops counting as `+DUE`, or nil when every date ahead does.
	let imminent: Date?
	let now: Date
	/// The week, month, quarter and year `now` falls in.
	let periods: [Calendar.Component: DateInterval]
	let scan: DependencyScan
	/// The day `now` falls on, and the days either side.
	let today: Date
	let tomorrow: Date?
	let yesterday: Date?

	init(coefficients: UrgencyCoefficients, now: Date, scan: DependencyScan, timeZone: TimeZone) {
		var calendar = Calendar(identifier: .gregorian)
		calendar.timeZone = timeZone
		// Weeks run Monday to Sunday, whatever `weekstart` says.
		calendar.firstWeekday = 2
		let today = calendar.startOfDay(for: now)
		self.calendar = calendar
		self.coefficients = coefficients
		imminent = coefficients.imminentDays == 0
			? nil
			: today.addingTimeInterval(TimeInterval(coefficients.imminentDays * secondsPerDay))
		self.now = now
		var periods: [Calendar.Component: DateInterval] = [:]
		for period in [Calendar.Component.month, .weekOfYear, .year] {
			periods[period] = calendar.dateInterval(of: period, for: now)
		}
		var quarter = calendar.dateComponents([.month, .year], from: now)
		quarter.month = quarter.month.map { $0 - ($0 - 1) % 3 }
		if
			let start = calendar.date(from: quarter),
			let end = calendar.date(byAdding: .month, value: 3, to: start)
		{
			periods[.quarter] = DateInterval(start: start, end: end)
		}
		self.periods = periods
		self.scan = scan
		self.today = today
		tomorrow = calendar.date(byAdding: .day, value: 1, to: today)
		yesterday = calendar.date(byAdding: .day, value: -1, to: today)
	}

	func urgency(of task: Task) -> Double {
		// In TW's order, which a sum of floats can depend on.
		let terms: [(term: Double, coefficient: Double)] = [
			(task.project != nil ? 1 : 0, coefficients.project),
			(task.start != nil ? 1 : 0, coefficients.active),
			(task.scheduled.map { $0 < now } == true ? 1 : 0, coefficients.scheduled),
			(isWaiting(task) ? 1 : 0, coefficients.waiting),
			(scan.blocked.contains(task.id) ? 1 : 0, coefficients.blocked),
			(countTerm(task.annotations.count), coefficients.annotations),
			(countTerm(task.tags.count), coefficients.tags),
			(dueTerm(task), coefficients.due),
			(scan.blocking.contains(task.id) ? 1 : 0, coefficients.blocking),
			(ageTerm(task), coefficients.age),
		]
		var urgency = 0.0
		for (term, coefficient) in terms where abs(coefficient) > epsilon {
			urgency += term * coefficient
		}
		for coefficient in coefficients.matchCoefficients where matches(task, coefficient.match) {
			urgency += coefficient.value
		}
		return urgency
	}

	private func ageTerm(_ task: Task) -> Double {
		guard let entry = task.entry else {
			return 1
		}
		// Whole days, truncated toward zero, so a task entered in the future has a negative age.
		let age = Double(Int(now.timeIntervalSince(entry)) / secondsPerDay)
		guard coefficients.ageMax != 0, age <= coefficients.ageMax else {
			return 1
		}
		return age / coefficients.ageMax
	}

	/// 0, 1, 2 and 3 or more annotations or tags weigh 0, 0.8, 0.9 and 1.
	private func countTerm(_ count: Int) -> Double {
		switch count {
		case 0: 0
		case 1: 0.8
		case 2: 0.9
		default: 1
		}
	}

	/// `Task::getDateState` for the due date.
	private func dueState(_ task: Task) -> DateState {
		guard let due = task.due, due.timeIntervalSince1970 > 0 else {
			return .notDue
		}
		if due < today {
			return .beforeToday
		}
		if calendar.isDate(due, inSameDayAs: now) {
			return due < now ? .earlierToday : .laterToday
		}
		guard let imminent else {
			return .afterToday
		}
		return due < imminent ? .afterToday : .notDue
	}

	private func dueTerm(_ task: Task) -> Double {
		guard let due = task.due else {
			return 0
		}
		// Linear from 0.2 two weeks ahead to 1 a week overdue.
		let daysOverdue = now.timeIntervalSince(due) / Double(secondsPerDay)
		if daysOverdue >= 7 {
			return 1
		}
		if daysOverdue >= -14 {
			return (daysOverdue + 14) * 0.8 / 21 + 0.2
		}
		return 0.2
	}

	/// `Task::hasTag`: a synthetic tag when `tag` starts with an uppercase letter and names one,
	/// otherwise one of the task's own.
	private func hasTag(_ task: Task, _ tag: String) -> Bool {
		guard tag.first?.isASCII == true, tag.first?.isUppercase == true else {
			return task.tags.contains(tag)
		}
		let isOpen = task.status.isOpen
		switch tag {
		case "ACTIVE": return task.start != nil

		case "ANNOTATED": return !task.annotations.isEmpty

		case "BLOCKED": return scan.blocked.contains(task.id)

		case "BLOCKING": return scan.blocking.contains(task.id)

		case "CHILD", "INSTANCE": return task.parent != nil || task.template != nil

		case "COMPLETED": return task.status == .completed

		case "DELETED": return task.status == .deleted

		case "DUE": return isOpen && [.afterToday, .earlierToday, .laterToday].contains(dueState(task))

		case "DUETODAY", "TODAY": return isOpen && [.earlierToday, .laterToday].contains(dueState(task))

		// `LATEST` means the task the running command added, and the app runs none.
		case "LATEST": return false

		case "MONTH": return isOpen && isDue(task, within: .month)

		case "ORPHAN": return !task.orphans.isEmpty

		case "OVERDUE":
			return isOpen && task.status != .recurring
				&& [.beforeToday, .earlierToday].contains(dueState(task))

		case "PARENT", "TEMPLATE": return task.hasTemplateTag

		case "PENDING": return task.status == .pending && !isWaiting(task)

		case "PRIORITY": return task.attribute("priority") != nil

		case "PROJECT": return task.project != nil

		case "QUARTER": return isOpen && isDue(task, within: .quarter)

		case "READY":
			return task.status == .pending && !isWaiting(task) && !scan.blocked.contains(task.id)
				&& task.scheduled.map { now > $0 } != false

		case "SCHEDULED": return task.scheduled != nil

		case "TAGGED": return !task.tags.isEmpty

		case "TOMORROW": return isOpen && isDue(task, on: tomorrow)

		case "UDA": return !task.udas.isEmpty

		case "UNBLOCKED": return !scan.blocked.contains(task.id)

		case "UNTIL": return task.until != nil

		case "WAITING": return isWaiting(task)

		case "WEEK": return isOpen && isDue(task, within: .weekOfYear)

		case "YEAR": return isOpen && isDue(task, within: .year)

		case "YESTERDAY": return isOpen && isDue(task, on: yesterday)

		default: return task.tags.contains(tag)
		}
	}

	private func isDue(_ task: Task, on day: Date?) -> Bool {
		guard let due = task.due, let day else {
			return false
		}
		return calendar.isDate(due, inSameDayAs: day)
	}

	/// Whether the task is due in the week, month, quarter or year `now` falls in.
	private func isDue(_ task: Task, within period: Calendar.Component) -> Bool {
		guard let due = task.due, let interval = periods[period] else {
			return false
		}
		return interval.start <= due && due < interval.end
	}

	/// TW's `is_waiting`: pending, with a `wait` still ahead.
	private func isWaiting(_ task: Task) -> Bool {
		task.status == .pending && task.wait.map { $0 > now } == true
	}

	private func matches(_ task: Task, _ match: UrgencyCoefficients.UserCoefficient.Match) -> Bool {
		switch match {
		case let .keyword(keyword):
			task.description.contains(keyword)

		case let .project(project):
			task.project.map { $0 == project || $0.hasPrefix(project + ".") } ?? false

		case let .tag(tag):
			hasTag(task, tag)

		case let .uda(name):
			task.attribute(name) != nil

		case let .udaValue(name, value):
			(task.attribute(name) ?? "") == value
		}
	}
}

private enum DateState {
	case afterToday
	case beforeToday
	case earlierToday
	case laterToday
	case notDue
}

/// TW's `epsilon`: a coefficient no larger than this counts as 0.
private let epsilon = 1e-6

private let secondsPerDay = 86_400

extension Task {
	/// TW's `has` and `get` in one: the stored text of any attribute, built-ins included, or nil where
	/// `get` returns "". TaskChampion keys a task by its UUID rather than storing it, so TW adds
	/// `uuid` itself.
	fileprivate func attribute(_ name: String) -> String? {
		name == "uuid" ? id.uuidString.lowercased() : properties[name]
	}
}
