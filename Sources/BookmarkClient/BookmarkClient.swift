// Bookmarks for Replicas and the Taskrcs paired with them.
public import ComposableArchitecture
public import Foundation
import Synchronization

@DependencyClient
public struct BookmarkClient: Sendable {
	/// Yields whenever any window pairs or detaches a Taskrc. A stale bookmark re-saved doesn't
	/// count, since it resolves where it did before.
	public var changes: @Sendable () -> AsyncStream<Void> = { .finished }
	public var create: @Sendable (_ url: URL) throws -> Data
	/// Pairs the Taskrc paired with the Replica last in `replica` with the one in `newReplica`, which
	/// `bookmark` locates, instead, dropping any the latter had. The first may be gone, so where its
	/// bookmark no longer resolves, it's found by the path the bookmark was made at.
	public var movePairing: @Sendable (_ replica: URL, _ newReplica: URL, _ bookmark: Data) -> Void
	/// The bookmarked URL, which follows a folder that moved, and a fresh bookmark to keep in place
	/// of `bookmark` where it's stale.
	public var resolve: @Sendable (_ bookmark: Data) throws -> (url: URL, refreshed: Data?)
	/// Pairs `taskrc` with the Replica in `replica`, or detaches the Replica's Taskrc when nil.
	public var saveTaskrc: @Sendable (_ taskrc: URL?, _ replica: URL) throws -> Void
	/// The Taskrc paired with the Replica in `replica`, re-saving a stale bookmark. Where the
	/// bookmark no longer resolves, the path it was made at, so reading it reports the file missing.
	public var taskrc: @Sendable (_ replica: URL) -> URL?
}

extension BookmarkClient: DependencyKey {
	public static let liveValue = Self(
		changes: {
			AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
				let id = UUID()
				changeContinuations.withLock { $0[id] = continuation }
				continuation.onTermination = { _ in
					changeContinuations.withLock { $0[id] = nil }
				}
			}
		},
		create: { url in
			try url.bookmarkData()
		},
		movePairing: { replica, newReplica, bookmark in
			update { stored in
				guard
					let index = pairingIndex(of: replica, in: &stored)
					?? lostPairingIndex(of: replica, in: stored)
				else {
					return
				}
				var pairing = stored.pairings.remove(at: index)
				pairing.replica = bookmark
				if let replaced = pairingIndex(of: newReplica, in: &stored) {
					stored.pairings.remove(at: replaced)
				}
				stored.pairings.append(pairing)
			}
			notifyChanges()
		},
		resolve: { bookmark in
			// A stale bookmark still resolves, to where the folder moved, or to one made at its path since.
			try refreshed(bookmark)
		},
		saveTaskrc: { taskrc, replica in
			let pairing = try taskrc.map { try Pairing(
				replica: replica.bookmarkData(),
				taskrc: $0.bookmarkData(),
			) }
			update { stored in
				switch (pairingIndex(of: replica, in: &stored), pairing) {
				case let (index?, pairing?):
					stored.pairings[index] = pairing

				case let (index?, nil):
					stored.pairings.remove(at: index)

				case let (nil, pairing?):
					stored.pairings.append(pairing)

				case (nil, nil):
					break
				}
			}
			notifyChanges()
		},
		taskrc: { replica in
			update { stored -> URL? in
				guard let index = pairingIndex(of: replica, in: &stored) else {
					return nil
				}
				let bookmark = stored.pairings[index].taskrc
				return url(of: bookmark) { stored.pairings[index].taskrc = $0 } ?? bookmarkPath(bookmark)
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

/// Every live `changes` stream, by an id its termination removes it with.
private let changeContinuations = Mutex<[UUID: AsyncStream<Void>.Continuation]>([:])

/// Tells every `changes` stream that a window saved a pairing.
private func notifyChanges() {
	changeContinuations.withLock { continuations in
		for continuation in continuations.values {
			continuation.yield()
		}
	}
}

/// A Taskrc and the Replica it's paired with, by bookmark on each, so the pairing follows a
/// Replica that moves and isn't inherited by another later made at its old path.
private struct Pairing: Codable, Equatable {
	var replica: Data
	var taskrc: Data
}

/// The index of the pairing whose Replica bookmark no longer resolves, but was made at the folder
/// `replica`. Only moving a pairing looks for one, so a Replica later made at that path doesn't
/// inherit it.
private func lostPairingIndex(of replica: URL, in stored: Stored) -> Int? {
	stored.pairings.firstIndex { pairing in
		(try? resolved(pairing.replica)) == nil
			&& bookmarkPath(pairing.replica).map(standardizedFolder) == standardizedFolder(replica)
	}
}

/// The index of the pairing whose Replica bookmark resolves to the folder `replica`, re-saving any
/// stale Replica bookmark it resolves on the way.
private func pairingIndex(of replica: URL, in stored: inout Stored) -> Int? {
	stored.pairings.indices.first { index in
		url(of: stored.pairings[index].replica) { stored.pairings[index].replica = $0 }
			.map(standardizedFolder) == standardizedFolder(replica)
	}
}

/// The path `bookmark` was made at, which it records even once it no longer resolves.
public func bookmarkPath(_ bookmark: Data) -> URL? {
	URL.resourceValues(forKeys: [.pathKey], fromBookmarkData: bookmark)?.path.map { URL(filePath: $0) }
}

/// The folder at `url`, standardized so two spellings of it compare equal: how the app tells
/// whether two URLs name the same Replica.
public func standardizedFolder(_ url: URL) -> URL {
	URL(filePath: url.path(percentEncoded: false), directoryHint: .isDirectory).standardizedFileURL
}

/// The URL `bookmark` resolves to, and whether the bookmark is stale and wants saving again.
private func resolved(_ bookmark: Data) throws -> (url: URL, isStale: Bool) {
	var isStale = false
	let url = try URL(resolvingBookmarkData: bookmark, bookmarkDataIsStale: &isStale)
	return (url, isStale)
}

/// The bookmarks the app keeps.
private struct Stored: Codable, Equatable {
	var pairings: [Pairing] = []
}

private let stored = Mutex(
	UserDefaults.standard
		.data(forKey: storedKey)
		.flatMap { try? JSONDecoder().decode(Stored.self, from: $0) } ?? Stored(),
)

private let storedKey = "bookmarks"

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

/// The URL `bookmark` resolves to, and a fresh bookmark to keep in its place where it's stale.
private func refreshed(_ bookmark: Data) throws -> (url: URL, refreshed: Data?) {
	let (url, isStale) = try resolved(bookmark)
	return (url, isStale ? try? url.bookmarkData() : nil)
}

/// The URL `bookmark` resolves to, passing `resave` a fresh bookmark when it's stale.
private func url(of bookmark: Data, resave: (Data) -> Void) -> URL? {
	guard let (url, fresh) = try? refreshed(bookmark) else {
		return nil
	}
	if let fresh {
		resave(fresh)
	}
	return url
}
