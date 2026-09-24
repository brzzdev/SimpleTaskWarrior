public import Foundation
public import Taskrc

/// TW's blocked rule over one Replica's tasks: a task is blocked while it depends on another and
/// neither is completed or deleted. TaskChampion's own rule counts only a pending dependency, so
/// there a Recurrence template never blocks.
public struct DependencyScan: Equatable, Sendable {
	public var blocked: Set<Task.ID> = []
	public var blocking: Set<Task.ID> = []

	public init(_ tasks: some Collection<Task>) {
		let statuses = Dictionary(
			tasks.map { ($0.id, $0.status) },
			uniquingKeysWith: { first, _ in first },
		)
		for task in tasks where task.status.isOpen {
			for dependency in task.dependencies where statuses[dependency]?.isOpen == true {
				blocked.insert(task.id)
				blocking.insert(dependency)
			}
		}
	}
}

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
	var user: [UserCoefficient]
	var waiting: Double

	public init(_ taskrc: Taskrc) {
		let coefficient = { (key: String) in taskrc[key].map(real) ?? 0 }
		active = coefficient("urgency.active.coefficient")
		age = coefficient("urgency.age.coefficient")
		ageMax = coefficient("urgency.age.max")
		annotations = coefficient("urgency.annotations.coefficient")
		blocked = coefficient("urgency.blocked.coefficient")
		blocking = coefficient("urgency.blocking.coefficient")
		due = coefficient("urgency.due.coefficient")
		// `Configuration::getInteger`.
		imminentDays = taskrc["due"].map { strtol($0, nil, 10) } ?? 0
		inherits = taskrc["urgency.inherit"].map(boolean) ?? false
		project = coefficient("urgency.project.coefficient")
		scheduled = coefficient("urgency.scheduled.coefficient")
		tags = coefficient("urgency.tags.coefficient")
		// TW finds these among the keys the Taskrc sets, not the ones only the Context does.
		user = taskrc.values
			.sorted { $0.key < $1.key }
			.compactMap { UserCoefficient(key: $0.key, value: real($0.value)) }
		waiting = coefficient("urgency.waiting.coefficient")
	}

	/// Every task's Urgency at `now`, as `task export` reports it. The date terms and synthetic tags
	/// read days, weeks, months, quarters and years in `timeZone`, as the CLI reads them in the
	/// local one.
	public func urgencies(
		of tasks: [Task],
		at now: Date,
		in timeZone: TimeZone,
	) -> [Task.ID: Double] {
		var calendar = Calendar(identifier: .gregorian)
		calendar.timeZone = timeZone
		let scorer = Scorer(
			calendar: calendar,
			coefficients: self,
			// TW reads the clock in whole seconds.
			now: Date(timeIntervalSince1970: now.timeIntervalSince1970.rounded(.down)),
			scan: DependencyScan(tasks),
		)
		var dependents: [Task.ID: [Task]] = [:]
		for task in tasks where task.status.isOpen {
			for dependency in task.dependencies {
				dependents[dependency, default: []].append(task)
			}
		}

		var urgencies: [Task.ID: Double] = [:]
		var visiting: Set<Task.ID> = []
		func urgency(of task: Task) -> Double {
			if let urgency = urgencies[task.id] {
				return urgency
			}
			var urgency = scorer.urgency(of: task)
			// TW recurses without a guard and never finishes on a cycle, so here a task in one skips
			// the tasks that lead back to it.
			if inherits, scorer.scan.blocking.contains(task.id), visiting.insert(task.id).inserted {
				let inherited = (dependents[task.id] ?? [])
					.filter { !visiting.contains($0.id) }
					.map(urgency(of:))
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
			/// One value of the attribute, which may itself contain dots.
			case udaValue(String, String)
		}

		var match: Match
		var value: Double

		init?(key: String, value: Double) {
			// TW skips a coefficient this close to 0.
			guard abs(value) > 1e-6 else {
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
				let parts = name.split(separator: ".", maxSplits: 1)
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
private struct Scorer {
	/// Gregorian, in the time zone the dates are read in.
	let calendar: Calendar
	let coefficients: UrgencyCoefficients
	let now: Date
	let scan: DependencyScan

	/// The day `now` falls on.
	var today: Date {
		calendar.startOfDay(for: now)
	}

	func urgency(of task: Task) -> Double {
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
		var urgency = terms
			.filter { abs($0.coefficient) > 1e-6 }
			.reduce(0) { $0 + $1.term * $1.coefficient }
		for coefficient in coefficients.user where matches(task, coefficient.match) {
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

	/// 0, 1, 2 and 3 or more annotations or tags score 0, 0.8, 0.9 and 1.
	private func countTerm(_ count: Int) -> Double {
		switch count {
		case 0: 0
		case 1: 0.8
		case 2: 0.9
		default: 1
		}
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

	private func matches(_ task: Task, _ match: UrgencyCoefficients.UserCoefficient.Match) -> Bool {
		switch match {
		case let .keyword(keyword):
			task.description.contains(keyword)

		case let .project(project):
			task.project.map { $0 == project || $0.hasPrefix(project + ".") } ?? false

		case let .tag(tag):
			hasTag(task, tag)

		case let .uda(name):
			task.hasAttribute(name)

		case let .udaValue(name, value):
			task.attribute(name) == value
		}
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
		case "MONTH": return isOpen && isDue(task, within: .month)
		case "ORPHAN": return !task.orphans.isEmpty
		case "OVERDUE":
			return isOpen && task.status != .recurring
				&& [.beforeToday, .earlierToday].contains(dueState(task))
		case "PARENT", "TEMPLATE": return task.mask != nil || task.last != nil
		case "PENDING": return task.status == .pending && !isWaiting(task)
		case "PRIORITY": return task.hasAttribute("priority")
		case "PROJECT": return task.project != nil
		case "QUARTER": return isOpen && isDue(task, within: .quarter)
		case "READY":
			return task.status == .pending && !isWaiting(task) && !scan.blocked.contains(task.id)
				&& task.scheduled.map { now > $0 } != false
		case "SCHEDULED": return task.scheduled != nil
		case "TAGGED": return !task.tags.isEmpty
		case "TOMORROW": return isOpen && isDue(task, daysFromToday: 1)
		case "UDA": return !task.udas.isEmpty
		case "UNBLOCKED": return !scan.blocked.contains(task.id)
		case "UNTIL": return task.until != nil
		case "WAITING": return isWaiting(task)
		case "WEEK": return isOpen && isDue(task, within: .weekOfYear)
		case "YEAR": return isOpen && isDue(task, within: .year)
		case "YESTERDAY": return isOpen && isDue(task, daysFromToday: -1)
		// `LATEST` means the task the running command added, and the app runs none.
		case "LATEST": return false
		default: return task.tags.contains(tag)
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
		guard coefficients.imminentDays != 0 else {
			return .afterToday
		}
		let imminent = today.addingTimeInterval(TimeInterval(coefficients.imminentDays * secondsPerDay))
		return due < imminent ? .afterToday : .notDue
	}

	private func isDue(_ task: Task, daysFromToday days: Int) -> Bool {
		guard let due = task.due, let day = calendar.date(byAdding: .day, value: days, to: today) else {
			return false
		}
		return calendar.isDate(due, inSameDayAs: day)
	}

	/// Whether the task is due in the week, month, quarter or year `now` falls in. Weeks run Monday
	/// to Sunday, whatever `weekstart` says.
	private func isDue(_ task: Task, within period: Calendar.Component) -> Bool {
		guard let due = task.due else {
			return false
		}
		var calendar = calendar
		calendar.firstWeekday = 2
		let interval: DateInterval?
		if period == .quarter {
			var components = calendar.dateComponents([.month, .year], from: now)
			components.month = components.month.map { $0 - ($0 - 1) % 3 }
			interval = calendar.date(from: components).flatMap { start in
				calendar.date(byAdding: .month, value: 3, to: start).map { DateInterval(start: start, end: $0) }
			}
		} else {
			interval = calendar.dateInterval(of: period, for: now)
		}
		guard let interval else {
			return false
		}
		return interval.start <= due && due < interval.end
	}

	/// TW's `is_waiting`: pending, with a `wait` still ahead.
	private func isWaiting(_ task: Task) -> Bool {
		task.status == .pending && task.wait.map { $0 > now } == true
	}
}

private enum DateState {
	case afterToday
	case beforeToday
	case earlierToday
	case laterToday
	case notDue
}

private let secondsPerDay = 86_400

extension Status {
	/// Neither completed nor deleted, which is what TW's blocked rule and date tags ask.
	fileprivate var isOpen: Bool {
		self != .completed && self != .deleted
	}
}

extension Task {
	/// The raw value TW's `get` reads for a UDA or orphan.
	fileprivate func attribute(_ name: String) -> String? {
		if let orphan = orphans[name] {
			return orphan
		}
		switch udas[name] {
		case let .date(date): return String(Int(date.timeIntervalSince1970))

		case let .duration(value), let .string(value): return value

		// As TW stores a number: without a fraction when it's whole.
		case let .numeric(value): return value.rounded() == value ? String(Int(value)) : String(value)

		case let .uuid(uuid): return uuid.uuidString.lowercased()

		case nil: return nil
		}
	}

	/// TW's `has` for a UDA or orphan, where `priority` is only ever one of those.
	fileprivate func hasAttribute(_ name: String) -> Bool {
		udas[name] != nil || orphans[name] != nil
	}
}

/// `Configuration::getBoolean`.
private func boolean(_ value: String) -> Bool {
	["1", "on", "true", "y", "yes"].contains(value.lowercased())
}

/// `Configuration::getReal`, which reads a leading number with `strtod` and ignores the rest.
private func real(_ value: String) -> Double {
	strtod(value, nil)
}
