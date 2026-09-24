// Parses a Taskrc the way Taskwarrior 3.5 does, over its compiled-in defaults.
import Darwin
import Foundation

/// A parsed Taskrc: TW's compiled-in defaults, overlaid by the Taskrc and the files it includes,
/// read through the active Context.
///
/// Where TW stops at the first error, this reports every problem and keeps the rest of the file.
public struct Taskrc: Equatable, Sendable {
	/// The active Context's write modifications, which new tasks take as defaults.
	public var contextWrite: ContextWrite
	public var problems: [Problem]
	/// Every key the defaults and the Taskrc set, each read through the active Context: what TW
	/// enumerates, as `task _show` prints it. Read a single key by name with the subscript.
	public var values: [String: String]

	/// Keys set only as `context.<active>.rc.<key>`, which TW reads by name but never enumerates.
	private var contextOnlyValues: [String: String]

	/// Parses the Taskrc at `path`, an absolute path, reading it and its includes with `readFile`.
	public init(
		path: String,
		environment: Environment,
		readFile: @escaping (_ path: String) throws(ReadError) -> File,
	) {
		var parser = Parser(environment: environment, readFile: readFile)
		parser.parse(taskwarriorDefaults, file: nil)
		do throws(ReadError) {
			try parser.load(path, from: nil, depth: 1)
		} catch {
			parser.problems.append(Problem(error.kind(path: path, unsetVariables: []), at: nil))
		}
		let configuration = Configuration(entries: parser.entries)
		contextOnlyValues = configuration.contextOnlyValues()
		contextWrite = ContextWrite(configuration)
		problems = parser.problems + configuration.problems()
		values = configuration.values()
	}

	/// The value TW reads for `key` by name, as `Configuration::get` does, which finds a key the
	/// active Context sets even when the Taskrc doesn't.
	public subscript(key: String) -> String? {
		contextOnlyValues[key] ?? values[key]
	}
}

extension Taskrc {
	/// The `project:x` and `+tag` modifications from the active Context's `write`.
	public struct ContextWrite: Equatable, Sendable {
		public var project: String?
		/// Modifications in any other form, which the app doesn't apply.
		public var skipped: [String]
		public var tags: [String]

		public init(project: String? = nil, skipped: [String] = [], tags: [String] = []) {
			self.project = project
			self.skipped = skipped
			self.tags = tags
		}
	}

	/// What `~` and `$NAME` in values and include paths expand to.
	public struct Environment: Sendable {
		/// The home directory for `~user`, or nil when there's no such user.
		public var homeDirectory: @Sendable (_ user: String) -> String?
		/// The variables for `$NAME`. `~` expands through `HOME`.
		public var variables: [String: String]

		public init(
			homeDirectory: @escaping @Sendable (_ user: String) -> String?,
			variables: [String: String],
		) {
			self.homeDirectory = homeDirectory
			self.variables = variables
		}
	}

	public struct File: Sendable {
		/// The file's text. The parser drops a leading BOM itself, as libshared does.
		public var contents: String
		/// The path with symlinks resolved, which relative includes resolve against, as TW's do.
		public var realPath: String

		public init(contents: String, realPath: String) {
			self.contents = contents
			self.realPath = realPath
		}
	}

	public struct Location: Equatable, Sendable {
		/// The path the file was read at.
		public var file: String
		/// 1-based.
		public var line: Int

		public init(file: String, line: Int) {
			self.file = file
			self.line = line
		}
	}

	public struct Problem: Equatable, Sendable {
		public enum Kind: Equatable, Sendable {
			/// An include past TW's 10 levels of nesting, which is how a cycle ends too.
			case includeNestedTooDeeply(path: String)
			case invalidUDAType(uda: String, type: String)
			case invalidWeekstart(String)
			case malformedLine(String)
			/// A file that doesn't exist at `path`: an include, or the Taskrc itself. A relative include
			/// reports the path next to the including file.
			case notFound(path: String, unsetVariables: [String])
			case unreadable(path: String, unsetVariables: [String])
			/// A value that used variables the environment doesn't set, which expanded to nothing.
			case unsetVariables([String], key: String)
		}

		public var kind: Kind
		/// The line that caused it, or nil when the Taskrc itself can't be read.
		public var location: Location?

		public init(_ kind: Kind, at location: Location?) {
			self.kind = kind
			self.location = location
		}
	}

	public enum ReadError: Error {
		case notFound
		case unreadable
	}
}

extension Taskrc.ContextWrite {
	fileprivate init(_ configuration: Configuration) {
		self.init()
		guard
			let context = configuration.entry("context")?.value,
			let write = configuration.entry("context.\(context).write")?.value
		else {
			return
		}
		for modification in write.split(whereSeparator: \.isWhitespace).map(String.init) {
			// Quotes mean the CLI would lex this differently from a split on whitespace.
			if modification.contains(where: { "\"'".contains($0) }) {
				skipped.append(modification)
			} else if let match = modification.wholeMatch(of: /project:(.+)/) {
				project = String(match.1)
			} else if let match = modification.wholeMatch(of: /\+(.+)/) {
				tags.append(String(match.1))
			} else {
				skipped.append(modification)
			}
		}
	}
}

/// The UDA types TW accepts, where an empty type means no UDA.
private let udaTypes: Set = ["", "date", "duration", "numeric", "string", "uuid"]

/// The days `weekstart` may name.
private let weekstartDays = ["monday", "sunday"]

/// The parsed keys, read as libshared's `Configuration` reads them.
private struct Configuration {
	var entries: [String: Entry]

	/// Keys set only under the active Context, by the name TW reads them with.
	func contextOnlyValues() -> [String: String] {
		guard let context = entries["context"]?.value else {
			return [:]
		}
		let prefix = "context.\(context).rc."
		return entries.reduce(into: [:]) { values, element in
			guard element.key.hasPrefix(prefix) else {
				return
			}
			let key = String(element.key.dropFirst(prefix.count))
			// `get` reads a `context.` key as it is, so an override of one never applies.
			guard entries[key] == nil, !key.hasPrefix("context.") else {
				return
			}
			values[key] = element.value.value
		}
	}

	/// `Configuration::get`: `context.<active>.rc.<key>` where that exists, else `key`.
	func entry(_ key: String) -> Entry? {
		guard
			!key.hasPrefix("context."),
			let context = entries["context"]?.value,
			let override = entries["context.\(context).rc.\(key)"]
		else {
			return entries[key]
		}
		return override
	}

	/// The values TW refuses once the Taskrc has parsed.
	func problems() -> [Taskrc.Problem] {
		var problems: [Taskrc.Problem] = []
		if let weekstart = entry("weekstart"), !isWeekstart(weekstart.value) {
			problems.append(
				Taskrc.Problem(.invalidWeekstart(weekstart.value), at: weekstart.location),
			)
		}
		// TW finds UDAs among the keys the Taskrc sets, then reads each type through the Context.
		let udas = Set(
			entries.keys.compactMap { $0.firstMatch(of: /^uda\.([^.]*)\./).map { String($0.1) } },
		)
		for uda in udas.sorted() {
			guard let type = entry("uda.\(uda).type"), !udaTypes.contains(type.value) else {
				continue
			}
			problems.append(
				Taskrc.Problem(.invalidUDAType(uda: uda, type: type.value), at: type.location),
			)
		}
		return problems
	}

	/// Every key the Taskrc sets, read through the Context.
	func values() -> [String: String] {
		entries.keys.reduce(into: [:]) { values, key in
			values[key] = entry(key)?.value
		}
	}

	/// `Datetime::dayOfWeek` finding Sunday or Monday: the whole name or 3+ letters of it, in any
	/// case.
	private func isWeekstart(_ value: String) -> Bool {
		let value = value.lowercased()
		return weekstartDays.contains { day in
			day == value || (value.count >= 3 && day.hasPrefix(value))
		}
	}
}

extension Taskrc.Environment {
	/// The app's environment, with `HOME` and `USER` set to the real user's rather than the sandbox
	/// container's, so `~` means what it does to the CLI.
	public static var live: Self {
		var variables = ProcessInfo.processInfo.environment
		if let account = getpwuid(getuid()) {
			variables["HOME"] = String(cString: account.pointee.pw_dir)
			variables["USER"] = String(cString: account.pointee.pw_name)
		}
		return Self(
			homeDirectory: { user in
				getpwnam(user).map { String(cString: $0.pointee.pw_dir) }
			},
			variables: variables,
		)
	}
}
