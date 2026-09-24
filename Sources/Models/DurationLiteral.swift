private let day = 86_400
private let hour = 3_600
private let minute = 60

/// Duration units, each with its length in seconds and whether it stands without a number. Sorted
/// by first letter and then length, so the first match is the longest.
private let units: [(name: String, seconds: Int, isStandalone: Bool)] = [
	("annual", 365 * day, true),
	("biannual", 730 * day, true),
	("bimonthly", 61 * day, true),
	("biweekly", 14 * day, true),
	("biyearly", 730 * day, true),
	("daily", day, true),
	("days", day, false),
	("day", day, true),
	("d", day, false),
	("fortnight", 14 * day, true),
	("hours", hour, false),
	("hour", hour, true),
	("hrs", hour, false),
	("hr", hour, true),
	("h", hour, false),
	("minutes", minute, false),
	("minute", minute, true),
	("mins", minute, false),
	("min", minute, true),
	("monthly", 30 * day, true),
	("months", 30 * day, false),
	("month", 30 * day, true),
	("mnths", 30 * day, false),
	("mths", 30 * day, false),
	("mth", 30 * day, true),
	("mos", 30 * day, false),
	("mo", 30 * day, true),
	("m", 30 * day, false),
	("quarterly", 91 * day, true),
	("quarters", 91 * day, false),
	("quarter", 91 * day, true),
	("qrtrs", 91 * day, false),
	("qrtr", 91 * day, true),
	("qtrs", 91 * day, false),
	("qtr", 91 * day, true),
	("q", 91 * day, false),
	("semiannual", 183 * day, true),
	("sennight", 14 * day, false),
	("seconds", 1, false),
	("second", 1, true),
	("secs", 1, false),
	("sec", 1, true),
	("s", 1, false),
	("weekdays", day, true),
	("weekly", 7 * day, true),
	("weeks", 7 * day, false),
	("week", 7 * day, true),
	("wks", 7 * day, false),
	("wk", 7 * day, true),
	("w", 7 * day, false),
	("yearly", 365 * day, true),
	("years", 365 * day, false),
	("year", 365 * day, true),
	("yrs", 365 * day, false),
	("yr", 365 * day, true),
	("y", 365 * day, false),
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
		for (designator, length) in [("Y", 365 * day), ("M", 30 * day), ("D", day)] {
			seconds = seconds &+ sign &* length &* (pig.getDesignated(designator) ?? 0)
		}
		if pig.skip("T"), !pig.isAtEnd {
			for (designator, length) in [("H", hour), ("M", minute), ("S", 1)] {
				seconds = seconds &+ sign &* length &* (pig.getDesignated(designator) ?? 0)
			}
		}
		guard pig.cursor - checkpoint >= 3, !isLatinAlpha(pig.peek()), !isLatinDigit(pig.peek()) else {
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
		guard pig.cursor - checkpoint >= 3, !isLatinAlpha(pig.peek()), !isLatinDigit(pig.peek()) else {
			pig.cursor = checkpoint
			return nil
		}
		return weeks &* 7 &* day
	}

	/// A standalone unit such as `weekly`, or a number and a unit, such as `1.5h` or `2 weeks`.
	private static func parseUnits(_ pig: inout Pig) -> Int? {
		let checkpoint = pig.cursor
		let names = units.map(\.name)
		if let name = pig.getOneOf(names) {
			if !isLatinAlpha(pig.peek()), !isLatinDigit(pig.peek()) {
				if let unit = units.first(where: { $0.name == name && $0.isStandalone }) {
					return unit.seconds
				}
			}
		} else if let number = pig.getDecimal() {
			_ = pig.skipWhitespace()
			// A `d` quantity over 10000 would read the start of a UUID as a duration.
			if
				let name = pig.getOneOf(names), !(name == "d" && number > 10_000),
				!isLatinAlpha(pig.peek()), !isLatinDigit(pig.peek()),
				let unit = units.first(where: { $0.name == name })
			{
				// Saturating, as arm64 converts, where C++ leaves an overflow undefined.
				let seconds = number * Double(unit.seconds)
				return seconds >= Double(Int.max) ? .max : seconds <= Double(Int.min) ? .min : Int(seconds)
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
