// Security-scoped bookmarks for Replicas, Taskrcs and the files a Taskrc includes.
public import ComposableArchitecture
public import Foundation
import Synchronization
public import Taskrc

@DependencyClient
public struct BookmarkClient: Sendable {
	public var create: @Sendable (_ url: URL) throws -> Data
	/// The kept include grants, by the line each answers. A stale bookmark is re-saved, and one that
	/// no longer resolves is left out, so its include asks again.
	public var grants: @Sendable () -> [Taskrc.Include: URL] = { [:] }
	/// The bookmarked URL. Whatever reads it holds its security scope, as
	/// `ReplicaClient.tasks` does.
	public var resolve: @Sendable (_ bookmark: Data) throws -> URL
	/// Keeps a grant of access to `file` for the `include` line.
	public var saveGrant: @Sendable (_ file: URL, _ include: Taskrc.Include) throws -> Void
	/// Pairs `taskrc` with the Replica in `replica`, or detaches the Replica's Taskrc when nil.
	public var saveTaskrc: @Sendable (_ taskrc: URL?, _ replica: URL) throws -> Void
	/// The Taskrc paired with the Replica in `replica`, re-saving a stale bookmark. Where the
	/// bookmark no longer resolves, the path it was made at, so reading it reports the file missing.
	public var taskrc: @Sendable (_ replica: URL) -> URL?
}

extension BookmarkClient: DependencyKey {
	public static let liveValue = Self(
		create: { url in
			try makeBookmark(url)
		},
		grants: {
			update { stored in
				let grants = stored.grants
				return grants.reduce(into: [:]) { resolved, grant in
					resolved[grant.key] = url(of: grant.value) { stored.grants[grant.key] = $0 }
				}
			}
		},
		resolve: { bookmark in
			// A stale bookmark still resolves, to where the folder moved. Re-saving it is part of
			// handling a lost Replica.
			try resolved(bookmark).url
		},
		saveGrant: { file, include in
			let bookmark = try makeBookmark(file)
			update { $0.grants[include] = bookmark }
		},
		saveTaskrc: { taskrc, replica in
			let bookmark = try taskrc.map(makeBookmark)
			update { $0.taskrcs[replica.path(percentEncoded: false)] = bookmark }
		},
		taskrc: { replica in
			update { stored -> URL? in
				let key = replica.path(percentEncoded: false)
				guard let bookmark = stored.taskrcs[key] else {
					return nil
				}
				return url(of: bookmark) { stored.taskrcs[key] = $0 }
					?? URL.resourceValues(forKeys: [.pathKey], fromBookmarkData: bookmark)?
					.path
					.map { URL(filePath: $0) }
			}
		},
	)

	public static let testValue = Self()
}

extension DependencyValues {
	public var bookmarkClient: BookmarkClient {
		get { self[BookmarkClient.self] }
		set { self[BookmarkClient.self] = newValue }
	}
}

/// The bookmarks the app keeps.
private struct Stored: Codable, Equatable {
	var grants: [Taskrc.Include: Data] = [:]
	/// Taskrc bookmarks by the path of the Replica they're paired with.
	var taskrcs: [String: Data] = [:]
}

private let storedKey = "bookmarks"

private let stored = Mutex(
	UserDefaults.standard
		.data(forKey: storedKey)
		.flatMap { try? JSONDecoder().decode(Stored.self, from: $0) } ?? Stored(),
)

/// Runs `body` on the kept bookmarks, then saves them to the user defaults if it changed them.
private func update<Result>(_ body: (inout Stored) -> Result) -> Result {
	stored.withLock { stored in
		let old = stored
		let result = body(&stored)
		if stored != old {
			UserDefaults.standard.set(try? JSONEncoder().encode(stored), forKey: storedKey)
		}
		return result
	}
}

/// A security-scoped bookmark on `url`, which it can make only inside the scope of a URL from a
/// file panel or another bookmark.
private func makeBookmark(_ url: URL) throws -> Data {
	let isAccessing = url.startAccessingSecurityScopedResource()
	defer {
		if isAccessing {
			url.stopAccessingSecurityScopedResource()
		}
	}
	return try url.bookmarkData(
		options: .withSecurityScope,
		includingResourceValuesForKeys: nil,
		relativeTo: nil,
	)
}

/// The URL `bookmark` resolves to, and whether the bookmark is stale and wants saving again.
private func resolved(_ bookmark: Data) throws -> (url: URL, isStale: Bool) {
	var isStale = false
	let url = try URL(
		resolvingBookmarkData: bookmark,
		options: .withSecurityScope,
		relativeTo: nil,
		bookmarkDataIsStale: &isStale,
	)
	return (url, isStale)
}

/// The URL `bookmark` resolves to, passing `resave` a fresh bookmark when it's stale.
private func url(of bookmark: Data, resave: (Data) -> Void) -> URL? {
	guard let (url, isStale) = try? resolved(bookmark) else {
		return nil
	}
	if isStale, let fresh = try? makeBookmark(url) {
		resave(fresh)
	}
	return url
}
