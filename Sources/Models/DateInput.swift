public import Foundation
public import Taskrc

/// Reads dates and durations typed in Taskwarrior's own syntax, as `task` 3.5 reads an attribute
/// value: ISO 8601, the Taskrc's `dateformat`, epochs, names such as `eow` or `monday`, and
/// arithmetic such as `due-1wk`, in one time zone.
///
/// Holiday names such as `easter`, which the CLI resolves, are refused.
public struct DateInput: Sendable {
	/// A task attribute's value, which an expression refers to by name, as in `wait:due-1wk`.
	public enum Reference: Sendable {
		case date(Date)
		case duration(TaskDuration)
		/// Any other attribute's value, or an empty string for an attribute the task doesn't have,
		/// as TW reads them.
		case text(String)
	}

	private let format: String
	private let settings: Datetime.Settings
	private let timeZone: TimeZone

	/// Reads the Taskrc's `dateformat`, `date.iso` and `weekstart`, which only affects ISO week
	/// dates such as `2026-W02`: named weeks such as `sow` always run Monday to Sunday.
	public init(taskrc: Taskrc, timeZone: TimeZone) {
		format = taskrc["dateformat"] ?? ""
		settings = Datetime.Settings(
			isISOEnabled: taskrc.boolean("date.iso"),
			weekstart: dayOfWeek(Array((taskrc["weekstart"] ?? "").utf8)) == 1 ? 1 : 0,
		)
		self.timeZone = timeZone
	}

	/// The date `text` means at `now`, to the second. A date alone means midnight, and `references`
	/// supplies the task's attributes by name.
	public func date(
		_ text: String,
		at now: Date,
		references: (String) -> Reference? = { _ in nil },
	) throws(DateInputError) -> Date {
		let epoch = try expression(at: now).date(text, references: references)
		return Date(timeIntervalSince1970: TimeInterval(epoch))
	}

	/// The duration `text` means at `now`, which only matters when it subtracts dates.
	public func duration(
		_ text: String,
		at now: Date,
		references: (String) -> Reference? = { _ in nil },
	) throws(DateInputError) -> TaskDuration {
		try TaskDuration(seconds: expression(at: now).duration(text, references: references))
	}

	private func expression(at now: Date) -> DateExpression {
		DateExpression(clock: Clock(now: now, timeZone: timeZone), format: format, settings: settings)
	}
}

public enum DateInputError: Error, Equatable, Sendable {
	/// A holiday such as `easter` or `midsommar`, which the CLI resolves and the app doesn't.
	case holiday(String)
	/// Input that isn't a date or duration.
	case invalid
	/// A date before 1980 or after 9999, which the CLI refuses.
	case outOfRange
}

/// A duration as Taskwarrior counts it: whole seconds, with months of 30 days and years of 365.
public struct TaskDuration: Hashable, Sendable {
	public var seconds: Int

	/// ISO 8601 in days, hours, minutes and seconds, as TW stores a duration: `P30D`, not `P1M`.
	public var iso: String {
		guard seconds != 0 else {
			return "PT0S"
		}
		var remainder = seconds.magnitude
		let secondsPart = remainder % 60
		remainder /= 60
		let minutes = remainder % 60
		remainder /= 60
		let hours = remainder % 24
		let days = remainder / 24

		var iso = seconds < 0 ? "-P" : "P"
		if days != 0 {
			iso += "\(days)D"
		}
		if hours != 0 || minutes != 0 || secondsPart != 0 {
			iso += "T"
			for (value, designator) in [(hours, "H"), (minutes, "M"), (secondsPart, "S")] where value != 0 {
				iso += "\(value)\(designator)"
			}
		}
		return iso
	}

	public init(seconds: Int) {
		self.seconds = seconds
	}

	/// Reads a stored value as TW does when an expression refers to it: as much of its start as is
	/// a duration, so `P1M` and `weekly` both read. Nil when none of it is.
	public init?(stored: String) {
		guard let duration = DurationLiteral.parse(Array(stored.utf8)) else {
			return nil
		}
		seconds = duration.seconds
	}
}

extension TaskDuration: CustomStringConvertible {
	/// The largest of weeks, days, hours and minutes that divides the duration exactly, as in `2w`
	/// or `90min`, else ISO 8601.
	public var description: String {
		let units = [("w", 604_800), ("d", 86_400), ("h", 3_600), ("min", 60)]
		guard let (unit, length) = units.first(where: { seconds.isMultiple(of: $0.1) }) else {
			return iso
		}
		return "\(seconds / length)\(unit)"
	}
}
