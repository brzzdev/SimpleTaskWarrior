// Fixtures shared by the test targets.
public import Foundation
public import Taskrc

extension Taskrc {
	/// Parses the Taskrc at `url` from disk, in the environment `just fixtures` records in.
	public init(fixture url: URL) {
		self
			.init(
				path: url.path(percentEncoded: false),
				environment: .fixture,
			) { path, _ throws(Self.ReadError) in
				try Self.File(reading: URL(filePath: path))
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
