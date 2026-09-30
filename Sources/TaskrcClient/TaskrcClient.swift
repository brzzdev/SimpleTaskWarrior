// Loads, watches and reloads the Taskrc a window runs on.
public import ComposableArchitecture
import Darwin
import Dispatch
public import Foundation
public import Taskrc

@DependencyClient
public struct TaskrcClient: Sendable {
	/// Parses the Taskrc that `taskrc` returns, or the one the CLI reads by default when it returns
	/// nil, then parses it again whenever it or an include it read changes. Calls `taskrc` before
	/// every parse, so a Taskrc that was moved or replaced is found again. With neither, yields TW's
	/// defaults, which become the last good Taskrc, until a default Taskrc appears; a Debug build has
	/// none, so it waits for a pairing. Until a parse succeeds, a broken Taskrc runs on `lastGood`.
	public var load: @Sendable (
		_ taskrc: @escaping @Sendable () -> URL?,
		_ lastGood: Taskrc,
	) -> AsyncStream<Loaded> = { _, _ in .finished }
}

extension TaskrcClient {
	public struct Loaded: Equatable, Sendable {
		/// Whether the Taskrc is the one paired with the window's Replica, not the CLI's default.
		public var isPaired: Bool
		/// The latest parse's problem, one TW refuses to run on where there is one. Then `taskrc` is
		/// an earlier parse.
		public var problem: Taskrc.Problem?
		/// The latest parse TW would run on, or TW's defaults when there's none.
		public var taskrc: Taskrc
		/// The Taskrc's file, or nil on TW's defaults.
		public var url: URL?

		public init(
			isPaired: Bool = false,
			problem: Taskrc.Problem? = nil,
			taskrc: Taskrc,
			url: URL?,
		) {
			self.isPaired = isPaired
			self.problem = problem
			self.taskrc = taskrc
			self.url = url
		}
	}
}

/// How long a change settles before the Taskrc is parsed again, so an editor's several writes
/// parse once.
private let debounce = Duration.milliseconds(250)

/// How often the Taskrc is parsed again while a file it names is missing or unreadable, or looked
/// for while there's none, since there's no file to watch until one appears.
private let missingFilePoll = Duration.seconds(2)

extension TaskrcClient: DependencyKey {
	public static let liveValue = Self(
		load: { taskrc, lastGood in
			AsyncStream { continuation in
				let loading = _Concurrency.Task {
					var lastGood = lastGood
					var lastLoaded: Loaded?
					// The files the last parse read, which the next is watched over.
					var watched: [URL] = []
					// Polling parses an unchanged Taskrc again, which the window needn't hear about.
					func publish(_ loaded: Loaded) {
						if loaded != lastLoaded {
							continuation.yield(loaded)
							lastLoaded = loaded
						}
					}
					while !_Concurrency.Task.isCancelled {
						let paired = taskrc()
						guard let url = paired ?? defaultTaskrc() else {
							// The window runs on the defaults now, so a broken Taskrc that appears later keeps the
							// defaults rather than a deleted one's settings.
							lastGood = .defaults
							publish(Loaded(taskrc: lastGood, url: nil))
							watched = []
							// Waits on the default Taskrc alone, since pairing one starts another load.
							await defaultTaskrcAppears()
							continue
						}

						// Armed before reading, so a save that lands mid-parse still wakes the loop.
						let watchedChanges = changes(to: watched)
						var read: [URL] = []
						let parsed = Taskrc(path: url.path(percentEncoded: false), environment: .live) {
							path throws(Taskrc.ReadError) in
							let file = URL(filePath: path)
							let contents = try Taskrc.File(reading: file)
							read.append(file)
							return contents
						}
						let fatal = parsed.problems.first(where: \.kind.isFatal)
						if fatal == nil {
							lastGood = parsed
						}
						publish(
							Loaded(
								isPaired: paired != nil,
								problem: fatal ?? parsed.problems.first,
								taskrc: lastGood,
								url: url,
							),
						)

						// A file the watch didn't cover may have changed unseen, so parse again under a watch that
						// does.
						guard read == watched else {
							watched = read
							continue
						}
						let isMissingFiles = parsed.problems.contains(where: \.kind.isUnreachableFile)
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

#if DEBUG
// A Debug build never reads the CLI's default Taskrc, so a development session can't pick up real
// settings by accident. It runs on TW's defaults until a Taskrc is paired.

private func defaultTaskrc() -> URL? {
	nil
}

/// Returns once cancelled. Nothing yields to this stream, and dropping its continuation doesn't
/// finish it, so only cancellation ends the iteration.
private func defaultTaskrcAppears() async {
	let never = AsyncStream<Void> { _ in }
	for await _ in never {}
}
#else
/// The Taskrc the CLI reads when nothing names another, unless there's no file at its path. TW
/// runs on its defaults without one. One the app can't reach is still returned, so its parse
/// reports it unreadable rather than dropping the window to the defaults.
private func defaultTaskrc() -> URL? {
	guard let path = Taskrc.Environment.live.taskrcPath else {
		return nil
	}
	// `ENOTDIR` when a folder on the path is a file, which leaves no file there either.
	let isAbsent = access(path, F_OK) != 0 && (errno == ENOENT || errno == ENOTDIR)
	guard !isAbsent else {
		return nil
	}
	return URL(filePath: path)
}

/// Returns once there's a default Taskrc, or once cancelled.
private func defaultTaskrcAppears() async {
	while defaultTaskrc() == nil, !_Concurrency.Task.isCancelled {
		try? await _Concurrency.Task.sleep(for: missingFilePoll)
	}
}
#endif

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

/// Yields when any of `files` is written, renamed or deleted, or a symlink among them is replaced.
/// The CLI's `task config` and `task context` write in place, an editor's atomic save arrives as a
/// delete, and so does a dotfile manager repointing its link.
private func changes(to files: [URL]) -> AsyncStream<Void> {
	AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
		let sources = files.flatMap { file in
			let path = file.path(percentEncoded: false)
			let flags = isSymlink(path) ? [O_EVTONLY, O_EVTONLY | O_SYMLINK] : [O_EVTONLY]
			return flags.compactMap { flags in
				watch(path, flags: flags) { continuation.yield() }
			}
		}
		continuation.onTermination = { _ in
			for source in sources {
				source.cancel()
			}
		}
	}
}

/// Whether the file at `path` is a symlink.
private func isSymlink(_ path: String) -> Bool {
	var info = stat()
	return lstat(path, &info) == 0 && info.st_mode & S_IFMT == S_IFLNK
}

/// A source calling `changed` when the file `open` finds at `path` with `flags` is written,
/// renamed or deleted, or nil when it can't be opened. `O_SYMLINK` opens a symlink itself.
private func watch(
	_ path: String,
	flags: Int32,
	changed: @escaping @Sendable () -> Void,
) -> (any DispatchSourceFileSystemObject)? {
	let descriptor = open(path, flags)
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
