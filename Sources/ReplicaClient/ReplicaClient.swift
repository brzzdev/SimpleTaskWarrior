// The only importer of the engine: one actor per open Replica.
public import ComposableArchitecture
import Dispatch
import Engine
public import Foundation
public import Models
import Synchronization

@DependencyClient
public struct ReplicaClient: Sendable {
	/// Commits `plan` as one Undo point to the Replica a `tasks` stream has open in `directory`,
	/// unless a value it read has changed since, then reads every task again. That read doesn't
	/// reach the stream, which yields only what changes after it. The window can undo the Undo
	/// point by `name`, which the Edit menu shows. Throws `lost` where the Replica's database is no
	/// longer the one the stream opened, as `undo` and `redo` do.
	public var apply: @Sendable (_ plan: WritePlan, _ name: String, _ directory: URL) async throws
		-> ApplyOutcome

	/// The database of the Replica in `directory` as it is now, nil where there's none.
	public var identity: @Sendable (_ directory: URL) -> ReplicaIdentity? = { _ in nil }

	/// Re-applies the Undo point the window last undid, as a new one it can undo again, provided
	/// nothing has written since. Reads every task again, as `apply` does.
	public var redo: @Sendable (_ directory: URL) async throws -> UndoOutcome

	/// Opens the Replica in `directory` for one window, yielding its tasks at once and again
	/// whenever anything, the CLI included, commits to it. Each read that fails yields its error,
	/// and the first to succeed after one yields the tasks whether or not they changed. Throws
	/// `lost` and closes the Replica once its database is no longer the one opened. Ending
	/// iteration closes the Replica once any open or read in flight returns.
	public var tasks: @Sendable (_ directory: URL)
		-> AsyncThrowingStream<Result<TaskSnapshot, ReplicaError>, any Error> = { _ in .finished() }

	/// Reverts the window's newest Undo point, provided it's still the Replica's newest, so a CLI
	/// change is never undone on the CLI's behalf. Reads every task again, as `apply` does.
	public var undo: @Sendable (_ directory: URL) async throws -> UndoOutcome

	/// Opens the Replica in `directory` and closes it again, so Open Replica… can refuse a folder
	/// before a window exists.
	public var validate: @Sendable (_ directory: URL) async throws -> Void
}

public struct ApplyOutcome: Equatable, Sendable {
	/// False where nothing was committed, because a value the plan read had changed.
	public var isCommitted: Bool
	/// Every task, read after the commit, or in place of it.
	public var snapshot: TaskSnapshot

	public init(isCommitted: Bool, snapshot: TaskSnapshot) {
		self.isCommitted = isCommitted
		self.snapshot = snapshot
	}
}

/// Every task in a Replica, as one read found them.
public struct TaskSnapshot: Equatable, Sendable {
	/// Counts the Replica's reads from 0. `apply` and the `tasks` stream each read, and deliver
	/// separately, so a read can arrive after a later one.
	public var readIndex: Int
	/// The name of the Undo point `redo` would re-apply, as of the read.
	public var redoName: String?
	public var tasks: [StoredTask]
	/// The name of the window's Undo point `undo` would revert, as of the read. Nil where the
	/// Replica's newest isn't the window's, such as after a CLI change.
	public var undoName: String?

	public init(
		readIndex: Int,
		redoName: String? = nil,
		tasks: [StoredTask],
		undoName: String? = nil,
	) {
		self.readIndex = readIndex
		self.redoName = redoName
		self.tasks = tasks
		self.undoName = undoName
	}
}

public struct UndoOutcome: Equatable, Sendable {
	/// False where the Undo point wasn't reverted or re-applied, or an error followed it.
	public var isApplied: Bool
	/// Every task, read after the change, or in place of it. Nil where an undo landed but the read
	/// after it failed, which the `tasks` stream's next read makes up.
	public var snapshot: TaskSnapshot?
	/// The tasks the Undo point changed.
	public var tasks: Set<Models.Task.ID>

	public init(isApplied: Bool, snapshot: TaskSnapshot?, tasks: Set<Models.Task.ID>) {
		self.isApplied = isApplied
		self.snapshot = snapshot
		self.tasks = tasks
	}
}

/// Which file a Replica's database is: its device and inode, which a move keeps and a replacement,
/// such as a recreation or a restore from backup, doesn't.
public struct ReplicaIdentity: Equatable, Sendable {
	public var device: UInt64
	public var inode: UInt64

	public init(device: UInt64, inode: UInt64) {
		self.device = device
		self.inode = inode
	}

	/// The database in `directory`, nil where there's none.
	init?(directory: URL) {
		guard let identity = databaseIdentity(directory: directory.path(percentEncoded: false)) else {
			return nil
		}
		self.init(device: identity.device, inode: identity.inode)
	}
}

public enum ReplicaError: Equatable, LocalizedError {
	/// Another connection, such as a `task` command, held the Replica's lock past the 5 s it's
	/// waited for. Nothing was written, so the call can be made again.
	case busy
	case failed(String)
	/// The Replica's database is no longer the one opened, `identity`: it moved, was replaced or is
	/// gone. Nothing was written, and nothing more will be, until a window opens it again.
	case lost(ReplicaIdentity)
	case notAReplica
	/// No window has the Replica open.
	case notOpen
	/// An undo failed, and the Replica couldn't be read to tell whether its reversal landed first.
	/// Undoing again could revert the Undo point before it.
	case undoUnconfirmed
	case unsupportedSchema

	public var errorDescription: String? {
		switch self {
		case .busy:
			"The Replica is busy. A `task` command may be holding it."

		case let .failed(message):
			message

		case .lost:
			"The Replica moved, was replaced or is gone"

		case .notAReplica:
			"This folder isn't a Taskwarrior 3 Replica"

		case .notOpen:
			"The Replica isn't open"

		case .undoUnconfirmed:
			"The change may have been undone. A `task` command may be holding the Replica."

		case .unsupportedSchema:
			"This Replica needs a newer version of SimpleTaskWarrior"
		}
	}
}

/// Each window's Replica, by the folder its `tasks` stream opened, which `apply` writes through.
private let openReplicas = Mutex<[URL: Replica]>([:])

/// How often a window checks whether anything has committed to its Replica.
private let pollInterval = Duration.milliseconds(500)

extension ReplicaClient: DependencyKey {
	public static let liveValue = Self(
		apply: { plan, name, directory in
			try await replicaErrors { try await openReplica(directory).apply(plan, name: name) }
		},
		identity: { directory in
			ReplicaIdentity(directory: directory)
		},
		redo: { directory in
			try await replicaErrors { try await openReplica(directory).redo() }
		},
		tasks: { directory in
			AsyncThrowingStream { continuation in
				let polling = _Concurrency.Task {
					do {
						let replica = try await Replica.open(directory: directory)
						// Cancelled while `open` waited, the window has closed, and one reopened on the
						// folder may have registered its own already. Checked under the lock, since a
						// window can only reopen once this one is cancelled.
						let isRegistered = openReplicas.withLock { replicas in
							guard !_Concurrency.Task.isCancelled else {
								return false
							}
							replicas[directory] = replica
							return true
						}
						guard isRegistered else {
							throw CancellationError()
						}
						defer {
							// A window reopened on the folder may have registered its own by now.
							openReplicas.withLock { replicas in
								if replicas[directory] === replica {
									replicas[directory] = nil
								}
							}
						}
						while true {
							// Before every read too: cancelling doesn't interrupt a blocked `open`, and
							// once it returns, a read would start a fresh wait on the lock.
							try _Concurrency.Task.checkCancellation()
							// A failed read retries next tick, leaving the window its last tasks.
							try await replica.publishTasksIfChanged(to: continuation)
							try await _Concurrency.Task.sleep(for: pollInterval)
						}
					} catch is CancellationError {
						continuation.finish()
					} catch {
						continuation.finish(throwing: error)
					}
				}
				continuation.onTermination = { _ in polling.cancel() }
			}
		},
		undo: { directory in
			try await replicaErrors { try await openReplica(directory).undo() }
		},
		validate: { directory in
			_ = try await Replica.open(directory: directory)
		},
	)

	public static let testValue = Self()
}

/// Runs `body`, reporting the engine's errors as the `ReplicaError`s they are.
private func replicaErrors<Value>(
	_ body: () async throws -> Value,
) async throws(ReplicaError) -> Value {
	do {
		return try await body()
	} catch {
		throw ReplicaError(error)
	}
}

/// The Replica a window's `tasks` stream has open in `directory`.
private func openReplica(_ directory: URL) throws(ReplicaError) -> Replica {
	guard let replica = openReplicas.withLock({ $0[directory] }) else {
		throw .notOpen
	}
	return replica
}

extension DependencyValues {
	public var replicaClient: ReplicaClient {
		get { self[ReplicaClient.self] }
		set { self[ReplicaClient.self] = newValue }
	}
}

/// One open Replica. Engine calls block for up to TaskChampion's 5 s lock timeout, so the
/// actor runs on its own serial queue rather than the cooperative pool, and its methods are
/// synchronous, so none of them interleave. The engine handle never leaves it.
actor Replica {
	/// One of the window's own Undo points, as it committed it.
	private struct UndoPoint {
		var name: String
		/// Exactly what the engine committed, its leading Undo point and timestamps included, which
		/// the Replica's newest undo operations must equal for it to be undone.
		var operations: [UndoOperation]

		/// What each property the point changes held before it, which a redo must find there still:
		/// only then has nothing written it since the undo. That's the first update's old value, since
		/// a later update to the same property starts from a value the point itself wrote.
		var redoExpectations: [Expectation] {
			var seen: Set<[String]> = []
			return operations.compactMap { operation in
				guard
					case let .update(uuid, property, oldValue, _, _) = operation,
					seen.insert([uuid, property]).inserted
				else {
					return nil
				}
				return Expectation(uuid: uuid, property: property, value: oldValue)
			}
		}

		var tasks: Set<Models.Task.ID> {
			Set(operations.compactMap { $0.uuid.flatMap(UUID.init(uuidString:)) })
		}
	}

	private let directory: URL
	private let engine: EngineHandle
	/// The database as it was opened, which every write checks it still is.
	private let identity: ReplicaIdentity
	private let queue: DispatchSerialQueue
	private var readCount = 0
	/// The `data_version` the last tasks were read at, nil before the first read.
	private var readVersion: Int64?
	/// The Undo point last undone, while the `data_version` read just after the undo holds: any
	/// write since, the window's own included, moves it.
	private var redoPoint: (point: UndoPoint, dataVersion: Int64)?
	/// The window's Undo points, newest last, for the window's lifetime.
	private var undoPoints: [UndoPoint] = []

	nonisolated var unownedExecutor: UnownedSerialExecutor {
		queue.asUnownedSerialExecutor()
	}

	/// Releasing the engine blocks too, while TaskChampion joins its storage thread, so the
	/// last reference is dropped on the actor's queue rather than wherever it happens to go.
	isolated deinit {}

	private init(directory: URL, queue: DispatchSerialQueue) throws(ReplicaError) {
		self.directory = directory
		self.queue = queue
		// Taken before opening, and checked again after: taken only after, a replacement landing while
		// the engine opened would be recorded in place of the database the engine has open.
		guard let identity = ReplicaIdentity(directory: directory) else {
			throw .notAReplica
		}
		self.identity = identity
		do {
			engine = try EngineHandle.open(directory: directory.path(percentEncoded: false))
		} catch {
			throw ReplicaError(error)
		}
		guard ReplicaIdentity(directory: directory) == identity else {
			throw .lost(identity)
		}
	}

	/// Opens on the actor's queue, since opening waits on a held lock like any other call. The
	/// whole actor is built there, so only it crosses back to the caller, never the engine handle.
	static func open(directory: URL) async throws(ReplicaError) -> Replica {
		let queue = DispatchSerialQueue(label: "dev.brzz.SimpleTaskWarrior.Replica")
		let replica = await withCheckedContinuation { continuation in
			queue.async {
				continuation.resume(returning: Result { () throws(ReplicaError) in
					try Replica(directory: directory, queue: queue)
				})
			}
		}
		return try replica.get()
	}

	/// Commits `plan` unless the engine refuses it as stale, then reads every task again.
	func apply(_ plan: WritePlan, name: String) throws -> ApplyOutcome {
		try checkIdentity()
		let outcome = try engine.apply(
			operations: plan.operations.map(PlannedOperation.init),
			expectations: plan.expectations.map(Expectation.init),
		)
		guard case let .committed(operations) = outcome else {
			return try ApplyOutcome(isCommitted: false, snapshot: readTasks())
		}
		// A plan that changes nothing commits nothing, so there's nothing to undo.
		if !operations.isEmpty {
			undoPoints.append(UndoPoint(name: name, operations: operations))
		}
		return try ApplyOutcome(isCommitted: true, snapshot: readTasks())
	}

	/// Re-applies the Undo point last undone, through the same writes a plan makes, where nothing
	/// has written since, stamping `modified` afresh as any change does. The engine checks the
	/// point's properties just before it commits, as it does a plan's, so a CLI write landing after
	/// the `data_version` check refuses the redo, but one landing between that check and the commit
	/// still gets through, since TaskChampion can't make a commit conditional. One attempt only: a
	/// redo that fails isn't offered again.
	func redo() throws -> UndoOutcome {
		try checkIdentity()
		guard let redoPoint, try engine.dataVersion() == redoPoint.dataVersion else {
			return try notApplied()
		}
		self.redoPoint = nil
		let point = redoPoint.point
		let modified = String(Date.now.epoch)
		let outcome = try engine.apply(
			operations: point.operations.compactMap { PlannedOperation($0, modified: modified) },
			expectations: point.redoExpectations,
		)
		guard case let .committed(operations) = outcome, !operations.isEmpty else {
			return try notApplied()
		}
		undoPoints.append(UndoPoint(name: point.name, operations: operations))
		return try UndoOutcome(isApplied: true, snapshot: readTasks(), tasks: point.tasks)
	}

	/// Reverts the newest Undo point, which the engine does only while it's the Replica's newest.
	/// An error can follow a reversal that landed, so every outcome reads the tasks again, which
	/// checks the Undo points afresh. An error where the reversal didn't land, as when the lock is
	/// held, is thrown, and the point stays for another try. So is `undoUnconfirmed`, where the
	/// engine can't tell whether it landed, and the next read settles the point.
	func undo() throws -> UndoOutcome {
		try checkIdentity()
		guard
			let point = undoPoints.last,
			case let .applied(error) = try engine.commitReversedOperations(operations: point.operations)
		else {
			return try notApplied()
		}
		undoPoints.removeLast()
		// Recorded before the read, which drops it should anything write in between, so Redo outlives
		// a read that fails.
		redoPoint = nil
		if error == nil, let dataVersion = try? engine.dataVersion() {
			redoPoint = (point, dataVersion)
		}
		// The reversal has landed, so a read failing now mustn't fail the undo: trying it again would
		// revert the point before it too. The stream reads in full next time instead.
		let snapshot = try? readTasks()
		if snapshot == nil {
			readVersion = nil
		}
		return UndoOutcome(isApplied: error == nil, snapshot: snapshot, tasks: point.tasks)
	}

	/// Yields every task when anything has committed since the last read, or the error that stopped
	/// it reading. After an error the next read is in full, so the window learns reads work again.
	/// Throws `lost`, rather than reading a database that's no longer the one opened.
	func publishTasksIfChanged(
		to continuation: AsyncThrowingStream<Result<TaskSnapshot, ReplicaError>, any Error>
			.Continuation,
	) throws(ReplicaError) {
		try checkIdentity()
		do {
			guard try engine.dataVersion() != readVersion else { return }
			// Decoded by the window, with its Taskrc's UDAs.
			try continuation.yield(.success(readTasks()))
		} catch {
			readVersion = nil
			continuation.yield(.failure(ReplicaError(error)))
		}
	}

	/// Throws `lost` where the database in the Replica's folder is no longer the one opened, before a
	/// write reaches it. A replacement landing between the check and the write can't be prevented,
	/// only found on the next check.
	private func checkIdentity() throws(ReplicaError) {
		guard ReplicaIdentity(directory: directory) == identity else {
			throw .lost(identity)
		}
	}

	/// An undo or redo that changed nothing, with the tasks read again.
	private func notApplied() throws -> UndoOutcome {
		try UndoOutcome(isApplied: false, snapshot: readTasks(), tasks: [])
	}

	/// Every task, recording the `data_version` they were read at, and which Undo points still
	/// apply.
	private func readTasks() throws -> TaskSnapshot {
		let snapshot = try engine.snapshot()
		if redoPoint?.dataVersion != snapshot.dataVersion {
			redoPoint = nil
		}
		let undoName = try reconcileUndoPoints()
		let workingSetIDs = Dictionary(
			snapshot.workingSet.map { ($0.uuid, Int($0.id)) },
			uniquingKeysWith: { first, _ in first },
		)
		let tasks = snapshot.tasks.map { task in
			StoredTask(
				properties: task.properties,
				uuid: task.uuid,
				workingSetID: workingSetIDs[task.uuid],
			)
		}
		// Recorded only once the whole read succeeds, so a read that fails partway through is
		// read again on the next poll.
		readVersion = snapshot.dataVersion
		defer {
			readCount += 1
		}
		return TaskSnapshot(
			readIndex: readCount,
			redoName: redoPoint?.point.name,
			tasks: tasks,
			undoName: undoName,
		)
	}

	/// Drops the Undo points the CLI undid, and names the one `undo` would revert, if any. The log
	/// only grows or loses its newest Undo point, so points newer than the one that's the log's
	/// newest were undone by `task undo`. Where none is, they're only covered by newer writes, and
	/// revive should those be undone, so they're kept.
	private func reconcileUndoPoints() throws -> String? {
		// Reading the log costs a pass over every unsynced operation, which a window that has
		// written nothing can skip.
		guard !undoPoints.isEmpty else {
			return nil
		}
		let newest = try engine.getUndoOperations()
		guard let index = undoPoints.lastIndex(where: { $0.operations == newest }) else {
			return nil
		}
		undoPoints.removeSubrange((index + 1)...)
		return undoPoints[index].name
	}
}

extension ReplicaError {
	/// `error` as the engine or the actor threw it.
	fileprivate init(_ error: any Error) {
		switch error {
		case EngineError.Busy: self = .busy
		case let EngineError.Failed(message): self = .failed(message)
		case EngineError.NotAReplica: self = .notAReplica
		case EngineError.UndoUnconfirmed: self = .undoUnconfirmed
		case EngineError.UnsupportedSchema: self = .unsupportedSchema
		case let error as ReplicaError: self = error
		default: self = .failed(error.localizedDescription)
		}
	}
}

extension Engine.Status {
	fileprivate init(_ status: Models.Status) {
		switch status {
		case .completed: self = .completed
		case .deleted: self = .deleted
		case .pending: self = .pending
		case .recurring: self = .recurring
		}
	}
}

extension Expectation {
	fileprivate init(_ expectation: WritePlan.Expectation) {
		self.init(
			uuid: expectation.uuid.uuidString.lowercased(),
			property: expectation.property,
			value: expectation.value,
		)
	}
}

extension PlannedOperation {
	/// The write that makes `operation` again, with `modified` set to `modified`, nil for an Undo
	/// point. The app never deletes a task outright, so it never commits a delete to redo.
	fileprivate init?(_ operation: UndoOperation, modified: String) {
		switch operation {
		case let .create(uuid):
			self = .create(uuid: uuid)

		case .delete, .undoPoint:
			return nil

		case let .update(uuid, property, _, value, _):
			self = .setValue(
				uuid: uuid,
				property: property,
				value: property == "modified" ? modified : value,
			)
		}
	}

	fileprivate init(_ operation: WritePlan.Operation) {
		switch operation {
		case let .create(uuid):
			self = .create(uuid: uuid.uuidString.lowercased())

		case let .setStatus(uuid, status):
			self = .setStatus(uuid: uuid.uuidString.lowercased(), status: Engine.Status(status))

		case let .setValue(uuid, property, value):
			self = .setValue(uuid: uuid.uuidString.lowercased(), property: property, value: value)
		}
	}
}

extension UndoOperation {
	/// The task the operation changes, nil for an Undo point.
	fileprivate var uuid: String? {
		switch self {
		case let .create(uuid), let .delete(uuid, _), let .update(uuid, _, _, _, _): uuid
		case .undoPoint: nil
		}
	}
}
