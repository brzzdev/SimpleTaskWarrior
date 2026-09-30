import Foundation
import Models
import Taskrc
import Testing
import TestSupport

/// Checked against what `task` 3.5 stores for each input `just fixtures` records.
struct DateInputTests {
	/// Inputs `task` resolves that the app refuses, as `DateFixtures/README.md` records.
	static let departures: [String: DateInputError] = [
		"due:ascension": .holiday("ascension"),
		"due:easter": .holiday("easter"),
		"due:easter+1d": .holiday("easter"),
		"due:eastermonday": .holiday("eastermonday"),
		"due:goodfriday": .holiday("goodfriday"),
		"due:juhannus": .holiday("juhannus"),
		"due:midsommar": .holiday("midsommar"),
		"due:midsommarafton": .holiday("midsommarafton"),
		"due:pentecost": .holiday("pentecost"),
	]

	/// What `just fixtures` sets before each input, for it to refer to.
	static let references: [String: DateInput.Reference] = [
		"review": .date(Date(timeIntervalSince1970: 1_791_000_000)),
		"scheduled": .date(Date(timeIntervalSince1970: 1_790_845_200)),
		"span": .duration(TaskDuration(seconds: 2 * 86_400)),
		// Unset, which TW reads as an empty string.
		"until": .text(""),
	]

	@Test(arguments: ["custom", "default", "noiso"])
	func inputsMatchTask(fixture: String) throws {
		let directory = try #require(Bundle.module.url(forResource: "DateFixtures", withExtension: nil))
			.appending(path: fixture)
		let taskrc = Taskrc(fixture: directory.appending(path: "taskrc"))
		let expected = try String(contentsOf: directory.appending(path: "expected"), encoding: .utf8)

		for line in expected.split(separator: "\n") {
			let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
			let (zone, second, input, stored) = (fields[0], fields[1], fields[2], fields[3])
			let (attribute, text) = try #require(input.firstIndex(of: ":").map {
				(String(input[..<$0]), String(input[input.index(after: $0)...]))
			})
			let dateInput = try DateInput(taskrc: taskrc, timeZone: #require(TimeZone(identifier: zone)))
			let now = try Date(timeIntervalSince1970: #require(TimeInterval(second)))
			let context = Comment(rawValue: "\(input) in \(zone)")

			if let departure = Self.departures[input] {
				#expect(!stored.isEmpty, "\(context): task refuses it too, so it's no departure")
				#expect(throws: departure, context) {
					try dateInput.date(text, at: now, references: { Self.references[$0] })
				}
				continue
			}
			if taskrc.udaTypes[attribute] == .duration {
				let duration = try? dateInput.duration(text, at: now) { Self.references[$0] }
				#expect(duration?.iso ?? "" == stored, context)
			} else {
				let date = try? dateInput.date(text, at: now) { Self.references[$0] }
				#expect(date.map { String(Int($0.timeIntervalSince1970)) } ?? "" == stored, context)
			}
		}
	}

	@Test(arguments: ["monday", "sunday"])
	func weeksRunMondayToSundayWhateverTheWeekstart(weekstart: String) throws {
		let dateInput = DateInput(taskrc: taskrc("weekstart=\(weekstart)"), timeZone: .gmt)
		// A Sunday.
		let now = try #require(ISO8601DateFormatter().date(from: "2026-09-27T12:00:00Z"))

		let date = { (text: String) in try dateInput.date(text, at: now).ISO8601Format() }

		#expect(try date("sow") == "2026-09-21T00:00:00Z")
		#expect(try date("eow") == "2026-09-27T23:59:59Z")
		#expect(try date("sonw") == "2026-09-28T00:00:00Z")
	}

	@Test(arguments: [
		(604_800, "1w"),
		(-1_209_600, "-2w"),
		(259_200, "3d"),
		(90_000, "25h"),
		(5_400, "90min"),
		(90, "PT1M30S"),
	])
	func durationsDisplayInTheLargestExactUnit(seconds: Int, display: String) throws {
		let duration = TaskDuration(seconds: seconds)

		#expect(duration.description == display)
		#expect(try DateInput(taskrc: taskrc(""), timeZone: .gmt).duration(display, at: .now) == duration)
	}

	/// Under a `dateformat` of its own, in a zone off UTC by a fraction of an hour, and on both
	/// occurrences of an hour the clocks go back over, the text reads back as the same second.
	@Test(arguments: [
		("America/New_York", 1_793_511_000, "2026-11-01T01:30"),
		("America/New_York", 1_793_514_600, "2026-11-01T01:30-05:00"),
		("Australia/Lord_Howe", 1_790_519_400, "2026-09-28T01:00"),
		("Australia/Lord_Howe", 1_790_519_415, "2026-09-28T01:00:15"),
		("Europe/Berlin", 1_792_888_200, "2026-10-25T02:30"),
		("Europe/Berlin", 1_792_891_800, "2026-10-25T02:30+01:00"),
		("Europe/London", 1_792_888_200, "2026-10-25T01:30"),
		("Europe/London", 1_792_891_800, "2026-10-25T01:30Z"),
		("Europe/London", 1_792_891_815, "2026-10-25T01:30:15Z"),
	])
	func isoLocalReadsBackAsTheSameSecond(zone: String, epoch: TimeInterval, text: String) throws {
		let timeZone = try #require(TimeZone(identifier: zone))
		let dateInput = DateInput(taskrc: taskrc("dateformat=m/d/Y"), timeZone: timeZone)
		let date = Date(timeIntervalSince1970: epoch)

		#expect(date.isoLocal(in: timeZone) == text)
		#expect(try dateInput.date(text, at: .now) == date)
	}

	/// A Taskrc of `contents` over TW's defaults.
	private func taskrc(_ contents: String) -> Taskrc {
		Taskrc(path: "/taskrc", environment: .fixture) { path throws(Taskrc.ReadError) in
			Taskrc.File(contents: contents, realPath: path)
		}
	}
}
