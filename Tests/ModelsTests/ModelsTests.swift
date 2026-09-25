import Foundation
import Models
import Taskrc
import Testing
import TestSupport

/// Checked against what `task` 3.5 reports for the Replicas `just fixtures` records.
struct ModelsTests {
	static let fixtures = ["inherit", "urgency"]

	@Test(arguments: fixtures)
	func blockedRuleMatchesTask(fixture: String) throws {
		let fixture = try Fixture(fixture)

		let scan = DependencyScan(fixture.tasks)

		#expect(try scan.blocked == fixture.uuids("blocked"))
		#expect(try scan.blocking == fixture.uuids("blocking"))
	}

	@Test(arguments: fixtures)
	func decodingMatchesTaskExport(fixture: String) throws {
		let fixture = try Fixture(fixture)
		let tasks = Dictionary(
			uniqueKeysWithValues: fixture.tasks.map { ($0.id.uuidString.lowercased(), $0) },
		)

		for var exported in try fixture.export() {
			exported["urgency"] = nil
			guard case let .string(uuid) = exported["uuid"] else {
				Issue.record("an exported task has no UUID")
				continue
			}
			let task = try #require(tasks[uuid])
			#expect(ExportValue.fields(of: task) == exported)
		}
	}

	@Test(arguments: fixtures)
	func templatesMatchTask(fixture: String) throws {
		let fixture = try Fixture(fixture)

		#expect(try Set(fixture.tasks.filter(\.isTemplate).map(\.id)) == fixture.uuids("templates"))
	}

	@Test(arguments: fixtures)
	func urgencyMatchesTaskExport(fixture: String) throws {
		let fixture = try Fixture(fixture)

		let urgencies = UrgencyCoefficients(fixture.taskrc)
			.urgencies(of: fixture.tasks, at: fixture.now, in: .gmt)
			.reduce(into: [:]) { $0[$1.key.uuidString.lowercased()] = $1.value }

		for exported in try fixture.export() {
			guard
				case let .string(uuid) = exported["uuid"],
				case let .string(description) = exported["description"],
				case let .number(expected) = exported["urgency"]
			else {
				Issue.record("an exported task has no UUID, description or Urgency")
				continue
			}
			let urgency = try #require(urgencies[uuid])
			// `export` prints 6 significant digits.
			#expect(abs(urgency - expected) <= 1e-5 * max(1, abs(expected)), "\(description)")
		}
	}
}

/// One recording from `just fixtures`.
private struct Fixture {
	private struct Record: Decodable {
		var properties: [String: String]
		var workingSetID: Int?
	}

	let directory: URL
	let now: Date
	let tasks: [Models.Task]
	let taskrc: Taskrc

	init(_ name: String) throws {
		directory = try #require(Bundle.module.url(forResource: "Fixtures", withExtension: nil))
			.appending(path: name)
		let now = try String(contentsOf: directory.appending(path: "now"), encoding: .utf8)
		let seconds = try #require(TimeInterval(now.trimmingCharacters(in: .newlines)))
		self.now = Date(timeIntervalSince1970: seconds)
		let taskrc = Taskrc(fixture: directory.appending(path: "taskrc"))
		self.taskrc = taskrc
		tasks = try JSONDecoder()
			.decode([String: Record].self, from: Data(contentsOf: directory.appending(path: "tasks.json")))
			.map { uuid, record in
				let task = Models.Task(
					properties: record.properties,
					udaTypes: taskrc.udaTypes,
					uuid: uuid,
					workingSetID: record.workingSetID,
				)
				return try #require(task)
			}
	}

	/// `task export`, one task per element.
	func export() throws -> [[String: ExportValue]] {
		try JSONDecoder().decode(
			[[String: ExportValue]].self,
			from: Data(contentsOf: directory.appending(path: "export.json")),
		)
	}

	/// The UUIDs `task` listed in `file`, one per line.
	func uuids(_ file: String) throws -> Set<UUID> {
		try Set(
			String(contentsOf: directory.appending(path: file), encoding: .utf8)
				.split(separator: "\n")
				.map { try #require(UUID(uuidString: String($0))) },
		)
	}
}

/// A field of `task export`, with its lists sorted.
private enum ExportValue: Decodable, Equatable {
	case annotations([Annotation])
	case number(Double)
	case string(String)
	case strings([String])

	struct Annotation: Decodable, Equatable {
		var description: String
		var entry: String
	}

	init(from decoder: any Decoder) throws {
		let container = try decoder.singleValueContainer()
		if let number = try? container.decode(Double.self) {
			self = .number(number)
		} else if let string = try? container.decode(String.self) {
			self = .string(string)
		} else if let strings = try? container.decode([String].self) {
			self = .strings(strings.sorted())
		} else {
			self = try .annotations(container.decode([Annotation].self))
		}
	}

	/// The fields `task export` writes for `task`, besides `urgency`.
	static func fields(of task: Models.Task) -> [String: Self] {
		var fields: [String: Self] = [
			"description": .string(task.description),
			"id": .number(Double(task.workingSetID ?? 0)),
			"status": .string(task.status.rawValue),
			"uuid": .string(task.id.uuidString.lowercased()),
		]
		let dates = [
			"due": task.due,
			"end": task.end,
			"entry": task.entry,
			"modified": task.modified,
			"scheduled": task.scheduled,
			"start": task.start,
			"until": task.until,
			"wait": task.wait,
		]
		for case let (key, date?) in dates {
			fields[key] = .string(iso(date))
		}
		let strings = [
			"mask": task.mask,
			"parent": task.parent,
			"project": task.project,
			"recur": task.recur,
			"rtype": task.rtype,
			"template": task.template,
		]
		for case let (key, string?) in strings {
			fields[key] = .string(string)
		}
		for case let (key, number?) in ["imask": task.imask, "last": task.last] {
			fields[key] = Double(number).map(Self.number)
		}
		if !task.annotations.isEmpty {
			fields["annotations"] = .annotations(
				task.annotations.map { Annotation(description: $0.description, entry: iso($0.entry)) },
			)
		}
		if !task.dependencies.isEmpty {
			fields["depends"] = .strings(task.dependencies.map { $0.uuidString.lowercased() }.sorted())
		}
		if !task.tags.isEmpty {
			fields["tags"] = .strings(task.tags.sorted())
		}
		for (key, value) in task.orphans {
			fields[key] = .string(value)
		}
		for (key, value) in task.udas {
			switch value {
			case let .date(date): fields[key] = .string(iso(date))
			case let .duration(duration): fields[key] = .string(duration.iso)
			case let .string(string): fields[key] = .string(string)
			case let .numeric(number): fields[key] = .number(number)
			case let .uuid(uuid): fields[key] = .string(uuid.uuidString.lowercased())
			}
		}
		return fields
	}

	/// A date as `task export` writes it.
	private static func iso(_ date: Date) -> String {
		date.formatted(.iso8601.dateSeparator(.omitted).timeSeparator(.omitted))
	}
}
