import Foundation
import Taskrc
import Testing

struct TaskrcTests {
	/// The environment `just fixtures` records with.
	let environment = Taskrc.Environment(
		homeDirectory: { $0 == "root" ? "/var/root" : nil },
		variables: ["FIXTURE": "value", "HOME": "/home/fixture", "USER": "fixture"],
	)

	@Test
	func contextOnlyKeyIsReadByNameButNotEnumerated() {
		let taskrc = parse([
			"/rc/taskrc": """
				context=work
				context.work.rc.default.project=Work
				""",
		])

		#expect(taskrc["default.project"] == "Work")
		#expect(taskrc.values["default.project"] == nil)
	}

	@Test
	func contextWriteKeepsProjectAndTagsAndSkipsTheRest() {
		let taskrc = parse([
			"/rc/taskrc": """
				context=work
				context.work.write=project:Work +urgent pro:Other -old due:tomorrow project:'A B' +next
				""",
		])

		#expect(
			taskrc.contextWrite == Taskrc.ContextWrite(
				project: "Work",
				skipped: ["pro:Other", "-old", "due:tomorrow", "project:'A", "B'"],
				tags: ["urgent", "next"],
			),
		)
	}

	@Test
	func includeReportsWhereItLookedAndWhyItFailed() {
		let taskrc = parse(
			[
				"/rc/taskrc": """
					include $UNSET/missing.rc
					include /etc/private.rc
					include ~/.config/task/holidays.en-GB.rc
					""",
			],
			unreadable: ["/etc/private.rc"],
		)

		#expect(
			taskrc.problems == [
				Taskrc.Problem(
					.notFound(path: "/missing.rc", unsetVariables: ["UNSET"]),
					at: Taskrc.Location(file: "/rc/taskrc", line: 1),
				),
				Taskrc.Problem(
					.unreadable(path: "/etc/private.rc", unsetVariables: []),
					at: Taskrc.Location(file: "/rc/taskrc", line: 2),
				),
				Taskrc.Problem(
					.notFound(path: "/home/fixture/.config/task/holidays.en-GB.rc", unsetVariables: []),
					at: Taskrc.Location(file: "/rc/taskrc", line: 3),
				),
			],
		)
	}

	@Test
	func includeResolvesAgainstTheIncludingFilesRealPath() {
		let taskrc = parse(
			[
				"/dotfiles/extra.rc": "extra=yes",
				"/rc/taskrc": "include extra.rc",
			],
			realPaths: ["/rc/taskrc": "/dotfiles/taskrc"],
		)

		#expect(taskrc.problems.isEmpty)
		#expect(taskrc.values["extra"] == "yes")
	}

	@Test
	func includeSkipsOnlyAFileTaskwarriorBundles() {
		let taskrc = parse([
			"/rc/mine.theme": "color.mine=red",
			"/rc/taskrc": """
				include dark-256.theme
				include holidays.en-GB.rc
				include mine.theme
				include dakr-256.theme
				""",
		])

		#expect(taskrc.values["color.mine"] == "red")
		#expect(
			taskrc.problems == [
				Taskrc.Problem(
					.notFound(path: "/rc/dakr-256.theme", unsetVariables: []),
					at: Taskrc.Location(file: "/rc/taskrc", line: 4),
				),
			],
		)
	}

	@Test
	func includeStopsPastTenLevels() {
		let taskrc = parse([
			"/rc/loop.rc": "include loop.rc",
			"/rc/taskrc": "include loop.rc",
		])

		#expect(
			taskrc.problems == [
				Taskrc.Problem(
					.includeNestedTooDeeply(path: "/rc/loop.rc"),
					at: Taskrc.Location(file: "/rc/loop.rc", line: 1),
				),
			],
		)
	}

	@Test
	func malformedLineIsReportedAndTheRestKept() {
		let taskrc = parse([
			"/rc/taskrc": """
				before=1
				not a setting
				after=2
				""",
		])

		#expect(
			taskrc.problems == [
				Taskrc.Problem(
					.malformedLine("not a setting"),
					at: Taskrc.Location(file: "/rc/taskrc", line: 2),
				),
			],
		)
		#expect(taskrc.values["before"] == "1")
		#expect(taskrc.values["after"] == "2")
	}

	@Test
	func missingTaskrcLeavesTheDefaults() {
		let taskrc = parse([:])

		#expect(
			taskrc.problems == [
				Taskrc.Problem(.notFound(path: "/rc/taskrc", unsetVariables: []), at: nil),
			],
		)
		#expect(taskrc.values["urgency.due.coefficient"] == "12.0")
	}

	@Test
	func unsetVariablesAreReportedWithTheirKey() {
		let taskrc = parse(["/rc/taskrc": "data.location=$XDG_DATA_HOME/task$SUFFIX"])

		#expect(
			taskrc.problems == [
				Taskrc.Problem(
					.unsetVariables(["XDG_DATA_HOME", "SUFFIX"], key: "data.location"),
					at: Taskrc.Location(file: "/rc/taskrc", line: 1),
				),
			],
		)
		#expect(taskrc.values["data.location"] == "/task")
	}

	@Test
	func validationReadsThroughTheContext() {
		let taskrc = parse([
			"/rc/taskrc": """
				context=work
				uda.size.type=numeric
				uda.estimate.type=time
				weekstart=monday
				context.work.rc.uda.size.type=number
				context.work.rc.weekstart=tuesday
				""",
		])

		#expect(
			taskrc.problems == [
				Taskrc.Problem(
					.invalidWeekstart("tuesday"),
					at: Taskrc.Location(file: "/rc/taskrc", line: 6),
				),
				Taskrc.Problem(
					.invalidUDAType(uda: "estimate", type: "time"),
					at: Taskrc.Location(file: "/rc/taskrc", line: 3),
				),
				Taskrc.Problem(
					.invalidUDAType(uda: "size", type: "number"),
					at: Taskrc.Location(file: "/rc/taskrc", line: 5),
				),
			],
		)
	}

	@Test(arguments: ["context", "defaults", "expansion", "includes", "syntax"])
	func valuesMatchTaskShow(fixture: String) throws {
		let directory = try #require(Bundle.module.url(forResource: "Fixtures", withExtension: nil))
			.appending(path: fixture)
		let expected = try String(contentsOf: directory.appending(path: "expected.rc"), encoding: .utf8)
			.split(separator: "\n")
			.map { $0.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false) }
			.reduce(into: [String: String]()) { $0[String($1[0])] = String($1[1]) }

		let taskrc = Taskrc(
			path: directory.appending(path: "taskrc").path(percentEncoded: false),
			environment: environment,
		) { path throws(Taskrc.ReadError) in
			let url = URL(filePath: path)
			guard let contents = try? String(contentsOf: url, encoding: .utf8) else {
				throw .notFound
			}
			return Taskrc.File(
				contents: contents,
				realPath: url.resolvingSymlinksInPath().path(percentEncoded: false),
			)
		}

		// Set by the bundled theme and holiday files the app skips, or overridden by the CLI at runtime.
		let isComparable = { (key: String) in
			!key.contains(/^(color|data\.location$|detection$|holiday\.|rule\.)/)
		}
		#expect(
			taskrc.values.filter { isComparable($0.key) } == expected.filter { isComparable($0.key) },
		)
	}

	/// Parses `/rc/taskrc` from `files`, keyed by path.
	private func parse(
		_ files: [String: String],
		realPaths: [String: String] = [:],
		unreadable: Set<String> = [],
	) -> Taskrc {
		Taskrc(path: "/rc/taskrc", environment: environment) { path throws(Taskrc.ReadError) in
			guard !unreadable.contains(path) else {
				throw .unreadable
			}
			guard let contents = files[path] else {
				throw .notFound
			}
			return Taskrc.File(contents: contents, realPath: realPaths[path] ?? path)
		}
	}
}
