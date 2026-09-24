// libshared's `Datetime` input parsing, as `task` 3.5 configures it, without the holidays.
import Foundation

/// TW's range for a stored date: 1980-01-01T00:00:00Z up to 9999-12-31T23:59:59 AoE.
let epochRange = 315_532_800 ..< 253_402_293_599

private let dayNames = [
	"sunday",
	"monday",
	"tuesday",
	"wednesday",
	"thursday",
	"friday",
	"saturday",
]

/// The holiday dates libshared names, which this port refuses rather than resolves.
private let holidayNames = [
	"ascension", "easter", "eastermonday", "goodfriday", "juhannus", "midsommar", "midsommarafton",
	"pentecost",
]

private let monthNames = [
	"january", "february", "march", "april", "may", "june", "july", "august", "september", "october",
	"november", "december",
]

/// `struct tm`, with the year in full and the month and weekday 0-based as `tm` has them. Fields
/// may run out of range before `WallClock.epoch` normalises them, as `mktime` does.
struct BrokenDownTime {
	var year: Int
	var month: Int
	var day: Int
	var hour: Int
	var minute: Int
	var second: Int
	/// 0 is Sunday. Output only.
	var weekday = 0
}

/// `localtime`, `gmtime`, `mktime` and `timegm` over one time zone, with `time()` fixed at `now`.
struct WallClock {
	private static let utcCalendar = {
		var calendar = Calendar(identifier: .gregorian)
		calendar.timeZone = .gmt
		return calendar
	}()

	/// Whole seconds, as TW reads the clock.
	let now: Int

	private let calendar: Calendar

	init(now: Date, timeZone: TimeZone) {
		self.now = Int(now.timeIntervalSince1970.rounded(.down))
		var calendar = Calendar(identifier: .gregorian)
		calendar.timeZone = timeZone
		self.calendar = calendar
	}

	func brokenDown(_ epoch: Int, utc: Bool = false) -> BrokenDownTime {
		let components = (utc ? Self.utcCalendar : calendar).dateComponents(
			[.day, .hour, .minute, .month, .second, .weekday, .year],
			from: Date(timeIntervalSince1970: TimeInterval(epoch)),
		)
		return BrokenDownTime(
			year: components.year ?? 0,
			month: (components.month ?? 1) - 1,
			day: components.day ?? 1,
			hour: components.hour ?? 0,
			minute: components.minute ?? 0,
			second: components.second ?? 0,
			weekday: (components.weekday ?? 1) - 1,
		)
	}

	/// Normalises out-of-range fields on the wall clock, as `mktime` does, before Foundation
	/// resolves the result, including a time a DST change skips or repeats.
	func epoch(_ time: BrokenDownTime, utc: Bool = false) -> Int {
		let (carriedDays, secondOfDay) = floorDivision(time.secondOfDay, secondsPerDay)
		let (carriedYears, month) = floorDivision(time.month, 12)
		let days = daysFromCivil(year: time.year + carriedYears, month: month + 1, day: 1)
			+ time.day - 1 + carriedDays
		let (year, month1, day) = civilFromDays(days)
		let components = DateComponents(
			year: year,
			month: month1,
			day: day,
			hour: secondOfDay / secondsPerHour,
			minute: secondOfDay % secondsPerHour / secondsPerMinute,
			second: secondOfDay % 60,
		)
		guard let date = (utc ? Self.utcCalendar : calendar).date(from: components) else {
			return 0
		}
		return Int(date.timeIntervalSince1970.rounded(.down))
	}

	/// `localtime(now)` changed by `adjust`, back through `mktime`.
	func local(_ adjust: (inout BrokenDownTime) -> Void) -> Int {
		var time = brokenDown(now)
		adjust(&time)
		return epoch(time)
	}
}

/// libshared's `Datetime`, parsing as `task` sets it up: `standaloneDateEnabled` and
/// `standaloneTimeEnabled` off, `timeRelative` on and a minimum match of 3 letters. Its fields
/// persist across the attempts one `parse` makes, as the original's do.
struct Datetime {
	/// The Taskrc settings TW copies into `Datetime`'s statics.
	struct Settings {
		/// `date.iso`.
		var isISOEnabled: Bool
		/// `weekstart`: 0 for Sunday or 1 for Monday.
		var weekstart: Int

		/// The digits an ISO week date's weekday may be: 1–7 from Monday, else 0–6 from Sunday.
		var weekdays: ClosedRange<Int> {
			weekstart == 1 ? 1 ... 7 : 0 ... 6
		}
	}

	let clock: WallClock
	let settings: Settings

	/// The parsed date, once `parse` succeeds.
	private(set) var date = 0

	private var day = 0
	private var julian = 0
	private var month = 0
	private var offset = 0
	private var seconds = 0
	private var utc = false
	private var week = 0
	private var weekday: Int
	private var year = 0

	init(clock: WallClock, settings: Settings) {
		self.clock = clock
		self.settings = settings
		weekday = settings.weekstart
	}

	/// Parses from `start` in `bytes`, returning where the date ends, or nil when none starts there.
	/// Throws when the date is a holiday.
	mutating func parse(
		_ bytes: [UInt8],
		from start: Int = 0,
		format: String,
	) throws(DateInputError) -> Int? {
		var pig = Pig(bytes, cursor: start)
		let checkpoint = pig.cursor

		if parseEpoch(&pig) {
			return pig.cursor
		}

		// A formatted date that fails validation leaves the cursor where it stopped.
		if parseFormatted(&pig, format: Array(format.utf8)), validate() {
			resolve()
			return pig.cursor
		}

		if
			parseDateTimeExtended(&pig) || parseDateTime(&pig)
			|| (
				settings.isISOEnabled
					&& (
						parseDateExtended(&pig) || parseTimeUTCExtended(&pig) || parseTimeUTC(&pig)
							|| parseTimeOffsetExtended(&pig) || parseTimeExtended(&pig)
					)
			)
		{
			if validate() {
				resolve()
				return pig.cursor
			}
		}

		pig.cursor = checkpoint
		if try parseNamed(&pig) {
			return pig.cursor
		}
		return nil
	}

	private mutating func parseFormatted(_ pig: inout Pig, format: [UInt8]) -> Bool {
		guard !format.isEmpty else {
			return false
		}
		let checkpoint = pig.cursor
		var month = -1
		var day = -1
		var year = -1
		var hour = -1
		var minute = -1
		var second = -1

		for (index, specifier) in format.enumerated() {
			let parsed: Bool
			switch Unicode.Scalar(specifier) {
			case "m":
				parsed = pig.getVariableDigits(into: &month, tensFrom: 1 ... 1)

			case "M":
				parsed = pig.getDigits(count: 2).map { month = $0 } != nil

			case "d":
				parsed = pig.getVariableDigits(into: &day, tensFrom: 1 ... 3)

			case "D":
				parsed = pig.getDigits(count: 2).map { day = $0 } != nil

			case "y":
				parsed = pig.getDigits(count: 2).map { year = $0 + 2_000 } != nil

			case "Y":
				parsed = pig.getDigits(count: 4).map { year = $0 } != nil

			case "h":
				parsed = pig.getVariableDigits(into: &hour, tensFrom: 1 ... 2)

			case "H":
				parsed = pig.getDigits(count: 2).map { hour = $0 } != nil

			case "n":
				parsed = pig.getVariableDigits(into: &minute, tensFrom: 0 ... 5)

			case "N":
				parsed = pig.getDigits(count: 2).map { minute = $0 } != nil

			case "s":
				parsed = pig.getVariableDigits(into: &second, tensFrom: 0 ... 5)

			case "S":
				parsed = pig.getDigits(count: 2).map { second = $0 } != nil

			// Weeks and weekdays are read but unused.
			case "v":
				var week = -1
				parsed = pig.getVariableDigits(into: &week, tensFrom: 0 ... 5)

			case "V":
				parsed = pig.getDigits(count: 2) != nil

			case "a":
				parsed = dayOfWeek(Array(pig.remainder.prefix(3))) != -1
				if parsed {
					_ = pig.skip(characters: 3)
				}

			case "b":
				month = monthOfYear(Array(pig.remainder.prefix(3)))
				parsed = month != -1
				if parsed {
					_ = pig.skip(characters: 3)
				}

			case "A", "B":
				let end = index + 1 < format.count ? Int(format[index + 1]) : 0
				guard let name = pig.getUntil(end).map({ Array($0.utf8) }) else {
					parsed = true
					break
				}
				if specifier == UInt8(ascii: "A") {
					parsed = dayOfWeek(name) != -1
				} else {
					month = monthOfYear(name)
					parsed = month != -1
				}

			default:
				parsed = pig.skip(Unicode.Scalar(specifier))
			}
			guard parsed else {
				pig.cursor = checkpoint
				return false
			}
		}

		// A format of `Y-M-D` mustn't match the start of `Y-M-DTH:N:SZ`.
		guard pig.isAtEnd || isWhitespace(pig.peek()) else {
			pig.cursor = checkpoint
			return false
		}

		// Missing values are filled in from the current date, down to the first one given.
		if year == -1 {
			let now = clock.brokenDown(clock.now)
			year = now.year
			if month == -1 {
				month = now.month + 1
				if day == -1 {
					day = now.day
					if hour == -1 {
						hour = now.hour
						if minute == -1 {
							minute = now.minute
							if second == -1 {
								second = now.second
							}
						}
					}
				}
			}
		}

		self.year = year
		self.month = month == -1 ? 1 : month
		self.day = day == -1 ? 1 : day
		seconds = max(hour, 0) * secondsPerHour + max(minute, 0) * secondsPerMinute + max(second, 0)
		return true
	}

	/// `named`, and the holidays, which throw.
	private mutating func parseNamed(_ pig: inout Pig) throws(DateInputError) -> Bool {
		if
			parseNow(&pig) || parseRelativeDay(&pig) || parseOrdinal(&pig) || parseDayName(&pig)
			|| parseMonthName(&pig) || parseLater(&pig) || parsePeriodBoundary(&pig)
		{
			return true
		}
		if let holiday = holidayNames.first(where: { pig.startsWithWord($0) }) {
			throw .holiday(holiday)
		}
		return parseInformalTime(&pig)
	}

	/// Unsigned integers from 1980 on, so `12` isn't taken for an epoch.
	private mutating func parseEpoch(_ pig: inout Pig) -> Bool {
		let checkpoint = pig.cursor
		if let epoch = pig.getDigits(), !isLatinAlpha(pig.peek()), epochRange.contains(epoch) {
			date = epoch
			return true
		}
		pig.cursor = checkpoint
		return false
	}

	/// `date_ext 'T' (time_utc_ext | time_off_ext | time_ext)`.
	private mutating func parseDateTimeExtended(_ pig: inout Pig) -> Bool {
		let checkpoint = pig.cursor
		if
			parseDateExtended(&pig), pig.skip("T"),
			parseTimeUTCExtended(&pig) || parseTimeOffsetExtended(&pig) || parseTimeExtended(&pig)
		{
			return true
		}
		pig.cursor = checkpoint
		return false
	}

	/// `YYYY-MM-DD`, `YYYY-MM`, `YYYY-DDD`, `YYYY-Www-D` or `YYYY-Www`.
	private mutating func parseDateExtended(_ pig: inout Pig) -> Bool {
		let checkpoint = pig.cursor
		guard let year = parseYear(&pig), pig.skip("-") else {
			pig.cursor = checkpoint
			return false
		}
		let yearCheckpoint = pig.cursor

		if pig.skip("W"), let week = parseWeek(&pig) {
			// A `-` without a weekday after it stays skipped, as it does in the original.
			var weekday = settings.weekstart
			if pig.skip("-"), let parsed = parseWeekday(&pig) {
				weekday = parsed
			}
			if !isLatinDigit(pig.peek()) {
				self.weekday = weekday
				self.week = week
				self.year = year
				return true
			}
		}

		pig.cursor = yearCheckpoint
		if
			let month = parseMonth(&pig), pig.skip("-"), let day = parseDay(&pig),
			!isLatinDigit(pig.peek())
		{
			self.year = year
			self.month = month
			self.day = day
			return true
		}

		pig.cursor = yearCheckpoint
		if let julian = parseJulian(&pig), !isLatinDigit(pig.peek()) {
			self.year = year
			self.julian = julian
			return true
		}

		pig.cursor = yearCheckpoint
		if
			let month = parseMonth(&pig), pig.peek() != ascii("-"),
			!isLatinDigit(pig.peek())
		{
			self.year = year
			self.month = month
			day = 1
			return true
		}

		pig.cursor = checkpoint
		return false
	}

	/// `±hh[:mm]`.
	private mutating func parseOffsetExtended(_ pig: inout Pig) -> Bool {
		let checkpoint = pig.cursor
		let sign = pig.peek()
		if sign == ascii("+") || sign == ascii("-") {
			pig.cursor += 1
			if let hour = parseOffsetHour(&pig) {
				var minute = 0
				if pig.skip(":") {
					guard let parsed = parseMinute(&pig) else {
						pig.cursor = checkpoint
						return false
					}
					minute = parsed
				}
				offset = hour * secondsPerHour + minute * secondsPerMinute
				if sign == ascii("-") {
					offset = -offset
				}
				if !isLatinDigit(pig.peek()) {
					return true
				}
			}
		}
		pig.cursor = checkpoint
		return false
	}

	/// `hh:mm[:ss]`. A `terminated` time can't run into an offset.
	private mutating func parseTimeExtended(_ pig: inout Pig, terminated: Bool = true) -> Bool {
		let checkpoint = pig.cursor
		if
			let hour = parseHour(&pig), pig.skip(":"), let minute = parseMinute(&pig)
		{
			let isOffset = { (character: Int) in
				character == ascii("+") || character == ascii("-")
			}
			if pig.skip(":") {
				if
					let second = parseMinute(&pig), !isLatinDigit(pig.peek()),
					!terminated || !isOffset(pig.peek())
				{
					seconds = hour * secondsPerHour + minute * secondsPerMinute + second
					return true
				}
				pig.cursor = checkpoint
				return false
			}
			let following = pig.peek()
			if
				!isLatinDigit(following), !terminated || !isOffset(following),
				!"AaPp".utf8.contains(where: { Int($0) == following })
			{
				seconds = hour * secondsPerHour + minute * secondsPerMinute
				return true
			}
		}
		pig.cursor = checkpoint
		return false
	}

	/// `time_ext 'Z'`.
	private mutating func parseTimeUTCExtended(_ pig: inout Pig) -> Bool {
		let checkpoint = pig.cursor
		if
			parseTimeExtended(&pig, terminated: false), pig.skip("Z"),
			!isLatinDigit(pig.peek())
		{
			utc = true
			return true
		}
		pig.cursor = checkpoint
		return false
	}

	/// `time_ext off_ext`.
	private mutating func parseTimeOffsetExtended(_ pig: inout Pig) -> Bool {
		let checkpoint = pig.cursor
		if parseTimeExtended(&pig, terminated: false), parseOffsetExtended(&pig) {
			return true
		}
		pig.cursor = checkpoint
		return false
	}

	/// `YYYYMMDD 'T' (time_utc | time_off | time)`.
	private mutating func parseDateTime(_ pig: inout Pig) -> Bool {
		let checkpoint = pig.cursor
		if
			parseDate(&pig), pig.skip("T"),
			parseTimeUTC(&pig) || parseTimeOffset(&pig) || parseTime(&pig)
		{
			return true
		}
		pig.cursor = checkpoint
		return false
	}

	/// `YYYYWww[D]`, `YYYYDDD`, `YYYYMMDD` or `YYYYMM`, which TW reads standalone only after a
	/// time.
	private mutating func parseDate(_ pig: inout Pig) -> Bool {
		let checkpoint = pig.cursor
		guard let year = parseYear(&pig) else {
			pig.cursor = checkpoint
			return false
		}
		let yearCheckpoint = pig.cursor

		if pig.skip("W"), let week = parseWeek(&pig) {
			let weekday = parseWeekday(&pig) ?? settings.weekstart
			if !isLatinDigit(pig.peek()) {
				self.year = year
				self.week = week
				self.weekday = weekday
				return true
			}
		}

		pig.cursor = yearCheckpoint
		if let julian = parseJulian(&pig), !isLatinDigit(pig.peek()) {
			self.year = year
			self.julian = julian
			return true
		}

		pig.cursor = yearCheckpoint
		if let month = parseMonth(&pig) {
			let day = parseDay(&pig)
			if !isLatinDigit(pig.peek()) {
				self.year = year
				self.month = month
				self.day = day ?? 1
				return true
			}
		}

		pig.cursor = checkpoint
		return false
	}

	/// `time 'Z'`. Sets `utc` even when it fails on a digit after the `Z`, as the original does.
	private mutating func parseTimeUTC(_ pig: inout Pig) -> Bool {
		let checkpoint = pig.cursor
		if parseTime(&pig, terminated: false), pig.skip("Z") {
			utc = true
			if !isLatinDigit(pig.peek()) {
				return true
			}
		}
		pig.cursor = checkpoint
		return false
	}

	/// `time off`.
	private mutating func parseTimeOffset(_ pig: inout Pig) -> Bool {
		let checkpoint = pig.cursor
		if parseTime(&pig, terminated: false), parseOffset(&pig) {
			let terminator = pig.peek()
			if terminator != ascii("-"), !isLatinDigit(terminator) {
				return true
			}
		}
		pig.cursor = checkpoint
		return false
	}

	/// `hhmm[ss]`.
	private mutating func parseTime(_ pig: inout Pig, terminated: Bool = true) -> Bool {
		let checkpoint = pig.cursor
		if let hour = parseHour(&pig), let minute = parseMinute(&pig) {
			let second = parseMinute(&pig) ?? 0
			let terminator = pig.peek()
			if
				!terminated
				|| (
					!isLatinDigit(terminator) && terminator != ascii("-")
						&& terminator != ascii("+")
				)
			{
				seconds = hour * secondsPerHour + minute * secondsPerMinute + second
				return true
			}
		}
		pig.cursor = checkpoint
		return false
	}

	/// `±hhmm` or `±hh`.
	private mutating func parseOffset(_ pig: inout Pig) -> Bool {
		let checkpoint = pig.cursor
		let sign = pig.peek()
		if sign == ascii("+") || sign == ascii("-") {
			pig.cursor += 1
			if let hour = parseOffsetHour(&pig) {
				let minute = parseMinute(&pig) ?? 0
				if !isLatinDigit(pig.peek()) {
					offset = hour * secondsPerHour + minute * secondsPerMinute
					if sign == ascii("-") {
						offset = -offset
					}
					return true
				}
			}
		}
		pig.cursor = checkpoint
		return false
	}

	private func parseYear(_ pig: inout Pig) -> Int? {
		pig.getDigits(count: 4, in: 1_970 ... 9_999)
	}

	private func parseMonth(_ pig: inout Pig) -> Int? {
		pig.getDigits(count: 2, in: 1 ... 12)
	}

	private func parseWeek(_ pig: inout Pig) -> Int? {
		pig.getDigits(count: 2, in: 1 ... 53)
	}

	private func parseJulian(_ pig: inout Pig) -> Int? {
		pig.getDigits(count: 3, in: 1 ... 366)
	}

	private func parseDay(_ pig: inout Pig) -> Int? {
		pig.getDigits(count: 2, in: 1 ... 31)
	}

	/// 1–7 when the week starts on Monday, else 0–6.
	private func parseWeekday(_ pig: inout Pig) -> Int? {
		let checkpoint = pig.cursor
		if let weekday = pig.getDigit(), settings.weekdays.contains(weekday) {
			return weekday
		}
		pig.cursor = checkpoint
		return nil
	}

	private func parseHour(_ pig: inout Pig) -> Int? {
		pig.getDigits(count: 2, in: 0 ... 23)
	}

	/// Minutes and seconds alike.
	private func parseMinute(_ pig: inout Pig) -> Int? {
		pig.getDigits(count: 2, in: 0 ... 59)
	}

	private func parseOffsetHour(_ pig: inout Pig) -> Int? {
		pig.getDigits(count: 2, in: 0 ... 12)
	}

	private mutating func parseNow(_ pig: inout Pig) -> Bool {
		guard pig.startsWithWord("now") else {
			return false
		}
		pig.cursor += 3
		date = clock.now
		return true
	}

	/// `yesterday`, `today` or `tomorrow`, or 3 letters or more of one.
	private mutating func parseRelativeDay(_ pig: inout Pig) -> Bool {
		for (name, days) in [("yesterday", -1), ("today", 0), ("tomorrow", 1)] {
			let checkpoint = pig.cursor
			if pig.skipPartial(name) >= 3, pig.isAtWordEnd {
				date = clock.local { $0.startOfDay(adding: days) }
				return true
			}
			pig.cursor = checkpoint
		}
		return false
	}

	/// `1st`, `2nd`, `3rd`, `4th` and so on up to `31st`: the next such day of a month, today
	/// excluded.
	private mutating func parseOrdinal(_ pig: inout Pig) -> Bool {
		let checkpoint = pig.cursor
		if
			let number = pig.getDigits(), (1 ... 31).contains(number),
			let first = pig.getCharacter(), let second = pig.getCharacter(), pig.isAtWordEnd
		{
			let units = number % 10
			let tens = number % 100
			let expected =
				switch units {
				case 1 where tens != 11: "st"
				case 2 where tens != 12: "nd"
				case 3 where tens != 13: "rd"
				default: "th"
				}
			if expected.utf8.map(Int.init) == [first, second] {
				date = clock.local { time in
					if number <= time.day {
						time.month += 1
					}
					time.startOfDay(adding: number - time.day)
				}
				return true
			}
		}
		pig.cursor = checkpoint
		return false
	}

	/// A day's name, or 3 letters or more of it, in any case: its next date, today excluded.
	private mutating func parseDayName(_ pig: inout Pig) -> Bool {
		let checkpoint = pig.cursor
		// Sunday twice, as 0 and 7, as the original loops.
		for day in 0 ... 7 {
			if
				pig.skipPartial(dayNames[day % 7], ignoringCase: true) >= 3, pig.isAtWordEnd,
				!pig.isAtPairSeparator
			{
				date = clock.local { time in
					time.startOfDay(adding: day - time.weekday + (time.weekday >= day ? 7 : 0))
				}
				return true
			}
			pig.cursor = checkpoint
		}
		return false
	}

	/// A month's name, or 3 letters or more of it, in any case: its next 1st, this month excluded.
	private mutating func parseMonthName(_ pig: inout Pig) -> Bool {
		let checkpoint = pig.cursor
		for (month, name) in monthNames.enumerated() {
			if
				pig.skipPartial(name, ignoringCase: true) >= 3, pig.isAtWordEnd,
				!pig.isAtPairSeparator
			{
				date = clock.local { time in
					if time.month >= month {
						time.year += 1
					}
					time.startOfMonth(adding: month - time.month)
				}
				return true
			}
			pig.cursor = checkpoint
		}
		return false
	}

	/// `later`, `someday`, or 3 letters or more of `later` or 4 of `someday`: 9999-12-30. A too-short
	/// `later` stays skipped when `someday` is tried, as it does in the original.
	private mutating func parseLater(_ pig: inout Pig) -> Bool {
		let checkpoint = pig.cursor
		let later = pig.skipPartial("later") >= 3
		if later || pig.skipPartial("someday") >= 4, pig.isAtWordEnd {
			date = clock.local { time in
				time.year = 9_999
				time.month = 11
				time.startOfDay(adding: 30 - time.day)
			}
			return true
		}
		pig.cursor = checkpoint
		return false
	}

	/// `sod`, `eow`, `sopq` and the rest: the start or end of the previous, current or next day,
	/// week, month, quarter or year. Weeks run Monday to Sunday, and the `ww` work weeks Monday to
	/// Friday, whatever `weekstart` says.
	private mutating func parsePeriodBoundary(_ pig: inout Pig) -> Bool {
		guard let (name, adjust) = periodBoundaries.first(where: { pig.startsWithWord($0.name) }) else {
			return false
		}
		pig.cursor += name.utf8.count
		date = clock.local(adjust)
		return true
	}

	/// `8am`, `8a`, `8:30am`, `8:30`, `8:30:00` and the like: the next such time, today included.
	private mutating func parseInformalTime(_ pig: inout Pig) -> Bool {
		let checkpoint = pig.cursor
		guard let (hours, minutes, seconds) = readInformalTime(&pig) else {
			pig.cursor = checkpoint
			return false
		}
		date = clock.local { time in
			if hours * secondsPerHour + minutes * secondsPerMinute + seconds < time.secondOfDay {
				time.day += 1
			}
			time.hour = hours
			time.minute = minutes
			time.second = seconds
		}
		return true
	}

	/// The hours, minutes and seconds of an informal time, leaving the cursor anywhere when there's
	/// none.
	private func readInformalTime(_ pig: inout Pig) -> (Int, Int, Int)? {
		guard var hours = pig.getDigit() else {
			return nil
		}
		if let digit = pig.getDigit() {
			hours = hours * 10 + digit
		}
		var minutes = 0
		var seconds = 0
		var needsDesignator = true
		if pig.skip(":") {
			guard let parsed = pig.getDigits(count: 2) else {
				return nil
			}
			minutes = parsed
			if pig.skip(":") {
				guard let parsed = pig.getDigits() else {
					return nil
				}
				seconds = parsed
			}
			needsDesignator = false
		}

		var hasDesignator = false
		if pig.skipLiteral("am") || pig.skipLiteral("a") {
			hasDesignator = true
			if hours == 12 {
				hours = 0
			}
		} else if pig.skipLiteral("pm") || pig.skipLiteral("p") {
			hasDesignator = true
			if hours != 12 {
				hours += 12
			}
		}

		let following = pig.peek()
		guard
			pig.isAtWordEnd, following != ascii(":"),
			following != ascii("-"), following != ascii("+"),
			hasDesignator || !needsDesignator, (0 ..< 24).contains(hours), (0 ..< 60).contains(minutes),
			(0 ..< 60).contains(seconds)
		else {
			return nil
		}
		return (hours, minutes, seconds)
	}

	/// Range checks on what the ISO and formatted parsers read.
	private func validate() -> Bool {
		if year != 0, !(1_900 ... 9_999).contains(year) {
			return false
		}
		if month != 0, !(1 ... 12).contains(month) {
			return false
		}
		if week != 0, !(1 ... 53).contains(week) {
			return false
		}
		if !settings.weekdays.contains(weekday) {
			return false
		}
		if julian != 0, !(1 ... daysInYear(year)).contains(julian) {
			return false
		}
		if day != 0, !(1 ... daysInMonth(year: year, month: month)).contains(day) {
			return false
		}
		if seconds != 0, !(1 ... secondsPerDay).contains(seconds) {
			return false
		}
		if offset != 0, !(-secondsPerDay ... secondsPerDay).contains(offset) {
			return false
		}
		return true
	}

	/// Turns the parsed fields into `date`, filling what's missing from now.
	private mutating func resolve() {
		var year = year
		var month = month
		var day = day
		var julian = julian
		var seconds = seconds
		var now = clock.now
		var utc = utc

		// Once the offset is taken off, only local and UTC times remain.
		if offset != 0 {
			seconds -= offset
			now -= offset
			utc = true
		}
		let timeNow = clock.brokenDown(now, utc: utc)

		// A time alone that's already passed today means tomorrow.
		let secondsNow = timeNow.secondOfDay
		if
			year == 0, month == 0, day == 0, week == 0, weekday == settings.weekstart,
			seconds < secondsNow
		{
			seconds += secondsPerDay
		}

		if week != 0 {
			let january4 = dayOfWeek(year: year, month: 1, day: 4)
			if settings.weekstart == 1 {
				// https://en.wikipedia.org/wiki/ISO_week_date
				julian = week * 7 + weekday - ((january4 == 0 ? 7 : january4) + 3)
				if julian < 1 {
					year -= 1
					julian += daysInYear(year)
				} else if julian > daysInYear(year) {
					julian -= daysInYear(year)
					year += 1
				}
			} else {
				julian = week * 7 + weekday - january4 - 3
			}
		} else if year == 0 {
			year = timeNow.year
			month = timeNow.month + 1
			day = timeNow.day
		} else if month == 0 {
			month = 1
			day = 1
		} else if day == 0 {
			day = 1
		}

		if julian != 0 {
			month = 1
			day = julian
		}

		var time = BrokenDownTime(
			year: year,
			month: month - 1,
			day: day,
			hour: 0,
			minute: 0,
			second: 0,
		)
		if seconds > secondsPerDay {
			time.day += seconds / secondsPerDay
			seconds %= secondsPerDay
		}
		time.hour = seconds / secondsPerHour
		time.minute = seconds % secondsPerHour / secondsPerMinute
		time.second = seconds % 60
		date = clock.epoch(time, utc: utc)
	}
}

/// The period boundaries in the order libshared tries them, which puts `sow` before `soww` so that
/// `soww` only matches whole.
private let periodBoundaries: [(name: String, adjust: @Sendable (inout BrokenDownTime) -> Void)] = [
	("sopd", { $0.startOfDay(adding: -1) }),
	("sod", { $0.startOfDay(adding: 0) }),
	("sond", { $0.startOfDay(adding: 1) }),
	("eopd", { $0.endOfDay(adding: -1) }),
	("eod", { $0.endOfDay(adding: 0) }),
	("eond", { $0.endOfDay(adding: 1) }),
	("sopw", { $0.startOfDay(adding: -$0.daysSinceMonday - 7) }),
	("sow", { $0.startOfDay(adding: -$0.daysSinceMonday) }),
	("sonw", { $0.startOfDay(adding: 7 - $0.daysSinceMonday) }),
	("eopw", { $0.endOfDay(adding: -$0.daysSinceMonday - 1) }),
	("eow", { $0.endOfDay(adding: 6 - $0.daysSinceMonday) }),
	("eonw", { $0.endOfDay(adding: 13 - $0.daysSinceMonday) }),
	("sopww", { $0.startOfDay(adding: -6 - $0.weekday) }),
	("sonww", { $0.startOfDay(adding: 8 - $0.weekday) }),
	("soww", { $0.startOfDay(adding: 1 - $0.weekday) }),
	("eopww", { $0.endOfDay(adding: -$0.weekday - 2) }),
	("eonww", { $0.endOfDay(adding: 12 - $0.weekday) }),
	("eoww", { $0.endOfDay(adding: 5 - $0.weekday) }),
	("sopm", { $0.startOfMonth(adding: -1) }),
	("som", { $0.startOfMonth(adding: 0) }),
	("sonm", { $0.startOfMonth(adding: 1) }),
	("eopm", { $0.endOfMonth(adding: -1) }),
	("eom", { $0.endOfMonth(adding: 0) }),
	("eonm", { $0.endOfMonth(adding: 1) }),
	("sopq", { $0.startOfMonth(adding: -$0.month % 3 - 3) }),
	("soq", { $0.startOfMonth(adding: -$0.month % 3) }),
	("sonq", { $0.startOfMonth(adding: 3 - $0.month % 3) }),
	("eopq", { $0.endOfMonth(adding: -$0.month % 3 - 1) }),
	("eoq", { $0.endOfMonth(adding: 2 - $0.month % 3) }),
	("eonq", { $0.endOfMonth(adding: 5 - $0.month % 3) }),
	("sopy", { $0.startOfMonth(adding: -$0.month - 12) }),
	("soy", { $0.startOfMonth(adding: -$0.month) }),
	("sony", { $0.startOfMonth(adding: 12 - $0.month) }),
	("eopy", { $0.endOfMonth(adding: -$0.month - 1) }),
	("eoy", { $0.endOfMonth(adding: 11 - $0.month) }),
	("eony", { $0.endOfMonth(adding: 23 - $0.month) }),
]

extension BrokenDownTime {
	/// Seconds since midnight, as the fields say, even out of range.
	var secondOfDay: Int {
		hour * secondsPerHour + minute * secondsPerMinute + second
	}

	/// Days back to Monday: 0 on a Monday, 6 on a Sunday.
	fileprivate var daysSinceMonday: Int {
		(weekday + 6) % 7
	}

	/// Midnight at the start of the day `days` from this one.
	fileprivate mutating func startOfDay(adding days: Int) {
		day += days
		hour = 0
		minute = 0
		second = 0
	}

	/// 23:59:59 on the day `days` from this one.
	fileprivate mutating func endOfDay(adding days: Int) {
		startOfDay(adding: days + 1)
		second = -1
	}

	/// Midnight on the 1st of the month `months` from this one.
	fileprivate mutating func startOfMonth(adding months: Int) {
		month += months
		startOfDay(adding: 1 - day)
	}

	/// 23:59:59 on the last day of the month `months` from this one.
	fileprivate mutating func endOfMonth(adding months: Int) {
		startOfMonth(adding: months + 1)
		second = -1
	}
}

extension Pig {
	/// Whether the next character would make the word an attribute name, as in `monday:x`.
	fileprivate var isAtPairSeparator: Bool {
		peek() == ascii(":") || peek() == ascii("=")
	}

	/// Digits as the formatted parser reads a variable-width field: a leading 0 reads the next
	/// digit in its place, then a value in `tens` reads another digit, taking the value as its tens.
	fileprivate mutating func getVariableDigits(
		into value: inout Int,
		tensFrom tens: ClosedRange<Int>,
	) -> Bool {
		guard var parsed = getDigit() else {
			return false
		}
		if parsed == 0, let digit = getDigit() {
			parsed = digit
		}
		if tens.contains(parsed), let digit = getDigit() {
			parsed = parsed * 10 + digit
		}
		value = parsed
		return true
	}

	/// Exactly `count` digits within `range`.
	fileprivate mutating func getDigits(count: Int, in range: ClosedRange<Int>) -> Int? {
		let checkpoint = cursor
		if let value = getDigits(count: count), range.contains(value) {
			return value
		}
		cursor = checkpoint
		return nil
	}
}

/// `Datetime::dayOfWeek`: the index of the day `name` names, whole or by 3 letters or more, in any
/// case, or -1.
func dayOfWeek(_ name: [UInt8]) -> Int {
	dayNames.firstIndex { closeEnough($0, name) } ?? -1
}

/// `Datetime::monthOfYear`: the 1-based month `name` names, as `dayOfWeek` matches, or -1.
private func monthOfYear(_ name: [UInt8]) -> Int {
	monthNames.firstIndex { closeEnough($0, name) }.map { $0 + 1 } ?? -1
}

/// libshared's `closeEnough` with a minimum of 3: `attempt` is `reference`, or a prefix of it at
/// least 3 long, ignoring case.
private func closeEnough(_ reference: String, _ attempt: [UInt8]) -> Bool {
	let attempt = String(decoding: attempt, as: UTF8.self).lowercased()
	return reference == attempt || (attempt.count >= 3 && reference.hasPrefix(attempt))
}

/// Zeller's congruence, as RFC 3339 has it: 0 is Sunday.
private func dayOfWeek(year: Int, month: Int, day: Int) -> Int {
	var year = year
	var month = month - 2
	if month < 1 {
		month += 12
		year -= 1
	}
	let century = year / 100
	year %= 100
	return ((26 * month - 2) / 10 + day + year + year / 4 + century / 4 + 5 * century) % 7
}

private func isLeapYear(_ year: Int) -> Bool {
	(year.isMultiple(of: 4) && !year.isMultiple(of: 100)) || year.isMultiple(of: 400)
}

private func daysInYear(_ year: Int) -> Int {
	isLeapYear(year) ? 366 : 365
}

private func daysInMonth(year: Int, month: Int) -> Int {
	switch month {
	case 2: isLeapYear(year) ? 29 : 28
	case 4, 6, 9, 11: 30
	default: 31
	}
}

private func floorDivision(_ dividend: Int, _ divisor: Int) -> (quotient: Int, remainder: Int) {
	let remainder = (dividend % divisor + divisor) % divisor
	return ((dividend - remainder) / divisor, remainder)
}

/// Days since 1970-01-01 in the proleptic Gregorian calendar, after Howard Hinnant's
/// `days_from_civil`.
private func daysFromCivil(year: Int, month: Int, day: Int) -> Int {
	let year = month <= 2 ? year - 1 : year
	let era = floorDivision(year, 400).quotient
	let yearOfEra = year - era * 400
	let dayOfYear = (153 * (month + (month > 2 ? -3 : 9)) + 2) / 5 + day - 1
	let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
	return era * 146_097 + dayOfEra - 719_468
}

/// The inverse of `daysFromCivil`.
private func civilFromDays(_ days: Int) -> (year: Int, month: Int, day: Int) {
	let days = days + 719_468
	let era = floorDivision(days, 146_097).quotient
	let dayOfEra = days - era * 146_097
	let yearOfEra = (dayOfEra - dayOfEra / 1_460 + dayOfEra / 36_524 - dayOfEra / 146_096) / 365
	let dayOfYear = dayOfEra - (365 * yearOfEra + yearOfEra / 4 - yearOfEra / 100)
	let monthIndex = (5 * dayOfYear + 2) / 153
	let day = dayOfYear - (153 * monthIndex + 2) / 5 + 1
	let month = monthIndex < 10 ? monthIndex + 3 : monthIndex - 9
	return (yearOfEra + era * 400 + (month <= 2 ? 1 : 0), month, day)
}
