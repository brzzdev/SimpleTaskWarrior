// Fixtures shared by the test targets.
public import Foundation
public import Taskrc

extension Taskrc {
	/// Parses the Taskrc at `url` from disk, in the environment `just fixtures` records in.
	public init(fixture url: URL) {
		self.init(path: url.path(percentEncoded: false), environment: .fixture) {
			path, _ throws(Self.ReadError) in
			let url = URL(filePath: path)
			// Decoded by hand, since `String(contentsOf:encoding:)` drops a BOM the parser must handle.
			guard let data = try? Data(contentsOf: url) else {
				throw .notFound
			}
			return Self.File(
				contents: String(decoding: data, as: UTF8.self),
				realPath: url.resolvingSymlinksInPath().path(percentEncoded: false),
			)
		}
	}
}

extension Taskrc.Environment {
	/// The environment `just fixtures` records in.
	public static let fixture = Self(
		homeDirectory: { $0 == "root" ? "/var/root" : nil },
		variables: ["FIXTURE": "value", "HOME": "/home/fixture", "USER": "fixture"],
	)
}
