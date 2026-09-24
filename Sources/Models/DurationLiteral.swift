let secondsPerDay = 86_400
let secondsPerHour = 3_600
let secondsPerMinute = 60

/// Duration units, each with its length in seconds and whether it stands without a number. Sorted
/// by first letter and then length, so the first match is the longest.
private let units: [(name: String, seconds: Int, isStandalone: Bool)] = [
	("annual", 365 * secondsPerDay, true),
	("biannual", 730 * secondsPerDay, true),
	("bimonthly", 61 * secondsPerDay, true),
	("biweekly", 14 * secondsPerDay, true),
	("biyearly", 730 * secondsPerDay, true),
	("daily", secondsPerDay, true),
	("days", secondsPerDay, false),
	("day", secondsPerDay, true),
	("d", secondsPerDay, false),
	("fortnight", 14 * secondsPerDay, true),
	("hours", secondsPerHour, false),
	("hour", secondsPerHour, true),
	("hrs", secondsPerHour, false),
	("hr", secondsPerHour, true),
	("h", secondsPerHour, false),
	("minutes", secondsPerMinute, false),
	("minute", secondsPerMinute, true),
	("mins", secondsPerMinute, false),
	("min", secondsPerMinute, true),
	("monthly", 30 * secondsPerDay, true),
	("months", 30 * secondsPerDay, false),
	("month", 30 * secondsPerDay, true),
	("mnths", 30 * secondsPerDay, false),
	("mths", 30 * secondsPerDay, false),
	("mth", 30 * secondsPerDay, true),
	("mos", 30 * secondsPerDay, false),
	("mo", 30 * secondsPerDay, true),
	("m", 30 * secondsPerDay, false),
	("quarterly", 91 * secondsPerDay, true),
	("quarters", 91 * secondsPerDay, false),
	("quarter", 91 * secondsPerDay, true),
	("qrtrs", 91 * secondsPerDay, false),
	("qrtr", 91 * secondsPerDay, true),
	("qtrs", 91 * secondsPerDay, false),
	("qtr", 91 * secondsPerDay, true),
	("q", 91 * secondsPerDay, false),
	("semiannual", 183 * secondsPerDay, true),
	("sennight", 14 * secondsPerDay, false),
	("seconds", 1, false),
	("second", 1, true),
	("secs", 1, false),
	("sec", 1, true),
	("s", 1, false),
	("weekdays", secondsPerDay, true),
	("weekly", 7 * secondsPerDay, true),
	("weeks", 7 * secondsPerDay, false),
	("week", 7 * secondsPerDay, true),
	("wks", 7 * secondsPerDay, false),
	("wk", 7 * secondsPerDay, true),
	("w", 7 * secondsPerDay, false),
	("yearly", 365 * secondsPerDay, true),
	("years", 365 * secondsPerDay, false),
	("year", 365 * secondsPerDay, true),
	("yrs", 365 * secondsPerDay, false),
	("yr", 365 * secondsPerDay, true),
	("y", 365 * secondsPerDay, false),
]

/// libshared's `Duration` parser with `standaloneSecondsEnabled` off, as `task` sets it, so a bare
/// number is never a duration. Months count as 30 days and years as 365.
enum DurationLiteral {
	/// Parses from `start` in `bytes`, returning the seconds and where the duration ends, or nil when
	/// none starts there.
	static func parse(_ bytes: [UInt8], from start: Int = 0) -> (seconds: Int, end: Int)? {
		var pig = Pig(bytes, cursor: start)
		guard let seconds = parseDesignated(&pig) ?? parseWeeks(&pig) ?? parseUnits(&pig) else {
			return nil
		}
		return (seconds, pig.cursor)
	}

	/// `[-] P [n Y] [n M] [n D] [T [n H] [n M] [n S]]`.
	private static func parseDesignated(_ pig: inout Pig) -> Int? {
		let checkpoint = pig.cursor
		let sign = pig.skip("-") ? -1 : 1
		guard pig.skip("P"), !pig.isAtEnd else {
			pig.cursor = checkpoint
			return nil
		}
		var seconds = 0
		for (designator, length) in [
			("Y", 365 * secondsPerDay),
			("M", 30 * secondsPerDay),
			("D", secondsPerDay),
		] {
			seconds = seconds &+ sign &* length &* (pig.getDesignated(designator) ?? 0)
		}
		if pig.skip("T"), !pig.isAtEnd {
			for (designator, length) in [("H", secondsPerHour), ("M", secondsPerMinute), ("S", 1)] {
				seconds = seconds &+ sign &* length &* (pig.getDesignated(designator) ?? 0)
			}
		}
		guard pig.cursor - checkpoint >= 3, pig.isAtWordEnd else {
			pig.cursor = checkpoint
			return nil
		}
		return seconds
	}

	/// `P [n W]`.
	private static func parseWeeks(_ pig: inout Pig) -> Int? {
		let checkpoint = pig.cursor
		guard pig.skip("P"), !pig.isAtEnd else {
			pig.cursor = checkpoint
			return nil
		}
		let weeks = pig.getDesignated("W") ?? 0
		guard pig.cursor - checkpoint >= 3, pig.isAtWordEnd else {
			pig.cursor = checkpoint
			return nil
		}
		return weeks &* 7 &* secondsPerDay
	}

	/// A standalone unit such as `weekly`, or a number and a unit, such as `1.5h` or `2 weeks`.
	private static func parseUnits(_ pig: inout Pig) -> Int? {
		let checkpoint = pig.cursor
		if let unit = units.first(where: { pig.skipLiteral($0.name) }) {
			if pig.isAtWordEnd, unit.isStandalone {
				return unit.seconds
			}
		} else if let number = pig.getDecimal() {
			_ = pig.skipWhitespace()
			// A `d` quantity over 10000 would read the start of a UUID as a duration.
			if
				let unit = units.first(where: { pig.skipLiteral($0.name) }),
				!(unit.name == "d" && number > 10_000), pig.isAtWordEnd
			{
				return saturating(number * Double(unit.seconds))
			}
		}
		pig.cursor = checkpoint
		return nil
	}
}

extension Pig {
	/// Digits followed by `designator`, or nil with the cursor unmoved.
	fileprivate mutating func getDesignated(_ designator: String) -> Int? {
		let checkpoint = cursor
		if let value = getDigits(), skipLiteral(designator) {
			return value
		}
		cursor = checkpoint
		return nil
	}
}
