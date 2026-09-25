// Loads, watches and reloads the Taskrc paired with a window.
public import ComposableArchitecture
import Darwin
import Dispatch
public import Foundation
public import Taskrc

@DependencyClient
public struct TaskrcClient: Sendable {
	/// Parses the Taskrc that `taskrc` returns, or yields TW's defaults when it returns nil, then
	/// parses it again whenever it or an include it read changes. Calls `taskrc` and `grants`
	/// before every parse, so a Taskrc that was moved or replaced is found again, and a grant made
	/// in another window is picked up. Reads an include through its grant where it has one, and
	/// holds the scope of every file it reads while it watches. Until a parse succeeds, a broken
	/// Taskrc runs on `lastGood`.
	public var load: @Sendable (
		_ taskrc: @escaping @Sendable () -> URL?,
		_ grants: @escaping @Sendable () -> [Taskrc.Include: URL],
		_ lastGood: Taskrc,
	) -> AsyncStream<Loaded> = { _, _, _ in .finished }
}

extension TaskrcClient {
	public struct Loaded: Equatable, Sendable {
		/// The latest parse's problem, one TW refuses to run on where there is one. Then `taskrc` is
		/// an earlier parse.
		public var problem: Taskrc.Problem?
		/// The latest parse TW would run on, or TW's defaults when there's none.
		public var taskrc: Taskrc
		/// The Taskrc's file, or nil on TW's defaults.
		public var url: URL?

		public init(problem: Taskrc.Problem? = nil, taskrc: Taskrc, url: URL?) {
			self.problem = problem
			self.taskrc = taskrc
			self.url = url
		}
	}
}

/// How long a change settles before the Taskrc is parsed again, so an editor's several writes
/// parse once.
private let debounce = Duration.milliseconds(250)

/// How often the Taskrc is parsed again while a file it names is missing or unreadable, since
/// there's no file to watch until one appears.
private let missingFilePoll = Duration.seconds(2)

extension TaskrcClient: DependencyKey {
	public static let liveValue = Self(
		load: { taskrc, grants, lastGood in
			AsyncStream { continuation in
				let loading = _Concurrency.Task {
					var lastGood = lastGood
					var lastLoaded: Loaded?
					// The files the last parse read, which the next is watched over.
					var watched: [URL] = []
					while !_Concurrency.Task.isCancelled {
						guard let url = taskrc() else {
							continuation.yield(Loaded(taskrc: .defaults, url: nil))
							break
						}
						// Held until the next parse, since the watchers below reopen the files.
						let grants = grants()
						let inScope = ([url] + grants.values).filter {
							$0.startAccessingSecurityScopedResource()
						}
						defer {
							for file in inScope {
								file.stopAccessingSecurityScopedResource()
							}
						}

						// Armed before reading, so a save that lands mid-parse still wakes the loop.
						let watchedChanges = changes(to: watched)
						var read: [URL] = []
						let parsed = Taskrc(path: url.path(percentEncoded: false), environment: .live) {
							path, include throws(Taskrc.ReadError) in
							let file = include.flatMap { grants[$0] } ?? URL(filePath: path)
							let contents = try Taskrc.File(reading: file)
							read.append(file)
							return contents
						}
						let fatal = parsed.problems.first(where: \.kind.isFatal)
						if fatal == nil {
							lastGood = parsed
						}
						let loaded = Loaded(problem: fatal ?? parsed.problems.first, taskrc: lastGood, url: url)
						// Polling parses an unchanged Taskrc again, which the window needn't hear about.
						if loaded != lastLoaded {
							continuation.yield(loaded)
							lastLoaded = loaded
						}

						// A file the watch didn't cover may have changed unseen, so parse again under a watch that
						// does.
						guard read == watched else {
							watched = read
							continue
						}
						let isMissingFiles = parsed.problems.contains { problem in
							switch problem.kind {
							case .notFound, .unreadable: true
							default: false
							}
						}
						await firstChange(in: watchedChanges, orAfter: isMissingFiles ? missingFilePoll : nil)
						try? await _Concurrency.Task.sleep(for: debounce)
					}
					continuation.finish()
				}
				continuation.onTermination = { _ in loading.cancel() }
			}
		},
	)

	public static let testValue = Self()
}

extension DependencyValues {
	public var taskrcClient: TaskrcClient {
		get { self[TaskrcClient.self] }
		set { self[TaskrcClient.self] = newValue }
	}
}

/// Returns once `changes` yields, or after `timeout` when there is one.
private func firstChange(in changes: AsyncStream<Void>, orAfter timeout: Duration?) async {
	await withTaskGroup { group in
		group.addTask {
			for await _ in changes {
				return
			}
		}
		if let timeout {
			group.addTask {
				try? await _Concurrency.Task.sleep(for: timeout)
			}
		}
		await group.next()
		group.cancelAll()
	}
}

/// Yields when any of `files` is written, renamed or deleted. The CLI's `task config` and
/// `task context` write in place, and an editor's atomic save arrives as a delete.
private func changes(to files: [URL]) -> AsyncStream<Void> {
	AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
		let sources = files.compactMap { file in
			watch(file.path(percentEncoded: false)) { continuation.yield() }
		}
		continuation.onTermination = { _ in
			for source in sources {
				source.cancel()
			}
		}
	}
}

/// A source calling `changed` when the file at `path` is written, renamed or deleted, or nil when
/// it can't be opened.
private func watch(
	_ path: String,
	changed: @escaping @Sendable () -> Void,
) -> (any DispatchSourceFileSystemObject)? {
	let descriptor = open(path, O_EVTONLY)
	guard descriptor >= 0 else {
		return nil
	}
	let source = DispatchSource.makeFileSystemObjectSource(
		fileDescriptor: descriptor,
		eventMask: [.delete, .extend, .rename, .write],
		queue: .global(),
	)
	source.setEventHandler(handler: changed)
	source.setCancelHandler { close(descriptor) }
	source.activate()
	return source
}
