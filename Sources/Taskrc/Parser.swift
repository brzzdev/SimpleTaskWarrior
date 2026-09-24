/// TW refuses a file nested deeper than this, counting the Taskrc as 1.
private let maximumDepth = 10

/// libshared's `trim` set.
private let whitespace: Set<Unicode.Scalar> = [" ", "\t", "\n", "\u{0C}", "\r"]

struct Entry {
	/// Nil for TW's defaults.
	var location: Taskrc.Location?
	var value: String
}

extension Unicode.Scalar {
	/// What `Path::expand` reads as part of `$NAME`.
	fileprivate var isVariableNameCharacter: Bool {
		("a" ... "z").contains(self) || ("A" ... "Z").contains(self) || ("0" ... "9").contains(self)
			|| self == "_"
	}
}

extension Substring.UnicodeScalarView {
	/// libshared's `trim`.
	fileprivate var trimmed: Self {
		guard
			let first = firstIndex(where: { !whitespace.contains($0) }),
			let last = lastIndex(where: { !whitespace.contains($0) })
		else {
			return self[endIndex...]
		}
		return self[first ... last]
	}
}

/// libshared's `Configuration::parse`, `Path::expand` and `json::decode`, at the commit TW 3.5
/// pins.
struct Parser {
	var entries: [String: Entry] = [:]
	let environment: Taskrc.Environment
	var problems: [Taskrc.Problem] = []
	let readFile: (_ path: String) throws(Taskrc.ReadError) -> Taskrc.File

	/// Parses one file's lines into `entries`, later keys winning. `file` is nil for TW's defaults.
	mutating func parse(_ contents: String, file: (path: String, realPath: String)?, depth: Int = 1) {
		// Split on scalars, since `\r\n` is one `Character`.
		let lines = contents.unicodeScalars.split(separator: "\n", omittingEmptySubsequences: false)
		for (index, rawLine) in lines.enumerated() {
			let line = rawLine.prefix { $0 != "#" }.trimmed
			guard !line.isEmpty else {
				continue
			}
			let location = file.map { Taskrc.Location(file: $0.path, line: index + 1) }

			if let equals = line.firstIndex(of: "=") {
				let key = String(line[..<equals].trimmed)
				let expansion = expand(line[line.index(after: equals)...].trimmed)
				if !expansion.unsetVariables.isEmpty {
					problems.append(
						Taskrc.Problem(.unsetVariables(expansion.unsetVariables, key: key), at: location),
					)
				}
				entries[key] = Entry(location: location, value: decodingJSONEscapes(expansion.value))
				continue
			}

			// Anything after the first `include` anywhere in the line is the path.
			guard let include = line.firstRange(of: "include".unicodeScalars) else {
				problems.append(Taskrc.Problem(.malformedLine(String(line)), at: location))
				continue
			}
			let expansion = expand(line[include.upperBound...].trimmed)
			let path = expansion.value
			// TW tries a relative path against the CWD first, which means nothing to a GUI app. The
			// defaults have no directory, which leaves only the share directory.
			let resolved = path.hasPrefix("/") ? path : file.map { directory(of: $0.realPath) + path }
			load(
				resolved,
				requested: path,
				unsetVariables: expansion.unsetVariables,
				from: location,
				depth: depth + 1,
			)
		}
	}

	/// Reads the file at `path` and parses it. `requested` is the path as the include line wrote it,
	/// after expansion, and `path` is nil where it can't resolve to a file the app can read.
	mutating func load(
		_ path: String?,
		requested: String,
		unsetVariables: [String],
		from location: Taskrc.Location?,
		depth: Int,
	) {
		guard depth <= maximumDepth else {
			problems.append(
				Taskrc.Problem(.includeNestedTooDeeply(path: path ?? requested), at: location),
			)
			return
		}
		let result = path.map { path in
			Result { () throws(Taskrc.ReadError) in try readFile(path) }
		}
		switch result ?? .failure(.notFound) {
		case .failure(.notFound) where !requested.hasPrefix("/") && isBundled(requested):
			// It could only resolve through TW's share directory, whose themes and holiday files set
			// nothing that changes tasks.
			return

		case .failure(.notFound):
			problems.append(
				Taskrc.Problem(
					.notFound(path: path ?? requested, unsetVariables: unsetVariables),
					at: location,
				),
			)

		case .failure(.unreadable):
			problems.append(
				Taskrc.Problem(
					.unreadable(path: path ?? requested, unsetVariables: unsetVariables),
					at: location,
				),
			)

		case let .success(file):
			parse(file.contents, file: (path ?? requested, file.realPath), depth: depth)
		}
	}

	/// `Path::expand`: a leading `~` or `~user`, then every `$NAME`, an unset one becoming empty.
	private func expand(
		_ input: Substring.UnicodeScalarView,
	) -> (value: String, unsetVariables: [String]) {
		var output = String.UnicodeScalarView()
		var unsetVariables: [String] = []
		var index = input.startIndex

		if input.first == "~" {
			let slash = input.dropFirst().firstIndex(of: "/") ?? input.endIndex
			let user = String(input[input.index(after: index) ..< slash])
			let home =
				if user.isEmpty {
					environment.variables["HOME"] ?? ""
				} else {
					environment.homeDirectory(user) ?? "/home/\(user)"
				}
			output.append(contentsOf: home.unicodeScalars)
			index = slash
		}

		while index < input.endIndex {
			guard input[index] == "$" else {
				output.append(input[index])
				index = input.index(after: index)
				continue
			}
			let nameStart = input.index(after: index)
			let nameEnd = input[nameStart...].firstIndex { !$0.isVariableNameCharacter } ?? input.endIndex
			index = nameEnd
			guard nameStart < nameEnd else {
				output.append("$")
				continue
			}
			let name = String(input[nameStart ..< nameEnd])
			guard let value = environment.variables[name] else {
				unsetVariables.append(name)
				continue
			}
			output.append(contentsOf: value.unicodeScalars)
		}

		return (String(output), unsetVariables)
	}

	/// `json::decode`, which libshared runs on every value.
	private func decodingJSONEscapes(_ input: String) -> String {
		var output = String.UnicodeScalarView()
		var scalars = input.unicodeScalars[...]
		while let scalar = scalars.popFirst() {
			guard scalar == "\\" else {
				output.append(scalar)
				continue
			}
			guard let escaped = scalars.popFirst() else {
				output.append("\\")
				break
			}
			switch escaped {
			case "/", "\"", "\\": output.append(escaped)

			case "b": output.append("\u{08}")

			case "f": output.append("\u{0C}")

			case "n": output.append("\n")

			case "r": output.append("\r")

			case "t": output.append("\t")

			case "u":
				// libshared reads 4 digits, counting a non-hex one as 0, and writes nothing for U+0000
				// or when fewer than 4 are left. A lone surrogate becomes U+FFFD where it would write
				// invalid UTF-8.
				let digits = scalars.prefix(4)
				scalars = scalars.dropFirst(4)
				guard digits.count == 4 else {
					break
				}
				let codepoint = digits.reduce(0) { $0 << 4 | (UInt32(String($1), radix: 16) ?? 0) }
				if codepoint != 0 {
					output.append(Unicode.Scalar(codepoint) ?? "\u{FFFD}")
				}

			default:
				output.append("\\")
				output.append(escaped)
			}
		}
		return String(output)
	}

	/// The directory `Configuration::parse` resolves includes against, with its trailing `/`.
	private func directory(of path: String) -> String {
		guard let slash = path.lastIndex(of: "/") else {
			return ""
		}
		return String(path[...slash])
	}

	/// A theme or holiday file, the kinds TW ships in its share directory.
	private func isBundled(_ path: String) -> Bool {
		let name = path.split(separator: "/").last ?? ""
		return name.hasSuffix(".theme") || (name.hasPrefix("holidays.") && name.hasSuffix(".rc"))
	}
}
