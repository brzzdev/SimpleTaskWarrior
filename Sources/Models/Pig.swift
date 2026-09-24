// libshared's `Pig`: the byte scanner TW's date and duration parsers are written against.
import Foundation

/// A cursor over UTF-8 bytes. `peek` reads a byte as C++'s signed `char` does, so a non-ASCII
/// byte never passes for ASCII whitespace; only the scanning loops decode whole characters.
struct Pig {
	let bytes: [UInt8]
	var cursor: Int

	/// What `save` stored for `restore`.
	private var saved = 0

	var isAtEnd: Bool {
		byte(at: cursor) == 0
	}

	/// The remaining text.
	var remainder: ArraySlice<UInt8> {
		bytes[min(cursor, bytes.count)...]
	}

	init(_ bytes: [UInt8], cursor: Int = 0) {
		self.bytes = bytes
		self.cursor = cursor
	}

	/// The character starting at `index`, decoded as `utf8_next_char` does, or nil at the end.
	static func character(
		in bytes: [UInt8],
		at index: Int,
	) -> (scalar: Unicode.Scalar, end: Int)? {
		guard index < bytes.count, bytes[index] != 0 else {
			return nil
		}
		let lead = bytes[index]
		let length =
			switch lead {
			case 0xF0...: 4
			case 0xE0...: 3
			case 0xC0...: 2
			default: 1
			}
		guard length > 1, index + length <= bytes.count else {
			return (Unicode.Scalar(lead), index + 1)
		}
		var value = UInt32(lead) & (0xFF >> (length + 1))
		for byte in bytes[index + 1 ..< index + length] {
			value = value << 6 | UInt32(byte & 0x3F)
		}
		return (Unicode.Scalar(value) ?? Unicode.Scalar(lead), index + length)
	}

	/// The byte at `index` as a signed `char`, or 0 past the end, where C++ reads the terminator.
	func byte(at index: Int) -> Int {
		index < bytes.count ? Int(Int8(bitPattern: bytes[index])) : 0
	}

	func peek() -> Int {
		byte(at: cursor)
	}

	mutating func save() {
		saved = cursor
	}

	mutating func restore() {
		cursor = saved
	}

	mutating func skip(_ character: Unicode.Scalar) -> Bool {
		guard peek() == Int(character.value) else {
			return false
		}
		cursor += 1
		return true
	}

	/// Skips `count` characters, or nothing when fewer remain.
	mutating func skip(characters count: Int) -> Bool {
		var index = cursor
		for _ in 0 ..< count {
			guard let next = Self.character(in: bytes, at: index) else {
				return false
			}
			index = next.end
		}
		cursor = index
		return true
	}

	mutating func skipWhitespace() -> Bool {
		let start = cursor
		while let next = Self.character(in: bytes, at: cursor), isUnicodeWhitespace(next.scalar) {
			cursor = next.end
		}
		return cursor > start
	}

	mutating func skipLiteral(_ literal: String) -> Bool {
		let literal = Array(literal.utf8)
		guard bytes[min(cursor, bytes.count)...].starts(with: literal) else {
			return false
		}
		cursor += literal.count
		return true
	}

	/// Skips the longest prefix of `reference` the text starts with, returning it, or nil when it
	/// starts with none of it. `ignoringCase` lowercases the text, not `reference`.
	mutating func skipPartial(_ reference: String, ignoringCase: Bool = false) -> String? {
		let reference = Array(reference.utf8)
		var length = 0
		while length < reference.count, cursor + length < bytes.count {
			var byte = bytes[cursor + length]
			if ignoringCase, (UInt8(ascii: "A") ... UInt8(ascii: "Z")).contains(byte) {
				byte += 32
			}
			guard byte == reference[length] else {
				break
			}
			length += 1
		}
		guard length > 0 else {
			return nil
		}
		defer { cursor += length }
		return String(decoding: bytes[cursor ..< cursor + length], as: UTF8.self)
	}

	/// The text up to `end` or the end of the input, which is empty when `end` comes first, or nil
	/// at the end already.
	mutating func getUntil(_ end: Int) -> String? {
		guard !isAtEnd else {
			return nil
		}
		let start = cursor
		while let next = Self.character(in: bytes, at: cursor), Int(next.scalar.value) != end {
			cursor = next.end
		}
		return String(decoding: bytes[start ..< cursor], as: UTF8.self)
	}

	mutating func getCharacter() -> Int? {
		guard !isAtEnd else {
			return nil
		}
		defer { cursor += 1 }
		return peek()
	}

	mutating func getDigit() -> Int? {
		guard isLatinDigit(peek()) else {
			return nil
		}
		defer { cursor += 1 }
		return peek() - ascii("0")
	}

	/// Exactly `count` digits.
	mutating func getDigits(count: Int) -> Int? {
		guard (cursor ..< cursor + count).allSatisfy({ isLatinDigit(byte(at: $0)) }) else {
			return nil
		}
		defer { cursor += count }
		return Int(String(decoding: bytes[cursor ..< cursor + count], as: UTF8.self))
	}

	/// Every digit there is, saturating as `strtoimax` does.
	mutating func getDigits() -> Int? {
		let start = cursor
		while isLatinDigit(peek()) {
			cursor += 1
		}
		guard cursor > start else {
			return nil
		}
		return Int(String(decoding: bytes[start ..< cursor], as: UTF8.self)) ?? .max
	}

	/// `[+-]? digit+ [. digit*]`, read with `strtod`.
	mutating func getDecimal() -> Double? {
		var index = cursor
		if byte(at: index) == ascii("-") || byte(at: index) == ascii("+") {
			index += 1
		}
		guard isLatinDigit(byte(at: index)) else {
			return nil
		}
		while isLatinDigit(byte(at: index)) {
			index += 1
		}
		if byte(at: index) == ascii(".") {
			index += 1
			while isLatinDigit(byte(at: index)) {
				index += 1
			}
		}
		defer { cursor = index }
		return strtod(String(decoding: bytes[cursor ..< index], as: UTF8.self), nil)
	}

	/// The first of `options` the text starts with.
	mutating func getOneOf(_ options: [String]) -> String? {
		options.first { skipLiteral($0) }
	}
}

/// A character's value, to compare with `peek`.
func ascii(_ character: Unicode.Scalar) -> Int {
	Int(character.value)
}

func isLatinAlpha(_ character: Int) -> Bool {
	(ascii("A") ... ascii("Z")).contains(character)
		|| (ascii("a") ... ascii("z")).contains(character)
}

func isLatinDigit(_ character: Int) -> Bool {
	(ascii("0") ... ascii("9")).contains(character)
}

/// Whether a byte read as a signed `char` is whitespace, which only ASCII can be.
func isWhitespace(_ character: Int) -> Bool {
	character > 0 && isUnicodeWhitespace(Unicode.Scalar(UInt8(character)))
}

/// libshared's whitespace list.
func isUnicodeWhitespace(_ scalar: Unicode.Scalar) -> Bool {
	switch scalar.value {
	case 0x09 ... 0x0D, 0x20, 0x85, 0xA0, 0x1680, 0x180E, 0x2000 ... 0x200D, 0x2028, 0x2029, 0x202F,
	     0x205F, 0x2060, 0x3000:
		true

	default:
		false
	}
}
