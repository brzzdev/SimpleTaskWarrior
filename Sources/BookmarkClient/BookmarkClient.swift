// Security-scoped bookmarks for Replicas, Taskrcs and the files a Taskrc includes.
public import ComposableArchitecture
public import Foundation

@DependencyClient
public struct BookmarkClient: Sendable {
	public var create: @Sendable (_ url: URL) throws -> Data
	/// The bookmarked URL. Whatever reads it holds its security scope, as
	/// `ReplicaClient.tasks` does.
	public var resolve: @Sendable (_ bookmark: Data) throws -> URL
}

extension BookmarkClient: DependencyKey {
	public static let liveValue = Self(
		create: { url in
			try url.bookmarkData(
				options: .withSecurityScope,
				includingResourceValuesForKeys: nil,
				relativeTo: nil,
			)
		},
		resolve: { bookmark in
			// A stale bookmark still resolves, to where the folder moved. Re-saving it is part of
			// handling a lost Replica.
			var isStale = false
			return try URL(
				resolvingBookmarkData: bookmark,
				options: .withSecurityScope,
				relativeTo: nil,
				bookmarkDataIsStale: &isStale,
			)
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
