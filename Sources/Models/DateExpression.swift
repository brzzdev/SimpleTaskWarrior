// The part of TW's `Lexer`, `Eval` and `Variant` that `task` 3.5 runs a date or duration value
// through: arithmetic on dates, durations, numbers and text, with the task's attributes as operands.
import Foundation

/// Why an expression has no value.
enum ExpressionError: Error {
	/// TW's `Eval` would throw here, so the CLI reads the whole input as a plain date instead.
	case evaluationFailed
	/// The input can't become a date or duration however it's read.
	case input(DateInputError)
}

/// A value as TW's `Variant` holds it, less booleans, which never become a date or duration.
enum Variant {
	case date(Int)
	case duration(Int)
	case integer(Int)
	case real(Double)
	case string([UInt8])
}

/// Evaluates one date or duration input the way `ColumnTypeDate::modify` and
/// `ColumnTypeDuration::modify` do.
struct DateExpression {
	let clock: WallClock
	let format: String
	let settings: Datetime.Settings

	/// Reads `text` as a date: an expression, or, where TW's evaluation fails, a plain date.
	func date(
		_ text: String,
		references: (String) -> DateInput.Reference?,
	) throws(DateInputError) -> Int {
		// Nil where the evaluation fails.
		let value: Variant?
		do {
			value = try evaluate(Array(text.utf8), references: references)
		} catch {
			switch error {
			case .evaluationFailed: value = nil
			case let .input(error): throw error
			}
		}
		let date =
			switch value {
			case let .date(date): date
			case let .duration(duration): clock.now &+ duration
			case let .integer(integer): integer
			case let .real(real): int32(real)
			case let .string(string): try castToDate(string)
			case nil: try castToDate(Array(text.utf8))
			}
		guard date != 0 else {
			throw .invalid
		}
		guard epochRange.contains(date) else {
			throw .outOfRange
		}
		return date
	}

	/// Reads `text` as a duration expression, in seconds. Unlike a date, there's no plain reading
	/// to fall back on.
	func duration(
		_ text: String,
		references: (String) -> DateInput.Reference?,
	) throws(DateInputError) -> Int {
		do throws(ExpressionError) {
			guard
				case let .duration(seconds) = try evaluate(Array(text.utf8), references: references)
			else {
				throw ExpressionError.input(.invalid)
			}
			return seconds
		} catch {
			switch error {
			case .evaluationFailed: throw .invalid
			case let .input(error): throw error
			}
		}
	}

	/// `Variant::cast` from a string to a date: the whole string as a date, else as a duration from
	/// now, else as much of its start as reads as a date in the Taskrc's format.
	private func castToDate(_ text: [UInt8]) throws(DateInputError) -> Int {
		let text = dequoted(text)
		var datetime = Datetime(clock: clock, settings: settings)
		if try datetime.parse(text, format: format) == text.count {
			return datetime.date
		}
		if let duration = DurationLiteral.parse(text), duration.end == text.count {
			return clock.now &+ duration.seconds
		}
		guard !format.isEmpty else {
			return 0
		}
		datetime = Datetime(clock: clock, settings: settings)
		guard try datetime.parse(text, format: format) != nil else {
			throw .invalid
		}
		return datetime.date
	}

	/// `Eval::evaluateInfixExpression`.
	private func evaluate(
		_ text: [UInt8],
		references: (String) -> DateInput.Reference?,
	) throws(ExpressionError) -> Variant {
		var tokens = try tokenize(text)
		markUnaryOperators(&tokens)
		return try evaluatePostfix(toPostfix(tokens), references: references)
	}

	/// `Lexer::token`, repeated.
	private func tokenize(_ text: [UInt8]) throws(ExpressionError) -> [Token] {
		var lexer = Lexer(text: text)
		var tokens: [Token] = []
		while true {
			while isWhitespace(lexer.byte(at: lexer.cursor)) {
				lexer.cursor += 1
			}
			guard lexer.cursor < text.count else {
				return tokens
			}
			try tokens.append(lexer.next(clock: clock, format: format, settings: settings))
		}
	}

	/// `Eval::infixParse`, which parses only to turn a prefix `-` or `+` into `_neg_` or `_pos_`,
	/// ignoring whether the whole input parses.
	private func markUnaryOperators(_ tokens: inout [Token]) {
		var parser = InfixParser(tokens: tokens)
		_ = parser.parseLogical()
		tokens = parser.tokens
	}

	/// `Eval::infixToPostfix`: Dijkstra's shunting yard.
	private func toPostfix(_ tokens: [Token]) throws(ExpressionError) -> [Token] {
		guard tokens.count > 1 else {
			return tokens
		}
		var postfix: [Token] = []
		var operators: [Token] = []
		for token in tokens {
			guard case let .operator(name) = token else {
				postfix.append(token)
				continue
			}
			if name == "(" {
				operators.append(token)
			} else if name == ")" {
				while let top = operators.last, top != .operator("(") {
					postfix.append(operators.removeLast())
				}
				guard operators.popLast() != nil else {
					throw .evaluationFailed
				}
			} else if let (precedence, isLeftAssociative) = operatorTraits[name] {
				while
					case let .operator(top)? = operators.last, let (topPrecedence, _) = operatorTraits[top],
					isLeftAssociative ? precedence <= topPrecedence : precedence < topPrecedence
				{
					postfix.append(operators.removeLast())
				}
				operators.append(token)
			} else {
				// An operator TW has no precedence for, such as `&&`, goes out as it came.
				postfix.append(token)
			}
		}
		while let top = operators.popLast() {
			guard top != .operator("("), top != .operator(")") else {
				throw .evaluationFailed
			}
			postfix.append(top)
		}
		return postfix
	}

	/// `Eval::evaluatePostfixStack`.
	private func evaluatePostfix(
		_ tokens: [Token],
		references: (String) -> DateInput.Reference?,
	) throws(ExpressionError) -> Variant {
		guard !tokens.isEmpty else {
			throw .evaluationFailed
		}
		var values: [Variant] = []
		for token in tokens {
			switch token {
			case .operator("_pos_"):
				continue

			case .operator("_neg_"):
				guard let right = values.popLast() else {
					throw .evaluationFailed
				}
				try values.append(subtract(.integer(0), right))

			case .operator("!"):
				guard !values.isEmpty else {
					throw .evaluationFailed
				}
				throw .input(.invalid)

			case let .operator(name):
				guard let right = values.popLast(), let left = values.popLast() else {
					throw .evaluationFailed
				}
				// Comparisons and logic make a boolean, which is no date or duration.
				if booleanOperators.contains(name) {
					throw .input(.invalid)
				}
				switch name {
				case "*": try values.append(multiply(left, right))

				case "+": try values.append(add(left, right))

				case "-": try values.append(subtract(left, right))

				case "/": try values.append(divide(left, right))

				// `%` and `^` only take numbers, and `~` and the tag operators need a task.
				default: throw .evaluationFailed
				}

			case let .date(text):
				do throws(DateInputError) {
					try values.append(.date(castToDate(text)))
				} catch let .holiday(name) {
					throw .input(.holiday(name))
				} catch {
					throw .evaluationFailed
				}

			case let .duration(text):
				let duration = DurationLiteral.parse(text).flatMap { $0.end == text.count ? $0.seconds : nil }
				values.append(.duration(duration ?? 0))

			case let .identifier(name):
				try values.append(value(of: name, references: references))

			case let .number(text):
				let string = String(decoding: text, as: UTF8.self)
				if text.allSatisfy({ isLatinDigit(Int($0)) }) {
					values.append(.integer(Int(string) ?? .max))
				} else {
					values.append(.real(strtod(string, nil)))
				}

			case let .text(text):
				values.append(.string(text))
			}
		}
		guard values.count == 1, let value = values.first else {
			throw .evaluationFailed
		}
		return value
	}

	/// A name's value from TW's named constants, then from the task: its own text when it's neither.
	private func value(
		of name: String,
		references: (String) -> DateInput.Reference?,
	) throws(ExpressionError) -> Variant {
		switch name {
		case "pi":
			return .real(3.14159165)

		// Booleans, which the app refuses to do arithmetic with.
		case "false", "true":
			throw .input(.invalid)

		default:
			break
		}
		return switch references(name) {
		case let .date(date): .date(Int(date.timeIntervalSince1970.rounded(.down)))
		case let .duration(duration): .duration(duration.seconds)
		case let .text(text): .string(Array(text.utf8))
		case nil: .string(Array(name.utf8))
		}
	}

	/// `(std::string)` of a value, as `Variant` converts one to add to text.
	private func text(_ value: Variant) -> [UInt8] {
		let text =
			switch value {
			case let .date(date): clock.brokenDown(date).isoLocalExtended
			case let .duration(duration): TaskDuration(seconds: duration).iso
			case let .integer(integer): String(integer)
			case let .real(real): String(format: "%g", real)
			case let .string(string): String(decoding: string, as: UTF8.self)
			}
		return Array(text.utf8)
	}

	/// `Variant::operator+=`, which joins text.
	private func add(_ left: Variant, _ right: Variant) throws(ExpressionError) -> Variant {
		switch (left, right) {
		case let (_, .string(string)):
			.string(text(left) + dequoted(string))

		case let (.string(string), _):
			.string(string + text(right))

		case let (.date(left), .duration(right)),
		     let (.date(left), .integer(right)),
		     let (.duration(right), .date(left)),
		     let (.integer(left), .date(right)):
			.date(left &+ right)

		case let (.date(left), .real(right)):
			.date(left &+ int32(right))

		case let (.duration(left), .duration(right)),
		     let (.duration(left), .integer(right)),
		     let (.integer(left), .duration(right)):
			.duration(left &+ right)

		case let (.duration(left), .real(right)):
			.duration(left &+ int32(right))

		case let (.integer(left), .integer(right)):
			.integer(left &+ right)

		case let (.integer(left), .real(right)):
			.real(Double(left) + right)

		case let (.real(left), .date(right)):
			.date(unsignedInt32(left) &+ right)

		case let (.real(left), .duration(right)):
			.duration(unsignedInt32(left) &+ right)

		case let (.real(left), .integer(right)):
			.real(left + Double(right))

		case let (.real(left), .real(right)):
			.real(left + right)

		case (.date, .date):
			throw .evaluationFailed
		}
	}
}

/// `Variant::operator-=`, which joins two texts with a `-`.
private func subtract(_ left: Variant, _ right: Variant) throws(ExpressionError) -> Variant {
	switch (left, right) {
	case let (.string(left), .string(right)):
		.string(left + [UInt8(ascii: "-")] + right)

	case (_, .string), (.duration, .date), (.string, _):
		throw .evaluationFailed

	case let (.date(left), .duration(right)),
	     let (.date(left), .integer(right)),
	     let (.integer(left), .date(right)):
		.date(left &- right)

	case let (.date(left), .real(right)):
		.date(left &- int32(right))

	case let (.date(left), .date(right)),
	     let (.duration(left), .duration(right)),
	     let (.duration(left), .integer(right)),
	     let (.integer(left), .duration(right)):
		.duration(left &- right)

	case let (.duration(left), .real(right)):
		.duration(left &- int32(right))

	case let (.integer(left), .integer(right)):
		.integer(left &- right)

	case let (.integer(left), .real(right)):
		.real(Double(left) - right)

	case let (.real(left), .date(right)),
	     let (.real(left), .duration(right)),
	     let (.real(left), .integer(right)):
		.real(left - Double(right))

	case let (.real(left), .real(right)):
		.real(left - right)
	}
}

/// `Variant::operator*=`, which repeats text.
private func multiply(_ left: Variant, _ right: Variant) throws(ExpressionError) -> Variant {
	switch (left, right) {
	case let (.integer(count), .string(string)):
		try .string(repeated(dequoted(string), count: count))

	case let (.string(string), .integer(count)) where count > 0:
		try .string(repeated(string, count: count))

	case let (.duration(left), .integer(right)), let (.integer(left), .duration(right)):
		.duration(left &* right)

	case let (.duration(left), .real(right)), let (.real(right), .duration(left)):
		.duration(unsignedInt32(Double(left) * right))

	case let (.integer(left), .integer(right)):
		.integer(left &* right)

	case let (.integer(left), .real(right)):
		.real(Double(left) * right)

	case let (.real(left), .integer(right)):
		.real(left * Double(right))

	case let (.real(left), .real(right)):
		.real(left * right)

	case (_, .date), (_, .string), (.date, _), (.duration, .duration), (.string, _):
		throw .evaluationFailed
	}
}

/// `Variant::operator/=`.
private func divide(_ left: Variant, _ right: Variant) throws(ExpressionError) -> Variant {
	switch (left, right) {
	// The one division TW doesn't check for zero.
	case let (.duration(left), .duration(right)):
		.real(Double(left) / Double(right))

	case (_, .date), (_, .duration(0)), (_, .integer(0)), (_, .real(0)), (_, .string), (.date, _),
	     (.string, _):
		throw .evaluationFailed

	case let (.duration(left), .integer(right)):
		.duration(left.dividedReportingOverflow(by: right).partialValue)

	case let (.duration(left), .real(right)):
		.duration(unsignedInt32(Double(left) / right))

	case let (.integer(left), .duration(right)):
		.duration(unsignedInt32(left.dividedReportingOverflow(by: right).partialValue))

	case let (.integer(left), .integer(right)):
		.integer(left.dividedReportingOverflow(by: right).partialValue)

	case let (.integer(left), .real(right)):
		.real(Double(left) / right)

	case let (.real(left), .duration(right)):
		.duration(unsignedInt32(left / Double(right)))

	case let (.real(left), .integer(right)):
		.real(left / Double(right))

	case let (.real(left), .real(right)):
		.real(left / right)
	}
}

/// The longest text `repeated` builds, a memory bound TW doesn't have.
private let maximumRepeatedLength = 4_096

/// `string` `count` times. Where TW would loop without end on a negative count, or build text past
/// `maximumRepeatedLength`, this fails the evaluation instead.
private func repeated(_ string: [UInt8], count: Int) throws(ExpressionError) -> [UInt8] {
	let length = count.multipliedReportingOverflow(by: string.count)
	guard count >= 0, !length.overflow, length.partialValue <= maximumRepeatedLength else {
		throw .evaluationFailed
	}
	return Array(repeatElement(string, count: count).joined())
}

/// C++'s `(int)` of a double.
private func int32(_ value: Double) -> Int {
	Int(saturating(value) as Int32)
}

/// C++'s `(time_t)(unsigned)(int)` of a double: a negative result wraps to a large positive one.
private func unsignedInt32(_ value: Double) -> Int {
	Int(UInt32(bitPattern: saturating(value)))
}

/// `(time_t)(unsigned)(int)` of an integer, keeping its low 32 bits.
private func unsignedInt32(_ value: Int) -> Int {
	Int(UInt32(truncatingIfNeeded: value))
}

extension BrokenDownTime {
	/// `Datetime::toISOLocalExtended`: `YYYY-MM-DDThh:mm:ss`.
	fileprivate var isoLocalExtended: String {
		String(
			format: "%04d-%02d-%02dT%02d:%02d:%02d",
			year,
			month + 1,
			day,
			hour,
			minute,
			second,
		)
	}
}

/// `Lexer::dequote`: drops a matching pair of quotes around the whole text.
private func dequoted(_ text: [UInt8]) -> [UInt8] {
	guard
		let first = text.first, let last = text.last, first == last,
		first == UInt8(ascii: "'") || first == UInt8(ascii: "\"")
	else {
		return text
	}
	return text.count < 2 ? [] : Array(text.dropFirst().dropLast())
}

/// Binary operators that yield a boolean.
private let booleanOperators: Set = [
	"!=", "!==", "&&", "<", "<=", "=", "==", ">", ">=", "and", "or", "xor", "||",
]

/// `Eval`'s operator table: precedence, and whether it's left-associative.
private let operatorTraits: [String: (precedence: Int, isLeftAssociative: Bool)] = [
	"!": (15, false), "!=": (9, true), "!==": (9, true), "!~": (8, true), "%": (13, true),
	"*": (13, true), "+": (12, true), "-": (12, true), "/": (13, true), "<": (10, true),
	"<=": (10, true), "=": (9, true), "==": (9, true), ">": (10, true), ">=": (10, true),
	"^": (16, false), "_hastag_": (14, true), "_neg_": (15, false), "_notag_": (14, true),
	"_pos_": (15, false), "and": (5, true), "or": (4, true), "xor": (3, true), "~": (8, true),
]

private enum Token: Equatable {
	case date([UInt8])
	case duration([UInt8])
	/// A name TW looks up as a constant or an attribute.
	case identifier(String)
	case number([UInt8])
	case `operator`(String)
	/// Anything TW reads as a string: quoted text, words, tags, paths, UUIDs and the like.
	case text([UInt8])
}

/// `Eval::infixParse`'s recursive descent, kept for the one thing it changes: which `-` and `+`
/// are prefixes.
private struct InfixParser {
	private static let logical: Set = ["and", "or", "xor"]
	private static let regex: Set = ["!~", "~"]
	private static let equality: Set = ["!=", "!==", "=", "=="]
	private static let comparative: Set = ["<", "<=", ">", ">="]
	private static let arithmetic: Set = ["+", "-"]
	private static let geometric: Set = ["%", "*", "/"]
	private static let tag: Set = ["_hastag_", "_notag_"]
	private static let exponent: Set = ["^"]

	var tokens: [Token]

	private var index = 0

	init(tokens: [Token]) {
		self.tokens = tokens
	}

	mutating func parseLogical() -> Bool {
		parseBinary(Self.logical) { $0.parseRegex() }
	}

	private mutating func parseRegex() -> Bool {
		parseBinary(Self.regex) { $0.parseEquality() }
	}

	private mutating func parseEquality() -> Bool {
		parseBinary(Self.equality) { $0.parseComparative() }
	}

	private mutating func parseComparative() -> Bool {
		parseBinary(Self.comparative) { $0.parseArithmetic() }
	}

	private mutating func parseArithmetic() -> Bool {
		parseBinary(Self.arithmetic) { $0.parseGeometric() }
	}

	private mutating func parseGeometric() -> Bool {
		parseBinary(Self.geometric) { $0.parseTag() }
	}

	private mutating func parseTag() -> Bool {
		parseBinary(Self.tag) { $0.parseUnary() }
	}

	private mutating func parseUnary() -> Bool {
		if index < tokens.count {
			switch tokens[index] {
			case .operator("-"):
				tokens[index] = .operator("_neg_")
				index += 1

			case .operator("+"):
				tokens[index] = .operator("_pos_")
				index += 1

			case .operator("!"):
				index += 1

			default:
				break
			}
		}
		return parseBinary(Self.exponent) { $0.parsePrimitive() }
	}

	private mutating func parsePrimitive() -> Bool {
		guard index < tokens.count else {
			return false
		}
		if tokens[index] == .operator("(") {
			index += 1
			if
				index < tokens.count, parseLogical(), index < tokens.count,
				tokens[index] == .operator(")")
			{
				index += 1
				return true
			}
			return false
		}
		if case .operator = tokens[index] {
			return false
		}
		index += 1
		return true
	}

	/// `operand {operator operand}` for any of `operators`.
	private mutating func parseBinary(
		_ operators: Set<String>,
		operand: (inout Self) -> Bool,
	) -> Bool {
		guard index < tokens.count, operand(&self) else {
			return false
		}
		while index < tokens.count, case let .operator(name) = tokens[index], operators.contains(name) {
			index += 1
			guard operand(&self) else {
				return false
			}
		}
		return true
	}
}

/// The tokenizing half of TW's `Lexer`.
private struct Lexer {
	let text: [UInt8]
	var cursor = 0

	private var remainder: ArraySlice<UInt8> {
		text[min(cursor, text.count)...]
	}

	func byte(at index: Int) -> Int {
		signedByte(in: text, at: index)
	}

	/// The token at the cursor, trying the kinds in `Lexer::token`'s order. A name TW would lex as
	/// a DOM reference is lexed as an identifier, which it looks up the same way.
	mutating func next(
		clock: WallClock,
		format: String,
		settings: Datetime.Settings,
	) throws(ExpressionError) -> Token {
		let start = cursor
		if let (word, end) = quotedWord(from: cursor, quotes: "'\"") {
			cursor = end
			return .text(word)
		}

		var datetime = Datetime(clock: clock, settings: settings)
		let dateEnd: Int?
		do throws(DateInputError) {
			dateEnd = try datetime.parse(text, from: cursor, format: format)
		} catch {
			throw .input(error)
		}
		if let end = dateEnd {
			cursor = end
			return .date(Array(text[start ..< end]))
		}

		var probe = self
		if probe.readOperator() == nil, let duration = DurationLiteral.parse(text, from: cursor) {
			cursor = duration.end
			return .duration(Array(text[start ..< cursor]))
		}

		if let end = urlEnd() ?? pairEnd() ?? uuidEnd() ?? setEnd() ?? hexEnd() {
			return textToken(until: end)
		}
		if let end = numberEnd() {
			cursor = end
			return .number(Array(text[start ..< end]))
		}
		if
			let end = separatorEnd() ?? tagEnd() ?? pathEnd() ?? substitutionEnd() ?? patternEnd()
		{
			return textToken(until: end)
		}
		if let name = readOperator() {
			return .operator(name)
		}
		if let end = identifierEnd(from: cursor) {
			cursor = end
			return .identifier(String(decoding: text[start ..< end], as: UTF8.self))
		}
		// `Lexer::isWord`: up to whitespace or an operator.
		var end = cursor + 1
		while end < text.count, !isWhitespace(byte(at: end)), !isSingleCharacterOperator(byte(at: end)) {
			end += 1
		}
		return textToken(until: end)
	}

	/// `Lexer::isOperator`, returning the operator and moving past it.
	mutating func readOperator() -> String? {
		if let literal = ["_hastag_", "_notag_", "_neg_", "_pos_"].first(where: { matches($0) }) {
			cursor += literal.utf8.count
			return literal
		}
		let (c1, c2, c3) = (byte(at: cursor + 1), byte(at: cursor + 2), byte(at: cursor + 3))
		let isTriple = (matches("and") && isBoundary(c2, c3)) || (matches("xor") && isBoundary(c2, c3))
			|| matches("!==")
		let isDouble = ["!=", "!~", "&&", "<=", "==", ">=", "||"].contains(where: { matches($0) })
			|| (matches("or") && isBoundary(c1, c2))
		let length = isTriple ? 3 : isDouble ? 2 : isSingleCharacterOperator(byte(at: cursor)) ? 1 : 0
		guard length > 0 else {
			return nil
		}
		defer { cursor += length }
		return String(decoding: text[cursor ..< cursor + length], as: UTF8.self)
	}

	/// The text from the cursor to `end`, as a token, moving past it.
	private mutating func textToken(until end: Int) -> Token {
		defer { cursor = end }
		return .text(Array(text[cursor ..< end]))
	}

	private func matches(_ literal: String) -> Bool {
		remainder.starts(with: literal.utf8)
	}

	/// `Lexer::isURL`: `http://` or `https://`, in any case, up to whitespace.
	private func urlEnd() -> Int? {
		guard text.count - cursor > 9 else {
			return nil
		}
		let lowercased = text[cursor ..< cursor + 8].map { $0 | 0x20 }
		let scheme = lowercased.starts(with: "https".utf8)
			? 5
			: lowercased.starts(with: "http".utf8) ? 4 : 0
		guard scheme > 0, text[(cursor + scheme)...].starts(with: "://".utf8) else {
			return nil
		}
		var end = cursor + scheme + 3
		while end < text.count, !isWhitespace(byte(at: end)) {
			end += 1
		}
		return end
	}

	/// `Lexer::isPair`: a name, then `:`, `=`, `::` or `:=`, then a quoted or plain word, or nothing.
	private func pairEnd() -> Int? {
		guard var end = identifierEnd(from: cursor) else {
			return nil
		}
		if text[end...].starts(with: "::".utf8) || text[end...].starts(with: ":=".utf8) {
			end += 2
		} else if byte(at: end) == ascii(":") || byte(at: end) == ascii("=") {
			end += 1
		} else {
			return nil
		}
		// An unclosed quote reads to the end, where TW's `readWord` leaves the cursor.
		if byte(at: end) == ascii("'") || byte(at: end) == ascii("\"") {
			return quotedWord(from: end, quotes: "'\"")?.end ?? text.count
		}
		return wordEnd(from: end) ?? end
	}

	/// `Lexer::isUUID`: 8 hex digits or more of the UUID pattern, then a boundary.
	private func uuidEnd() -> Int? {
		let pattern = Array("xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx".utf8)
		var length = 0
		while length < pattern.count, cursor + length < text.count {
			let character = byte(at: cursor + length)
			let matches = pattern[length] == UInt8(ascii: "x")
				? isHexDigit(character)
				: character == Int(pattern[length])
			guard matches else {
				break
			}
			length += 1
		}
		let following = byte(at: cursor + length)
		guard
			length >= 8,
			following == 0 || isWhitespace(following) || isSingleCharacterOperator(following)
		else {
			return nil
		}
		return cursor + length
	}

	/// `Lexer::isSet`: integers and ranges joined by commas, such as `1,3-5`, with more than one
	/// integer.
	private func setEnd() -> Int? {
		var index = cursor
		var count = 0
		repeat {
			guard let end = integerEnd(from: index) else {
				return nil
			}
			index = end
			count += 1
			if byte(at: index) == ascii("-") {
				guard let end = integerEnd(from: index + 1) else {
					return nil
				}
				index = end
				count += 1
			}
			guard byte(at: index) == ascii(",") else {
				break
			}
			index += 1
		} while
			true
		let current = byte(at: index)
		let following = byte(at: index + 1)
		let isHardBoundary = following == 0 || [current, following].contains {
			$0 == ascii("(") || $0 == ascii(")")
		}
		guard count > 1, index >= text.count || isWhitespace(current) || isHardBoundary else {
			return nil
		}
		return index
	}

	/// `Lexer::isInteger`: digits, with no leading zero unless it's 0 itself.
	private func integerEnd(from start: Int) -> Int? {
		var index = start
		skipDigits(&index)
		guard index > start, byte(at: start) != ascii("0") || index - start == 1 else {
			return nil
		}
		return index
	}

	/// `Lexer::isHexNumber`: `0x` and at least one hex digit.
	private func hexEnd() -> Int? {
		guard matches("0x") else {
			return nil
		}
		var end = cursor + 2
		while isHexDigit(byte(at: end)) {
			end += 1
		}
		return end > cursor + 2 ? end : nil
	}

	/// `Lexer::isNumber`: an integer, decimal or exponent that an operator, whitespace or the end
	/// follows.
	private func numberEnd() -> Int? {
		var index = cursor
		guard isLatinDigit(byte(at: index)) else {
			return nil
		}
		let hasLeadingZero = byte(at: index) == ascii("0")
		index += 1
		if hasLeadingZero, isLatinDigit(byte(at: index)) {
			return nil
		}
		skipDigits(&index)
		if byte(at: index) == ascii(".") {
			index += 1
			skipDigits(&index)
		}
		if byte(at: index) == ascii("e") || byte(at: index) == ascii("E") {
			index += 1
			if byte(at: index) == ascii("+") || byte(at: index) == ascii("-") {
				index += 1
			}
			if isLatinDigit(byte(at: index)) {
				skipDigits(&index)
				if byte(at: index) == ascii(".") {
					index += 1
					skipDigits(&index)
				}
			}
		}
		let following = byte(at: index)
		guard index >= text.count || isWhitespace(following) || isSingleCharacterOperator(following)
		else {
			return nil
		}
		return index
	}

	private func skipDigits(_ index: inout Int) {
		while isLatinDigit(byte(at: index)) {
			index += 1
		}
	}

	private func separatorEnd() -> Int? {
		text[cursor...].starts(with: "--".utf8) ? cursor + 2 : nil
	}

	/// `Lexer::isTag`: `+name` or `-name` at the start, or after whitespace or a parenthesis.
	private func tagEnd() -> Int? {
		if cursor > 0 {
			let previous = byte(at: cursor - 1)
			guard isWhitespace(previous) || previous == ascii("(") || previous == ascii(")") else {
				return nil
			}
		}
		guard
			byte(at: cursor) == ascii("+") || byte(at: cursor) == ascii("-"),
			isIdentifierStart(byte(at: cursor + 1))
		else {
			return nil
		}
		return wordEnd(from: cursor + 1)
	}

	/// `Lexer::isPath`: more than three `/`, each followed by a segment.
	private func pathEnd() -> Int? {
		let isSegment = { (index: Int) in
			index < text.count && !isWhitespace(byte(at: index)) && byte(at: index) != ascii("/")
		}
		var end = cursor
		var slashes = 0
		while byte(at: end) == ascii("/") {
			end += 1
			slashes += 1
			guard isSegment(end) else {
				break
			}
			while isSegment(end) {
				end += 1
			}
		}
		return slashes > 3 ? end : nil
	}

	/// `Lexer::isSubstitution`: `/from/to/`, with an optional `g`, then whitespace or the end.
	private func substitutionEnd() -> Int? {
		guard
			let from = quotedWord(from: cursor, quotes: "/"),
			var end = quotedWord(from: from.end - 1, quotes: "/")?.end
		else {
			return nil
		}
		if byte(at: end) == ascii("g") {
			end += 1
		}
		return end >= text.count || isWhitespace(byte(at: end)) ? end : nil
	}

	/// `Lexer::isPattern`: `/pattern/`, then whitespace or the end.
	private func patternEnd() -> Int? {
		guard let end = quotedWord(from: cursor, quotes: "/")?.end else {
			return nil
		}
		return end >= text.count || isWhitespace(byte(at: end)) ? end : nil
	}

	/// `Lexer::isIdentifier`.
	private func identifierEnd(from start: Int) -> Int? {
		guard isIdentifierStart(byte(at: start)) else {
			return nil
		}
		var end = start + 1
		while isIdentifierNext(byte(at: end)) {
			end += 1
		}
		return end
	}

	/// `Lexer::readWord` for a word in one of `quotes`: the word, quotes and all, with escapes
	/// resolved, and the index past its closing quote. Nil when it isn't closed.
	private func quotedWord(from start: Int, quotes: String) -> (word: [UInt8], end: Int)? {
		guard start < text.count, quotes.utf8.contains(text[start]) else {
			return nil
		}
		let quote = text[start]
		var word = [quote]
		var index = start + 1
		while index < text.count {
			if text[index] == quote {
				return (word + [quote], index + 1)
			}
			let (characters, end) = escapedCharacter(at: index)
			word += characters
			index = end
		}
		return nil
	}

	/// `Lexer::readWord` for an unquoted word: the index past it, stopping at whitespace or a
	/// parenthesis, or nil when it's empty.
	private func wordEnd(from start: Int) -> Int? {
		var index = start
		var previous = 0
		while index < text.count, !isWhitespace(byte(at: index)) {
			let character = byte(at: index)
			if
				previous != 0,
				[previous, character].contains(where: { $0 == ascii("(") || $0 == ascii(")") })
			{
				break
			}
			index = escapedCharacter(at: index).end
			previous = character
		}
		return index > start ? index : nil
	}

	/// The character `readWord` reads at `index`: a `U+XXXX` or `\uXXXX` code point, a backslash
	/// escape, or a plain character. Returns its bytes and where the next one starts.
	private func escapedCharacter(at index: Int) -> (bytes: [UInt8], end: Int) {
		let hexDigits = (index + 2 ..< index + 6).allSatisfy { isHexDigit(byte(at: $0)) }
		if
			text.count - index >= 6, hexDigits,
			text[index...].starts(with: "U+".utf8) || text[index...].starts(with: "\\u".utf8),
			let value = UInt32(String(decoding: text[index + 2 ..< index + 6], as: UTF8.self), radix: 16),
			let scalar = Unicode.Scalar(value)
		{
			return (Array(String(scalar).utf8), index + 6)
		}
		if text[index] == UInt8(ascii: "\\") {
			guard index + 1 < text.count else {
				return ([0], index + 2)
			}
			let escaped: UInt8 =
				switch text[index + 1] {
				case UInt8(ascii: "b"): 0x08
				case UInt8(ascii: "f"): 0x0C
				case UInt8(ascii: "n"): 0x0A
				case UInt8(ascii: "r"): 0x0D
				case UInt8(ascii: "t"): 0x09
				case UInt8(ascii: "v"): 0x0B
				default: text[index + 1]
				}
			return ([escaped], index + 2)
		}
		let end = Pig.character(in: text, at: index)?.end ?? index + 1
		return (Array(text[index ..< end]), end)
	}
}

private func isHexDigit(_ character: Int) -> Bool {
	isLatinDigit(character) || (ascii("a") ... ascii("f")).contains(character)
		|| (ascii("A") ... ascii("F")).contains(character)
}

private func isSingleCharacterOperator(_ character: Int) -> Bool {
	"+-*/()<>^!%=~".unicodeScalars.contains { ascii($0) == character }
}

/// `Lexer::isPunctuation`: printable ASCII other than space, `@`, `#`, `$`, `_`, letters and
/// digits.
private func isPunctuation(_ character: Int) -> Bool {
	(0x21 ... 0x7E).contains(character) && !"@#$_".unicodeScalars.contains { ascii($0) == character }
		&& !isLatinDigit(character) && !isLatinAlpha(character)
}

/// `Lexer::isBoundary`: the end, or a change between letter, digit and whitespace, or punctuation
/// either side.
private func isBoundary(_ left: Int, _ right: Int) -> Bool {
	right == 0 || isLatinAlpha(left) != isLatinAlpha(right)
		|| isLatinDigit(left) != isLatinDigit(right) || isWhitespace(left) != isWhitespace(right)
		|| isPunctuation(left) || isPunctuation(right)
}

private func isIdentifierStart(_ character: Int) -> Bool {
	character != 0 && !isWhitespace(character) && !isLatinDigit(character)
		&& !isSingleCharacterOperator(character) && !isPunctuation(character)
}

/// Stops at `:` and `=`, which make a name an attribute pair.
private func isIdentifierNext(_ character: Int) -> Bool {
	character != 0 && character != ascii(":") && character != ascii("=")
		&& !isWhitespace(character) && !isSingleCharacterOperator(character)
}
