import AppKit
import OSLog
import StwEngine

// Spike: every result goes to the unified log, read with
// `log show --predicate 'subsystem == "me.brzz.stwspike"'`.
let log = Logger(subsystem: "me.brzz.stwspike", category: "spike")

enum BookmarkKey: String {
	case replica
	case taskrc
}

@MainActor
final class Delegate: NSObject, NSApplicationDelegate {
	var engine: Engine?
	var lastDataVersion: Int64?
	var taskrcSource: DispatchSourceFileSystemObject?
	var taskrcURL: URL?

	func applicationDidFinishLaunching(_ notification: Notification) {
		log.notice("launched, sandboxed=\(ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil, privacy: .public)")
		if let url = resolve(.replica) { openReplica(url) }
		if let url = resolve(.taskrc) { watchTaskrc(url) }
		Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { _ in
			MainActor.assumeIsolated { self.pollDataVersion() }
		}
	}

	func application(_ application: NSApplication, open urls: [URL]) {
		for url in urls {
			if url.scheme == "stwspike" {
				handle(command: url)
				continue
			}
			let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory
			let key: BookmarkKey = isDirectory == true ? .replica : .taskrc
			store(url, as: key)
			// Prove the bookmark, not the open event's grant, by resolving it back.
			guard let resolved = resolve(key) else { continue }
			key == .replica ? openReplica(resolved) : watchTaskrc(resolved)
		}
	}

	func store(_ url: URL, as key: BookmarkKey) {
		do {
			let data = try url.bookmarkData(options: .withSecurityScope)
			UserDefaults.standard.set(data, forKey: key.rawValue)
			log.notice("stored \(key.rawValue, privacy: .public) bookmark for \(url.path, privacy: .public)")
		} catch {
			log.error("bookmark \(key.rawValue, privacy: .public) failed: \(error, privacy: .public)")
		}
	}

	func resolve(_ key: BookmarkKey) -> URL? {
		guard let data = UserDefaults.standard.data(forKey: key.rawValue) else { return nil }
		do {
			var isStale = false
			let url = try URL(
				resolvingBookmarkData: data,
				options: .withSecurityScope,
				bookmarkDataIsStale: &isStale,
			)
			let accessing = url.startAccessingSecurityScopedResource()
			log.notice("resolved \(key.rawValue, privacy: .public) → \(url.path, privacy: .public) stale=\(isStale, privacy: .public) accessing=\(accessing, privacy: .public)")
			if isStale { store(url, as: key) }
			return url
		} catch {
			log.error("resolve \(key.rawValue, privacy: .public) failed: \(error, privacy: .public)")
			return nil
		}
	}

	func openReplica(_ url: URL) {
		do {
			let engine = try Engine.open(directory: url.path)
			self.engine = engine
			let version = try engine.dataVersion()
			lastDataVersion = version
			let sqlite = try engine.sqliteVersion()
			let pending = try engine.pendingDescriptions().count
			log.notice("opened replica sqlite=\(sqlite, privacy: .public) data_version=\(version, privacy: .public) pending=\(pending, privacy: .public)")
		} catch {
			log.error("open replica failed: \(error, privacy: .public)")
		}
	}

	func pollDataVersion() {
		guard let engine else { return }
		do {
			let version = try engine.dataVersion()
			guard version != lastDataVersion else { return }
			lastDataVersion = version
			let pending = try engine.pendingDescriptions()
			log.notice("data_version → \(version, privacy: .public), pending=\(pending.sorted(), privacy: .public)")
		} catch {
			log.error("poll failed: \(error, privacy: .public)")
		}
	}

	func handle(command url: URL) {
		guard let engine else {
			log.error("command \(url, privacy: .public) with no replica")
			return
		}
		let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
		let argument = items.first?.value ?? ""
		let command = url.host() ?? ""
		// Off the main actor: a commit may wait up to 5s on the CLI's lock.
		Task.detached {
			let start = ContinuousClock.now
			do {
				switch command {
				case "add":
					let uuid = try engine.addTask(description: argument)
					log.notice("add '\(argument, privacy: .public)' ok uuid=\(uuid, privacy: .public) in \(start.duration(to: .now), privacy: .public)")
				case "hold":
					log.notice("hold \(argument, privacy: .public)s begin")
					try engine.holdWriteLock(seconds: Double(argument) ?? 1)
					log.notice("hold released after \(start.duration(to: .now), privacy: .public)")
				default:
					log.error("unknown command \(command, privacy: .public)")
				}
			} catch {
				log.error("\(command, privacy: .public) '\(argument, privacy: .public)' failed after \(start.duration(to: .now), privacy: .public): \(error, privacy: .public)")
			}
		}
	}

	func watchTaskrc(_ url: URL) {
		taskrcURL = url
		taskrcSource?.cancel()
		let descriptor = open(url.path, O_EVTONLY)
		guard descriptor >= 0 else {
			log.error("taskrc open failed errno=\(errno, privacy: .public)")
			return
		}
		logTaskrc(reason: "watch armed")
		let source = DispatchSource.makeFileSystemObjectSource(
			fileDescriptor: descriptor,
			eventMask: [.attrib, .delete, .extend, .rename, .write],
			queue: .main,
		)
		source.setEventHandler { [weak self] in
			MainActor.assumeIsolated {
				guard let self, let source = self.taskrcSource else { return }
				let event = source.data
				self.logTaskrc(reason: "event \(event.rawValue)")
				// Replaced rather than rewritten: the descriptor now points at the old inode.
				guard event.contains(.delete) || event.contains(.rename) else { return }
				DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
					self.watchTaskrc(url)
				}
			}
		}
		source.setCancelHandler { close(descriptor) }
		taskrcSource = source
		source.resume()
	}

	func logTaskrc(reason: String) {
		guard let url = taskrcURL else { return }
		let inode = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.systemFileNumber]
		do {
			let text = try String(contentsOf: url, encoding: .utf8)
			let context = text.split(separator: "\n").last { $0.hasPrefix("context=") } ?? "context unset"
			log.notice("taskrc \(reason, privacy: .public): inode=\(String(describing: inode), privacy: .public) readable bytes=\(text.utf8.count, privacy: .public) \(context, privacy: .public)")
		} catch {
			log.error("taskrc \(reason, privacy: .public): inode=\(String(describing: inode), privacy: .public) unreadable: \(error, privacy: .public)")
		}
	}
}

let app = NSApplication.shared
let delegate = Delegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
