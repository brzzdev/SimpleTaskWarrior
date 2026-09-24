// Loads, watches and reloads the Taskrc paired with a window.
public import ComposableArchitecture
import Darwin
import Dispatch
public import Foundation
public import Taskrc

@DependencyClient
public struct TaskrcClient: Sendable {
	/// Parses the Taskrc that `taskrc` returns, or yields TW's defaults when it returns nil, then
	/// parses it again whenever it or an include it read changes. Calls `taskrc` before every
	/// parse, so a Taskrc that was moved or replaced is found again. Reads an include through its
	/// grant where it has one, and holds the scope of every file it reads while it watches.
	public var load: @Sendable (
		_ taskrc: @escaping @Sendable () -> URL?,
		_ grants: [Taskrc.Include: URL],
	) -> AsyncStream<Loaded> = { _, _ in .finished }
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

extension TaskrcClient: DependencyKey {
	public static let liveValue = Self(
		load: { taskrc, grants in
			AsyncStream { continuation in
				let loading = _Concurrency.Task {
					let grantsInScope = grants.values.filter { $0.startAccessingSecurityScopedResource() }
					defer {
						for grant in grantsInScope {
							grant.stopAccessingSecurityScopedResource()
						}
					}
					var lastGood = Taskrc.defaults
					while !_Concurrency.Task.isCancelled {
						guard let url = taskrc() else {
							continuation.yield(Loaded(taskrc: .defaults, url: nil))
							break
						}
						// Held until the next parse, since the watchers below reopen the file.
						let isAccessing = url.startAccessingSecurityScopedResource()
						defer {
							if isAccessing {
								url.stopAccessingSecurityScopedResource()
							}
						}

						var read: [URL] = []
						let parsed = Taskrc(path: url.path(percentEncoded: false), environment: .live) {
							path, include throws(Taskrc.ReadError) in
							let file = include.flatMap { grants[$0] } ?? URL(filePath: path)
							let contents: Data
							do {
								contents = try Data(contentsOf: file)
							} catch CocoaError.fileReadNoSuchFile {
								throw .notFound
							} catch {
								throw .unreadable
							}
							read.append(file)
							// Decoded by hand, since `String(contentsOf:encoding:)` drops a BOM the parser
							// must handle.
							return Taskrc.File(
								contents: String(decoding: contents, as: UTF8.self),
								realPath: file.resolvingSymlinksInPath().path(percentEncoded: false),
							)
						}
						let fatal = parsed.problems.first(where: \.kind.isFatal)
						if fatal == nil {
							lastGood = parsed
						}
						continuation.yield(
							Loaded(problem: fatal ?? parsed.problems.first, taskrc: lastGood, url: url),
						)

						for await _ in changes(to: read) {
							break
						}
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

/// Yields when any of `files` is written, renamed or deleted. The CLI's `task config` and
/// `task context` write in place, and an editor's atomic save arrives as a delete.
private func changes(to files: [URL]) -> AsyncStream<Void> {
	AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
		let sources = files.compactMap { file -> (any DispatchSourceFileSystemObject)? in
			let descriptor = open(file.path(percentEncoded: false), O_EVTONLY)
			guard descriptor >= 0 else {
				return nil
			}
			let source = DispatchSource.makeFileSystemObjectSource(
				fileDescriptor: descriptor,
				eventMask: [.delete, .extend, .rename, .write],
				queue: .global(),
			)
			source.setEventHandler { continuation.yield() }
			source.setCancelHandler { close(descriptor) }
			source.activate()
			return source
		}
		continuation.onTermination = { _ in
			for source in sources {
				source.cancel()
			}
		}
	}
}
